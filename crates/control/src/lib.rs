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
use proto::domain::{Instance, InstanceId, InstanceLimits, InstanceState, UserId};
use sandbox::{
    CreateSpec, NetworkPolicy, Resources, SandboxId, SandboxInfo, SandboxProvider, SandboxState,
};
use serde_json::json;
use store::{Db, InstanceRuntime, NewInstance, Tx, Worker};
use tracing::{info, warn};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("unknown agent {0}")]
    UnknownAgent(String),
    #[error("no template for {agent} {version}")]
    UnknownVersion { agent: String, version: String },
    #[error("invalid: {0}")]
    Invalid(String),
    #[error("instance is deleted")]
    Deleted,
    #[error("instance has a run in progress")]
    Busy,
    #[error("sandbox {0} timed out")]
    Timeout(&'static str),
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
}

/// 内置清单（`crates/catalog/manifests`），每个 agent 一个版本。
pub struct BuiltinTemplates;

impl Templates for BuiltinTemplates {
    fn current(&self, agent_id: &str) -> Option<Manifest> {
        catalog::builtin(agent_id)
    }

    fn manifest(&self, agent_id: &str, version: &str) -> Option<Manifest> {
        catalog::builtin(agent_id).filter(|m| m.agent.version == version)
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
    /// 沙箱出网白名单（模型网关、控制面接入点）。
    pub network_allow: Vec<String>,
    pub disk_mb: u32,
    /// 单个沙箱操作的上限。
    pub op_timeout: Duration,
    /// 每轮巡检每类最多处理几个实例。
    pub sweep_batch: i64,
}

impl Default for LifecycleConfig {
    fn default() -> Self {
        Self {
            idle_pause: Duration::from_secs(10 * 60),
            archive_after: Duration::from_secs(7 * 24 * 3600),
            keep_if_trigger_within: Duration::from_secs(24 * 3600),
            network_allow: Vec::new(),
            disk_mb: Resources::default().disk_mb,
            op_timeout: sandbox::DEFAULT_OP_TIMEOUT,
            sweep_batch: 20,
        }
    }
}

/// 一轮巡检的结果。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SweepReport {
    pub paused: usize,
    pub archived: usize,
    pub purged: usize,
    pub failed: usize,
}

pub struct Lifecycle {
    db: Db,
    provider: Arc<dyn SandboxProvider>,
    templates: Arc<dyn Templates>,
    cfg: LifecycleConfig,
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
        }
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
        let m = self
            .templates
            .current(agent_id)
            .ok_or_else(|| Error::UnknownAgent(agent_id.into()))?;
        let harness = match harness {
            Some(h) => m
                .harness(h)
                .ok_or_else(|| Error::Invalid(format!("{agent_id} has no harness {h}")))?,
            None => m.default_harness(),
        };
        if name.trim().is_empty() || name.chars().count() > 64 {
            return Err(Error::Invalid("name must be 1-64 characters".into()));
        }
        let mut t = self.db.tenant(user).await?;
        let instance = t
            .create_instance(&NewInstance {
                agent_id: m.agent.id.clone(),
                agent_version: m.agent.version.clone(),
                harness: harness.id.clone(),
                name: name.trim().into(),
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
            &json!({ "agent": m.agent.id, "version": m.agent.version, "harness": harness.id }),
        )
        .await?;
        t.commit().await?;
        info!(instance = %instance.id, agent = %m.agent.id, "instance adopted");
        Ok(instance)
    }

    /// 保证实例的沙箱在运行，返回最新的绑定（沙箱 id、地址）。编排服务在开始或继续一个运行前调用。
    pub async fn ensure_running(&self, id: InstanceId) -> Result<InstanceRuntime> {
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        let rt = match rt.state {
            InstanceState::Deleted => return Err(Error::Deleted),
            InstanceState::Running | InstanceState::Paused => match &rt.sandbox_id {
                Some(sid) => {
                    let sid = SandboxId(sid.clone());
                    match self.op("get", self.provider.get(&sid)).await? {
                        Some(info) if info.state == SandboxState::Running => {
                            if rt.state == InstanceState::Running {
                                w.touch_instance(id).await?;
                                w.commit().await?;
                                return Ok(rt);
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
        Ok(rt)
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

    /// 归档：销毁沙箱，只留工作区卷。有正在执行的运行时不归档，返回 false。
    pub async fn archive(&self, id: InstanceId) -> Result<bool> {
        let mut w = self.db.worker().await?;
        let rt = w.lock_instance(id).await?;
        if !matches!(rt.state, InstanceState::Running | InstanceState::Paused) {
            return Ok(false);
        }
        if w.instance_busy(id).await? {
            return Ok(false);
        }
        self.archive_locked(&mut w, &rt).await?;
        w.commit().await?;
        Ok(true)
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
        if let Some(sid) = &rt.sandbox_id {
            self.op("destroy", self.provider.destroy(&SandboxId(sid.clone())))
                .await?;
        }
        let rt = self.create(&mut w, &rt).await?;
        w.commit().await?;
        Ok(rt)
    }

    /// 巡检：暂停空闲的、归档长期暂停的、回收已删除实例的沙箱和工作区卷。单个实例出错不影响其他实例。
    pub async fn sweep(&self) -> Result<SweepReport> {
        let mut report = SweepReport::default();

        let mut w = self.db.worker().await?;
        for rt in w
            .idle_instances(
                InstanceState::Running,
                self.cfg.idle_pause,
                self.cfg.sweep_batch,
            )
            .await?
        {
            match self.pause_locked(&mut w, &rt).await {
                Ok(()) => report.paused += 1,
                Err(e) => {
                    warn!(instance = %rt.id, error = %e, "idle pause failed");
                    report.failed += 1;
                }
            }
        }
        w.commit().await?;

        let mut w = self.db.worker().await?;
        for rt in w
            .idle_instances(
                InstanceState::Paused,
                self.cfg.archive_after,
                self.cfg.sweep_batch,
            )
            .await?
        {
            if w.trigger_due_within(rt.id, self.cfg.keep_if_trigger_within)
                .await?
            {
                continue;
            }
            match self.archive_locked(&mut w, &rt).await {
                Ok(()) => report.archived += 1,
                Err(e) => {
                    warn!(instance = %rt.id, error = %e, "archive failed");
                    report.failed += 1;
                }
            }
        }
        w.commit().await?;

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
        match self.bind(w, rt, InstanceState::Running, &info).await {
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

    async fn archive_locked(&self, w: &mut Tx<Worker>, rt: &InstanceRuntime) -> Result<()> {
        if let Some(sid) = rt.sandbox_id.as_deref() {
            self.op("destroy", self.provider.destroy(&SandboxId(sid.into())))
                .await?;
        }
        self.set_state(w, rt, InstanceState::Archived, None).await
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
