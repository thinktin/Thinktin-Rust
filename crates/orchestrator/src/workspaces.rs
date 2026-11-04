//! 工作区归档放进对象存储（没有工作区卷的沙箱后端，见 docs/sandbox-acs.md）：沙箱里打好的 tar.gz
//! 按用户 DEK 分块加密，写进临时文件（只有密文落盘）再整个上传；放回时下载到临时文件，逐块解密写给沙箱。
//! 和产出物共用一个对象存储（键在 `workspaces/` 下）和一个清理队列。

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use control::{ArchiveMeta, PutTicket, WorkspaceStore};
use keyvault::{CHUNK_LEN, FRAME_HEADER_LEN, Kms};
use proto::domain::UserId;
use sha2::{Digest, Sha256};
use store::{Db, WorkspaceArchive};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tracing::warn;
use uuid::Uuid;

use crate::artifacts::{BlobStore, user_vault};

pub struct ObjectWorkspaceStore {
    db: Db,
    blobs: Arc<dyn BlobStore>,
    kms: Arc<dyn Kms>,
    /// 这个进程放密文临时文件的目录：`<temp_dir>/thinktin-workspaces/<随机>/`，里面的锁文件一直锁着。
    /// 进程被杀时来不及删的临时文件，下次启动时连目录删掉（锁随进程释放）。
    temp_dir: PathBuf,
    _temp_lock: std::fs::File,
    /// 临时文件的空间（MiB），存、放各占一半，各自按大小排队，不把临时卷撑爆（撑爆了副本会被驱逐）。
    /// 分开排是因为等着存的不该挡住放回（放回时用户在等）。
    puts: Pool,
    restores: Pool,
    /// 一次上传或下载的上限。
    timeout: Duration,
}

struct Pool {
    permits: Arc<Semaphore>,
    mib: u32,
}

impl Pool {
    fn new(mib: u32) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(mib as usize)),
            mib,
        }
    }

    /// 先占好明文 `bytes` 字节的归档加密后要的空间（不够时等别的做完）。
    async fn reserve(&self, bytes: u64) -> Result<OwnedSemaphorePermit, String> {
        let need = mib(sealed_len(bytes));
        if need > self.mib {
            return Err(too_big(need, self.mib));
        }
        self.take(need).await
    }

    async fn take(&self, mib: u32) -> Result<OwnedSemaphorePermit, String> {
        self.permits
            .clone()
            .acquire_many_owned(mib)
            .await
            .map_err(|e| e.to_string())
    }
}

fn too_big(need: u32, have: u32) -> String {
    format!(
        "the workspace archive needs {need} MiB of temp space, more than the {have} MiB available"
    )
}

/// 放回占的临时空间：一般只从放的一边（`own`）占。比那一边还大的（调小上限之前存的大归档）把这一边全占上，
/// 不够的再从存的一边（`spill`）占，排在它们后面等：照样放得回来，只是要等。两边加起来都不够才报错。
/// 总是先占 `own` 再占 `spill`，存的只占 `spill`，不会互相等死。
async fn reserve_restore(
    own: &Pool,
    spill: &Pool,
    bytes: u64,
) -> Result<Vec<OwnedSemaphorePermit>, String> {
    let need = mib(sealed_len(bytes));
    if need <= own.mib {
        return Ok(vec![own.take(need).await?]);
    }
    if need > own.mib.saturating_add(spill.mib) {
        return Err(too_big(need, own.mib.saturating_add(spill.mib)));
    }
    let all = own.take(own.mib).await?;
    let rest = spill.take(need - own.mib).await?;
    Ok(vec![all, rest])
}

/// 每块密文比明文多出的字节：帧头、nonce、校验码。
const FRAME_OVERHEAD: u64 = FRAME_HEADER_LEN as u64 + 28;

/// 各进程的临时目录放在 `temp_dir` 下的这里。
const TEMP_SUBDIR: &str = "thinktin-workspaces";
const LOCK_FILE: &str = ".lock";

/// 明文 `bytes` 字节加密后最多多大（最后可能多一个空块）。
fn sealed_len(bytes: u64) -> u64 {
    bytes + (bytes / CHUNK_LEN as u64 + 2) * FRAME_OVERHEAD
}

fn mib(bytes: u64) -> u32 {
    u32::try_from(bytes.div_ceil(1 << 20)).unwrap_or(u32::MAX)
}

/// 临时空间 `budget` 字节（向下取整到 MiB）分给存、放两边。
fn split_budget(budget: u64) -> (u32, u32) {
    let total = u32::try_from(budget >> 20).unwrap_or(u32::MAX);
    (total / 2, total - total / 2)
}

/// `budget` 字节的临时空间够不够存、放 `max_bytes` 的归档：两边各要放得下一份（和运行时一样算，启动时查）。
pub fn temp_budget_fits(max_bytes: u64, budget: u64) -> bool {
    let (puts, restores) = split_budget(budget);
    let need = mib(sealed_len(max_bytes));
    puts >= need && restores >= need
}

/// 放得下 `max_bytes` 的归档最少要多少临时空间（报错时提示用）。
pub fn min_temp_budget(max_bytes: u64) -> u64 {
    (u64::from(mib(sealed_len(max_bytes))) * 2) << 20
}

