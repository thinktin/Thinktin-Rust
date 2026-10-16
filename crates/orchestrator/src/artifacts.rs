//! 产出物服务（WBS 8.4）：agent 之间不直接通信，数据通过平台的产出物传递。
//! 内容按用户 DEK 加密后放进对象存储（[`BlobStore`]，生产是 S3 / OSS，开发是本地目录），
//! 索引在 `artifacts` 表里：名字在一棵运行树里唯一，同名再发布是新版本。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use keyvault::{KeyStore, KeyVault, Kms, MemoryKeyStore, WrappedKey};
use proto::domain::{ArtifactId, InstanceId, RunId, UserId};
use sha2::{Digest, Sha256};
use store::{Db, NewArtifact, StoredArtifact};

/// 单个产出物的大小上限。
pub const MAX_ARTIFACT_BYTES: usize = 20 << 20;

#[derive(Debug, thiserror::Error)]
pub enum ArtifactError {
    #[error("invalid: {0}")]
    Invalid(String),
    #[error(transparent)]
    Store(#[from] store::Error),
    #[error("encryption: {0}")]
    Crypto(#[from] keyvault::Error),
    #[error("object storage: {0}")]
    Blob(#[from] std::io::Error),
}

/// 对象存储。键由平台生成（`<用户>/<产出物>`），内容已经加密。
#[async_trait]
pub trait BlobStore: Send + Sync {
    async fn put(&self, key: &str, bytes: &[u8]) -> std::io::Result<()>;
    async fn get(&self, key: &str) -> std::io::Result<Vec<u8>>;
    /// 不存在也算成功。
    async fn delete(&self, key: &str) -> std::io::Result<()>;
}

/// 本地目录（开发、测试）。
pub struct LocalBlobStore {
    root: PathBuf,
}

impl LocalBlobStore {
    pub fn new(root: impl Into<PathBuf>) -> std::io::Result<Self> {
        let root = root.into();
        std::fs::create_dir_all(&root)?;
        Ok(Self { root })
    }

    fn path(&self, key: &str) -> std::io::Result<PathBuf> {
        let ok = !key.is_empty()
            && key.split('/').all(|p| {
                !p.is_empty()
                    && p != "."
                    && p != ".."
                    && p.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            });
        if !ok {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "bad blob key",
            ));
        }
        Ok(self.root.join(Path::new(key)))
    }
}

#[async_trait]
impl BlobStore for LocalBlobStore {
    async fn put(&self, key: &str, bytes: &[u8]) -> std::io::Result<()> {
        let path = self.path(key)?;
        if let Some(dir) = path.parent() {
            tokio::fs::create_dir_all(dir).await?;
        }
        // 先写临时文件再改名：读的人不会看到写了一半的内容。
        let tmp = path.with_extension("tmp");
        tokio::fs::write(&tmp, bytes).await?;
        tokio::fs::rename(&tmp, &path).await
    }

    async fn get(&self, key: &str) -> std::io::Result<Vec<u8>> {
        tokio::fs::read(self.path(key)?).await
    }

    async fn delete(&self, key: &str) -> std::io::Result<()> {
        match tokio::fs::remove_file(self.path(key)?).await {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            r => r,
        }
    }
}

/// 拿到用户的 DEK（`create` 时没有就生成一个；并发生成时以先写进库的为准），包成只含这个用户的密钥库。
pub async fn user_vault(
    db: &Db,
    kms: Arc<dyn Kms>,
    user: UserId,
    create: bool,
) -> Result<KeyVault<Arc<dyn Kms>, MemoryKeyStore>, ArtifactError> {
    let uid = user.to_string();
    let with_key = |kms_key_id: String, ciphertext: Vec<u8>| {
        let store = MemoryKeyStore::default();
        store.insert_new(
            &uid,
            WrappedKey {
                kms_key_id,
                ciphertext,
            },
        );
        KeyVault::new(kms.clone(), store)
    };
    let mut w = db.worker().await?;
    if let Some((kms_key_id, ciphertext)) = w.user_key(user).await? {
        w.rollback().await?;
        return Ok(with_key(kms_key_id, ciphertext));
    }
    if !create {
        return Err(keyvault::Error::NoUserKey(uid).into());
    }
    let vault = KeyVault::new(kms.clone(), MemoryKeyStore::default());
    vault.create_user_key(&uid).await?;
    let wrapped = vault
        .store()
        .get(&uid)
        .ok_or_else(|| ArtifactError::Invalid("generated key vanished".into()))?;
    match w
        .insert_user_key(user, &wrapped.kms_key_id, &wrapped.ciphertext)
        .await
    {
        Ok(()) => {
            w.commit().await?;
            Ok(vault)
        }
        Err(store::Error::Conflict(_)) => {
            drop(w);
            let mut w = db.worker().await?;
            let (kms_key_id, ciphertext) = w
                .user_key(user)
                .await?
                .ok_or_else(|| ArtifactError::Invalid("user key disappeared".into()))?;
            w.rollback().await?;
            Ok(with_key(kms_key_id, ciphertext))
        }
        Err(e) => Err(e.into()),
    }
}

/// 产出物名：文件名风格，不含路径分隔符。
pub fn check_name(name: &str) -> Result<(), ArtifactError> {
    let ok = !name.is_empty()
        && name.chars().count() <= 200
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | '.' | ' '));
    if ok {
        Ok(())
    } else {
        Err(ArtifactError::Invalid(
            "artifact names are file names (letters, digits, - _ . and spaces, no leading dot)"
                .into(),
        ))
    }
}

