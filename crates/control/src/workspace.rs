//! 工作区归档（没有工作区卷的沙箱后端，如 ACS，见 docs/sandbox-acs.md）：销毁沙箱前在沙箱里把工作区
//! 打成 tar.gz，经 [`WorkspaceStore`] 按用户 DEK 加密存进对象存储；从模板重建沙箱时传回沙箱、在沙箱里解开。
//! 打包、解包都在沙箱里做，服务端只经手数据流和密文，不解析用户的文件。

use std::any::Any;

use async_trait::async_trait;
use proto::domain::{ProjectId, UserId};
use store::{InstanceRuntime, WorkspaceArchive};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};
use uuid::Uuid;

/// 存好的一份归档：加密时进 AAD 的 id，明文（tar.gz）的大小和 SHA-256。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveMeta {
    pub id: Uuid,
    pub bytes: u64,
    pub sha256: [u8; 32],
}

/// [`WorkspaceStore::reserve_put`] 占好的资源（临时空间），交给 [`WorkspaceStore::put`]，存完释放。
#[derive(Default)]
pub struct PutTicket(Option<Box<dyn Any + Send + Sync>>);

impl PutTicket {
    pub fn new(held: impl Any + Send + Sync) -> Self {
        Self(Some(Box::new(held)))
    }

    /// 什么都没占（默认的 [`WorkspaceStore::reserve_put`]）。
    pub fn is_empty(&self) -> bool {
        self.0.is_none()
    }
}

/// 归档是谁的（8.16）：私人实例的归档按用户 DEK 加密、放在 `workspaces/<用户>/` 下；专属于项目的实例的归档按项目 DEK
/// 加密、放在 `projects/<项目>/workspaces/` 下（项目删了就解不开，个人的密钥也解不开）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArchiveOwner {
    User(UserId),
    Project(ProjectId),
}

impl From<UserId> for ArchiveOwner {
    fn from(u: UserId) -> Self {
        Self::User(u)
    }
}

impl From<ProjectId> for ArchiveOwner {
    fn from(p: ProjectId) -> Self {
        Self::Project(p)
    }
}

impl ArchiveOwner {
    /// 按实例这一刻的空间（和生成键的是同一次读）。
    pub fn of(rt: &InstanceRuntime) -> Self {
        match rt.workspace_project_id {
            Some(p) => Self::Project(p),
            None => Self::User(rt.user_id),
        }
    }

    /// 这个主人的归档都在这个前缀下（库里的 instances_archive_space 也按它查）。
    pub fn prefix(&self) -> String {
        match self {
            Self::User(u) => format!("workspaces/{}/", u.0.simple()),
            Self::Project(p) => format!("projects/{}/workspaces/", p.0.simple()),
        }
    }
}

/// 工作区归档放在哪（生产是对象存储，按主人的 DEK 加密）。
#[async_trait]
pub trait WorkspaceStore: Send + Sync {
    /// 一份新归档的对象键：每次归档换一个，旧的由数据库触发器排进清理队列。
    fn key(&self, owner: ArchiveOwner, workspace: &str, id: Uuid) -> String {
        format!("{}{workspace}/{}", owner.prefix(), id.simple())
    }

    /// 存一份最大 `max` 字节的归档之前先占好要用的资源，一时不够时排队。调用方占好了才开始打包，
    /// 排队的时间不算在存的时限里。默认什么都不占。
    async fn reserve_put(&self, _max: u64) -> Result<PutTicket, String> {
        Ok(PutTicket::default())
    }

    /// 读完 `data`（明文 tar.gz，超过 `max` 字节就报错），加密存到 `key`。`ticket` 是
    /// [`Self::reserve_put`] 给的，存完释放。
    async fn put(
        &self,
        owner: ArchiveOwner,
        key: &str,
        id: Uuid,
        data: &mut (dyn AsyncRead + Send + Unpin),
        max: u64,
        ticket: PutTicket,
    ) -> Result<ArchiveMeta, String>;

    /// 删掉一个没记成归档的对象：上传完才发现不用了（待定的被换掉、实例回收了），清理队列里已经没有它。
    /// 不存在也算成功。
    async fn delete(&self, owner: ArchiveOwner, key: &str) -> Result<(), String>;

    /// 取回、解密，明文写进 `sink`。大小、SHA-256 和记录的对不上就报错（这时已经写出去的不可信，
    /// 调用方要丢掉）。
    async fn restore(
        &self,
        owner: ArchiveOwner,
        archive: &WorkspaceArchive,
        sink: &mut (dyn AsyncWrite + Send + Unpin),
    ) -> Result<(), String>;
}

/// 归档在沙箱里的临时位置（相对沙箱根目录），放回时先传到这里再解开。
pub const RESTORE_FILE: &str = "workspace/.thinktin/restore.tgz";

/// 在工作区里打包，写到标准输出。不打包上次放回时留下的临时文件；套接字 tar 会跳过。
pub const EXPORT_ARGV: &[&str] = &[
    "tar",
    "--create",
    "--gzip",
    "--file=-",
    "--exclude=./.thinktin/restore.tgz",
    ".",
];

/// 在工作区里解开放回的归档（文件属主用运行用户，不用归档里记的）。
pub const EXTRACT_ARGV: &[&str] = &[
    "tar",
    "--extract",
    "--gzip",
    "--file=.thinktin/restore.tgz",
    "--no-same-owner",
];

pub const CLEANUP_ARGV: &[&str] = &["rm", "-f", ".thinktin/restore.tgz"];

/// 进程的标准错误留多少（报错时附上）。
pub(crate) const STDERR_KEEP: usize = 8 << 10;

/// 读完一路输出，只留前 `keep` 字节（读完是为了不让进程卡在写满的管道上）。换行、制表符以外的控制字符
/// 换成空格：报错会写进日志、审计和数据库（Postgres 存不了 NUL）。
pub(crate) async fn drain(mut r: Box<dyn AsyncRead + Send + Unpin>, keep: usize) -> String {
    let mut kept = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        match r.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let room = keep.saturating_sub(kept.len());
                kept.extend_from_slice(&buf[..n.min(room)]);
            }
        }
    }
    String::from_utf8_lossy(&kept)
        .chars()
        .map(|c| {
            if c.is_control() && c != '\n' && c != '\t' {
                ' '
            } else {
                c
            }
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn drained_output_has_no_control_characters() {
        let out = b"tar: a\0b\x1b[31m\r\nnext\tline\n".to_vec();
        let text = drain(Box::new(std::io::Cursor::new(out)), 1024).await;
        assert_eq!(text, "tar: a b [31m \nnext\tline");
        let text = drain(Box::new(std::io::Cursor::new(vec![b'x'; 100])), 10).await;
        assert_eq!(text, "x".repeat(10));
    }
}
