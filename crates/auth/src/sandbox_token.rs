//! 沙箱令牌（架构方案 4.6、5.6，WBS 4.4）：唯一进沙箱的凭证。
//!
//! - 由编排服务在唤醒沙箱时用运行授权换出，控制面用 Ed25519 私钥签发；模型网关只持有公钥。
//! - 绑定实例、用户、运行授权、沙箱 id 和沙箱的网络身份（网关看到的来源地址）。
//!   令牌被带出沙箱也用不了；每次唤醒换新沙箱 id，旧令牌随之失效（网关核对实例当前的沙箱 id）。
//! - 格式：`tts1.<kid>.<base64url(claims JSON)>.<base64url(签名)>`，签名覆盖前三段。
//!   `kid` 标识签名密钥，便于轮换。

use std::collections::HashMap;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const PREFIX: &str = "tts1";
/// 校验时间时允许的时钟偏差。
const LEEWAY_SECS: u64 = 30;
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

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TokenError {
    #[error("malformed sandbox token")]
    Malformed,
    #[error("unknown signing key {0}")]
    UnknownKey(String),
    #[error("bad signature")]
    BadSignature,
    #[error("token expired")]
    Expired,
    #[error("token not yet valid")]
    NotYetValid,
    #[error("invalid ttl")]
    InvalidTtl,
    #[error("random number generator failed")]
    Rng,
}

/// 签发方（控制面）。
pub struct SandboxTokenIssuer {
    kid: String,
    key: SigningKey,
}

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
    pub fn new(kid: impl Into<String>, key: SigningKey) -> Self {
        Self {
            kid: kid.into(),
            key,
        }
    }

    /// 生成新的签名密钥。
    pub fn generate(kid: impl Into<String>) -> Result<Self, TokenError> {
        let mut seed = Zeroizing::new([0u8; 32]);
        getrandom::fill(seed.as_mut()).map_err(|_| TokenError::Rng)?;
        Ok(Self::new(kid, SigningKey::from_bytes(&seed)))
    }

    /// 从 base64url 编码的 32 字节私钥种子创建。
    pub fn from_seed_b64(kid: impl Into<String>, seed: &str) -> Result<Self, TokenError> {
        let bytes = Zeroizing::new(
            URL_SAFE_NO_PAD
                .decode(seed.trim())
                .map_err(|_| TokenError::Malformed)?,
        );
        let seed: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| TokenError::Malformed)?;
        let seed = Zeroizing::new(seed);
        Ok(Self::new(kid, SigningKey::from_bytes(&seed)))
    }

    pub fn seed_b64(&self) -> Zeroizing<String> {
        Zeroizing::new(URL_SAFE_NO_PAD.encode(self.key.to_bytes()))
    }

    pub fn kid(&self) -> &str {
        &self.kid
    }

    pub fn verifying_key_b64(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.key.verifying_key().to_bytes())
    }

    pub fn issue(&self, req: TokenRequest, ttl_secs: u64, now: u64) -> Result<String, TokenError> {
        if ttl_secs == 0 || ttl_secs > MAX_TTL_SECS {
            return Err(TokenError::InvalidTtl);
        }
        let mut jti = [0u8; 12];
        getrandom::fill(&mut jti).map_err(|_| TokenError::Rng)?;
        let claims = SandboxClaims {
            iid: req.iid,
            uid: req.uid,
            grant: req.grant,
            sbx: req.sbx,
            net: req.net,
            iat: now,
            exp: now + ttl_secs,
            jti: URL_SAFE_NO_PAD.encode(jti),
        };
        let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).expect("claims serialize"));
        let signed = format!("{PREFIX}.{}.{body}", self.kid);
        let sig = self.key.sign(signed.as_bytes());
        Ok(format!(
            "{signed}.{}",
            URL_SAFE_NO_PAD.encode(sig.to_bytes())
        ))
    }
}

/// 校验方（模型网关）。可同时持有多把公钥，支持签名密钥轮换。
#[derive(Default, Clone)]
pub struct SandboxTokenVerifier {
    keys: HashMap<String, VerifyingKey>,
}

impl SandboxTokenVerifier {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_key(&mut self, kid: impl Into<String>, key: VerifyingKey) {
        self.keys.insert(kid.into(), key);
    }

    pub fn add_key_b64(&mut self, kid: impl Into<String>, key: &str) -> Result<(), TokenError> {
        let bytes = URL_SAFE_NO_PAD
            .decode(key.trim())
            .map_err(|_| TokenError::Malformed)?;
        let bytes: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| TokenError::Malformed)?;
        let key = VerifyingKey::from_bytes(&bytes).map_err(|_| TokenError::Malformed)?;
        self.add_key(kid, key);
        Ok(())
    }

    /// 校验签名和有效期。实例、授权、沙箱是否仍然有效，以及来源地址是否匹配，由调用方核对。
    pub fn verify(&self, token: &str, now: u64) -> Result<SandboxClaims, TokenError> {
        let mut parts = token.split('.');
        let (Some(prefix), Some(kid), Some(body), Some(sig), None) = (
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
        ) else {
            return Err(TokenError::Malformed);
        };
        if prefix != PREFIX {
            return Err(TokenError::Malformed);
        }
        let key = self
            .keys
            .get(kid)
            .ok_or_else(|| TokenError::UnknownKey(kid.to_owned()))?;
        let sig_bytes = URL_SAFE_NO_PAD
            .decode(sig)
            .map_err(|_| TokenError::Malformed)?;
        let sig_bytes: [u8; 64] = sig_bytes
            .as_slice()
            .try_into()
            .map_err(|_| TokenError::Malformed)?;
        let signed_len = prefix.len() + 1 + kid.len() + 1 + body.len();
        key.verify_strict(
            &token.as_bytes()[..signed_len],
            &Signature::from_bytes(&sig_bytes),
        )
        .map_err(|_| TokenError::BadSignature)?;
        let claims: SandboxClaims = URL_SAFE_NO_PAD
            .decode(body)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .ok_or(TokenError::Malformed)?;
        if now > claims.exp + LEEWAY_SECS {
            return Err(TokenError::Expired);
        }
        if claims.iat > now + LEEWAY_SECS {
            return Err(TokenError::NotYetValid);
        }
        Ok(claims)
    }
}

/// 令牌在日志里只显示 kid 和 jti 的前几位。
pub fn redact(token: &str) -> String {
    let kid = token.split('.').nth(1).unwrap_or("?");
    format!("tts1.{kid}.***")
}

#[cfg(test)]
mod tests {
    use super::*;

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