/// 删掉进程已经没了的临时目录（锁得上说明没人锁着）。刚建、还没来得及锁的目录（一分钟内）不动。
fn clear_abandoned(base: &Path) {
    let Ok(entries) = std::fs::read_dir(base) else {
        return;
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let abandoned = match std::fs::File::open(dir.join(LOCK_FILE)) {
            Ok(lock) => lock.try_lock().is_ok(),
            Err(_) => entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| SystemTime::now().duration_since(t).ok())
                .is_some_and(|age| age > Duration::from_secs(60)),
        };
        if abandoned && let Err(e) = std::fs::remove_dir_all(&dir) {
            warn!(dir = %dir.display(), error = %e, "could not remove abandoned workspace temp files");
        }
    }
}

impl ObjectWorkspaceStore {
    /// `temp_budget` 是临时文件一共能占的字节数，存、放各一半，各要放得下最大的一份归档
    /// （[`temp_budget_fits`]）。在 `temp_dir` 下建这个进程自己的临时目录，顺便删掉进程没了的留下的。
    pub fn new(
        db: Db,
        blobs: Arc<dyn BlobStore>,
        kms: Arc<dyn Kms>,
        temp_dir: impl Into<PathBuf>,
        temp_budget: u64,
        timeout: Duration,
    ) -> std::io::Result<Self> {
        let base = temp_dir.into().join(TEMP_SUBDIR);
        std::fs::create_dir_all(&base)?;
        clear_abandoned(&base);
        let dir = base.join(Uuid::now_v7().simple().to_string());
        std::fs::create_dir(&dir)?;
        let lock = std::fs::File::create(dir.join(LOCK_FILE))?;
        lock.try_lock().map_err(std::io::Error::from)?;
        let (puts, restores) = split_budget(temp_budget);
        Ok(Self {
            db,
            blobs,
            kms,
            temp_dir: dir,
            _temp_lock: lock,
            puts: Pool::new(puts),
            restores: Pool::new(restores),
            timeout,
        })
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
    async fn reserve_put(&self, max: u64) -> Result<PutTicket, String> {
        Ok(PutTicket::new(self.puts.reserve(max).await?))
    }

    async fn put(
        &self,
        user: UserId,
        key: &str,
        id: Uuid,
        data: &mut (dyn AsyncRead + Send + Unpin),
        max: u64,
        ticket: PutTicket,
    ) -> Result<ArchiveMeta, String> {
        self.check_owner(user, key)?;
        let _space = if ticket.is_empty() {
            PutTicket::new(self.puts.reserve(max).await?)
        } else {
            ticket
        };
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
        let _space = reserve_restore(&self.restores, &self.puts, archive.bytes).await?;
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

    async fn delete(&self, user: UserId, key: &str) -> Result<(), String> {
        self.check_owner(user, key)?;
        self.blobs
            .delete(key)
            .await
            .map_err(|e| format!("deleting: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn budget_checks_match_the_reservations() {
        let max = 4u64 << 30;
        let need = mib(sealed_len(max));
        assert_eq!(need, 4097);
        assert!(
            !temp_budget_fits(max, 8 << 30),
            "8 GiB holds one save, not one of each"
        );
        assert!(temp_budget_fits(max, min_temp_budget(max)));
        assert!(!temp_budget_fits(max, min_temp_budget(max) - 1));
        assert!(temp_budget_fits(max, 9 << 30));
        // 小上限时舍入比 1% 多：按 MiB 算，不按比例。
        let small = 50u64 << 20;
        assert!(!temp_budget_fits(small, 53_000_000 * 2));
        assert!(temp_budget_fits(small, min_temp_budget(small)));
    }

    /// 调小上限之前存的大归档：放的一边不够时连存的一边也占上，等存的做完；两边都不够才报错。
    #[tokio::test]
    async fn large_restores_borrow_the_save_side() {
        let (own, spill) = (Pool::new(12), Pool::new(12));
        let small = reserve_restore(&own, &spill, 4 << 20).await.unwrap();
        assert_eq!(own.permits.available_permits(), 7);
        drop(small);
        let save = spill.reserve(6 << 20).await.unwrap();
        let big = reserve_restore(&own, &spill, 18 << 20);
        tokio::pin!(big);
        assert!(
            tokio::time::timeout(Duration::from_millis(100), &mut big)
                .await
                .is_err(),
            "waits for the save to finish"
        );
        drop(save);
        let held = big.await.unwrap();
        assert_eq!(held.len(), 2);
        assert_eq!(own.permits.available_permits(), 0);
        assert_eq!(spill.permits.available_permits(), 5);
        drop(held);
        let err = reserve_restore(&own, &spill, 30 << 20).await.unwrap_err();
        assert!(err.contains("more than the 24 MiB"), "{err}");
    }

    #[test]
    fn temp_dirs_of_dead_processes_are_removed() {
        let root = tempfile::tempdir().unwrap();
        let base = root.path().join(TEMP_SUBDIR);
        // 进程没了：锁文件在，没人锁着。
        let dead = base.join("dead");
        std::fs::create_dir_all(&dead).unwrap();
        std::fs::File::create(dead.join(LOCK_FILE)).unwrap();
        std::fs::write(dead.join(".tmpabc"), b"ciphertext").unwrap();
        // 还活着：锁着。
        let live = base.join("live");
        std::fs::create_dir_all(&live).unwrap();
        let lock = std::fs::File::create(live.join(LOCK_FILE)).unwrap();
        lock.try_lock().unwrap();
        // 刚建、还没锁上的不动。
        let young = base.join("young");
        std::fs::create_dir_all(&young).unwrap();
        clear_abandoned(&base);
        assert!(!dead.exists());
        assert!(live.exists());
        assert!(young.exists());
    }
}