/// 内容类型：agent 给的，要是短的、合法的 MIME 类型（`type/subtype`，可带 `; key=value` 参数）。
/// 它会原样作为下载的 Content-Type 返回。
pub fn check_content_type(ct: &str) -> Result<(), ArtifactError> {
    let token = |t: &str| {
        !t.is_empty()
            && t.len() <= 127
            && t.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$&^_.+-".contains(&b))
    };
    let mut parts = ct.split(';');
    let base_ok = parts
        .next()
        .and_then(|b| b.trim().split_once('/'))
        .is_some_and(|(t, sub)| token(t) && token(sub));
    let params_ok = parts.all(|p| {
        p.trim()
            .split_once('=')
            .is_some_and(|(k, v)| token(k) && token(v.trim_matches('"')))
    });
    if ct.len() <= 200 && base_ok && params_ok {
        Ok(())
    } else {
        Err(ArtifactError::Invalid(
            "content_type must be a MIME type like text/markdown".into(),
        ))
    }
}

pub struct ArtifactStore {
    db: Db,
    blobs: Arc<dyn BlobStore>,
    kms: Arc<dyn Kms>,
}

/// 发布时的来源：哪个用户的哪个运行。
#[derive(Debug, Clone, Copy)]
pub struct Origin {
    pub user: UserId,
    pub instance: InstanceId,
    pub run: RunId,
    pub root: RunId,
}

impl ArtifactStore {
    pub fn new(db: Db, blobs: Arc<dyn BlobStore>, kms: Arc<dyn Kms>) -> Self {
        Self { db, blobs, kms }
    }

    /// 加密、存进对象存储、登记索引。
    pub async fn publish(
        &self,
        origin: Origin,
        name: &str,
        content_type: &str,
        bytes: &[u8],
    ) -> Result<StoredArtifact, ArtifactError> {
        check_name(name)?;
        check_content_type(content_type)?;
        if bytes.len() > MAX_ARTIFACT_BYTES {
            return Err(ArtifactError::Invalid(format!(
                "artifacts are limited to {} MiB",
                MAX_ARTIFACT_BYTES >> 20
            )));
        }
        let id = ArtifactId::new();
        let vault = user_vault(&self.db, self.kms.clone(), origin.user, true).await?;
        let sealed = vault
            .seal_bytes(&origin.user.to_string(), &id.to_string(), bytes)
            .await?;
        let key = format!("{}/{}", origin.user.0.simple(), id.0.simple());
        self.blobs.put(&key, &sealed).await?;
        let sha: [u8; 32] = Sha256::digest(bytes).into();
        let stored = async {
            let mut w = self.db.worker().await?;
            let a = w
                .insert_artifact(&NewArtifact {
                    id,
                    user: origin.user,
                    instance: origin.instance,
                    run: origin.run,
                    root: origin.root,
                    name,
                    content_type,
                    size: bytes.len() as u64,
                    sha256: &sha,
                    blob_key: &key,
                })
                .await?;
            w.append_event(
                origin.instance,
                Some(origin.run),
                "artifact.published",
                &serde_json::json!({ "artifact_id": a.artifact.id, "name": name, "version": a.artifact.version, "size": a.artifact.size }),
            )
            .await?;
            w.commit().await?;
            Ok::<_, store::Error>(a)
        }
        .await;
        match stored {
            Ok(a) => Ok(a),
            Err(e) => {
                // 索引没写成：内容也删掉，不留孤儿。
                let _ = self.blobs.delete(&key).await;
                Err(e.into())
            }
        }
    }

    /// 取出并解密。
    pub async fn read(&self, a: &StoredArtifact) -> Result<Vec<u8>, ArtifactError> {
        let sealed = self.blobs.get(&a.blob_key).await?;
        let vault = user_vault(&self.db, self.kms.clone(), a.user_id, false).await?;
        Ok(vault
            .open_bytes(&a.user_id.to_string(), &a.artifact.id.to_string(), &sealed)
            .await?)
    }

    pub async fn delete_blob(&self, key: &str) -> Result<(), ArtifactError> {
        Ok(self.blobs.delete(key).await?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_types_are_short_mime_types() {
        for ok in [
            "text/markdown",
            "text/plain; charset=utf-8",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "image/svg+xml",
        ] {
            assert!(check_content_type(ok).is_ok(), "{ok}");
        }
        let long = format!("text/{}", "x".repeat(300));
        for bad in [
            "",
            "markdown",
            "text/",
            "text/html\r\nX-Evil: 1",
            "text/plain; charset",
            long.as_str(),
        ] {
            assert!(check_content_type(bad).is_err(), "{bad:?}");
        }
    }
}
