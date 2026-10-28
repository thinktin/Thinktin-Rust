//! 沙箱抽象（架构方案 4.10、6，WBS 6.1）：按 E2B 的接口定义创建、执行进程、暂停、恢复、快照、销毁。
//!
//! 控制服务只依赖 [`SandboxProvider`]。生产环境用 [`cube::CubeProvider`]，对接 CubeSandbox 的 E2B 兼容接口（6.2），
//! 或 [`acs::AcsProvider`]，对接阿里云 ACS 上 OpenKruise Agents 的 E2B 兼容私有协议；
//! 本地开发和端到端测试用 [`local::LocalProvider`]（6.3）：沙箱就是本机上的一个目录加一组进程，没有隔离。

use std::collections::BTreeMap;
use std::net::IpAddr;
use std::process::ExitStatus;
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};

pub mod acs;
pub mod cube;
mod envd;
pub mod local;

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SandboxId(pub String);

impl std::fmt::Display for SandboxId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SnapshotId(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SandboxState {
    Running,
    /// 已暂停：内存和磁盘都保留，恢复后进程接着跑。
    Paused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resources {
    pub cpu_millis: u32,
    pub memory_mb: u32,
    pub disk_mb: u32,
}

impl Default for Resources {
    fn default() -> Self {
        // 架构方案 9 节的默认档位：1 核、1 GiB 内存、5 GiB 磁盘。
        Self {
            cpu_millis: 1000,
            memory_mb: 1024,
            disk_mb: 5120,
        }
    }
}

/// 出网策略：默认全部拒绝，只放行列出的目标（通常只有模型网关）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkPolicy {
    /// `host:port`。
    pub allow: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct CreateSpec {
    /// 模板 id，对应 agent 及其锁定版本，比如 `claude@0.90.0`。
    pub template: String,
    /// 工作区卷 id：同一个实例重建沙箱时挂回同一块卷。
    pub workspace: Option<String>,
    pub resources: Resources,
    pub network: NetworkPolicy,
    /// 沙箱的标签（实例 id、用户 id 等），只用于运维查询。
    pub metadata: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxInfo {
    pub id: SandboxId,
    pub template: String,
    pub workspace: Option<String>,
    pub state: SandboxState,
    /// 模型网关看到的这个沙箱的来源地址，签发沙箱令牌时绑定它。恢复后可能变化。
    pub address: Option<IpAddr>,
    pub metadata: BTreeMap<String, String>,
}

/// 环境变量的值。`Secret` 的值不会出现在日志和 `Debug` 输出里（比如沙箱令牌）。
#[derive(Clone)]
pub enum EnvValue {
    Plain(String),
    Secret(String),
}

impl std::fmt::Debug for EnvValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Plain(v) => write!(f, "{v:?}"),
            Self::Secret(_) => f.write_str("\"***\""),
        }
    }
}

impl EnvValue {
    pub fn expose(&self) -> &str {
        match self {
            Self::Plain(v) | Self::Secret(v) => v,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ExecSpec {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, EnvValue>,
    /// 相对沙箱根目录的工作目录，默认是工作区。
    pub cwd: Option<String>,
}

/// 沙箱里跑起来的进程。stdin、stdout 用来和 agent-shim 交换 JSON Lines。
pub struct Process {
    pub stdin: Box<dyn AsyncWrite + Send + Unpin>,
    pub stdout: Box<dyn AsyncRead + Send + Unpin>,
    pub stderr: Box<dyn AsyncRead + Send + Unpin>,
    pub control: Box<dyn ProcessControl>,
}

#[async_trait]
pub trait ProcessControl: Send {
    /// 等进程退出。
    async fn wait(&mut self) -> Result<ExitStatus>;
    /// 立即结束进程（连同它的子进程）。
    async fn kill(&mut self) -> Result<()>;
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("sandbox {0} not found")]
    NotFound(SandboxId),
    #[error("snapshot {0:?} not found")]
    SnapshotNotFound(SnapshotId),
    #[error("sandbox {id} is {actual:?}, expected {expected:?}")]
    InvalidState {
        id: SandboxId,
        expected: SandboxState,
        actual: SandboxState,
    },
    #[error("invalid request: {0}")]
    Invalid(String),
    #[error("provider error: {0}")]
    Provider(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

/// 沙箱后端。方法都是幂等或可重试的，控制服务失败后会重试。
#[async_trait]
pub trait SandboxProvider: Send + Sync {
    fn name(&self) -> &'static str;

    async fn create(&self, spec: CreateSpec) -> Result<SandboxInfo>;

    async fn get(&self, id: &SandboxId) -> Result<Option<SandboxInfo>>;

    /// 在运行中的沙箱里启动一个进程。
    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> Result<Process>;

    /// 暂停：保留内存和磁盘，不占算力。已暂停时直接返回。
    async fn pause(&self, id: &SandboxId) -> Result<()>;

    /// 恢复暂停的沙箱。运行中时直接返回。
    async fn resume(&self, id: &SandboxId) -> Result<SandboxInfo>;

    /// 给沙箱打快照（磁盘，以及后端支持时的内存）。
    async fn snapshot(&self, id: &SandboxId) -> Result<SnapshotId>;

    /// 从快照建一个新沙箱（宿主机故障后换机恢复用）。
    async fn restore(&self, snapshot: &SnapshotId, spec: CreateSpec) -> Result<SandboxInfo>;

    /// 销毁沙箱，结束里面的所有进程。工作区卷保留（[`Self::workspace_persists`] 为 false 的后端没有卷，
    /// 工作区随沙箱删掉）。不存在时直接返回。
    async fn destroy(&self, id: &SandboxId) -> Result<()>;

    /// 销毁沙箱后工作区还在不在（同一个工作区重建沙箱时能不能挂回去）。
    fn workspace_persists(&self) -> bool {
        true
    }

    /// 删除工作区卷（实例销毁时）。
    async fn delete_workspace(&self, workspace: &str) -> Result<()>;

    /// 往沙箱里写文件（交接产出物、续跑简报）。路径相对沙箱根目录。
    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> Result<()>;

    /// 读沙箱里的文件，最多 `max` 字节；更大的报 [`Error::Invalid`]，不读进内存
    /// （文件内容由 agent 控制，可能是一个很大的稀疏文件）。
    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> Result<Vec<u8>>;
}

/// 沙箱里的相对路径不能跳出沙箱。
pub fn check_relative_path(path: &str) -> Result<()> {
    let p = std::path::Path::new(path);
    if path.is_empty()
        || p.is_absolute()
        || p.components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err(Error::Invalid(format!("bad sandbox path {path:?}")));
    }
    Ok(())
}

/// 等待的默认上限，供调用方给沙箱操作设超时。
pub const DEFAULT_OP_TIMEOUT: Duration = Duration::from_secs(120);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_paths_stay_inside() {
        assert!(check_relative_path("work/a.txt").is_ok());
        for bad in ["", "/etc/passwd", "../x", "a/../../b", "./a"] {
            assert!(check_relative_path(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn secret_env_is_not_printed() {
        let v = EnvValue::Secret("tts1.k.x.y".into());
        assert_eq!(format!("{v:?}"), "\"***\"");
        assert_eq!(v.expose(), "tts1.k.x.y");
    }
}
