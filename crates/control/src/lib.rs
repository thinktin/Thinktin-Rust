//! 控制服务（WBS 6.4）：实例生命周期——领养、唤醒、暂停、归档、重建、销毁。
//!
//! ```text
//! 领养 → 准备中 ──唤醒──→ 运行中 ──空闲──→ 已暂停（内存快照）──7 天无活动──→ 已归档（只留工作区卷）
//!                          ↑ └────────────────唤醒───────────────┘                     │
//!                          └──────────────────────唤醒（从模板重建）─────────────────────┘
//! ```
//!
//! - 实例的状态以数据库为准，每个操作先锁住实例行，多个副本不会同时给一个实例建沙箱。
//! - 沙箱丢了（宿主机故障、本地开发后端重启）不算错误：唤醒时发现就从模板重建，工作区卷还在。
//! - 有正在执行的运行时不暂停、不归档、不重建（架构方案 4.10）。
//! - 每次状态变化都写一条实例事件（`instance.state`），客户端据此更新界面。

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use catalog::Manifest;
use chrono::{DateTime, Utc};
use proto::domain::{Instance, InstanceId, InstanceLimits, InstanceState, RunState, UserId};
use sandbox::{
    CreateSpec, ExecSpec, NetworkPolicy, Process, Resources, SandboxId, SandboxInfo,
    SandboxProvider, SandboxState,
};
use serde_json::json;
use store::{Db, InstanceRuntime, NewInstance, Tenant, Tx, Worker, WorkspaceArchive};
use tracing::{info, warn};
use uuid::Uuid;

pub mod workspace;

