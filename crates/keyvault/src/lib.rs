//! 密钥库：信封加密（架构方案 5.4）。
//!
//! - 每个用户一把数据密钥（DEK，256 位），由 KMS 的主密钥加密（包裹）后存库，明文 DEK 不落盘。
//! - 用户的 API key 用 DEK 做 AES-256-GCM 加密。附加数据（AAD）绑定用户 id 和密钥记录 id，
//!   密文被挪到别的用户或别的记录下会解不开。
//! - 保存后只回显后 4 位；明文只在调用方（模型网关）内存里短暂存在，用 `SecretString` 包装，
//!   离开作用域时清零。
//! - 注销即销毁：删掉用户的包裹 DEK，名下所有密文都无法再解开（加密销毁）。
//!
//! KMS 用 [`Kms`] 抽象（异步：云 KMS 是网络调用）。[`LocalKms`] 只用于开发和测试；生产环境接云 KMS（WBS 2.6）。
//! [`KmsRing`] 按 DEK 记下的主密钥 id 找对应的 KMS（换主密钥后老的 DEK 照样解得开），
//! [`CachingKms`] 把解开的 DEK 在进程里缓存一会儿，省得每次加解密都调云 KMS。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{Aead, KeyInit, Nonce, Payload};
use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
    /// 云 KMS 调不通（网络、权限、限流）：可以重试。
    #[error("KMS is unavailable: {0}")]
    Kms(String),
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

/// 密钥管理服务：包裹和解包数据密钥。`context` 是用户 id：包裹时绑进去，解包时对不上就失败。
#[async_trait]
pub trait Kms: Send + Sync {
    /// 当前用于包裹新 DEK 的主密钥标识。
    fn current_key_id(&self) -> &str;
    async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey>;
    async fn unwrap(&self, wrapped: &WrappedKey, context: &str)
    -> Result<Zeroizing<[u8; DEK_LEN]>>;
}

#[async_trait]
impl<T: Kms + ?Sized> Kms for Arc<T> {
    fn current_key_id(&self) -> &str {
        (**self).current_key_id()
    }

    async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey> {
        (**self).wrap(dek, context).await
    }

    async fn unwrap(
        &self,
        wrapped: &WrappedKey,
        context: &str,
    ) -> Result<Zeroizing<[u8; DEK_LEN]>> {
        (**self).unwrap(wrapped, context).await
    }
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

#[async_trait]
impl Kms for LocalKms {
    fn current_key_id(&self) -> &str {
        &self.key_id
    }

    async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey> {
        let aad = format!("thinktin/dek/{}/{context}", self.key_id);
        Ok(WrappedKey {
            kms_key_id: self.key_id.clone(),
            ciphertext: seal_raw(&self.cipher, dek, aad.as_bytes())?,
        })
    }

