//! 密钥库：信封加密（架构方案 5.4）。
//!
//! - 每个用户一把数据密钥（DEK，256 位），由 KMS 的主密钥加密（包裹）后存库，明文 DEK 不落盘。
//! - 用户的 API key 用 DEK 做 AES-256-GCM 加密。附加数据（AAD）绑定用户 id 和密钥记录 id，
//!   密文被挪到别的用户或别的记录下会解不开。
//! - 保存后只回显后 4 位；明文只在调用方（模型网关）内存里短暂存在，用 `SecretString` 包装，
//!   离开作用域时清零。
//! - 注销即销毁：删掉用户的包裹 DEK，名下所有密文都无法再解开（加密销毁）。
//!
//! KMS 用 [`Kms`] 抽象。[`LocalKms`] 只用于开发和测试；生产环境接云 KMS（WBS 2.6）。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{Aead, KeyInit, Nonce, Payload};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

pub use secrecy;

const NONCE_LEN: usize = 12;
const DEK_LEN: usize = 32;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("no data key for user {0}")]
    NoUserKey(String),
    #[error("data key for user {0} already exists")]
    UserKeyExists(String),
    #[error("KMS key {0} is not available")]
    UnknownKmsKey(String),
    /// 密文被篡改、挪用（AAD 不符）或密钥不对。不区分具体原因，免得给攻击者提示。
    #[error("decryption failed")]
    Decrypt,
    #[error("random number generator failed")]
    Rng,
    #[error("malformed sealed data")]
    Malformed,
}

pub type Result<T> = std::result::Result<T, Error>;

/// 被 KMS 主密钥包裹的数据密钥。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WrappedKey {
    /// KMS 主密钥的标识，用于主密钥轮换后找到对应的解包密钥。
    pub kms_key_id: String,
    /// KMS 返回的不透明密文。
    pub ciphertext: Vec<u8>,
}

/// 密钥管理服务：包裹和解包数据密钥。
pub trait Kms: Send + Sync {
    /// 当前用于包裹新 DEK 的主密钥标识。
    fn current_key_id(&self) -> &str;
    fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey>;
    fn unwrap(&self, wrapped: &WrappedKey, context: &str) -> Result<Zeroizing<[u8; DEK_LEN]>>;
}

/// 开发和测试用的本地 KMS：主密钥在进程内存里，用 AES-256-GCM 包裹 DEK。
/// 生产环境必须换成云 KMS，主密钥不离开 KMS。
pub struct LocalKms {
    key_id: String,
    cipher: Aes256Gcm,
}

impl LocalKms {
    pub fn new(key_id: impl Into<String>, master_key: &[u8; DEK_LEN]) -> Self {
        Self {
            key_id: key_id.into(),
            cipher: Aes256Gcm::new_from_slice(master_key).expect("32-byte key"),
        }
    }

    /// 从 64 位十六进制字符串创建（开发环境从环境变量读入）。
    pub fn from_hex(key_id: impl Into<String>, hex: &str) -> Result<Self> {
        let mut bytes = Zeroizing::new([0u8; DEK_LEN]);
        decode_hex(hex.trim(), bytes.as_mut()).ok_or(Error::Malformed)?;
        Ok(Self::new(key_id, &bytes))
    }
}

impl Kms for LocalKms {
    fn current_key_id(&self) -> &str {
        &self.key_id
    }

    fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey> {
        let aad = format!("thinktin/dek/{}/{context}", self.key_id);
        Ok(WrappedKey {
            kms_key_id: self.key_id.clone(),
            ciphertext: seal_raw(&self.cipher, dek, aad.as_bytes())?,
        })
    }

    fn unwrap(&self, wrapped: &WrappedKey, context: &str) -> Result<Zeroizing<[u8; DEK_LEN]>> {
        if wrapped.kms_key_id != self.key_id {
            return Err(Error::UnknownKmsKey(wrapped.kms_key_id.clone()));
        }
        let aad = format!("thinktin/dek/{}/{context}", self.key_id);
        let plain = Zeroizing::new(open_raw(&self.cipher, &wrapped.ciphertext, aad.as_bytes())?);
        let mut dek = Zeroizing::new([0u8; DEK_LEN]);
        if plain.len() != DEK_LEN {
            return Err(Error::Malformed);
        }
        dek.copy_from_slice(&plain);
        Ok(dek)
    }
}

