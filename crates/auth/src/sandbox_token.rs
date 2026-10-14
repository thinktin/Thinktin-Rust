//! 沙箱令牌（架构方案 4.6、5.6，WBS 4.4）：唯一进沙箱的凭证。
//!
//! - 由编排服务在唤醒沙箱时用运行授权换出，控制面用 Ed25519 私钥签发；模型网关只持有公钥。
//! - 绑定实例、用户、运行授权、沙箱 id 和沙箱的网络身份（网关看到的来源地址）。
//!   令牌被带出沙箱也用不了；每次唤醒换新沙箱 id，旧令牌随之失效（网关核对实例当前的沙箱 id）。
//! - 格式：`tts1.<kid>.<base64url(claims JSON)>.<base64url(签名)>`，签名覆盖前三段。
//!   `kid` 标识签名密钥，便于轮换。

use serde::{Deserialize, Serialize};

use crate::signed::{self, Signer25519, TimedClaims, Verifier25519};
pub use crate::signed::{LEEWAY_SECS, TokenError, redact};

const PREFIX: &str = "tts1";
/// 令牌最长 7 天，防止误签出“永久”令牌。
const MAX_TTL_SECS: u64 = 7 * 24 * 3600;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxClaims {
    /// 实例 id（用户领养的一个 agent）。
    pub iid: String,
    /// 用户 id。
    pub uid: String,
    /// 运行授权 id。授权被吊销后，网关拒绝所有据它换出的令牌。
    pub grant: String,
    /// 沙箱 id，每次唤醒或重建都变。
    pub sbx: String,
    /// 沙箱的网络身份：网关应当看到的请求来源地址。为空表示不绑定（只用于本地开发）。
    pub net: Option<String>,
    pub iat: u64,
    pub exp: u64,
    /// 令牌 id，用于审计。
    pub jti: String,
}

impl TimedClaims for SandboxClaims {
    fn iat(&self) -> u64 {
        self.iat
    }
    fn exp(&self) -> u64 {
        self.exp
    }
}

/// 签发方（控制面）。
pub struct SandboxTokenIssuer(Signer25519);

/// 签发时调用方提供的字段；时间和 jti 由签发方填。
#[derive(Debug, Clone)]
pub struct TokenRequest {
    pub iid: String,
    pub uid: String,
    pub grant: String,
    pub sbx: String,
    pub net: Option<String>,
}

impl SandboxTokenIssuer {
    pub fn new(kid: impl Into<String>, key: ed25519_dalek::SigningKey) -> Self {
        Self(Signer25519::new(kid, key))
    }

    /// 生成新的签名密钥。
    pub fn generate(kid: impl Into<String>) -> Result<Self, TokenError> {
        Signer25519::generate(kid).map(Self)
    }

    /// 从 base64url 编码的 32 字节私钥种子创建。
    pub fn from_seed_b64(kid: impl Into<String>, seed: &str) -> Result<Self, TokenError> {
        Signer25519::from_seed_b64(kid, seed).map(Self)
    }

    pub fn seed_b64(&self) -> zeroize::Zeroizing<String> {
        self.0.seed_b64()
    }

    pub fn kid(&self) -> &str {
        self.0.kid()
    }

    pub fn verifying_key_b64(&self) -> String {
        self.0.verifying_key_b64()
    }

    pub fn issue(&self, req: TokenRequest, ttl_secs: u64, now: u64) -> Result<String, TokenError> {
        if ttl_secs == 0 || ttl_secs > MAX_TTL_SECS {
            return Err(TokenError::InvalidTtl);
        }
        let claims = SandboxClaims {
            iid: req.iid,
            uid: req.uid,
            grant: req.grant,
            sbx: req.sbx,
            net: req.net,
            iat: now,
            exp: now + ttl_secs,
            jti: signed::random_jti()?,
        };
        Ok(self.0.sign(PREFIX, &claims))
    }
}

/// 校验方（模型网关）。可同时持有多把公钥，支持签名密钥轮换。
#[derive(Default, Clone)]
pub struct SandboxTokenVerifier(Verifier25519);

impl SandboxTokenVerifier {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_key(&mut self, kid: impl Into<String>, key: ed25519_dalek::VerifyingKey) {
        self.0.add_key(kid, key);
    }