pub use workspace::{ArchiveMeta, WorkspaceStore};
use workspace::{CLEANUP_ARGV, EXPORT_ARGV, EXTRACT_ARGV, RESTORE_FILE, STDERR_KEEP, drain};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("unknown agent {0}")]
    UnknownAgent(String),
    #[error("no template for {agent} {version}")]
    UnknownVersion { agent: String, version: String },
    #[error("invalid: {0}")]
    Invalid(String),
    /// 版本因为安全问题下架了，而且没有能换过去的版本（当前版本也下架了）。
    #[error("{agent} {version} was withdrawn ({advisory}) and no safe version is available")]
    Withdrawn {
        agent: String,
        version: String,
        advisory: String,
    },
    #[error("instance is deleted")]
    Deleted,
    /// 实例数到了账号的上限（11.9）。
    #[error("at most {max} instances per account")]
    InstanceLimit { max: u64 },
    #[error("instance has a run in progress")]
    Busy,
    #[error("sandbox {0} timed out")]
    Timeout(&'static str),
    /// 工作区归档存不进去、放不回来（没有卷的后端）。
    #[error("workspace archive: {0}")]
    Workspace(String),
    #[error(transparent)]
    Store(#[from] store::Error),
    #[error(transparent)]
    Sandbox(#[from] sandbox::Error),
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

/// agent 模板的来源：领养时锁定当前版本，之后按实例锁定的版本找模板。
pub trait Templates: Send + Sync {
    /// 当前上架的版本。
    fn current(&self, agent_id: &str) -> Option<Manifest>;
    /// 指定版本；下架或不存在时返回 None。
    fn manifest(&self, agent_id: &str, version: &str) -> Option<Manifest>;
    /// 可以用的版本，当前版本在前（升级、回滚）。
    fn versions(&self, agent_id: &str) -> Vec<String> {
        self.current(agent_id)
            .map(|m| m.agent.version)
            .into_iter()
            .collect()
    }
    /// 版本因为安全问题下架了（15.5）：返回公告编号或原因。下架的版本 [`Templates::manifest`] 取不到。
    fn withdrawn(&self, _agent_id: &str, _version: &str) -> Option<String> {
        None
    }
}

/// 内置清单（`crates/catalog/manifests`），每个 agent 一个版本。
pub struct BuiltinTemplates;

impl Templates for BuiltinTemplates {
    fn current(&self, agent_id: &str) -> Option<Manifest> {
        catalog::builtin(agent_id)
    }

    fn manifest(&self, agent_id: &str, version: &str) -> Option<Manifest> {
        catalog::builtin_version(agent_id, version)
    }

    fn versions(&self, agent_id: &str) -> Vec<String> {
        catalog::builtin_versions(agent_id)
    }

    fn withdrawn(&self, agent_id: &str, version: &str) -> Option<String> {
        catalog::withdrawn(agent_id, version).map(String::from)
    }
}

#[derive(Debug, Clone)]
pub struct LifecycleConfig {
    /// 运行中的实例空闲这么久就暂停。
    pub idle_pause: Duration,
    /// 暂停的实例这么久没有活动就归档。
    pub archive_after: Duration,
    /// 这段时间内有计划要触发的不归档。
    pub keep_if_trigger_within: Duration,
    /// 计划快到点时提前这么久把要用的实例从暂停里唤醒（6.5 预热），到点时 agent 马上能干活。0 不预热。
    pub prewarm_lead: Duration,
    /// 沙箱出网白名单（模型网关、控制面接入点）。
    pub network_allow: Vec<String>,
    pub disk_mb: u32,
    /// 单个沙箱操作的上限。
    pub op_timeout: Duration,
    /// 每轮巡检每类最多处理几个实例。
    pub sweep_batch: i64,
    /// 等审批的运行不挡空闲暂停（agent 进程随沙箱一起暂停，用户批了再恢复）。关掉时等审批的实例一直运行。
    pub pause_waiting_approval: bool,
    /// 工作区归档（没有卷的后端）：打包上传、下载放回各自最多多久。
    pub archive_timeout: Duration,
    /// 工作区归档（tar.gz）的大小上限，超了不归档、沙箱留着。
    pub max_archive_bytes: u64,
}

impl Default for LifecycleConfig {
    fn default() -> Self {
        Self {
            idle_pause: Duration::from_secs(10 * 60),
            archive_after: Duration::from_secs(7 * 24 * 3600),
            keep_if_trigger_within: Duration::from_secs(24 * 3600),
            prewarm_lead: Duration::from_secs(2 * 60),
            network_allow: Vec::new(),
            disk_mb: Resources::default().disk_mb,
            op_timeout: sandbox::DEFAULT_OP_TIMEOUT,
            sweep_batch: 20,
            pause_waiting_approval: true,
            archive_timeout: Duration::from_secs(30 * 60),
            max_archive_bytes: 4 << 30,
        }
    }
}

/// 一轮巡检的结果。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SweepReport {
    /// 计划快到点、提前唤醒的（6.5）。
    pub prewarmed: usize,
    pub paused: usize,
    pub archived: usize,
    pub purged: usize,
    pub failed: usize,
}

/// 领养（不需要沙箱后端，接口层直接调用）：锁定 agent 当前版本和接入方式，建实例记录。不限实例数。
pub async fn adopt(
    db: &Db,
    templates: &dyn Templates,
    user: UserId,
    actor: &str,
    agent_id: &str,
    harness: Option<&str>,
    name: &str,
) -> Result<Instance> {
    let spec = AdoptSpec {
        agent_id,
        harness,
        name,
    };
    adopt_capped(db, templates, user, actor, spec, 0).await
}

/// 领养什么。
#[derive(Debug, Clone, Copy)]
pub struct AdoptSpec<'a> {
    pub agent_id: &'a str,
    pub harness: Option<&'a str>,
    pub name: &'a str,
}

/// 同 [`adopt`]，账号最多 `max_instances` 个没删除的实例（0 不限）：到了上限是 [`Error::InstanceLimit`]。
/// 按用户加锁再数，并发领养不会一起超过。
pub async fn adopt_capped(
    db: &Db,
    templates: &dyn Templates,
    user: UserId,
    actor: &str,
    spec: AdoptSpec<'_>,
    max_instances: u64,
) -> Result<Instance> {
    let resolved = resolve(templates, spec)?;
    let mut t = db.tenant(user).await?;
    if max_instances > 0 && t.lock_instance_count().await? >= max_instances {
        return Err(Error::InstanceLimit { max: max_instances });
    }
    let instance = insert(&mut t, actor, &resolved).await?;
    t.commit().await?;
    info!(instance = %instance.id, agent = %resolved.agent_id, "instance adopted");
    Ok(instance)
}

/// 在调用方的事务里领养，不提交、不查上限：一次领养好几个的（团队模板）在同一个事务里全成或全不成，上限由调用方
/// 在同一个事务里用 `lock_instance_count` 查（锁到提交）。
pub async fn adopt_in(
    t: &mut Tx<Tenant>,
    templates: &dyn Templates,
    actor: &str,
    spec: AdoptSpec<'_>,
) -> Result<Instance> {
    let resolved = resolve(templates, spec)?;
    insert(t, actor, &resolved).await
}

/// 查过的领养请求：agent 的当前版本和接入方式。
struct Resolved {
    agent_id: String,
    version: String,
    harness: String,
    name: String,
}

fn resolve(templates: &dyn Templates, spec: AdoptSpec<'_>) -> Result<Resolved> {
    let AdoptSpec {
        agent_id,
        harness,
        name,
    } = spec;
    let m = templates
        .current(agent_id)
        .ok_or_else(|| Error::UnknownAgent(agent_id.into()))?;
    if let Some(advisory) = templates.withdrawn(agent_id, &m.agent.version) {
        return Err(Error::Withdrawn {
            agent: agent_id.into(),
            version: m.agent.version.clone(),
            advisory,
        });
    }
    let harness = match harness {
        Some(h) => m
            .harness(h)
            .ok_or_else(|| Error::Invalid(format!("{agent_id} has no harness {h}")))?,
        None => m.default_harness(),
    };
    if name.trim().is_empty() || name.chars().count() > 64 {
        return Err(Error::Invalid("name must be 1-64 characters".into()));
    }
    Ok(Resolved {
        agent_id: m.agent.id.clone(),
        version: m.agent.version.clone(),
        harness: harness.id.clone(),
        name: name.trim().into(),
    })
}

async fn insert(t: &mut Tx<Tenant>, actor: &str, r: &Resolved) -> Result<Instance> {
    let instance = t
        .create_instance(&NewInstance {
            agent_id: r.agent_id.clone(),
            agent_version: r.version.clone(),
            harness: r.harness.clone(),
            name: r.name.clone(),
            workspace_id: format!("ws-{}", uuid::Uuid::now_v7().simple()),
            limits: InstanceLimits::default(),
        })
        .await?;
    t.append_event(
        instance.id,
        None,
        "instance.state",
        &json!({ "state": instance.state }),
    )
    .await?;
    t.audit(
        actor,
        "instance.adopt",
        Some(&instance.id.to_string()),
        &json!({ "agent": r.agent_id, "version": r.version, "harness": r.harness }),
    )
    .await?;
    Ok(instance)
}

pub struct Lifecycle {
    db: Db,
    provider: Arc<dyn SandboxProvider>,
    templates: Arc<dyn Templates>,
    cfg: LifecycleConfig,
    workspaces: Option<Arc<dyn WorkspaceStore>>,
}

/// 什么情况下归档，每次重新锁住实例后据此判断还该不该归档。
enum ArchiveWhen {
    /// 巡检：还暂停着，上次活动时间没变（期间没被用过），没有在跑、等审批的运行，近期没有计划要触发。
    Idle { seen: DateTime<Utc> },
    /// 手动归档：运行中或暂停着，没有在跑的运行。
    Asked,
    /// 换版本重建：还是这个沙箱。
    Rebuild { sandbox: String },
}

impl Lifecycle {
    pub fn new(
        db: Db,
        provider: Arc<dyn SandboxProvider>,
        templates: Arc<dyn Templates>,
        cfg: LifecycleConfig,
    ) -> Self {
        Self {
            db,
            provider,
            templates,
            cfg,
            workspaces: None,
        }
    }

    /// 沙箱后端没有工作区卷时（ACS），销毁沙箱前把工作区存进这里，重建沙箱时放回。
    pub fn with_workspace_store(mut self, store: Arc<dyn WorkspaceStore>) -> Self {
        self.workspaces = Some(store);
        self
    }

    /// 领养：锁定 agent 当前版本，建实例记录和工作区卷名。沙箱在第一次唤醒时创建。
    pub async fn adopt(
        &self,
        user: UserId,
        actor: &str,
        agent_id: &str,
        harness: Option<&str>,
        name: &str,
    ) -> Result<Instance> {
        adopt(
            &self.db,
            self.templates.as_ref(),
            user,
            actor,
            agent_id,
            harness,
            name,
        )
        .await
    }

    /// 保证实例的沙箱在运行，返回最新的绑定（沙箱 id、地址）。编排服务在开始或继续一个运行前调用。
    pub async fn ensure_running(&self, id: InstanceId) -> Result<InstanceRuntime> {
        // 换版本时工作区先存进对象存储、销毁旧沙箱（各步单独提交），之后从头再来一遍。
        for _ in 0..3 {
            if let Some(rt) = self.ensure_running_once(id).await? {
                return Ok(rt);
            }
        }
        Err(Error::Workspace(
            "the instance kept changing while its workspace was being saved".into(),
        ))
    }

    async fn ensure_running_once(&self, id: InstanceId) -> Result<Option<InstanceRuntime>> {
        let mut w = self.db.worker().await?;
        let mut rt = w.lock_instance(id).await?;
        // 锁定的版本因为安全问题下架了（15.5）：换到当前版本，按重建处理（工作区卷保留）。
        if rt.state != InstanceState::Deleted
            && let Some(advisory) = self.templates.withdrawn(&rt.agent_id, &rt.agent_version)
        {
            let to = self
                .templates
                .current(&rt.agent_id)
                .map(|m| m.agent.version)
                .filter(|v| self.templates.withdrawn(&rt.agent_id, v).is_none())
                .ok_or_else(|| Error::Withdrawn {
                    agent: rt.agent_id.clone(),
                    version: rt.agent_version.clone(),
                    advisory: advisory.clone(),
                })?;
            warn!(instance = %id, from = %rt.agent_version, to = %to, %advisory, "template version was withdrawn, moving the instance to the current version");
            w.set_instance_version(id, &to).await?;
            w.mark_rebuild_pending(id).await?;
            w.audit(
                Some(rt.user_id),
                "system",
                "instance.version.withdrawn",
                Some(&id.to_string()),
                &json!({ "from": rt.agent_version, "to": to, "advisory": advisory }),
            )
            .await?;
            rt.agent_version = to;
            rt.rebuild_pending = true;
        }
        // 用户换了模板版本（升级、回滚）：丢掉旧沙箱，按新版本重建，工作区卷保留。
        if rt.rebuild_pending && rt.state != InstanceState::Deleted {
            self.templates
                .manifest(&rt.agent_id, &rt.agent_version)
                .ok_or_else(|| Error::UnknownVersion {
                    agent: rt.agent_id.clone(),
                    version: rt.agent_version.clone(),
                })?;
            if let Some(sid) = &rt.sandbox_id {
                if let Some(store) = self.archives() {
                    // 版本的变化先提交（rebuild_pending 留着），存好工作区、销毁旧沙箱后再来。
                    w.commit().await?;
                    info!(instance = %id, "saving the workspace before rebuilding");
                    let when = ArchiveWhen::Rebuild {
                        sandbox: sid.clone(),
                    };
                    self.archive_to_store(store, id, when).await?;
                    return Ok(None);
                }
                if !self.provider.workspace_persists() {
                    return Err(self.no_volumes());
                }
                self.op("destroy", self.provider.destroy(&SandboxId(sid.clone())))
                    .await?;
            }
            info!(instance = %id, version = %rt.agent_version, "rebuilding for a new template version");
            let mut rt = self.create(&mut w, &rt).await?;
            w.clear_rebuild_pending(id).await?;
            rt.rebuild_pending = false;
            w.touch_instance(id).await?;
            w.commit().await?;
            return Ok(Some(rt));
        }
        let rt = match rt.state {
            InstanceState::Deleted => return Err(Error::Deleted),
            InstanceState::Running | InstanceState::Paused => match &rt.sandbox_id {
                Some(sid) => {
                    let sid = SandboxId(sid.clone());
                    match self.op("get", self.provider.get(&sid)).await? {
                        Some(info) if info.state == SandboxState::Running => {
                            if rt.state == InstanceState::Running {
                                // 沙箱令牌绑定这个地址：后端报的变了就记下新的（不算状态变化）。
                                let mut rt = rt;
                                if info.address != rt.sandbox_address {
                                    w.set_instance_runtime(
                                        id,
                                        InstanceState::Running,
                                        Some(&info.id.0),
                                        info.address,
                                        None,
                                    )
                                    .await?;
                                    rt.sandbox_address = info.address;
                                    rt.snapshot_id = None;
                                }
                                w.touch_instance(id).await?;
                                w.commit().await?;
                                return Ok(Some(rt));
                            }
                            self.bind(&mut w, &rt, InstanceState::Running, &info)
                                .await?
                        }
                        Some(_) => match self.op("resume", self.provider.resume(&sid)).await {
                            Ok(info) => {
                                self.bind(&mut w, &rt, InstanceState::Running, &info)
                                    .await?
                            }
                            Err(Error::Sandbox(sandbox::Error::NotFound(_))) => {
                                self.create(&mut w, &rt).await?
                            }
                            Err(e) => return Err(e),
                        },
                        None => {
                            warn!(instance = %id, sandbox = %sid, "sandbox is gone, rebuilding from template");
                            self.create(&mut w, &rt).await?
                        }
                    }
                }
                None => self.create(&mut w, &rt).await?,
            },
            InstanceState::Provisioning | InstanceState::Archived => {
                self.create(&mut w, &rt).await?
            }
        };
        w.touch_instance(id).await?;
        w.commit().await?;
        Ok(Some(rt))
    }

    /// 暂停（内存快照）。有正在执行的运行时不暂停，返回 false。
    pub async fn pause(&self, id: InstanceId) -> Result<bool> {
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if rt.state != InstanceState::Running {
            return Ok(false);
        }
        if w.instance_busy(id).await? {
            return Ok(false);
        }
        self.pause_locked(&mut w, &rt).await?;
        w.commit().await?;
        Ok(true)
    }

    /// 归档：销毁沙箱，只留工作区卷（没有卷的后端先把工作区存进对象存储）。有正在执行的运行时不归档，
    /// 返回 false。
    pub async fn archive(&self, id: InstanceId) -> Result<bool> {
        self.archive_one(id, ArchiveWhen::Asked).await
    }

    /// 重建：销毁当前沙箱，按（可选的新）模板版本重新创建。升级、回滚、故障恢复用。
    pub async fn rebuild(&self, id: InstanceId, version: Option<&str>) -> Result<InstanceRuntime> {
        let mut w = self.db.worker().await?;
        let mut rt = w.lock_instance(id).await?;
        if rt.state == InstanceState::Deleted {
            return Err(Error::Deleted);
        }
        if w.instance_busy(id).await? {
            return Err(Error::Busy);
        }
        if let Some(v) = version {
            self.templates
                .manifest(&rt.agent_id, v)
                .ok_or_else(|| Error::UnknownVersion {
                    agent: rt.agent_id.clone(),
                    version: v.into(),
                })?;
            w.set_instance_version(id, v).await?;
            rt.agent_version = v.into();
        }
        if rt.sandbox_id.is_some() && self.archives().is_some() {
            // 和换版本一样：先存工作区再按（新）版本建，见 ensure_running。
            w.mark_rebuild_pending(id).await?;
            w.commit().await?;
            return self.ensure_running(id).await;
        }
        if let Some(sid) = &rt.sandbox_id {
            if !self.provider.workspace_persists() {
                return Err(self.no_volumes());
            }
            self.op("destroy", self.provider.destroy(&SandboxId(sid.clone())))
                .await?;
        }
        let mut rt = self.create(&mut w, &rt).await?;
        w.clear_rebuild_pending(id).await?;
        rt.rebuild_pending = false;
        w.commit().await?;
        Ok(rt)
    }

    /// 巡检：预热快到点的、暂停空闲的、归档长期暂停的、回收已删除实例的沙箱和工作区卷。
    /// 单个实例出错不影响其他实例。
    pub async fn sweep(&self) -> Result<SweepReport> {
        let mut report = SweepReport::default();

        // 预热（6.5）：计划快到点了，它要用的实例（计划自己的、流水线第一批步骤的）还暂停着就提前唤醒。
        // 唤醒时记一次活动，下面的空闲暂停不会马上又把它停掉。
        if !self.cfg.prewarm_lead.is_zero() {
            let mut w = self.db.worker().await?;
            let due = w
                .instances_to_prewarm(self.cfg.prewarm_lead, self.cfg.sweep_batch)
                .await?;
            w.commit().await?;
            for id in due {
                match self.ensure_running(id).await {
                    Ok(_) => report.prewarmed += 1,
                    Err(e) => {
                        warn!(instance = %id, error = %e, "prewarm failed");
                        report.failed += 1;
                    }
                }
            }
        }

        let waiting: &[RunState] = if self.cfg.pause_waiting_approval {
            &[]
        } else {
            &[RunState::WaitingApproval]
        };
        // 先列出来，再逐个锁住处理：归档要打包上传，不能一直锁着别的实例。
        let mut w = self.db.worker().await?;
        let idle = w
            .idle_instance_ids(
                InstanceState::Running,
                self.cfg.idle_pause,
                self.cfg.sweep_batch,
                waiting,
            )
            .await?;
        w.commit().await?;
        for (id, seen) in idle {
            match self.pause_idle(id, seen, waiting).await {
                Ok(true) => report.paused += 1,
                Ok(false) => {}
                Err(e) => {
                    warn!(instance = %id, error = %e, "idle pause failed");
                    report.failed += 1;
                }
            }
        }

        // 工作区留不住（没有卷、也没接对象存储）时不归档，暂停的沙箱一直留着。
        let stale = if self.check_workspace_kept().is_ok() {
            let mut w = self.db.worker().await?;
            let ids = w
                .idle_instance_ids(
                    InstanceState::Paused,
                    self.cfg.archive_after,
                    self.cfg.sweep_batch,
                    &[RunState::WaitingApproval],
                )
                .await?;
            w.commit().await?;
            ids
        } else {
            Vec::new()
        };

        for (id, seen) in stale {
            match self.archive_one(id, ArchiveWhen::Idle { seen }).await {
                Ok(true) => report.archived += 1,
                Ok(false) => {}
                Err(e) => {
                    warn!(instance = %id, error = %e, "archive failed");
                    report.failed += 1;
                }
            }
        }

        let mut w = self.db.worker().await?;
        for rt in w.instances_to_purge(self.cfg.sweep_batch).await? {
            match self.purge_locked(&mut w, &rt).await {
                Ok(()) => report.purged += 1,
                Err(e) => {
                    warn!(instance = %rt.id, error = %e, "purge failed");
                    report.failed += 1;
                }
            }
        }
        w.commit().await?;
        Ok(report)
    }

    async fn op<T>(
        &self,
        what: &'static str,
        fut: impl std::future::Future<Output = sandbox::Result<T>>,
    ) -> Result<T> {
        match tokio::time::timeout(self.cfg.op_timeout, fut).await {
            Ok(r) => Ok(r?),
            Err(_) => Err(Error::Timeout(what)),
        }
    }

    fn spec(&self, rt: &InstanceRuntime) -> Result<CreateSpec> {
        let m = self
            .templates
            .manifest(&rt.agent_id, &rt.agent_version)
            .ok_or_else(|| Error::UnknownVersion {
                agent: rt.agent_id.clone(),
                version: rt.agent_version.clone(),
            })?;
        Ok(CreateSpec {
            template: m.runtime.template.clone(),
            workspace: Some(rt.workspace_id.clone()),
            resources: Resources {
                cpu_millis: m.runtime.vcpu.saturating_mul(1000),
                memory_mb: m.runtime.memory_mb,
                disk_mb: self.cfg.disk_mb,
            },
            network: NetworkPolicy {
                allow: self.cfg.network_allow.clone(),
            },
            metadata: BTreeMap::from([
                ("instance".into(), rt.id.to_string()),
                ("user".into(), rt.user_id.to_string()),
                (
                    "agent".into(),
                    format!("{}@{}", rt.agent_id, rt.agent_version),
                ),
            ]),
        })
    }

    /// 从模板建新沙箱（挂上工作区卷），写回绑定。写库失败时销毁刚建的沙箱，不留孤儿。
    async fn create(&self, w: &mut Tx<Worker>, rt: &InstanceRuntime) -> Result<InstanceRuntime> {
        let spec = self.spec(rt)?;
        let info = self.op("create", self.provider.create(spec)).await?;
        // 没有卷的后端：把最近一份工作区归档放回去，放好了才算建好。
        let restored = match (self.archives(), &rt.archive) {
            (Some(store), Some(archive)) => {
                let r = self.restore_into(store, rt, archive, &info.id).await;
                if r.is_ok() {
                    if archive.archived_at < rt.last_active_at {
                        // 沙箱是自己没的（不是归档掉的）：最近的改动没存下来。
                        warn!(instance = %rt.id, archived_at = %archive.archived_at, "restored a stale workspace archive");
                    } else {
                        info!(instance = %rt.id, bytes = archive.bytes, "workspace restored");
                    }
                }
                r
            }
            _ => Ok(()),
        };
        let bound = match restored {
            Ok(()) => self.bind(w, rt, InstanceState::Running, &info).await,
            Err(e) => Err(e),
        };
        match bound {
            Ok(rt) => {
                info!(instance = %rt.id, sandbox = %info.id, "sandbox created");
                Ok(rt)
            }
            Err(e) => {
                if let Err(d) = self.op("destroy", self.provider.destroy(&info.id)).await {
                    warn!(sandbox = %info.id, error = %d, "could not destroy orphaned sandbox");
                }
                Err(e)
            }
        }
    }

    async fn bind(
        &self,
        w: &mut Tx<Worker>,
        rt: &InstanceRuntime,
        state: InstanceState,
        info: &SandboxInfo,
    ) -> Result<InstanceRuntime> {
        w.set_instance_runtime(rt.id, state, Some(&info.id.0), info.address, None)
            .await?;
        w.append_event(rt.id, None, "instance.state", &json!({ "state": state }))
            .await?;
        Ok(InstanceRuntime {
            state,
            sandbox_id: Some(info.id.0.clone()),
            sandbox_address: info.address,
            snapshot_id: None,
            ..rt.clone()
        })
    }

    async fn set_state(
        &self,
        w: &mut Tx<Worker>,
        rt: &InstanceRuntime,
        state: InstanceState,
        sandbox: Option<&str>,
    ) -> Result<()> {
        let address = sandbox.and(rt.sandbox_address);
        w.set_instance_runtime(rt.id, state, sandbox, address, None)
            .await?;
        w.append_event(rt.id, None, "instance.state", &json!({ "state": state }))
            .await?;
        Ok(())
    }

    async fn pause_locked(&self, w: &mut Tx<Worker>, rt: &InstanceRuntime) -> Result<()> {
        let Some(sid) = rt.sandbox_id.as_deref() else {
            return self.set_state(w, rt, InstanceState::Archived, None).await;
        };
        match self
            .op("pause", self.provider.pause(&SandboxId(sid.into())))
            .await
        {
            Ok(()) => {
                self.set_state(w, rt, InstanceState::Paused, Some(sid))
                    .await
            }
            // 沙箱已经没了：工作区卷还在，等同归档，下次唤醒从模板重建。
            Err(Error::Sandbox(sandbox::Error::NotFound(_))) => {
                self.set_state(w, rt, InstanceState::Archived, None).await
            }
            Err(e) => Err(e),
        }
    }

    /// 销毁沙箱前确认工作区留得住：后端没有卷（ACS）时不销毁，免得丢了用户的文件。
    /// 有没有接对象存储（[`Self::with_workspace_store`]）都算：接了的先存工作区再销毁。
    fn check_workspace_kept(&self) -> Result<()> {
        if self.provider.workspace_persists() || self.workspaces.is_some() {
            return Ok(());
        }
        Err(self.no_volumes())
    }

    fn no_volumes(&self) -> Error {
        Error::Invalid(format!(
            "the {} sandbox provider keeps no workspace after a sandbox is destroyed",
            self.provider.name()
        ))
    }

    /// 直接销毁沙箱、只留工作区卷（后端有卷时）。
    async fn archive_locked(&self, w: &mut Tx<Worker>, rt: &InstanceRuntime) -> Result<()> {
        if let Some(sid) = rt.sandbox_id.as_deref() {
            if !self.provider.workspace_persists() {
                return Err(self.no_volumes());
            }
            self.op("destroy", self.provider.destroy(&SandboxId(sid.into())))
                .await?;
        }
        self.set_state(w, rt, InstanceState::Archived, None).await
    }

    /// 要不要把工作区存进对象存储：后端没有卷、又接了存储时。
    fn archives(&self) -> Option<&Arc<dyn WorkspaceStore>> {
        if self.provider.workspace_persists() {
            return None;
        }
        self.workspaces.as_ref()
    }

    async fn pause_idle(
        &self,
        id: InstanceId,
        seen: DateTime<Utc>,
        also_busy: &[RunState],
    ) -> Result<bool> {
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if rt.state != InstanceState::Running
            || rt.last_active_at != seen
            || w.instance_busy_with(id, also_busy).await?
        {
            return Ok(false);
        }
        self.pause_locked(&mut w, &rt).await?;
        w.commit().await?;
        Ok(true)
    }

    async fn may_archive(
        &self,
        w: &mut Tx<Worker>,
        rt: &InstanceRuntime,
        when: &ArchiveWhen,
    ) -> Result<bool> {
        Ok(match when {
            ArchiveWhen::Idle { seen } => {
                rt.state == InstanceState::Paused
                    && rt.last_active_at == *seen
                    && !w
                        .instance_busy_with(rt.id, &[RunState::WaitingApproval])
                        .await?
                    && !w
                        .trigger_due_within(rt.id, self.cfg.keep_if_trigger_within)
                        .await?
            }
            ArchiveWhen::Asked => {
                matches!(rt.state, InstanceState::Running | InstanceState::Paused)
                    && !w.instance_busy(rt.id).await?
            }
            ArchiveWhen::Rebuild { sandbox } => {
                rt.state != InstanceState::Deleted && rt.sandbox_id.as_deref() == Some(sandbox)
            }
        })
    }

    async fn archive_one(&self, id: InstanceId, when: ArchiveWhen) -> Result<bool> {
        if let Some(store) = self.archives() {
            return self.archive_to_store(store, id, when).await;
        }
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if !self.may_archive(&mut w, &rt, &when).await? {
            return Ok(false);
        }
        self.archive_locked(&mut w, &rt).await?;
        w.commit().await?;
        Ok(true)
    }

    /// 没有卷的后端归档：工作区存进对象存储，再销毁沙箱，记为已归档。每一步单独提交——先记下要上传的
    /// 对象，上传完记下归档，最后销毁沙箱：中途出错或进程被杀都不丢工作区，最多留下一个没用上的对象
    /// （下次归档或回收实例时排进清理队列）。返回 false 表示情况变了、没归档。
    async fn archive_to_store(
        &self,
        store: &Arc<dyn WorkspaceStore>,
        id: InstanceId,
        when: ArchiveWhen,
    ) -> Result<bool> {
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if !self.may_archive(&mut w, &rt, &when).await? {
            return Ok(false);
        }
        let Some(sid) = rt.sandbox_id.clone() else {
            self.set_state(&mut w, &rt, InstanceState::Archived, None)
                .await?;
            w.commit().await?;
            return Ok(true);
        };
        let archive_id = Uuid::now_v7();
        let key = store.key(rt.user_id, &rt.workspace_id, archive_id);
        w.begin_workspace_archive(id, &key).await?;
        w.commit().await?;
        let result = self
            .save_and_destroy(store, id, &when, &sid, &key, archive_id)
            .await;
        // 没记成归档的上传（出错、情况变了）排进清理队列；记成了的这里什么都不改。
        let mut w = self.db.worker().await?;
        w.abort_workspace_archive(id, &key).await?;
        w.commit().await?;
        result
    }

    async fn save_and_destroy(
        &self,
        store: &Arc<dyn WorkspaceStore>,
        id: InstanceId,
        when: &ArchiveWhen,
        sid: &str,
        key: &str,
        archive_id: Uuid,
    ) -> Result<bool> {
        let sandbox = SandboxId(sid.to_owned());
        // 打包上传，记下归档。一直锁着实例：期间要唤醒它的等这一步做完。
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if rt.sandbox_id.as_deref() != Some(sid) || !self.may_archive(&mut w, &rt, when).await? {
            return Ok(false);
        }
        let Some(resumed) = self.wake_for_export(&sandbox).await? else {
            warn!(instance = %id, sandbox = %sid, "sandbox is gone before its workspace was saved, keeping the last archive");
            self.set_state(&mut w, &rt, InstanceState::Archived, None)
                .await?;
            w.commit().await?;
            return Ok(true);
        };
        let saved = async {
            let meta = self.export(store, &rt, &sandbox, key, archive_id).await?;
            if !w
                .finish_workspace_archive(id, key, meta.id, meta.bytes, &meta.sha256)
                .await?
            {
                return Err(Error::Workspace(
                    "another upload replaced this archive".into(),
                ));
            }
            Ok(meta)
        }
        .await;
        let meta = match saved {
            Ok(m) => m,
            Err(e) => {
                self.repause(&sandbox, resumed).await;
                return Err(e);
            }
        };
        w.commit().await?;
        info!(instance = %id, bytes = meta.bytes, "workspace saved");

        // 销毁沙箱。归档已经记下了：这一步失败下次再来，工作区不会丢。
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if rt.sandbox_id.as_deref() != Some(sid) {
            return Ok(false);
        }
        if !self.may_archive(&mut w, &rt, when).await? {
            if rt.state == InstanceState::Paused {
                self.repause(&sandbox, resumed).await;
            }
            return Ok(false);
        }
        if let Err(e) = self.op("destroy", self.provider.destroy(&sandbox)).await {
            self.repause(&sandbox, resumed).await;
            return Err(e);
        }
        self.set_state(&mut w, &rt, InstanceState::Archived, None)
            .await?;
        w.commit().await?;
        Ok(true)
    }

    /// 打包要沙箱在运行：暂停着的先恢复。返回是不是恢复了；沙箱没了返回 None。
    async fn wake_for_export(&self, sandbox: &SandboxId) -> Result<Option<bool>> {
        match self.op("get", self.provider.get(sandbox)).await? {
            None => Ok(None),
            Some(i) if i.state == SandboxState::Running => Ok(Some(false)),
            Some(_) => match self.op("resume", self.provider.resume(sandbox)).await {
                Ok(_) => Ok(Some(true)),
                Err(Error::Sandbox(sandbox::Error::NotFound(_))) => Ok(None),
                Err(e) => Err(e),
            },
        }
    }

    /// 为了打包恢复过的沙箱，没归档成就再暂停回去（实例在库里还是暂停的，巡检不会去暂停它）。
    async fn repause(&self, sandbox: &SandboxId, resumed: bool) {
        if !resumed {
            return;
        }
        if let Err(e) = self.op("pause", self.provider.pause(sandbox)).await {
            warn!(sandbox = %sandbox, error = %e, "could not pause the sandbox again after saving its workspace failed");
        }
    }

    /// 在沙箱里打包工作区，经 `store` 加密存到 `key`。
    async fn export(
        &self,
        store: &Arc<dyn WorkspaceStore>,
        rt: &InstanceRuntime,
        sandbox: &SandboxId,
        key: &str,
        archive_id: Uuid,
    ) -> Result<ArchiveMeta> {
        let Process {
            stdin,
            mut stdout,
            stderr,
            mut control,
        } = self
            .op("exec", self.provider.exec(sandbox, argv(EXPORT_ARGV)))
            .await?;
        drop(stdin);
        // 标准错误另开任务读：上传出错不再读标准输出时，tar 卡住也不会连带这里卡住。
        let stderr = tokio::spawn(drain(stderr, STDERR_KEEP));
        let put = tokio::time::timeout(
            self.cfg.archive_timeout,
            store.put(
                rt.user_id,
                key,
                archive_id,
                &mut *stdout,
                self.cfg.max_archive_bytes,
            ),
        )
        .await;
        let meta = match put {
            Ok(Ok(meta)) => meta,
            Ok(Err(e)) => {
                let _ = control.kill().await;
                return Err(Error::Workspace(e));
            }
            Err(_) => {
                let _ = control.kill().await;
                return Err(Error::Timeout("archive"));
            }
        };
        let status = match tokio::time::timeout(self.cfg.op_timeout, control.wait()).await {
            Ok(status) => status?,
            Err(_) => {
                let _ = control.kill().await;
                return Err(Error::Timeout("archive"));
            }
        };
        let err = stderr.await.unwrap_or_default();
        // GNU tar 的退出码 1 是“有文件在打包时变了”，归档照样能用。
        if !matches!(status.code(), Some(0 | 1)) {
            return Err(Error::Workspace(format!("tar exited with {status}: {err}")));
        }
        Ok(meta)
    }

    /// 把归档传进新沙箱、在沙箱里解开。
    async fn restore_into(
        &self,
        store: &Arc<dyn WorkspaceStore>,
        rt: &InstanceRuntime,
        archive: &WorkspaceArchive,
        sandbox: &SandboxId,
    ) -> Result<()> {
        let (mut writer, reader) = tokio::io::duplex(1 << 20);
        let upload =
            self.provider
                .write_file_stream(sandbox, RESTORE_FILE, Box::new(reader), archive.bytes);
        let download = async move {
            let r = store.restore(rt.user_id, archive, &mut writer).await;
            drop(writer);
            r
        };
        let both = async {
            let (down, up) = tokio::join!(download, upload);
            down.map_err(Error::Workspace)?;
            up?;
            Ok::<_, Error>(())
        };
        match tokio::time::timeout(self.cfg.archive_timeout, both).await {
            Ok(r) => r?,
            Err(_) => return Err(Error::Timeout("restore")),
        }
        self.run_in_sandbox(sandbox, EXTRACT_ARGV).await?;
        self.run_in_sandbox(sandbox, CLEANUP_ARGV).await
    }

    /// 在沙箱的工作区里跑一条命令，要它成功。
    async fn run_in_sandbox(&self, sandbox: &SandboxId, cmd: &[&str]) -> Result<()> {
        let run = async {
            let Process {
                stdin,
                stdout,
                stderr,
                mut control,
            } = self.provider.exec(sandbox, argv(cmd)).await?;
            drop(stdin);
            let (_, err) = tokio::join!(drain(stdout, 0), drain(stderr, STDERR_KEEP));
            let status = control.wait().await?;
            if status.success() {
                Ok(())
            } else {
                Err(Error::Workspace(format!(
                    "{} exited with {status}: {err}",
                    cmd[0]
                )))
            }
        };
        match tokio::time::timeout(self.cfg.archive_timeout, run).await {
            Ok(r) => r,
            Err(_) => Err(Error::Timeout("restore")),
        }
    }

    async fn purge_locked(&self, w: &mut Tx<Worker>, rt: &InstanceRuntime) -> Result<()> {
        if let Some(sid) = rt.sandbox_id.as_deref() {
            self.op("destroy", self.provider.destroy(&SandboxId(sid.into())))
                .await?;
        }
        self.op(
            "delete_workspace",
            self.provider.delete_workspace(&rt.workspace_id),
        )
        .await?;
        w.mark_instance_purged(rt.id).await?;
        info!(instance = %rt.id, "instance resources purged");
        Ok(())
    }
}

fn argv(cmd: &[&str]) -> ExecSpec {
    ExecSpec {
        argv: cmd.iter().map(|s| s.to_string()).collect(),
        ..ExecSpec::default()
    }
}
