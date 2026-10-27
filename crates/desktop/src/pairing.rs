//! 配对的电脑一侧（WBS 14.8 的 Rust 部分，docs/pairing.md 第 2 节）：电脑出二维码（[`crate::Desktop::start_pairing`]），
//! 手机扫码后签名回复（`pair_response`），电脑验签、用自己的私钥签确认（`pair_confirm`）发回，然后记下这台手机。
//!
//! 电脑的私钥由 App 放在钥匙串 / Secure Enclave 里，实现 [`PairingKey`]；[`SoftwareKey`] 给测试和开发用。
//! 一次只有一个邀请：重新开始配对会作废上一个；手机的回复验不过（不是这次的邀请、签名不对、过期）时邀请作废，
//! 要重新出二维码。

use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};

/// 电脑的签名密钥（P-256）。
pub trait PairingKey: Send + Sync {
    /// 公钥（SEC1）。
    fn public_key(&self) -> Vec<u8>;
    /// ECDSA P-256 + SHA-256 签名，DER 或 r‖s。
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String>;
}

/// 内存里的软件密钥（测试、开发用；App 用钥匙串里的）。
pub struct SoftwareKey(SigningKey);

impl SoftwareKey {
    /// 随机生成一把。
    pub fn generate() -> Self {
        loop {
            let mut bytes = [0u8; 32];
            getrandom::fill(&mut bytes).expect("random bytes");
            // 极少数随机数不是合法的私钥（为零或不小于群的阶），再来一次。
            if let Ok(key) = SigningKey::from_slice(&bytes) {
                return Self(key);
            }
        }
    }

    /// 从 32 字节的私钥（大端）恢复。
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
        SigningKey::from_slice(bytes)
            .map(Self)
            .map_err(|_| "not a P-256 private key".to_owned())
    }
}

impl PairingKey for SoftwareKey {
    fn public_key(&self) -> Vec<u8> {
        self.0
            .verifying_key()
            .to_sec1_point(false)
            .as_bytes()
            .to_vec()
    }

    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String> {
        let signature: Signature = self.0.sign(message);
        Ok(signature.to_der().as_bytes().to_vec())
    }
}

/// 配对进行到哪了（给 App 的配对界面用）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingStatus {
    /// 没在配对。
    Idle,
    /// 二维码在显示：内容、过期时间（Unix 秒）。
    Waiting { uri: String, expires_at: u64 },
    /// 和这台手机配好了。
    Paired { phone_id: String },
    /// 手机的回复验不过，或者邀请过期了：要重新出二维码。
    Failed { reason: String },
}

#[cfg(test)]
mod tests {
    use super::*;
    use client_core::pairing::encode_public_key;

    #[test]
    fn software_keys_sign_with_their_public_key() {
        let key = SoftwareKey::generate();
        let public = key.public_key();
        assert_eq!(public.len(), 65);
        assert_eq!(public[0], 0x04);
        assert!(encode_public_key(public.clone()).is_ok());
        let signature = key.sign(b"thinktin").unwrap();
        let verifying = p256::ecdsa::VerifyingKey::from_sec1_bytes(&public).unwrap();
        let parsed = Signature::from_der(&signature).unwrap();
        use p256::ecdsa::signature::Verifier;
        assert!(verifying.verify(b"thinktin", &parsed).is_ok());
        assert!(SoftwareKey::from_bytes(&[0u8; 32]).is_err());
        assert_eq!(
            SoftwareKey::from_bytes(&[7u8; 32]).unwrap().public_key(),
            SoftwareKey::from_bytes(&[7u8; 32]).unwrap().public_key()
        );
    }
}