/// 用户 API key 的密文记录。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SealedSecret {
    /// 随机数（12 字节）在前，密文和认证标签在后。
    pub ciphertext: Vec<u8>,
    /// 明文的后 4 位，给用户辨认是哪把 key。
    pub last4: String,
}

/// 存放包裹后的 DEK。生产环境是 Postgres 里按用户一行（WBS 3.3），这里只定义接口。
pub trait KeyStore: Send + Sync {
    fn get(&self, user_id: &str) -> Option<WrappedKey>;
    /// 只在不存在时插入，返回是否插入成功。
    fn insert_new(&self, user_id: &str, key: WrappedKey) -> bool;
    /// 删除并返回是否存在过。
    fn remove(&self, user_id: &str) -> bool;
}

impl<T: KeyStore + ?Sized> KeyStore for std::sync::Arc<T> {
    fn get(&self, user_id: &str) -> Option<WrappedKey> {
        (**self).get(user_id)
    }

    fn insert_new(&self, user_id: &str, key: WrappedKey) -> bool {
        (**self).insert_new(user_id, key)
    }

    fn remove(&self, user_id: &str) -> bool {
        (**self).remove(user_id)
    }
}

/// 解密用户 API key 的能力，供模型网关以 trait 对象持有。
pub trait SecretOpener: Send + Sync {
    fn open_secret(
        &self,
        user_id: &str,
        record_id: &str,
        sealed: &SealedSecret,
    ) -> Result<SecretString>;
}

impl<K: Kms, S: KeyStore> SecretOpener for KeyVault<K, S> {
    fn open_secret(
        &self,
        user_id: &str,
        record_id: &str,
        sealed: &SealedSecret,
    ) -> Result<SecretString> {
        self.open(user_id, record_id, sealed)
    }
}

/// 内存里的 [`KeyStore`]，用于测试和单机开发。
#[derive(Default)]
pub struct MemoryKeyStore(Mutex<HashMap<String, WrappedKey>>);

impl KeyStore for MemoryKeyStore {
    fn get(&self, user_id: &str) -> Option<WrappedKey> {
        self.0.lock().unwrap().get(user_id).cloned()
    }

    fn insert_new(&self, user_id: &str, key: WrappedKey) -> bool {
        let mut map = self.0.lock().unwrap();
        if map.contains_key(user_id) {
            return false;
        }
        map.insert(user_id.to_owned(), key);
        true
    }

    fn remove(&self, user_id: &str) -> bool {
        self.0.lock().unwrap().remove(user_id).is_some()
    }
}

/// 解开的 DEK 在内存里缓存一小段时间，省得每个请求都调 KMS（5.4：比如 5 分钟）。
struct CachedDek {
    dek: Zeroizing<[u8; DEK_LEN]>,
    expires: Instant,
}

pub struct KeyVault<K: Kms, S: KeyStore> {
    kms: K,
    store: S,
    cache: Mutex<HashMap<String, CachedDek>>,
    cache_ttl: Duration,
}

impl<K: Kms, S: KeyStore> KeyVault<K, S> {
    pub fn new(kms: K, store: S) -> Self {
        Self {
            kms,
            store,
            cache: Mutex::default(),
            cache_ttl: Duration::from_secs(300),
        }
    }

