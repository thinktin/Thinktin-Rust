//! 工作区归档放进对象存储（没有工作区卷的沙箱后端，见 docs/sandbox-acs.md）：沙箱里打好的 tar.gz
//! 按用户 DEK 分块加密，写进临时文件（只有密文落盘）再整个上传；放回时下载到临时文件，逐块解密写给沙箱。
//! 和产出物共用一个对象存储（键在 `workspaces/` 下）和一个清理队列。

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use control::{ArchiveMeta, WorkspaceStore};
use keyvault::{CHUNK_LEN, FRAME_HEADER_LEN, Kms};
use proto::domain::UserId;
use sha2::{Digest, Sha256};
use store::{Db, WorkspaceArchive};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

use crate::artifacts::{BlobStore, user_vault};

pub struct ObjectWorkspaceStore {
    db: Db,
    blobs: Arc<dyn BlobStore>,
    kms: Arc<dyn Kms>,
    /// 放密文临时文件的目录（后台副本的 /tmp 是单独的临时卷）。
    temp_dir: PathBuf,
    /// 临时文件一共最多占多少（MiB）：同时有几个存、放时按大小排队，不把临时卷撑爆（撑爆了副本会被驱逐）。
    temp_budget: Arc<Semaphore>,
    temp_budget_mib: u32,
    /// 一次上传或下载的上限。
    timeout: Duration,
}

/// 每块密文比明文多出的字节：帧头、nonce、校验码。
const FRAME_OVERHEAD: u64 = FRAME_HEADER_LEN as u64 + 28;

/// 明文 `bytes` 字节加密后最多多大（最后可能多一个空块）。
fn sealed_len(bytes: u64) -> u64 {
    bytes + (bytes / CHUNK_LEN as u64 + 2) * FRAME_OVERHEAD
}

impl ObjectWorkspaceStore {
    /// `temp_budget` 是临时文件一共能占的字节数，要放得下最大的一份归档。
    pub fn new(
        db: Db,
        blobs: Arc<dyn BlobStore>,
        kms: Arc<dyn Kms>,
        temp_dir: impl Into<PathBuf>,
        temp_budget: u64,
        timeout: Duration,
    ) -> Self {
        let mib = u32::try_from((temp_budget >> 20).max(1)).unwrap_or(u32::MAX);
        Self {
            db,
            blobs,
            kms,
            temp_dir: temp_dir.into(),
            temp_budget: Arc::new(Semaphore::new(mib as usize)),
            temp_budget_mib: mib,
            timeout,
        }
    }

    /// 先占好临时文件的空间（放不下时等别的存、放做完）。
    async fn reserve(&self, bytes: u64) -> Result<OwnedSemaphorePermit, String> {
        let mib = u32::try_from(sealed_len(bytes).div_ceil(1 << 20)).unwrap_or(u32::MAX);
        if mib > self.temp_budget_mib {
            return Err(format!(
                "the workspace archive needs {mib} MiB of temp space, more than the {} MiB budget",
                self.temp_budget_mib
            ));
        }
        self.temp_budget
            .clone()
            .acquire_many_owned(mib)
            .await
            .map_err(|e| e.to_string())
    }

    /// 归档只能是这个用户自己的（键是 [`WorkspaceStore::key`] 生成的）。
    fn check_owner(&self, user: UserId, key: &str) -> Result<(), String> {
        let own = format!("workspaces/{}/", user.0.simple());
        if key.starts_with(&own) {
            Ok(())
        } else {
            Err("the workspace archive belongs to another user".into())
        }
    }

    fn temp_file(&self) -> Result<(tempfile::NamedTempFile, tokio::fs::File), String> {
        let tmp = tempfile::NamedTempFile::new_in(&self.temp_dir)
            .map_err(|e| format!("temp file in {}: {e}", self.temp_dir.display()))?;
        let file = tmp.reopen().map_err(|e| format!("temp file: {e}"))?;
        Ok((tmp, tokio::fs::File::from_std(file)))
    }
}