    async fn unwrap(
        &self,
        wrapped: &WrappedKey,
        context: &str,
    ) -> Result<Zeroizing<[u8; DEK_LEN]>> {
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

/// 几把主密钥：新 DEK 用当前的包裹；解包按 DEK 记下的主密钥 id 找对应的。
/// 换主密钥（比如从本地主密钥迁到云 KMS）以后，老的 DEK 照样解得开，用户不用重新存 key。
pub struct KmsRing {
    current: Arc<dyn Kms>,
    older: Vec<Arc<dyn Kms>>,
}

impl KmsRing {
    pub fn new(current: Arc<dyn Kms>) -> Self {
        Self {
            current,
            older: Vec::new(),
        }
    }

    /// 加一把只用来解包老 DEK 的主密钥。
    pub fn with_older(mut self, kms: Arc<dyn Kms>) -> Self {
        self.older.push(kms);
        self
    }
}

#[async_trait]
impl Kms for KmsRing {
    fn current_key_id(&self) -> &str {
        self.current.current_key_id()
    }

    async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey> {
        self.current.wrap(dek, context).await
    }

    async fn unwrap(
        &self,
        wrapped: &WrappedKey,
        context: &str,
    ) -> Result<Zeroizing<[u8; DEK_LEN]>> {
        let kms = std::iter::once(&self.current)
            .chain(&self.older)
            .find(|k| k.current_key_id() == wrapped.kms_key_id)
            .ok_or_else(|| Error::UnknownKmsKey(wrapped.kms_key_id.clone()))?;
        kms.unwrap(wrapped, context).await
    }
}

/// 解开的 DEK 在进程里缓存一会儿：云 KMS 每次都是网络调用（还按次收费），
/// 而控制面每次加解密都会重新从库里取包裹的 DEK。按（主密钥 id、用户、密文）的哈希缓存，
/// 过期的条目顺手清掉，条目太多时整个清空；DEK 放在堆上，丢弃时清零。
pub struct CachingKms<K> {
    inner: K,
    ttl: Duration,
    max_entries: usize,
    cache: Mutex<HashMap<[u8; 32], CachedDek>>,
}

impl<K: Kms> CachingKms<K> {
    pub fn new(inner: K, ttl: Duration) -> Self {
        Self {
            inner,
            ttl,
            max_entries: 10_000,
            cache: Mutex::default(),
        }
    }

    fn cache_key(wrapped: &WrappedKey, context: &str) -> [u8; 32] {
        let mut h = Sha256::new();
        for part in [
            wrapped.kms_key_id.as_bytes(),
            context.as_bytes(),
            &wrapped.ciphertext,
        ] {
            h.update((part.len() as u64).to_be_bytes());
            h.update(part);
        }
        h.finalize().into()
    }
}

#[async_trait]
impl<K: Kms> Kms for CachingKms<K> {
    fn current_key_id(&self) -> &str {
        self.inner.current_key_id()
    }

    async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey> {
        self.inner.wrap(dek, context).await
    }

    async fn unwrap(
        &self,
        wrapped: &WrappedKey,
        context: &str,
    ) -> Result<Zeroizing<[u8; DEK_LEN]>> {
        let key = Self::cache_key(wrapped, context);
        let now = Instant::now();
        let hit = {
            let cache = self.cache.lock().unwrap();
            cache
                .get(&key)
                .filter(|c| c.expires > now)
                .map(|c| (*c.dek).clone())
        };
        if let Some(dek) = hit {
            return Ok(dek);
        }
        let dek = self.inner.unwrap(wrapped, context).await?;
        let mut cache = self.cache.lock().unwrap();
        cache.retain(|_, c| c.expires > now);
        if cache.len() >= self.max_entries {
            cache.clear();
        }
        cache.insert(
            key,
            CachedDek {
                dek: Box::new(dek.clone()),
                expires: now + self.ttl,
            },
        );
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

/// 保险箱条目的明文（9.11）：账号（可以为空）和密码。只在内存里短暂存在，丢弃时清零；
/// 调试输出不显示内容。
#[derive(Clone, PartialEq, Eq)]
pub struct VaultSecret {
    pub username: String,
    pub password: String,
}

impl std::fmt::Debug for VaultSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VaultSecret")
            .field("has_username", &!self.username.is_empty())
            .finish_non_exhaustive()
    }
}

impl Drop for VaultSecret {
    fn drop(&mut self) {
        self.username.zeroize();
        self.password.zeroize();
    }
}

impl VaultSecret {
    /// 格式：版本 1、账号长度（4 字节大端）、账号、密码。
    fn encode(&self) -> Zeroizing<Vec<u8>> {
        let mut out = Zeroizing::new(Vec::with_capacity(
            5 + self.username.len() + self.password.len(),
        ));
        out.push(1);
        out.extend_from_slice(&(self.username.len() as u32).to_be_bytes());
        out.extend_from_slice(self.username.as_bytes());
        out.extend_from_slice(self.password.as_bytes());
        out
    }

    fn decode(plain: &[u8]) -> Result<Self> {
        let [1, a, b, c, d, rest @ ..] = plain else {
            return Err(Error::Malformed);
        };
        let n = u32::from_be_bytes([*a, *b, *c, *d]) as usize;
        if n > rest.len() {
            return Err(Error::Malformed);
        }
        let (user, pass) = rest.split_at(n);
        let text = |b: &[u8]| String::from_utf8(b.to_vec()).map_err(|_| Error::Malformed);
        Ok(Self {
            username: text(user)?,
            password: text(pass)?,
        })
    }
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
#[async_trait]
pub trait SecretOpener: Send + Sync {
    async fn open_secret(
        &self,
        user_id: &str,
        record_id: &str,
        sealed: &SealedSecret,
    ) -> Result<SecretString>;

    /// 解密保险箱条目（9.11）：模型网关转发前要把里面的值从请求里抹掉。
    async fn open_vault_secret(
        &self,
        user_id: &str,
        item_id: &str,
        sealed: &[u8],
    ) -> Result<VaultSecret>;

    /// 丢掉为这个用户缓存的解密材料。用户注销（销毁 DEK）后由控制面通知网关调用，不必等缓存过期。
    fn forget_user(&self, _user_id: &str) {}
}

#[async_trait]
impl<K: Kms, S: KeyStore> SecretOpener for KeyVault<K, S> {
    async fn open_secret(
        &self,
        user_id: &str,
        record_id: &str,
        sealed: &SealedSecret,
    ) -> Result<SecretString> {
        self.open(user_id, record_id, sealed).await
    }

    async fn open_vault_secret(
        &self,
        user_id: &str,
        item_id: &str,
        sealed: &[u8],
    ) -> Result<VaultSecret> {
        self.open_vault(user_id, item_id, sealed).await
    }

    fn forget_user(&self, user_id: &str) {
        self.cache.lock().unwrap().remove(user_id);
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
    /// 放在堆上：哈希表扩容、删除时只搬指针，不在旧内存里留下密钥的副本。
    dek: Box<Zeroizing<[u8; DEK_LEN]>>,
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
    pub async fn create_user_key(&self, user_id: &str) -> Result<()> {
        let mut dek = Zeroizing::new([0u8; DEK_LEN]);
        getrandom::fill(dek.as_mut()).map_err(|_| Error::Rng)?;
        let wrapped = self.kms.wrap(&dek, user_id).await?;
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
    pub async fn seal(
        &self,
        user_id: &str,
        record_id: &str,
        secret: &SecretString,
    ) -> Result<SealedSecret> {
        let dek = self.dek(user_id).await?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        let plain = secret.expose_secret();
        Ok(SealedSecret {
            ciphertext: seal_raw(&cipher, plain.as_bytes(), &aad(user_id, record_id))?,
            last4: last4(plain),
        })
    }

    /// 加密一段数据（产出物等）。`object_id` 进 AAD，用的是和 key 不同的域，两类密文不能互换。
    pub async fn seal_bytes(
        &self,
        user_id: &str,
        object_id: &str,
        plain: &[u8],
    ) -> Result<Vec<u8>> {
        let dek = self.dek(user_id).await?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        seal_raw(&cipher, plain, &blob_aad(user_id, object_id))
    }

    pub async fn open_bytes(
        &self,
        user_id: &str,
        object_id: &str,
        sealed: &[u8],
    ) -> Result<Vec<u8>> {
        let dek = self.dek(user_id).await?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        open_raw(&cipher, sealed, &blob_aad(user_id, object_id))
    }

    /// 解密一把 API key。只应在模型网关里调用，结果尽快用完丢弃。
    pub async fn open(
        &self,
        user_id: &str,
        record_id: &str,
        sealed: &SealedSecret,
    ) -> Result<SecretString> {
        let dek = self.dek(user_id).await?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        let mut plain = open_raw(&cipher, &sealed.ciphertext, &aad(user_id, record_id))?;
        let text = String::from_utf8(std::mem::take(&mut plain)).map_err(|e| {
            let mut bytes = e.into_bytes();
            bytes.zeroize();
            Error::Malformed
        })?;
        Ok(SecretString::from(text))
    }

    /// 加密一个保险箱条目（9.11）。`item_id` 进 AAD，用的是单独的域，和 key、产出物的密文不能互换。
    pub async fn seal_vault(
        &self,
        user_id: &str,
        item_id: &str,
        secret: &VaultSecret,
    ) -> Result<Vec<u8>> {
        let dek = self.dek(user_id).await?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        seal_raw(&cipher, &secret.encode(), &vault_aad(user_id, item_id))
    }

    pub async fn open_vault(
        &self,
        user_id: &str,
        item_id: &str,
        sealed: &[u8],
    ) -> Result<VaultSecret> {
        let dek = self.dek(user_id).await?;
        let cipher = Aes256Gcm::new_from_slice(dek.as_ref()).expect("32-byte key");
        let plain = Zeroizing::new(open_raw(&cipher, sealed, &vault_aad(user_id, item_id))?);
        VaultSecret::decode(&plain)
    }

    async fn dek(&self, user_id: &str) -> Result<Zeroizing<[u8; DEK_LEN]>> {
        let now = Instant::now();
        {
            let mut cache = self.cache.lock().unwrap();
            match cache.get(user_id) {
                Some(c) if c.expires > now => return Ok((*c.dek).clone()),
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
        let dek = self.kms.unwrap(&wrapped, user_id).await?;
        let mut cache = self.cache.lock().unwrap();
        // 顺手清掉所有过期的条目，不让不再来的用户（包括已注销的）的 DEK 一直留在内存里。
        cache.retain(|_, c| c.expires > now);
        cache.insert(
            user_id.to_owned(),
            CachedDek {
                dek: Box::new(dek.clone()),
                expires: now + self.cache_ttl,
            },
        );
        Ok(dek)
    }
}

fn blob_aad(user_id: &str, object_id: &str) -> Vec<u8> {
    let mut out = b"thinktin/blob/v1/".to_vec();
    out.extend_from_slice(&(user_id.len() as u32).to_be_bytes());
    out.extend_from_slice(user_id.as_bytes());
    out.extend_from_slice(&(object_id.len() as u32).to_be_bytes());
    out.extend_from_slice(object_id.as_bytes());
    out
}

fn vault_aad(user_id: &str, item_id: &str) -> Vec<u8> {
    let mut out = b"thinktin/vault/v1/".to_vec();
    out.extend_from_slice(&(user_id.len() as u32).to_be_bytes());
    out.extend_from_slice(user_id.as_bytes());
    out.extend_from_slice(&(item_id.len() as u32).to_be_bytes());
    out.extend_from_slice(item_id.as_bytes());
    out
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

/// 比这短的值不抹：太容易误伤正常文字（保险箱也不收这么短的密码）。
pub const MIN_SCRUB_LEN: usize = 4;

/// 从文字里抹掉保险箱里的值（9.11）：模型网关转发前、运行日志落盘前用。
/// 每个值连同它的百分号编码、JSON 转义形式一起找，换成 `[vault:名字]`。
#[derive(Default)]
pub struct Scrubber {
    /// （值，替换成的标签），按值从长到短排。
    entries: Vec<(Zeroizing<String>, String)>,
}

impl std::fmt::Debug for Scrubber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Scrubber({} values)", self.entries.len())
    }
}

impl Scrubber {
    pub fn new() -> Self {
        Self::default()
    }

    /// 加一个要抹掉的值。太短的不加。
    pub fn add(&mut self, name: &str, value: &str) {
        if value.chars().count() < MIN_SCRUB_LEN {
            return;
        }
        let label = format!("[vault:{name}]");
        let mut forms = vec![value.to_owned(), percent_encode(value), json_escape(value)];
        forms.sort();
        forms.dedup();
        for form in forms {
            if !self.entries.iter().any(|(v, _)| **v == form) {
                self.entries.push((Zeroizing::new(form), label.clone()));
            }
        }
        self.entries.sort_by_key(|e| std::cmp::Reverse(e.0.len()));
    }

    /// 加一个条目的密码（账号不算秘密，不抹）。
    pub fn add_secret(&mut self, name: &str, secret: &VaultSecret) {
        self.add(name, &secret.password);
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 抹掉 `text` 里的值。没有要抹的返回 None。重叠时取靠前、较长的那个。
    pub fn scrub(&self, text: &str) -> Option<String> {
        let mut hits: Vec<(usize, usize, &str)> = Vec::new();
        for (value, label) in &self.entries {
            for (start, m) in text.match_indices(value.as_str()) {
                hits.push((start, start + m.len(), label.as_str()));
            }
        }
        if hits.is_empty() {
            return None;
        }
        hits.sort_by_key(|h| (h.0, std::cmp::Reverse(h.1)));
        let mut out = String::with_capacity(text.len());
        let mut at = 0;
        for (start, end, label) in hits {
            if start < at {
                continue;
            }
            out.push_str(&text[at..start]);
            out.push_str(label);
            at = end;
        }
        out.push_str(&text[at..]);
        Some(out)
    }
}

/// RFC 3986 的百分号编码（只留不保留字符），值出现在网址、表单里时是这个样子。
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// JSON 字符串里的转义形式（和 serde_json 一样不转义 `/`），值出现在没解析的 JSON 文本里时是这个样子。
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
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
    fn scrubber_replaces_values_and_their_encodings() {
        let mut s = Scrubber::new();
        s.add("github", "p@ss/w\"rd");
        s.add("pin", "123");
        s.add("mail", "mail-secret-1");
        s.add_secret(
            "bank",
            &VaultSecret {
                username: "alice".into(),
                password: "bank-pass".into(),
            },
        );
        assert!(!s.is_empty());
        assert_eq!(s.scrub("nothing here"), None);
        assert_eq!(
            s.scrub("login p@ss/w\"rd then mail-secret-1, mail-secret-1")
                .unwrap(),
            "login [vault:github] then [vault:mail], [vault:mail]"
        );
        // 网址里的百分号编码、没解析的 JSON 里的转义形式也抹掉；太短的值、账号不抹。
        assert_eq!(
            s.scrub("https://u:p%40ss%2Fw%22rd@host").unwrap(),
            "https://u:[vault:github]@host"
        );
        assert_eq!(
            s.scrub(r#"{"pw":"p@ss/w\"rd"}"#).unwrap(),
            r#"{"pw":"[vault:github]"}"#
        );
        assert_eq!(s.scrub("pin 123 for alice"), None);
        assert_eq!(s.scrub("bank-pass").unwrap(), "[vault:bank]");
        // 重叠：取靠前、较长的。
        let mut o = Scrubber::new();
        o.add("short", "abcd");
        o.add("long", "abcdef");
        assert_eq!(
            o.scrub("xabcdefx abcd").unwrap(),
            "x[vault:long]x [vault:short]"
        );
        assert!(!format!("{s:?}").contains("bank-pass"));
    }

    #[tokio::test]
    async fn vault_secrets_roundtrip_and_stay_in_their_domain() {
        let v = vault();
        v.create_user_key("u1").await.unwrap();
        v.create_user_key("u2").await.unwrap();
        let secret = VaultSecret {
            username: "张三@example.com".into(),
            password: "p@ss wörd".into(),
        };
        let sealed = v.seal_vault("u1", "item-1", &secret).await.unwrap();
        assert_eq!(v.open_vault("u1", "item-1", &sealed).await.unwrap(), secret);
        let no_user = VaultSecret {
            username: String::new(),
            password: "x".repeat(300),
        };
        let sealed2 = v.seal_vault("u1", "item-2", &no_user).await.unwrap();
        assert_eq!(
            v.open_vault("u1", "item-2", &sealed2).await.unwrap(),
            no_user
        );
        // 挪到别的条目、别的用户、别的域（key、产出物）都解不开。
        assert!(v.open_vault("u1", "item-2", &sealed).await.is_err());
        assert!(v.open_vault("u2", "item-1", &sealed).await.is_err());
        assert!(v.open_bytes("u1", "item-1", &sealed).await.is_err());
        let blob = v
            .seal_bytes("u1", "item-1", b"\x01\0\0\0\0pw")
            .await
            .unwrap();
        assert!(v.open_vault("u1", "item-1", &blob).await.is_err());
        assert!(!format!("{secret:?}").contains("wörd"));
        assert!(VaultSecret::decode(&[1, 0, 0, 0, 9, b'a']).is_err());
        assert!(VaultSecret::decode(&[2, 0, 0, 0, 0]).is_err());
    }

    #[tokio::test]
    async fn seal_and_open_roundtrip() {
        let v = vault();
        v.create_user_key("u1").await.unwrap();
        let sealed = v
            .seal("u1", "k1", &key("sk-deepseek-1234567890abcd"))
            .await
            .unwrap();
        assert_eq!(sealed.last4, "abcd");
        assert!(!String::from_utf8_lossy(&sealed.ciphertext).contains("sk-deepseek"));
        let opened = v.open("u1", "k1", &sealed).await.unwrap();
        assert_eq!(opened.expose_secret(), "sk-deepseek-1234567890abcd");
    }

    #[tokio::test]
    async fn ciphertext_is_bound_to_user_and_record() {
        let v = vault();
        v.create_user_key("u1").await.unwrap();
        v.create_user_key("u2").await.unwrap();
        let sealed = v
            .seal("u1", "k1", &key("sk-aaaaaaaaaaaaaaaa"))
            .await
            .unwrap();
        assert!(matches!(
            v.open("u1", "k2", &sealed).await,
            Err(Error::Decrypt)
        ));
        assert!(matches!(
            v.open("u2", "k1", &sealed).await,
            Err(Error::Decrypt)
        ));
        let mut tampered = sealed.clone();
        *tampered.ciphertext.last_mut().unwrap() ^= 1;
        assert!(matches!(
            v.open("u1", "k1", &tampered).await,
            Err(Error::Decrypt)
        ));
    }

    #[tokio::test]
    async fn nonces_are_unique() {
        let v = vault();
        v.create_user_key("u1").await.unwrap();
        let a = v
            .seal("u1", "k1", &key("sk-same-secret-value"))
            .await
            .unwrap();
        let b = v
            .seal("u1", "k1", &key("sk-same-secret-value"))
            .await
            .unwrap();
        assert_ne!(a.ciphertext, b.ciphertext);
    }

    #[tokio::test]
    async fn destroying_user_key_shreds_secrets() {
        let v = vault();
        v.create_user_key("u1").await.unwrap();
        let sealed = v
            .seal("u1", "k1", &key("sk-bbbbbbbbbbbbbbbb"))
            .await
            .unwrap();
        v.open("u1", "k1", &sealed).await.unwrap(); // 进缓存
        assert!(v.destroy_user_key("u1"));
        assert!(matches!(
            v.open("u1", "k1", &sealed).await,
            Err(Error::NoUserKey(_))
        ));
        // 重新建用户密钥也解不开旧密文。
        v.create_user_key("u1").await.unwrap();
        assert!(matches!(
            v.open("u1", "k1", &sealed).await,
            Err(Error::Decrypt)
        ));
    }

    #[tokio::test]
    async fn user_key_is_never_overwritten() {
        let v = vault();
        v.create_user_key("u1").await.unwrap();
        assert!(matches!(
            v.create_user_key("u1").await,
            Err(Error::UserKeyExists(_))
        ));
    }

    #[tokio::test]
    async fn wrapped_dek_is_bound_to_user_and_kms_key() {
        let kms = LocalKms::new("local-1", &[7u8; 32]);
        let wrapped = kms.wrap(&[9u8; 32], "u1").await.unwrap();
        assert_eq!(*kms.unwrap(&wrapped, "u1").await.unwrap(), [9u8; 32]);
        assert!(kms.unwrap(&wrapped, "u2").await.is_err());
        let other = LocalKms::new("local-2", &[7u8; 32]);
        assert!(matches!(
            other.unwrap(&wrapped, "u1").await,
            Err(Error::UnknownKmsKey(_))
        ));
    }

    #[tokio::test]
    async fn expired_deks_are_swept_and_can_be_forgotten() {
        let v = vault().with_cache_ttl(Duration::from_millis(20));
        for u in ["u1", "u2"] {
            v.create_user_key(u).await.unwrap();
            v.seal(u, "r", &SecretString::from("sk-test-0000".to_owned()))
                .await
                .unwrap();
        }
        assert_eq!(v.cache.lock().unwrap().len(), 2);
        tokio::time::sleep(Duration::from_millis(30)).await;
        // 别的用户来取 DEK 时，过期的条目一并清掉。
        v.create_user_key("u3").await.unwrap();
        v.seal("u3", "r", &SecretString::from("sk-test-0000".to_owned()))
            .await
            .unwrap();
        assert_eq!(v.cache.lock().unwrap().keys().collect::<Vec<_>>(), ["u3"]);
        SecretOpener::forget_user(&v, "u3");
        assert!(v.cache.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn blobs_are_bound_to_user_and_object() {
        let vault = KeyVault::new(LocalKms::new("k", &[1; 32]), MemoryKeyStore::default());
        vault.create_user_key("u1").await.unwrap();
        vault.create_user_key("u2").await.unwrap();
        let sealed = vault.seal_bytes("u1", "a1", b"report body").await.unwrap();
        assert_eq!(
            vault.open_bytes("u1", "a1", &sealed).await.unwrap(),
            b"report body"
        );
        assert!(vault.open_bytes("u1", "a2", &sealed).await.is_err());
        assert!(vault.open_bytes("u2", "a1", &sealed).await.is_err());
        // 和 key 的密文域分开：同样的 id 也解不开。
        let key = vault
            .seal("u1", "a1", &SecretString::from("sk-test-1234".to_string()))
            .await
            .unwrap();
        assert!(vault.open_bytes("u1", "a1", &key.ciphertext).await.is_err());
    }

    /// 数解包次数的 KMS（看缓存有没有挡住重复调用）。
    struct Counting(LocalKms, std::sync::atomic::AtomicUsize);

    #[async_trait]
    impl Kms for Counting {
        fn current_key_id(&self) -> &str {
            self.0.current_key_id()
        }
        async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> Result<WrappedKey> {
            self.0.wrap(dek, context).await
        }
        async fn unwrap(
            &self,
            wrapped: &WrappedKey,
            context: &str,
        ) -> Result<Zeroizing<[u8; DEK_LEN]>> {
            self.1.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.0.unwrap(wrapped, context).await
        }
    }

    #[tokio::test]
    async fn a_ring_unwraps_with_older_master_keys() {
        let old: Arc<dyn Kms> = Arc::new(LocalKms::new("local-1", &[1; 32]));
        let new: Arc<dyn Kms> = Arc::new(LocalKms::new("cloud-1", &[2; 32]));
        let legacy = old.wrap(&[5; 32], "u1").await.unwrap();
        let ring = KmsRing::new(new.clone()).with_older(old);
        assert_eq!(ring.current_key_id(), "cloud-1");
        // 老的 DEK 用老的主密钥解，新的 DEK 用新的包裹。
        assert_eq!(*ring.unwrap(&legacy, "u1").await.unwrap(), [5; 32]);
        let fresh = ring.wrap(&[6; 32], "u1").await.unwrap();
        assert_eq!(fresh.kms_key_id, "cloud-1");
        assert_eq!(*ring.unwrap(&fresh, "u1").await.unwrap(), [6; 32]);
        let unknown = WrappedKey {
            kms_key_id: "gone".into(),
            ciphertext: fresh.ciphertext.clone(),
        };
        assert!(matches!(
            ring.unwrap(&unknown, "u1").await,
            Err(Error::UnknownKmsKey(_))
        ));
    }

    #[tokio::test]
    async fn the_cache_spares_repeated_kms_calls() {
        let kms = CachingKms::new(
            Counting(LocalKms::new("k", &[3; 32]), Default::default()),
            Duration::from_millis(50),
        );
        let w = kms.wrap(&[8; 32], "u1").await.unwrap();
        for _ in 0..3 {
            assert_eq!(*kms.unwrap(&w, "u1").await.unwrap(), [8; 32]);
        }
        assert_eq!(kms.inner.1.load(std::sync::atomic::Ordering::SeqCst), 1);
        // 用户对不上不能命中别人的缓存，照样解包失败。
        assert!(kms.unwrap(&w, "u2").await.is_err());
        // 过期以后重新解包。
        tokio::time::sleep(Duration::from_millis(60)).await;
        kms.unwrap(&w, "u1").await.unwrap();
        assert_eq!(kms.inner.1.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[test]
    fn last4_never_reveals_short_keys() {
        assert_eq!(last4("short"), "****");
        assert_eq!(last4("sk-0123456789ab"), "89ab");
    }

    #[tokio::test]
    async fn local_kms_from_hex() {
        let hex = "07".repeat(32);
        let kms = LocalKms::from_hex("k", &hex).unwrap();
        let w = kms.wrap(&[1u8; 32], "u").await.unwrap();
        assert_eq!(*kms.unwrap(&w, "u").await.unwrap(), [1u8; 32]);
        assert!(LocalKms::from_hex("k", "zz").is_err());
    }
}
