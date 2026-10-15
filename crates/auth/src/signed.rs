//! 平台签发的 Ed25519 令牌的公共格式：`<前缀>.<kid>.<base64url(claims JSON)>.<base64url(签名)>`，签名覆盖前三段。
//!
//! 前缀区分令牌种类（沙箱令牌 `tts1`、访问令牌 `tta1`），一种令牌的签名不能当另一种用。
//! `kid` 标识签名密钥，校验方可以同时持有多把公钥，支持轮换。

use std::collections::HashMap;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::Serialize;
use serde::de::DeserializeOwned;
use zeroize::Zeroizing;

/// 校验时间时允许的时钟偏差。
pub const LEEWAY_SECS: u64 = 30;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TokenError {
    #[error("malformed token")]
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

/// 令牌声明里必须有的时间字段。
pub trait TimedClaims {
    fn iat(&self) -> u64;
    fn exp(&self) -> u64;
}

/// 签名方：持有一把私钥。
pub struct Signer25519 {
    kid: String,
    key: SigningKey,
}

impl Signer25519 {
    pub fn new(kid: impl Into<String>, key: SigningKey) -> Self {
        Self {
            kid: kid.into(),
            key,
        }
    }

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

    pub fn sign<C: Serialize>(&self, prefix: &str, claims: &C) -> String {
        let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).expect("claims serialize"));
        let signed = format!("{prefix}.{}.{body}", self.kid);
        let sig = self.key.sign(signed.as_bytes());
        format!("{signed}.{}", URL_SAFE_NO_PAD.encode(sig.to_bytes()))
    }
}

/// 校验方：按 kid 持有多把公钥。
#[derive(Default, Clone)]
pub struct Verifier25519 {
    keys: HashMap<String, VerifyingKey>,
}

impl Verifier25519 {
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

    /// 校验前缀、签名和有效期，返回声明。
    pub fn verify<C: DeserializeOwned + TimedClaims>(
        &self,
        prefix: &str,
        token: &str,
        now: u64,
    ) -> Result<C, TokenError> {
        let mut parts = token.split('.');
        let (Some(p), Some(kid), Some(body), Some(sig), None) = (
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
        ) else {
            return Err(TokenError::Malformed);
        };
        if p != prefix {
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
        let signed_len = p.len() + 1 + kid.len() + 1 + body.len();
        key.verify_strict(
            &token.as_bytes()[..signed_len],
            &Signature::from_bytes(&sig_bytes),
        )
        .map_err(|_| TokenError::BadSignature)?;
        let claims: C = URL_SAFE_NO_PAD
            .decode(body)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .ok_or(TokenError::Malformed)?;
        if now > claims.exp().saturating_add(LEEWAY_SECS) {
            return Err(TokenError::Expired);
        }
        if claims.iat() > now.saturating_add(LEEWAY_SECS) {
            return Err(TokenError::NotYetValid);
        }
        Ok(claims)
    }
}

/// 随机令牌 id（12 字节，base64url）。
pub fn random_jti() -> Result<String, TokenError> {
    let mut jti = [0u8; 12];
    getrandom::fill(&mut jti).map_err(|_| TokenError::Rng)?;
    Ok(URL_SAFE_NO_PAD.encode(jti))
}

/// 日志里只显示前缀和 kid。
pub fn redact(token: &str) -> String {
    let mut parts = token.split('.');
    let prefix = parts.next().unwrap_or("?");
    let kid = parts.next().unwrap_or("?");
    format!("{prefix}.{kid}.***")
}