/// 读满一块（最多 [`CHUNK_LEN`]），读到末尾时可能不满。
async fn read_chunk(data: &mut (dyn AsyncRead + Send + Unpin)) -> Result<Vec<u8>, String> {
    let mut buf = Vec::with_capacity(CHUNK_LEN);
    (&mut *data)
        .take(CHUNK_LEN as u64)
        .read_to_end(&mut buf)
        .await
        .map_err(|e| format!("reading the workspace: {e}"))?;
    Ok(buf)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[async_trait]
impl WorkspaceStore for ObjectWorkspaceStore {
    async fn put(
        &self,
        user: UserId,
        key: &str,
        id: Uuid,
        data: &mut (dyn AsyncRead + Send + Unpin),
        max: u64,
    ) -> Result<ArchiveMeta, String> {
        self.check_owner(user, key)?;
        let _space = self.reserve(max).await?;
        let vault = user_vault(&self.db, self.kms.clone(), user, true)
            .await
            .map_err(|e| format!("user key: {e}"))?;
        let mut sealer = vault
            .workspace_sealer(&user.to_string(), &id.to_string())
            .await
            .map_err(|e| format!("user key: {e}"))?;
        let (tmp, mut file) = self.temp_file()?;
        let mut plain_sha = Sha256::new();
        let mut cipher_sha = Sha256::new();
        let (mut plain_len, mut cipher_len) = (0u64, 0u64);
        // 读到下一块是空的，才知道这一块是最后一块。
        let mut chunk = read_chunk(data).await?;
        loop {
            let next = if chunk.len() == CHUNK_LEN {
                read_chunk(data).await?
            } else {
                Vec::new()
            };
            let last = next.is_empty();
            plain_len += chunk.len() as u64;
            if plain_len > max {
                return Err(format!("the workspace archive is larger than {max} bytes"));
            }
            plain_sha.update(&chunk);
            let frame = sealer
                .seal(&chunk, last)
                .map_err(|e| format!("encrypting: {e}"))?;
            cipher_sha.update(&frame);
            cipher_len += frame.len() as u64;
            file.write_all(&frame)
                .await
                .map_err(|e| format!("temp file: {e}"))?;
            if last {
                break;
            }
            chunk = next;
        }
        file.flush().await.map_err(|e| format!("temp file: {e}"))?;
        drop(file);
        self.blobs
            .put_file(
                key,
                tmp.path(),
                cipher_len,
                &hex(&cipher_sha.finalize()),
                self.timeout,
            )
            .await
            .map_err(|e| format!("uploading: {e}"))?;
        Ok(ArchiveMeta {
            id,
            bytes: plain_len,
            sha256: plain_sha.finalize().into(),
        })
    }

    async fn restore(
        &self,
        user: UserId,
        archive: &WorkspaceArchive,
        sink: &mut (dyn AsyncWrite + Send + Unpin),
    ) -> Result<(), String> {
        self.check_owner(user, &archive.key)?;
        let _space = self.reserve(archive.bytes).await?;
        let (tmp, _) = self.temp_file()?;
        let max = sealed_len(archive.bytes);
        self.blobs
            .get_to_file(&archive.key, tmp.path(), max, self.timeout)
            .await
            .map_err(|e| format!("downloading: {e}"))?;
        let vault = user_vault(&self.db, self.kms.clone(), user, false)
            .await
            .map_err(|e| format!("user key: {e}"))?;
        let mut opener = vault
            .workspace_opener(&user.to_string(), &archive.id.to_string())
            .await
            .map_err(|e| format!("user key: {e}"))?;
        let mut file = tokio::io::BufReader::new(
            tokio::fs::File::open(tmp.path())
                .await
                .map_err(|e| format!("temp file: {e}"))?,
        );
        let mut sha = Sha256::new();
        let mut total = 0u64;
        let broken = |what: &str| format!("the workspace archive is damaged ({what})");
        loop {
            // 帧之间正好读完才算结束；半个帧头也是截断。
            let mut header = [0u8; FRAME_HEADER_LEN];
            match file.read(&mut header[..1]).await {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) => return Err(format!("temp file: {e}")),
            }
            file.read_exact(&mut header[1..])
                .await
                .map_err(|_| broken("truncated"))?;
            let (len, last) = opener.frame(&header).map_err(|_| broken("frame"))?;
            let mut body = vec![0u8; len];
            file.read_exact(&mut body)
                .await
                .map_err(|_| broken("truncated"))?;
            let plain = opener.open(&body, last).map_err(|_| broken("chunk"))?;
            sha.update(&plain);
            total += plain.len() as u64;
            sink.write_all(&plain)
                .await
                .map_err(|e| format!("writing to the sandbox: {e}"))?;
        }
        opener.finish().map_err(|_| broken("truncated"))?;
        let digest: [u8; 32] = sha.finalize().into();
        if total != archive.bytes || digest != archive.sha256 {
            return Err(broken("does not match its record"));
        }
        sink.flush()
            .await
            .map_err(|e| format!("writing to the sandbox: {e}"))
    }
}
