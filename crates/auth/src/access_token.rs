//! 设备会话的访问令牌（架构方案 4.6，WBS 4.2）：15 分钟有效，绑定用户、设备和会话。
//!
//! 访问令牌是自包含的签名令牌，接入网关验签后再核对会话是否被吊销（远程下线、退出登录）；
//! 刷新令牌是不透明的随机串（见 [`crate::secrets::RefreshToken`]），只存哈希，按设备保存、每次刷新轮换。

use serde::{Deserialize, Serialize};

use crate::signed::{self, Signer25519, TimedClaims, TokenError, Verifier25519};

const PREFIX: &str = "tta1";
/// 访问令牌有效期。
pub const ACCESS_TTL_SECS: u64 = 15 * 60;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccessClaims {
    /// 用户 id。
    pub uid: String,
    /// 设备 id。
    pub did: String,
    /// 会话 id：吊销以会话为单位。
    pub sid: String,
    pub iat: u64,
    pub exp: u64,
    pub jti: String,
}

impl TimedClaims for AccessClaims {
    fn iat(&self) -> u64 {
        self.iat
    }
    fn exp(&self) -> u64 {
        self.exp
    }
}

pub struct AccessTokenIssuer(pub Signer25519);

impl AccessTokenIssuer {
    pub fn issue(&self, uid: &str, did: &str, sid: &str, now: u64) -> Result<String, TokenError> {
        let claims = AccessClaims {
            uid: uid.into(),
            did: did.into(),
            sid: sid.into(),
            iat: now,
            exp: now + ACCESS_TTL_SECS,
            jti: signed::random_jti()?,
        };
        Ok(self.0.sign(PREFIX, &claims))
    }
}

#[derive(Default, Clone)]
pub struct AccessTokenVerifier(pub Verifier25519);

impl AccessTokenVerifier {
    /// 只验签名和有效期；会话是否已被吊销由调用方查。
    pub fn verify(&self, token: &str, now: u64) -> Result<AccessClaims, TokenError> {
        self.0.verify(PREFIX, token, now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};

    fn pair() -> (AccessTokenIssuer, AccessTokenVerifier) {
        let signer = Signer25519::generate("a1").unwrap();
        let mut v = Verifier25519::new();
        v.add_key_b64("a1", &signer.verifying_key_b64()).unwrap();
        (AccessTokenIssuer(signer), AccessTokenVerifier(v))
    }

    #[test]
    fn issue_verify_expire() {
        let (issuer, verifier) = pair();
        let t = issuer.issue("u1", "d1", "s1", 1000).unwrap();
        assert!(t.starts_with("tta1.a1."));
        let c = verifier.verify(&t, 1000 + ACCESS_TTL_SECS).unwrap();
        assert_eq!(
            (c.uid.as_str(), c.did.as_str(), c.sid.as_str()),
            ("u1", "d1", "s1")
        );
        assert_eq!(
            verifier.verify(&t, 1000 + ACCESS_TTL_SECS + signed::LEEWAY_SECS + 1),
            Err(TokenError::Expired)
        );
    }

    #[test]
    fn token_kinds_do_not_mix() {
        // 同一把密钥签的沙箱令牌不能当访问令牌用，反之亦然。
        let signer = Signer25519::generate("k").unwrap();
        let seed = signer.seed_b64();
        let mut v = Verifier25519::new();
        v.add_key_b64("k", &signer.verifying_key_b64()).unwrap();
        let access = AccessTokenIssuer(signer).issue("u", "d", "s", 10).unwrap();
        let sandbox = SandboxTokenIssuer::from_seed_b64("k", &seed)
            .unwrap()
            .issue(
                TokenRequest {
                    ep: 0,
                    iid: "i".into(),
                    uid: "u".into(),
                    grant: "g".into(),
                    sbx: "s".into(),
                    net: None,
                },
                60,
                10,
            )
            .unwrap();
        let av = AccessTokenVerifier(v.clone());
        assert_eq!(av.verify(&sandbox, 11), Err(TokenError::Malformed));
        let mut sv = SandboxTokenVerifier::new();
        sv.add_key_b64(
            "k",
            &Signer25519::from_seed_b64("k", &seed)
                .unwrap()
                .verifying_key_b64(),
        )
        .unwrap();
        assert_eq!(sv.verify(&access, 11), Err(TokenError::Malformed));
        // 改前缀也不行：签名覆盖前缀。
        let forged = access.replacen("tta1.", "tts1.", 1);
        assert_eq!(sv.verify(&forged, 11), Err(TokenError::BadSignature));
    }
}
