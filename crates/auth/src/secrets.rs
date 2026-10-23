//! 登录相关的秘密值（WBS 4.1、4.2）：手机号规范化、短信验证码、刷新令牌。数据库里只存它们的哈希。

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::signed::TokenError;

type HmacSha256 = Hmac<Sha256>;

/// 验证码有效期。
pub const CODE_TTL_SECS: u64 = 5 * 60;
/// 一个验证码最多试这么多次，超过就作废。
pub const CODE_MAX_ATTEMPTS: u32 = 5;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PhoneError {
    #[error("invalid phone number")]
    Invalid,
}

/// 把手机号规范成 E.164（`+` 加 8 到 15 位数字）。11 位、以 1 开头的按中国大陆号码补 `+86`。
pub fn normalize_phone(input: &str) -> Result<String, PhoneError> {
    let cleaned: String = input
        .chars()
        .filter(|c| !matches!(c, ' ' | '-' | '(' | ')'))
        .collect();
    let digits = cleaned.strip_prefix('+').unwrap_or(&cleaned);
    if !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(PhoneError::Invalid);
    }
    let e164 = if cleaned.starts_with('+') {
        format!("+{digits}")
    } else if digits.len() == 11 && digits.starts_with('1') {
        format!("+86{digits}")
    } else {
        return Err(PhoneError::Invalid);
    };
    let n = e164.len() - 1;
    if !(8..=15).contains(&n) || e164.starts_with("+0") {
        return Err(PhoneError::Invalid);
    }
    Ok(e164)
}

/// 生成 6 位数字验证码（均匀分布，不用取模偏差）。
pub fn generate_code() -> Result<Zeroizing<String>, TokenError> {
    loop {
        let mut b = [0u8; 4];
        getrandom::fill(&mut b).map_err(|_| TokenError::Rng)?;
        let v = u32::from_be_bytes(b);
        // 拒绝采样：只用 [0, 4_294_000_000) 这段，保证对 1_000_000 取模是均匀的。
        if v < 4_294_000_000 {
            return Ok(Zeroizing::new(format!("{:06}", v % 1_000_000)));
        }
    }
}

/// 验证码的哈希：HMAC-SHA256(服务端密钥, 用途 | 手机号 | 验证码)。6 位数字的空间很小，
/// 不加服务端密钥的哈希一拿到就能穷举，所以必须用密钥。
pub fn code_hash(pepper: &[u8], purpose: &str, phone: &str, code: &str) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(pepper).expect("hmac accepts any key length");
    for part in [purpose, phone, code] {
        mac.update(&(part.len() as u32).to_be_bytes());
        mac.update(part.as_bytes());
    }
    mac.finalize().into_bytes().into()
}

pub fn verify_code(pepper: &[u8], purpose: &str, phone: &str, code: &str, stored: &[u8]) -> bool {
    let expected = code_hash(pepper, purpose, phone, code.trim());
    expected.ct_eq(stored).into()
}

/// 刷新令牌：`rtk1.<会话 id>.<32 字节随机数>`。按会话 id 找到记录后，比对随机数部分的 SHA-256。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefreshToken {
    pub session_id: String,
    secret: Zeroizing<String>,
}

const REFRESH_PREFIX: &str = "rtk1";

impl RefreshToken {
    pub fn generate(session_id: &str) -> Result<Self, TokenError> {
        let mut b = Zeroizing::new([0u8; 32]);
        getrandom::fill(b.as_mut()).map_err(|_| TokenError::Rng)?;
        Ok(Self {
            session_id: session_id.to_owned(),
            secret: Zeroizing::new(URL_SAFE_NO_PAD.encode(b.as_ref())),
        })
    }

    pub fn parse(token: &str) -> Result<Self, TokenError> {
        let mut parts = token.trim().split('.');
        match (parts.next(), parts.next(), parts.next(), parts.next()) {
            (Some(REFRESH_PREFIX), Some(sid), Some(secret), None)
                if !sid.is_empty() && sid.len() <= 64 && secret.len() == 43 =>
            {
                Ok(Self {
                    session_id: sid.to_owned(),
                    secret: Zeroizing::new(secret.to_owned()),
                })
            }
            _ => Err(TokenError::Malformed),
        }
    }

    /// 交给客户端的完整令牌。
    pub fn encode(&self) -> Zeroizing<String> {
        Zeroizing::new(format!(
            "{REFRESH_PREFIX}.{}.{}",
            self.session_id,
            self.secret.as_str()
        ))
    }

    /// 存库的哈希。随机数有 256 位熵，直接 SHA-256 即可，不需要慢哈希。
    pub fn hash(&self) -> [u8; 32] {
        Sha256::digest(self.secret.as_bytes()).into()
    }

    pub fn matches(&self, stored: &[u8]) -> bool {
        self.hash().ct_eq(stored).into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phone_normalization() {
        assert_eq!(normalize_phone("138 0013 8000").unwrap(), "+8613800138000");
        assert_eq!(
            normalize_phone("+86 138-0013-8000").unwrap(),
            "+8613800138000"
        );
        assert_eq!(
            normalize_phone("+1 (415) 555-0100").unwrap(),
            "+14155550100"
        );
        for bad in [
            "",
            "12345",
            "abc",
            "+0123456789",
            "+1234567890123456",
            "23800138000",
            "+86 138x",
        ] {
            assert!(normalize_phone(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn codes_are_six_digits_and_bound_to_phone_and_purpose() {
        let pepper = b"server-side-pepper";
        for _ in 0..100 {
            let c = generate_code().unwrap();
            assert_eq!(c.len(), 6);
            assert!(c.bytes().all(|b| b.is_ascii_digit()));
        }
        let h = code_hash(pepper, "login", "+8613800138000", "123456");
        assert!(verify_code(
            pepper,
            "login",
            "+8613800138000",
            " 123456 ",
            &h
        ));
        assert!(!verify_code(
            pepper,
            "login",
            "+8613800138000",
            "123457",
            &h
        ));
        assert!(!verify_code(
            pepper,
            "login",
            "+8613800138001",
            "123456",
            &h
        ));
        assert!(!verify_code(
            pepper,
            "delete_account",
            "+8613800138000",
            "123456",
            &h
        ));
        assert!(!verify_code(
            b"other",
            "login",
            "+8613800138000",
            "123456",
            &h
        ));
    }

    #[test]
    fn refresh_tokens() {
        let t = RefreshToken::generate("sess-1").unwrap();
        let wire = t.encode();
        assert!(wire.starts_with("rtk1.sess-1."));
        let parsed = RefreshToken::parse(&wire).unwrap();
        assert_eq!(parsed, t);
        assert!(parsed.matches(&t.hash()));
        let other = RefreshToken::generate("sess-1").unwrap();
        assert!(!other.matches(&t.hash()));
        for bad in [
            "",
            "rtk1.sess.short",
            "rtk0.sess-1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "rtk1..x",
            "rtk1.a.b.c",
        ] {
            assert!(RefreshToken::parse(bad).is_err(), "{bad}");
        }
    }
}