    pub fn with_cache_ttl(mut self, ttl: Duration) -> Self {
        self.cache_ttl = ttl;
        self
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    /// 为新用户生成 DEK。已存在时报错，不会覆盖（覆盖等于销毁旧密文）。
    pub fn create_user_key(&self, user_id: &str) -> Result<()> {
        let mut dek = Zeroizing::new([0u8; DEK_LEN]);
        getrandom::fill(dek.as_mut()).map_err(|_| Error::Rng)?;
        let wrapped = self.kms.wrap(&dek, user_id)?;
        if !self.store.insert_new(user_id, wrapped) {
            return Err(Error::UserKeyExists(user_id.to_owned()));
        }
        Ok(())
    }

    /// 注销即销毁：删除用户的 DEK 并清掉缓存，之后该用户的所有密文都无法解开。
    pub fn destroy_user_key(&self, user_id: &str) -> bool {
        self.cache.lock().unwrap().remove(user_id);
        self.store.remove(user_id)
    }

    /// 加密一把 API key。`record_id` 是密钥记录的 id，和用户 id 一起进 AAD。
    pub fn seal(
        &self,
        user_id: &str,
        record_id: &str,
        secret: &SecretString,
    ) -> Result<SealedSecret> {
        let dek = self.dek(user_id)?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        let plain = secret.expose_secret();
        Ok(SealedSecret {
            ciphertext: seal_raw(&cipher, plain.as_bytes(), &aad(user_id, record_id))?,
            last4: last4(plain),
        })
    }

    /// 解密一把 API key。只应在模型网关里调用，结果尽快用完丢弃。
    pub fn open(
        &self,
        user_id: &str,
        record_id: &str,
        sealed: &SealedSecret,
    ) -> Result<SecretString> {
        let dek = self.dek(user_id)?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        let mut plain = open_raw(&cipher, &sealed.ciphertext, &aad(user_id, record_id))?;
        let text = String::from_utf8(std::mem::take(&mut plain)).map_err(|e| {
            let mut bytes = e.into_bytes();
            bytes.zeroize();
            Error::Malformed
        })?;
        Ok(SecretString::from(text))
    }

    fn dek(&self, user_id: &str) -> Result<Zeroizing<[u8; DEK_LEN]>> {
        let now = Instant::now();
        {
            let mut cache = self.cache.lock().unwrap();
            match cache.get(user_id) {
                Some(c) if c.expires > now => return Ok(c.dek.clone()),
                Some(_) => {
                    cache.remove(user_id);
                }
                None => {}
            }
        }
        let wrapped = self
            .store
            .get(user_id)
            .ok_or_else(|| Error::NoUserKey(user_id.to_owned()))?;
        let dek = self.kms.unwrap(&wrapped, user_id)?;
        self.cache.lock().unwrap().insert(
            user_id.to_owned(),
            CachedDek {
                dek: dek.clone(),
                expires: now + self.cache_ttl,
            },
        );
        Ok(dek)
    }
}

fn aad(user_id: &str, record_id: &str) -> Vec<u8> {
    // 长度前缀，避免 ("ab","c") 和 ("a","bc") 拼成同一个 AAD。
    let mut out = Vec::with_capacity(user_id.len() + record_id.len() + 32);
    out.extend_from_slice(b"thinktin/secret/v1/");
    out.extend_from_slice(&(user_id.len() as u32).to_be_bytes());
    out.extend_from_slice(user_id.as_bytes());
    out.extend_from_slice(&(record_id.len() as u32).to_be_bytes());
    out.extend_from_slice(record_id.as_bytes());
    out
}

fn seal_raw(cipher: &Aes256Gcm, plain: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    let mut nonce_bytes = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce_bytes).map_err(|_| Error::Rng)?;
    let nonce = Nonce::<Aes256Gcm>::from(nonce_bytes);
    let ct = cipher
        .encrypt(&nonce, Payload { msg: plain, aad })
        .map_err(|_| Error::Decrypt)?;
    let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

fn open_raw(cipher: &Aes256Gcm, sealed: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    if sealed.len() < NONCE_LEN + 16 {
        return Err(Error::Malformed);
    }
    let (nonce_bytes, ct) = sealed.split_at(NONCE_LEN);
    let nonce_arr: [u8; NONCE_LEN] = nonce_bytes.try_into().expect("split at NONCE_LEN");
    let nonce = Nonce::<Aes256Gcm>::from(nonce_arr);
    cipher
        .decrypt(&nonce, Payload { msg: ct, aad })
        .map_err(|_| Error::Decrypt)
}

/// 后 4 位；太短的 key 只显示星号，免得整把 key 被回显出来。
fn last4(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() < 12 {
        return "****".into();
    }
    chars[chars.len() - 4..].iter().collect()
}

fn decode_hex(hex: &str, out: &mut [u8]) -> Option<()> {
    if hex.len() != out.len() * 2 {
        return None;
    }
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault() -> KeyVault<LocalKms, MemoryKeyStore> {
        KeyVault::new(
            LocalKms::new("local-1", &[7u8; 32]),
            MemoryKeyStore::default(),
        )
    }

    fn key(s: &str) -> SecretString {
        SecretString::from(s.to_owned())
    }

    #[test]
    fn seal_and_open_roundtrip() {
        let v = vault();
        v.create_user_key("u1").unwrap();
        let sealed = v
            .seal("u1", "k1", &key("sk-deepseek-1234567890abcd"))
            .unwrap();
        assert_eq!(sealed.last4, "abcd");
        assert!(!String::from_utf8_lossy(&sealed.ciphertext).contains("sk-deepseek"));
        let opened = v.open("u1", "k1", &sealed).unwrap();
        assert_eq!(opened.expose_secret(), "sk-deepseek-1234567890abcd");
    }

    #[test]
    fn ciphertext_is_bound_to_user_and_record() {
        let v = vault();
        v.create_user_key("u1").unwrap();
        v.create_user_key("u2").unwrap();
        let sealed = v.seal("u1", "k1", &key("sk-aaaaaaaaaaaaaaaa")).unwrap();
        assert!(matches!(v.open("u1", "k2", &sealed), Err(Error::Decrypt)));
        assert!(matches!(v.open("u2", "k1", &sealed), Err(Error::Decrypt)));
        let mut tampered = sealed.clone();
        *tampered.ciphertext.last_mut().unwrap() ^= 1;
        assert!(matches!(v.open("u1", "k1", &tampered), Err(Error::Decrypt)));
    }

    #[test]
    fn nonces_are_unique() {
        let v = vault();
        v.create_user_key("u1").unwrap();
        let a = v.seal("u1", "k1", &key("sk-same-secret-value")).unwrap();
        let b = v.seal("u1", "k1", &key("sk-same-secret-value")).unwrap();
        assert_ne!(a.ciphertext, b.ciphertext);
    }

    #[test]
    fn destroying_user_key_shreds_secrets() {
        let v = vault();
        v.create_user_key("u1").unwrap();
        let sealed = v.seal("u1", "k1", &key("sk-bbbbbbbbbbbbbbbb")).unwrap();
        v.open("u1", "k1", &sealed).unwrap(); // 进缓存
        assert!(v.destroy_user_key("u1"));
        assert!(matches!(
            v.open("u1", "k1", &sealed),
            Err(Error::NoUserKey(_))
        ));
        // 重新建用户密钥也解不开旧密文。
        v.create_user_key("u1").unwrap();
        assert!(matches!(v.open("u1", "k1", &sealed), Err(Error::Decrypt)));
    }

    #[test]
    fn user_key_is_never_overwritten() {
        let v = vault();
        v.create_user_key("u1").unwrap();
        assert!(matches!(
            v.create_user_key("u1"),
            Err(Error::UserKeyExists(_))
        ));
    }

    #[test]
    fn wrapped_dek_is_bound_to_user_and_kms_key() {
        let kms = LocalKms::new("local-1", &[7u8; 32]);
        let wrapped = kms.wrap(&[9u8; 32], "u1").unwrap();
        assert_eq!(*kms.unwrap(&wrapped, "u1").unwrap(), [9u8; 32]);
        assert!(kms.unwrap(&wrapped, "u2").is_err());
        let other = LocalKms::new("local-2", &[7u8; 32]);
        assert!(matches!(
            other.unwrap(&wrapped, "u1"),
            Err(Error::UnknownKmsKey(_))
        ));
    }

    #[test]
    fn last4_never_reveals_short_keys() {
        assert_eq!(last4("short"), "****");
        assert_eq!(last4("sk-0123456789ab"), "89ab");
    }

    #[test]
    fn local_kms_from_hex() {
        let hex = "07".repeat(32);
        let kms = LocalKms::from_hex("k", &hex).unwrap();
        let w = kms.wrap(&[1u8; 32], "u").unwrap();
        assert_eq!(*kms.unwrap(&w, "u").unwrap(), [1u8; 32]);
        assert!(LocalKms::from_hex("k", "zz").is_err());
    }
}