    pub fn add_key_b64(&mut self, kid: impl Into<String>, key: &str) -> Result<(), TokenError> {
        self.0.add_key_b64(kid, key)
    }

    /// 校验签名和有效期。实例、授权、沙箱是否仍然有效，以及来源地址是否匹配，由调用方核对。
    pub fn verify(&self, token: &str, now: u64) -> Result<SandboxClaims, TokenError> {
        self.0.verify(PREFIX, token, now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    fn req() -> TokenRequest {
        TokenRequest {
            iid: "inst-1".into(),
            uid: "user-1".into(),
            grant: "grant-1".into(),
            sbx: "sbx-1".into(),
            net: Some("10.1.2.3".into()),
        }
    }

    fn pair() -> (SandboxTokenIssuer, SandboxTokenVerifier) {
        let issuer = SandboxTokenIssuer::generate("k1").unwrap();
        let mut verifier = SandboxTokenVerifier::new();
        verifier
            .add_key_b64("k1", &issuer.verifying_key_b64())
            .unwrap();
        (issuer, verifier)
    }

    #[test]
    fn issue_and_verify() {
        let (issuer, verifier) = pair();
        let token = issuer.issue(req(), 3600, 1000).unwrap();
        assert!(token.starts_with("tts1.k1."));
        let claims = verifier.verify(&token, 1500).unwrap();
        assert_eq!(
            (claims.iid.as_str(), claims.sbx.as_str(), claims.exp),
            ("inst-1", "sbx-1", 4600)
        );
        assert_eq!(claims.net.as_deref(), Some("10.1.2.3"));
    }

    #[test]
    fn expiry_and_clock_skew() {
        let (issuer, verifier) = pair();
        let token = issuer.issue(req(), 60, 1000).unwrap();
        assert!(verifier.verify(&token, 1060 + LEEWAY_SECS).is_ok());
        assert_eq!(
            verifier.verify(&token, 1061 + LEEWAY_SECS),
            Err(TokenError::Expired)
        );
        assert_eq!(
            verifier.verify(&token, 1000 - LEEWAY_SECS - 1),
            Err(TokenError::NotYetValid)
        );
    }

    #[test]
    fn tampering_is_detected() {
        let (issuer, verifier) = pair();
        let token = issuer.issue(req(), 60, 1000).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        // 把实例 id 改成别人的，签名不再匹配。
        let mut claims: SandboxClaims =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
        claims.iid = "inst-2".into();
        let forged_body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        let forged = format!("{}.{}.{}.{}", parts[0], parts[1], forged_body, parts[3]);
        assert_eq!(
            verifier.verify(&forged, 1001),
            Err(TokenError::BadSignature)
        );
        // 换 kid 也不行。
        let other_kid = token.replacen("tts1.k1.", "tts1.k2.", 1);
        assert_eq!(
            verifier.verify(&other_kid, 1001),
            Err(TokenError::UnknownKey("k2".into()))
        );
        assert_eq!(
            verifier.verify("tts1.k1.x", 1001),
            Err(TokenError::Malformed)
        );
        assert_eq!(
            verifier.verify(&format!("{token}.extra"), 1001),
            Err(TokenError::Malformed)
        );
    }

    #[test]
    fn other_issuers_are_rejected() {
        let (_, verifier) = pair();
        let attacker = SandboxTokenIssuer::generate("k1").unwrap();
        let token = attacker.issue(req(), 60, 1000).unwrap();
        assert_eq!(verifier.verify(&token, 1001), Err(TokenError::BadSignature));
    }

    #[test]
    fn ttl_is_bounded_and_seed_roundtrips() {
        let (issuer, verifier) = pair();
        assert_eq!(issuer.issue(req(), 0, 1), Err(TokenError::InvalidTtl));
        assert_eq!(
            issuer.issue(req(), MAX_TTL_SECS + 1, 1),
            Err(TokenError::InvalidTtl)
        );
        let again = SandboxTokenIssuer::from_seed_b64("k1", &issuer.seed_b64()).unwrap();
        let token = again.issue(req(), 60, 1000).unwrap();
        assert!(verifier.verify(&token, 1001).is_ok());
        assert_eq!(redact(&token), "tts1.k1.***");
    }
}
