//! 执行器（WBS 7.3、7.4、7.7、7.9）：领取运行，唤醒沙箱，换沙箱令牌，启动 agent-shim，
//! 把任务交给 agent，把事件写进运行日志，处理审批、预算和取消，最后写结果和通知。
//!
//! - 租约：领取时拿到，执行中定期续租。续租失败说明用户取消了（停下 agent 这一轮）
//!   或者租约被别的副本接管了（直接放手）。副本崩溃后租约过期，别的副本用
//!   [`Executor::take_over_expired`] 接手，按可重试失败处理。
//! - 预算：时长到点、token（以模型网关的计费记录为准）或步数超限，就取消这一轮并判定失败。
//! - 停机：停止领取新运行，进行中的运行取消这一轮后转入退避，别的副本马上接着跑。

use std::collections::HashSet;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use auth::grants::GrantService;
use auth::service::AuthError;
use chrono::Utc;
use control::Lifecycle;
use keyvault::{Kms, Scrubber};
use notify::PushKind;
use proto::domain::{
    ApprovalState, ApprovalTimeoutAction, GrantId, PlanPolicy, RunState, UserId, VaultItemId,
    valid_vault_name,
};
use proto::shim::{DecisionSource, SecretValues, ShimCommand, ShimEvent, StopReason};
use serde_json::{Value, json};
use store::{Db, NewApproval, RunChange, RunRecord};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;
use tracing::Instrument;
use tracing::{debug, error, info, warn};

use crate::outbox::{Notice, notify};
use crate::shim::{
    PlatformTools, ShimConnector, ShimLaunch, ShimSession, ToolContext, ToolOutput, event_kind,
};

#[derive(Debug, Clone)]
pub struct ExecutorConfig {
    /// 执行租约，以及多久续一次。
    pub lease: Duration,
    pub renew_every: Duration,
    /// 没有可领的运行时多久再看一次。
    pub claim_poll: Duration,
    /// 这个副本同时执行的运行数上限。
    pub max_concurrent: usize,
    /// shim 启动并握手的上限。
    pub handshake_timeout: Duration,
    /// 等审批时多久查一次用户的决定。
    pub approval_poll: Duration,
    /// 取消这一轮后等 agent 收尾、等 shim 退出的上限。
    pub stop_timeout: Duration,
    /// 可重试失败的退避（指数增长）。
    pub backoff_base: Duration,
    pub backoff_max: Duration,
    /// 多久扫一次别的副本留下的过期租约。
    pub takeover_every: Duration,
    /// 文字流攒多久写一次运行日志。
    pub flush_every: Duration,
    /// 一次运行最多写这么多字节的运行日志（agent 的输出完全由 agent 控制，不能无限写进共享的数据库）。
    /// 超过以后只写一条 `run.log_truncated`，状态变化照常记。
    pub max_run_log_bytes: usize,
}

impl Default for ExecutorConfig {
    fn default() -> Self {
        Self {
            lease: Duration::from_secs(60),
            renew_every: Duration::from_secs(15),
            claim_poll: Duration::from_secs(1),
            max_concurrent: 16,
            handshake_timeout: Duration::from_secs(180),
            approval_poll: Duration::from_secs(2),
            stop_timeout: Duration::from_secs(15),
            backoff_base: Duration::from_secs(30),
            backoff_max: Duration::from_secs(30 * 60),
            takeover_every: Duration::from_secs(15),
            flush_every: Duration::from_millis(500),
            max_run_log_bytes: 64 << 20,
        }
    }
}

/// 一个运行怎么结束的。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Succeeded {
        summary: Option<String>,
        reason: Option<String>,
    },
    /// 不重试的失败。
    Failed(String),
    /// 可以重试的失败（沙箱、shim、agent 出问题）。
    Retry(String),
    /// 用户取消（库里已经是终态）。
    Cancelled,
    /// 租约被别的副本接管：放手，什么都不写。
    LeaseLost,
    /// 这个副本要停机：转入退避，别的副本马上接着跑。
    Interrupted,
}

/// 指标里的结果标签（取值固定，基数小）。
fn outcome_label(o: &Outcome) -> &'static str {
    match o {
        Outcome::Succeeded { .. } => "succeeded",
        Outcome::Failed(_) => "failed",
        Outcome::Retry(_) => "retry",
        Outcome::Cancelled => "cancelled",
        Outcome::LeaseLost => "lease_lost",
        Outcome::Interrupted => "interrupted",
    }
}

pub struct Executor {
    db: Db,
    node_id: String,
    lifecycle: Arc<Lifecycle>,
    grants: Arc<GrantService>,
    connector: Arc<dyn ShimConnector>,
    tools: Arc<dyn PlatformTools>,
    handoff: Option<Arc<crate::pipeline::HandoffCopier>>,
    /// 密码保险箱（9.11）：解开用户的条目，给沙箱里的助手、给运行日志抹值。
    vault: Option<Arc<dyn Kms>>,
    cfg: ExecutorConfig,
    /// 同时执行的运行数。等审批的运行让出名额（沙箱也可能被空闲回收暂停），审批有结果后再拿回来。
    slots: Arc<Semaphore>,
}

/// 一个运行执行过程中的状态。
struct Exec<'a> {
    ex: &'a Executor,
    rec: &'a RunRecord,
    state: RunState,
    policy: PlanPolicy,
    session: ShimSession,
    ctx: ToolContext,
    message: String,
    thought: String,
    /// 最后一次工具调用之后的回复（作为运行摘要）。
    answer: String,
    steps: u32,
    pending: HashSet<String>,
    usage_since: chrono::DateTime<Utc>,
    /// 占着的执行名额；等审批时让出（`slot_released`），审批有结果后再拿回来。
    slot: Option<OwnedSemaphorePermit>,
    slot_released: bool,
    /// 已经把用户的决定交给 shim、还没收到 permission_resolved 的请求（只发一次）。
    delivered: HashSet<String>,
    /// 授权范围内、告诉了 agent 的平台工具。调用时再核对一次：shim 和 agent 在同一个沙箱里，不可信。
    allowed_tools: HashSet<String>,
    /// 租约至少续到什么时候（最后一次成功续租 + 租约时长）。续租一直失败、过了这个时间就自己停下，
    /// 不能和接手的副本同时跑同一个运行。
    lease_ok_until: Instant,
    /// 这次执行已经写进运行日志的字节数。
    logged: usize,
    log_capped: bool,
    /// 用户保险箱里的值：写运行日志、摘要、审批之前抹掉（9.11）。
    scrubber: Scrubber,
}

/// 运行摘要从回复里取，最多留这么多字节（摘要只用前 400 个字）。
const MAX_ANSWER: usize = 8 << 10;
/// 运行日志里单个字符串的上限：agent 的回复、工具输出这类长文本截断。
const MAX_EVENT_STRING: usize = 16 << 10;
/// 单条运行日志的上限，截断字符串以后还超过就只留一个占位。
const MAX_EVENT_PAYLOAD: usize = 256 << 10;

/// 往 `s` 后面追加，总长不超过 `cap` 字节（按字符边界截断）。
fn push_capped(s: &mut String, text: &str, cap: usize) {
    let room = cap.saturating_sub(s.len());
    if room == 0 {
        return;
    }
    let mut end = text.len().min(room);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    s.push_str(&text[..end]);
}

/// 写进运行日志之前限制大小：长字符串截断，整条还太大就换成占位。
fn bound_payload(v: &Value) -> Value {
    fn walk(v: &Value) -> Value {
        match v {
            Value::String(s) if s.len() > MAX_EVENT_STRING => {
                let mut cut = String::with_capacity(MAX_EVENT_STRING + 16);
                push_capped(&mut cut, s, MAX_EVENT_STRING);
                cut.push_str("…[truncated]");
                Value::String(strip_nul(cut))
            }
            // jsonb 也存不了 \u0000。
            Value::String(s) if s.contains('\0') => Value::String(strip_nul(s.clone())),
            Value::Array(items) => Value::Array(items.iter().map(walk).collect()),
            Value::Object(map) => Value::Object(
                map.iter()
                    .map(|(k, v)| (strip_nul(k.clone()), walk(v)))
                    .collect(),
            ),
            other => other.clone(),
        }
    }
    let bounded = walk(v);
    let size = serde_json::to_vec(&bounded).map_or(0, |b| b.len());
    if size > MAX_EVENT_PAYLOAD {
        json!({ "type": v.get("type").cloned().unwrap_or(Value::Null), "truncated": true, "bytes": size })
    } else {
        bounded
    }
}

/// 截断成最多 `max` 个字，顺便去掉 NUL：摘要、原因、标题都来自 agent，NUL 存不进 Postgres，
/// 一条写不进去就会让整个收尾事务失败、运行卡在 running 直到被接管重跑。
fn truncate(s: &str, max: usize) -> String {
    let s = s.trim();
    let cut = match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_owned(),
    };
    strip_nul(cut)
}

fn strip_nul(s: String) -> String {
    if s.contains('\0') {
        s.replace('\0', "")
    } else {
        s
    }
}

impl Executor {
    pub fn new(
        db: Db,
        node_id: impl Into<String>,
        lifecycle: Arc<Lifecycle>,
        grants: Arc<GrantService>,
        connector: Arc<dyn ShimConnector>,
        tools: Arc<dyn PlatformTools>,
        cfg: ExecutorConfig,
    ) -> Self {
        Self {
            db,
            node_id: node_id.into(),
            lifecycle,
            grants,
            connector,
            tools,
            handoff: None,
            vault: None,
            slots: Arc::new(Semaphore::new(cfg.max_concurrent.max(1))),
            cfg,
        }
    }

    /// 流水线步骤开始前把上游产出物复制到工作区（8.5）。
    pub fn with_handoff(mut self, handoff: Arc<crate::pipeline::HandoffCopier>) -> Self {
        self.handoff = Some(handoff);
        self
    }

    /// 密码保险箱（9.11）：沙箱里的助手按名字要值，运行日志落盘前抹掉用户保险箱里的值。
    pub fn with_vault(mut self, kms: Arc<dyn Kms>) -> Self {
        self.vault = Some(kms);
        self
    }

    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    /// 用户保险箱里的值，运行日志落盘前抹掉（9.11）。出错只记日志：抹值是额外的一层保护。
    async fn scrubber(&self, user: UserId) -> Scrubber {
        match &self.vault {
            Some(kms) => crate::vault::user_scrubber(&self.db, kms.clone(), user).await,
            None => Scrubber::new(),
        }
    }

    /// 领取并执行运行，直到 `stop` 完成；之后等进行中的运行收尾。
    pub async fn run(self: Arc<Self>, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let (stop_tx, stop_rx) = watch::channel(false);
        let slots = self.slots.clone();
        let mut running = JoinSet::new();
        let mut takeover = tokio::time::interval(self.cfg.takeover_every);
        info!(node = %self.node_id, "executor started");
        loop {
            while running.try_join_next().is_some() {}
            tokio::select! {
                () = &mut stop => break,
                _ = takeover.tick() => {
                    if let Err(e) = self.take_over_expired().await {
                        error!(error = %e, "lease takeover failed");
                    }
                }
                permit = slots.clone().acquire_owned() => {
                    let Ok(permit) = permit else { break };
                    match self.claim().await {
                        Ok(Some(rec)) => {
                            let me = self.clone();
                            let stop = stop_rx.clone();
                            running.spawn(async move {
                                me.execute_in_slot(rec, stop, Some(permit)).await;
                            });
                        }
                        Ok(None) => {
                            drop(permit);
                            tokio::select! {
                                () = &mut stop => break,
                                () = tokio::time::sleep(self.cfg.claim_poll) => {}
                            }
                        }
                        Err(e) => {
                            drop(permit);
                            error!(error = %e, "claiming a run failed");
                            tokio::time::sleep(self.cfg.claim_poll).await;
                        }
                    }
                }
            }
        }
        let _ = stop_tx.send(true);
        let drain = async { while running.join_next().await.is_some() {} };
        if tokio::time::timeout(self.cfg.stop_timeout * 2, drain)
            .await
            .is_err()
        {
            warn!("runs still stopping after the grace period, aborting them");
            running.shutdown().await;
        }
        info!("executor stopped");
    }

    pub async fn claim(&self) -> store::Result<Option<RunRecord>> {
        let mut w = self.db.worker().await?;
        let rec = w.claim_next_run(&self.node_id, self.cfg.lease).await?;
        w.commit().await?;
        Ok(rec)
    }

    /// 接手别的副本留下的过期租约：它们的 agent 会话随那个副本没了，按可重试失败处理。
    pub async fn take_over_expired(&self) -> store::Result<usize> {
        let mut w = self.db.worker().await?;
        let runs = w
            .take_over_expired(&self.node_id, self.cfg.lease, 20)
            .await?;
        w.commit().await?;
        let n = runs.len();
        for rec in runs {
            warn!(run = %rec.run.id, previous = ?rec.lease_owner, "took over an expired lease");
            self.finish(
                &rec,
                rec.run.state,
                Outcome::Retry("execution was interrupted (lease expired)".into()),
            )
            .await;
        }
        Ok(n)
    }

    /// 执行一个已领取（启动中）的运行，直到结束。这次执行的日志都挂在一个 `run` span 下（2.8）。
    pub async fn execute(&self, rec: RunRecord, stop: watch::Receiver<bool>) {
        self.execute_in_slot(rec, stop, None).await;
    }

    /// 执行一个运行，`slot` 是它占的执行名额（等审批时让出）。
    async fn execute_in_slot(
        &self,
        rec: RunRecord,
        stop: watch::Receiver<bool>,
        slot: Option<OwnedSemaphorePermit>,
    ) {
        let span = tracing::info_span!(
            "run",
            run = %rec.run.id,
            instance = %rec.run.instance_id,
            attempt = rec.run.attempt
        );
        async {
            let started = std::time::Instant::now();
            info!("run starting");
            let (state, outcome) = match self.start_renewing(&rec, slot).await {
                Ok(exec) => exec.drive(stop).await,
                Err(outcome) => (rec.run.state, outcome),
            };
            info!(?outcome, "run finished");
            let label = outcome_label(&outcome);
            metrics::counter!("thinktin_run_attempts_total", "outcome" => label).increment(1);
            metrics::histogram!("thinktin_run_attempt_seconds", "outcome" => label)
                .record(started.elapsed().as_secs_f64());
            self.finish(&rec, state, outcome).await;
        }
        .instrument(span)
        .await
    }

    /// 启动（唤醒沙箱、重建、握手）可能比租约还长：启动期间也按时续租，免得被当成过期接手、重跑一遍。
    /// 启动期间丢了租约就放弃启动。
    async fn start_renewing<'a>(
        &'a self,
        rec: &'a RunRecord,
        slot: Option<OwnedSemaphorePermit>,
    ) -> Result<Exec<'a>, Outcome> {
        let start = self.start(rec, slot);
        tokio::pin!(start);
        let mut renew =
            tokio::time::interval_at(Instant::now() + self.cfg.renew_every, self.cfg.renew_every);
        let mut ok_until = Instant::now() + self.cfg.lease;
        loop {
            tokio::select! {
                result = &mut start => return result,
                _ = renew.tick() => {
                    let held = async {
                        let mut w = self.db.worker().await?;
                        let held = w.renew_lease(rec.run.id, &self.node_id, self.cfg.lease).await?;
                        w.commit().await?;
                        Ok::<_, store::Error>(held)
                    }
                    .await;
                    match held {
                        Ok(true) => ok_until = Instant::now() + self.cfg.lease,
                        Ok(false) => {
                            warn!(run = %rec.run.id, "lease was taken over while starting, giving up");
                            return Err(Outcome::LeaseLost);
                        }
                        Err(e) if Instant::now() >= ok_until => {
                            warn!(run = %rec.run.id, error = %e, "could not renew the lease in time while starting");
                            return Err(Outcome::LeaseLost);
                        }
                        Err(e) => warn!(run = %rec.run.id, error = %e, "lease renewal failed while starting"),
                    }
                }
            }
        }
    }

    async fn start<'a>(
        &'a self,
        rec: &'a RunRecord,
        slot: Option<OwnedSemaphorePermit>,
    ) -> Result<Exec<'a>, Outcome> {
        let instance = rec.run.instance_id;
        let rt = self
            .lifecycle
            .ensure_running(instance)
            .await
            .map_err(|e| match e {
                control::Error::Deleted => Outcome::Failed("instance was deleted".into()),
                control::Error::UnknownVersion { .. } => Outcome::Failed(e.to_string()),
                e => Outcome::Retry(format!("waking the sandbox failed: {e}")),
            })?;
        let retry = |e: store::Error| Outcome::Retry(e.to_string());
        let mut w = self.db.worker().await.map_err(retry)?;
        let grant: GrantId = match rec.run_grant_id {
            Some(g) => g,
            None => w
                .active_grant_for_instance(instance)
                .await
                .map_err(retry)?
                .ok_or_else(|| Outcome::Failed("the instance has no active run grant".into()))?,
        };
        let (_, grant_row) = w.run_grant(grant).await.map_err(retry)?;
        let mut models: Vec<String> = w
            .route_aliases(instance)
            .await
            .map_err(retry)?
            .into_iter()
            .filter(|a| grant_row.scope.aliases.is_empty() || grant_row.scope.aliases.contains(a))
            .collect();
        // 叫 main 的别名当默认模型。
        if let Some(i) = models.iter().position(|m| m == "main") {
            let main = models.remove(i);
            models.insert(0, main);
        }
        let policy = match rec.run.plan_id {
            Some(plan) => w.plan(plan).await.map(|p| p.policy).unwrap_or_default(),
            None => PlanPolicy::default(),
        };
        w.rollback().await.map_err(retry)?;
        let cred = self
            .grants
            .sandbox_token(grant, instance)
            .await
            .map_err(|e| match e {
                AuthError::AccountFrozen => Outcome::Failed("account is frozen".into()),
                AuthError::Invalid(m) => Outcome::Failed(m),
                e => Outcome::Retry(e.to_string()),
            })?;
        if let Some(h) = &self.handoff {
            h.copy(rec, &rt)
                .await
                .map_err(|e| Outcome::Retry(format!("handing over upstream artifacts: {e}")))?;
        }
        let platform_tools: Vec<_> = self
            .tools
            .tools()
            .into_iter()
            .filter(|t| grant_row.scope.platform_tools.contains(&t.name))
            .collect();
        let allowed_tools = platform_tools.iter().map(|t| t.name.clone()).collect();
        let launch = ShimLaunch {
            instance: rt.clone(),
            run: rec.run.id,
            token: cred.token,
            allow_tools: policy.preauthorized_tools.clone(),
            ask_timeout: Duration::from_secs(policy.approval_timeout_secs),
            platform_tools,
            models,
        };
        let mut session = self
            .connector
            .start(&launch)
            .await
            .map_err(|e| Outcome::Retry(e.to_string()))?;
        // 等 shim 就绪（agent 启动、会话建好或接回）。
        let ready = tokio::time::timeout(self.cfg.handshake_timeout, async {
            while let Some(ev) = session.events.recv().await {
                match ev {
                    ShimEvent::Ready { .. } => return Ok(ev),
                    other => debug!(run = %rec.run.id, event = event_kind(&other), "before ready"),
                }
            }
            Err(Outcome::Retry(
                "agent-shim exited before it was ready".into(),
            ))
        })
        .await;
        let ready = match ready {
            Ok(Ok(ev)) => ev,
            Ok(Err(o)) => {
                session.process.kill().await;
                return Err(o);
            }
            Err(_) => {
                session.process.kill().await;
                return Err(Outcome::Retry(
                    "agent-shim did not get ready in time".into(),
                ));
            }
        };
        let mut exec = Exec {
            ex: self,
            rec,
            state: rec.run.state,
            policy,
            session,
            ctx: ToolContext {
                user: rec.user_id,
                instance,
                run: rec.run.id,
                plan: rec.run.plan_id,
                grant,
            },
            message: String::new(),
            thought: String::new(),
            answer: String::new(),
            steps: rec.steps,
            pending: HashSet::new(),
            usage_since: rec.run.started_at.unwrap_or_else(Utc::now),
            allowed_tools,
            slot,
            slot_released: false,
            lease_ok_until: Instant::now() + self.cfg.lease,
            delivered: HashSet::new(),
            logged: 0,
            log_capped: false,
            scrubber: self.scrubber(rec.user_id).await,
        };
        exec.persist(&ready).await;
        Ok(exec)
    }

    fn backoff(&self, attempt: u32) -> Duration {
        let exp = attempt.saturating_sub(1).min(16);
        self.cfg
            .backoff_base
            .saturating_mul(1 << exp)
            .min(self.cfg.backoff_max)
    }

    /// 写结果：状态迁移、运行日志里的状态事件、通知，同一个事务。
    async fn finish(&self, rec: &RunRecord, state: RunState, outcome: Outcome) {
        if let Err(e) = self.finish_inner(rec, state, outcome).await {
            match e {
                // 用户刚好取消了，或者租约刚好被接管：以对方为准。
                store::Error::InvalidTransition { .. } | store::Error::LeaseLost { .. } => {
                    debug!(run = %rec.run.id, error = %e, "run changed underneath, leaving it");
                }
                e => error!(run = %rec.run.id, error = %e, "recording the run result failed"),
            }
        }
    }

    async fn finish_inner(
        &self,
        rec: &RunRecord,
        state: RunState,
        outcome: Outcome,
    ) -> store::Result<()> {
        let run = rec.run.id;
        let (to, change, push) = match outcome {
            Outcome::Cancelled => {
                let mut w = self.db.worker().await?;
                // 令牌代数在取消的同一个事务里已经加过（见 store 的取消）：这时实例上可能已经
                // 有下一个运行了，再加会让它的令牌失效。
                w.cancel_run_approvals(run).await?;
                return w.commit().await;
            }
            // 租约已经被别的副本接手：这次运行归它了，什么都别动（包括它新建的审批）。
            Outcome::LeaseLost => return Ok(()),
            Outcome::Succeeded { summary, reason } => {
                let body = summary
                    .as_deref()
                    .map(|s| truncate(s, 100))
                    .unwrap_or_else(|| "任务完成".into());
                (
                    RunState::Succeeded,
                    RunChange {
                        summary,
                        reason,
                        ..Default::default()
                    },
                    Some((PushKind::RunFinished, body)),
                )
            }
            Outcome::Failed(error) => (
                RunState::Failed,
                RunChange {
                    reason: Some(truncate(&error, 200)),
                    error: Some(error.clone()),
                    ..Default::default()
                },
                Some((PushKind::RunFailed, truncate(&error, 100))),
            ),
            Outcome::Retry(error) if rec.run.attempt >= rec.max_attempts => (
                RunState::Failed,
                RunChange {
                    reason: Some(format!("gave up after {} attempts", rec.run.attempt)),
                    error: Some(error.clone()),
                    ..Default::default()
                },
                Some((PushKind::RunFailed, truncate(&error, 100))),
            ),
            Outcome::Retry(error) => {
                let delay = self.backoff(rec.run.attempt);
                (
                    RunState::Backoff,
                    RunChange {
                        reason: Some(truncate(&error, 200)),
                        error: Some(error),
                        not_before: Some(
                            Utc::now() + chrono::Duration::from_std(delay).unwrap_or_default(),
                        ),
                        release_lease: true,
                        ..Default::default()
                    },
                    None,
                )
            }
            Outcome::Interrupted => (
                RunState::Backoff,
                RunChange {
                    reason: Some("interrupted by a deploy or restart, resuming shortly".into()),
                    not_before: Some(Utc::now()),
                    release_lease: true,
                    ..Default::default()
                },
                None,
            ),
        };
        let mut w = self.db.worker().await?;
        // 状态机里成功只能从运行中到达、退避不能从等待中到达：先回到运行中。
        let detour = matches!(to, RunState::Succeeded | RunState::Backoff)
            && (state == RunState::Starting && to == RunState::Succeeded || state.is_waiting());
        if detour {
            w.transition_run(run, &self.node_id, RunState::Running, &RunChange::default())
                .await?;
        }
        let done = w.transition_run(run, &self.node_id, to, &change).await?;
        // 这次尝试结束了：没处理的审批作废（下次尝试 agent 会重新请求）。走到这里说明还拿着租约
        // （没拿住时 transition_run 报错），不会误伤接手的副本新建的审批。
        w.cancel_run_approvals(run).await?;
        // 这次尝试签出的沙箱令牌作废：agent 留在沙箱里的后台进程不能接着花用户的模型额度。
        // 和状态变更在同一个事务里，下一个运行签令牌时一定拿到新的代数。
        w.bump_token_epoch(rec.run.instance_id).await?;
        w.append_event(
            rec.run.instance_id,
            Some(run),
            "run.state",
            &json!({ "state": to, "reason": done.run.state_reason, "attempt": done.run.attempt }),
        )
        .await?;
        // 流水线的步骤不单独通知：整条流水线结束时由根运行通知（8.3）。
        if let Some((kind, body)) = push.filter(|_| rec.run.step_key.is_none()) {
            let title = match rec.run.plan_id {
                Some(plan) => w.plan(plan).await.map(|p| p.title).unwrap_or_default(),
                None => String::new(),
            };
            let title = if title.is_empty() {
                "ThinkTin".to_owned()
            } else {
                title
            };
            let notice = Notice {
                instance: Some(rec.run.instance_id),
                run: Some(run),
                plan: rec.run.plan_id,
                thread_id: Some(run.to_string()),
                dedupe_key: Some(format!("run:{run}:{to}")),
                // 成功时正文是 agent 写的摘要；失败原因是平台写的。
                ai_generated: kind == PushKind::RunFinished,
                ..Notice::new(kind, title, body)
            };
            notify(&mut w, rec.user_id, &notice).await?;
        }
        w.commit().await
    }
}

impl Exec<'_> {
    /// 审批记录里的请求 id：shim 每次启动都从 perm-1 重新编号，加上第几次尝试，重试时不会撞上旧的。
    fn approval_key(&self, request_id: &str) -> String {
        format!("{}:{request_id}", self.rec.run.attempt)
    }

    async fn send(&mut self, cmd: ShimCommand) -> bool {
        self.session.commands.send(cmd).await.is_ok()
    }

    /// 写运行日志：限制单条大小和这次运行的总量。
    async fn persist_raw(&mut self, kind: &str, payload: &Value) {
        let payload = if self.scrubber.is_empty() {
            bound_payload(payload)
        } else {
            let mut clean = payload.clone();
            crate::vault::scrub_json(&self.scrubber, &mut clean);
            bound_payload(&clean)
        };
        let size = serde_json::to_vec(&payload).map_or(0, |b| b.len());
        if self.logged.saturating_add(size) > self.ex.cfg.max_run_log_bytes {
            if !self.log_capped {
                self.log_capped = true;
                warn!(run = %self.rec.run.id, logged = self.logged, "run log limit reached; dropping further agent output");
                self.write_event(
                    "run.log_truncated",
                    &json!({ "limit_bytes": self.ex.cfg.max_run_log_bytes }),
                )
                .await;
            }
            return;
        }
        self.logged += size;
        self.write_event(kind, &payload).await;
    }

    /// 写一条运行日志。写失败只记日志：运行本身比日志重要。
    async fn write_event(&self, kind: &str, payload: &Value) {
        let result = async {
            let mut w = self.ex.db.worker().await?;
            w.append_event(
                self.rec.run.instance_id,
                Some(self.rec.run.id),
                kind,
                payload,
            )
            .await?;
            w.commit().await
        }
        .await;
        if let Err(e) = result {
            warn!(run = %self.rec.run.id, error = %e, "writing the run log failed");
        }
    }

    async fn persist(&mut self, ev: &ShimEvent) {
        let payload = serde_json::to_value(ev).unwrap_or(Value::Null);
        self.persist_raw(event_kind(ev), &payload).await;
    }

    /// 把攒着的文字写进运行日志。
    async fn flush(&mut self) {
        if !self.message.is_empty() {
            let text = std::mem::take(&mut self.message);
            self.persist_raw(
                "agent.message",
                &json!({ "type": "message_chunk", "text": text }),
            )
            .await;
        }
        if !self.thought.is_empty() {
            let text = std::mem::take(&mut self.thought);
            self.persist_raw(
                "agent.thought",
                &json!({ "type": "thought_chunk", "text": text }),
            )
            .await;
        }
    }

    async fn transition(&mut self, to: RunState, reason: Option<String>) -> Result<(), Outcome> {
        let result = async {
            let mut w = self.ex.db.worker().await?;
            let done = w
                .transition_run(
                    self.rec.run.id,
                    &self.ex.node_id,
                    to,
                    &RunChange {
                        reason: reason.clone(),
                        ..Default::default()
                    },
                )
                .await?;
            w.append_event(
                self.rec.run.instance_id,
                Some(self.rec.run.id),
                "run.state",
                &json!({ "state": to, "reason": reason }),
            )
            .await?;
            w.commit().await?;
            Ok::<_, store::Error>(done)
        }
        .await;
        match result {
            Ok(done) => {
                self.state = to;
                if to == RunState::Running && self.rec.run.started_at.is_none() {
                    self.usage_since = done.run.started_at.unwrap_or(self.usage_since);
                }
                Ok(())
            }
            Err(store::Error::LeaseLost { .. }) => Err(Outcome::LeaseLost),
            Err(store::Error::InvalidTransition {
                from: RunState::Cancelled,
                ..
            }) => Err(Outcome::Cancelled),
            Err(e) => Err(Outcome::Retry(e.to_string())),
        }
    }

    /// 取消 agent 这一轮，等它收尾（最多 stop_timeout），期间的事件照常记录。
    async fn cancel_turn(&mut self) {
        let run_id = self.rec.run.id.to_string();
        if !self
            .send(ShimCommand::Cancel {
                run_id: run_id.clone(),
            })
            .await
        {
            return;
        }
        let deadline = Instant::now() + self.ex.cfg.stop_timeout;
        while let Ok(Some(ev)) = tokio::time::timeout_at(deadline, self.session.events.recv()).await
        {
            let ended = matches!(&ev, ShimEvent::TurnEnded { run_id: r, .. } if *r == run_id);
            self.persist(&ev).await;
            if ended {
                break;
            }
        }
    }

    /// 把 agent 这一轮跑完。返回结束时的状态和结果。
    async fn drive(mut self, mut stop: watch::Receiver<bool>) -> (RunState, Outcome) {
        let outcome = self.drive_inner(&mut stop).await;
        self.flush().await;
        let _ = self.session.commands.send(ShimCommand::Shutdown).await;
        if tokio::time::timeout(self.ex.cfg.stop_timeout, self.session.process.wait())
            .await
            .is_err()
        {
            self.session.process.kill().await;
        }
        (self.state, outcome)
    }

    async fn drive_inner(&mut self, stop: &mut watch::Receiver<bool>) -> Outcome {
        let run_id = self.rec.run.id.to_string();
        let mut prompt = self.rec.run.prompt.clone();
        if self.rec.run.attempt > 1 {
            prompt = format!(
                "（续跑说明：这是第 {} 次尝试，上一次执行中途中断了。先检查工作区里已有的进度，从中断的地方继续，不要重复已经完成的对外操作。）\n\n{prompt}",
                self.rec.run.attempt
            );
        }
        if !self
            .send(ShimCommand::Prompt {
                run_id: run_id.clone(),
                text: prompt,
            })
            .await
        {
            return Outcome::Retry("agent-shim exited".into());
        }
        let budget = self.rec.budget;
        let deadline = Instant::now() + Duration::from_secs(budget.max_duration_secs.max(1));
        let sleep = tokio::time::sleep_until(deadline);
        tokio::pin!(sleep);
        let mut renew = tokio::time::interval_at(
            Instant::now() + self.ex.cfg.renew_every,
            self.ex.cfg.renew_every,
        );
        let mut poll = tokio::time::interval(self.ex.cfg.approval_poll);
        let mut flush = tokio::time::interval(self.ex.cfg.flush_every);
        loop {
            tokio::select! {
                biased;
                () = async { let _ = stop.wait_for(|s| *s).await; } => {
                    self.cancel_turn().await;
                    return Outcome::Interrupted;
                }
                ev = self.session.events.recv() => {
                    let Some(ev) = ev else {
                        return Outcome::Retry("agent-shim exited".into());
                    };
                    if let Some(outcome) = self.on_event(ev, &run_id).await {
                        return outcome;
                    }
                }
                _ = renew.tick() => {
                    if let Some(outcome) = self.on_renew().await {
                        return outcome;
                    }
                }
                _ = poll.tick(), if !self.pending.is_empty() => {
                    if let Err(outcome) = self.poll_approvals().await {
                        return outcome;
                    }
                }
                _ = flush.tick() => self.flush().await,
                () = &mut sleep => {
                    self.cancel_turn().await;
                    return Outcome::Failed(format!(
                        "time budget exceeded ({} s)", budget.max_duration_secs
                    ));
                }
            }
        }
    }

    async fn on_event(&mut self, ev: ShimEvent, run_id: &str) -> Option<Outcome> {
        match &ev {
            ShimEvent::MessageChunk { text, .. } => {
                self.message.push_str(text);
                push_capped(&mut self.answer, text, MAX_ANSWER);
                if self.message.len() > 4096 {
                    self.flush().await;
                }
                return None;
            }
            ShimEvent::ThoughtChunk { text, .. } => {
                self.thought.push_str(text);
                if self.thought.len() > 4096 {
                    self.flush().await;
                }
                return None;
            }
            _ => {}
        }
        self.flush().await;
        self.persist(&ev).await;
        match ev {
            ShimEvent::TurnStarted { run_id: r } if r == run_id => {
                if self.state == RunState::Starting
                    && let Err(o) = self.transition(RunState::Running, None).await
                {
                    return Some(o);
                }
            }
            ShimEvent::ToolCall { .. } => {
                self.steps += 1;
                self.answer.clear();
                if let Some(max) = self.rec.budget.max_steps
                    && self.steps > max
                {
                    self.cancel_turn().await;
                    return Some(Outcome::Failed(format!(
                        "step budget exceeded ({max} steps)"
                    )));
                }
            }
            ShimEvent::PermissionRequested {
                request_id,
                title,
                options,
                tool_call,
                ..
            } => {
                if let Err(o) = self
                    .on_permission(&request_id, title.as_deref(), &options, &tool_call)
                    .await
                {
                    return Some(o);
                }
            }
            ShimEvent::PermissionResolved {
                request_id,
                by,
                option_id,
                ..
            } => {
                if let Some(o) = self
                    .on_resolved(&request_id, by, option_id.as_deref())
                    .await
                {
                    return Some(o);
                }
            }
            ShimEvent::PlatformToolCall {
                call_id,
                name,
                arguments,
                ..
            } => {
                let out = if self.allowed_tools.contains(&name) {
                    self.ex.tools.call(&self.ctx, &name, &arguments).await
                } else {
                    warn!(run = %self.rec.run.id, tool = %name, "platform tool outside the run grant");
                    ToolOutput::error(format!("unknown platform tool {name}"))
                };
                self.send(ShimCommand::PlatformToolResult {
                    call_id,
                    content: out.content,
                    is_error: out.is_error,
                })
                .await;
            }
            ShimEvent::VaultReveal { call_id, refs, .. } => {
                let (values, error) = match self.reveal(&refs).await {
                    Ok(values) => (values, None),
                    Err(e) => (Vec::new(), Some(e)),
                };
                self.send(ShimCommand::VaultValues {
                    call_id,
                    values: SecretValues(values),
                    error,
                })
                .await;
            }
            ShimEvent::AgentExited {
                will_restart: false,
                code,
                ..
            } => {
                return Some(Outcome::Retry(format!(
                    "agent exited ({code:?}) and will not be restarted"
                )));
            }
            ShimEvent::TurnEnded {
                run_id: r,
                stop_reason,
            } if r == run_id => {
                let answer = self
                    .scrubber
                    .scrub(&self.answer)
                    .unwrap_or_else(|| self.answer.clone());
                let summary = Some(truncate(&answer, 400)).filter(|s| !s.is_empty());
                return Some(match stop_reason {
                    StopReason::EndTurn => Outcome::Succeeded {
                        summary,
                        reason: None,
                    },
                    StopReason::MaxTokens | StopReason::MaxTurnRequests => Outcome::Succeeded {
                        summary,
                        reason: Some(format!("agent stopped early: {stop_reason:?}")),
                    },
                    StopReason::Cancelled => Outcome::Failed("the agent cancelled the turn".into()),
                    StopReason::Refusal => Outcome::Failed("the model refused the task".into()),
                    StopReason::Unknown => {
                        Outcome::Failed("the turn ended for an unknown reason".into())
                    }
                });
            }
            _ => {}
        }
        None
    }

    /// 沙箱里的助手要用保险箱里的值（9.11）：核对授权和实例，解密，记审计和运行日志（只记名字）。
    /// 解开的密码加进抹值的列表：不管 agent 拿它做什么，运行日志里都看不到。
    async fn reveal(&mut self, refs: &[String]) -> Result<Vec<String>, String> {
        fn internal(e: impl std::fmt::Display) -> String {
            warn!(error = %e, "revealing vault values failed");
            "the password vault is not available, try again later".into()
        }
        let Some(kms) = self.ex.vault.clone() else {
            return Err("the password vault is not available on this platform".into());
        };
        if !self.allowed_tools.contains("vault_list") {
            return Err("this agent is not allowed to use the password vault".into());
        }
        if refs.is_empty() || refs.len() > 20 {
            return Err("ask for 1-20 values at a time".into());
        }
        let mut wanted: Vec<(String, bool)> = Vec::with_capacity(refs.len());
        for r in refs {
            let (name, field) = r.split_once('.').unwrap_or((r.as_str(), "password"));
            if !valid_vault_name(name) || !matches!(field, "password" | "username") {
                return Err(format!(
                    "{r:?} is not a vault reference (name, name.username or name.password)"
                ));
            }
            wanted.push((name.to_owned(), field == "username"));
        }
        let mut names: Vec<String> = wanted.iter().map(|(n, _)| n.clone()).collect();
        names.sort();
        names.dedup();
        let user = self.rec.user_id;
        let instance = self.rec.run.instance_id;
        let mut w = self.ex.db.worker().await.map_err(internal)?;
        let items = w
            .vault_items_for_instance(user, instance, &names)
            .await
            .map_err(internal)?;
        w.rollback().await.map_err(internal)?;
        if let Some(missing) = names
            .iter()
            .find(|n| !items.iter().any(|i| &i.item.name == *n))
        {
            return Err(format!(
                "no vault item named {missing} for this agent; ask the user with vault_request"
            ));
        }
        let vault = crate::artifacts::user_vault(&self.ex.db, kms, user, false)
            .await
            .map_err(internal)?;
        let uid = user.to_string();
        let mut opened = Vec::with_capacity(items.len());
        for item in &items {
            let secret = vault
                .open_vault(&uid, &item.item.id.to_string(), &item.sealed)
                .map_err(internal)?;
            self.scrubber.add_secret(&item.item.name, &secret);
            opened.push((item.item.name.as_str(), secret));
        }
        let mut values = Vec::with_capacity(wanted.len());
        for (name, username) in &wanted {
            let Some((_, secret)) = opened.iter().find(|(n, _)| n == name) else {
                return Err(format!("no vault item named {name} for this agent"));
            };
            if *username {
                if secret.username.is_empty() {
                    return Err(format!("{name} has no username"));
                }
                values.push(secret.username.clone());
            } else {
                values.push(secret.password.clone());
            }
        }
        let ids: Vec<VaultItemId> = items.iter().map(|i| i.item.id).collect();
        let run = self.rec.run.id;
        let recorded = async {
            let mut w = self.ex.db.worker().await?;
            w.touch_vault_items(&ids).await?;
            w.audit(
                Some(user),
                &format!("agent:{instance}"),
                "vault.use",
                None,
                &json!({ "run": run, "items": names }),
            )
            .await?;
            w.append_event(
                instance,
                Some(run),
                "vault.used",
                &json!({ "names": names }),
            )
            .await?;
            w.commit().await
        }
        .await;
        recorded.map_err(internal)?;
        Ok(values)
    }

    async fn on_permission(
        &mut self,
        request_id: &str,
        title: Option<&str>,
        options: &[proto::shim::PermissionOption],
        tool_call: &Value,
    ) -> Result<(), Outcome> {
        // 标题、选项、工具调用都来自 agent：抹掉保险箱里的值、限制大小、去掉 NUL 再入库。
        let options_json = bound_payload(&serde_json::to_value(options).unwrap_or(Value::Null));
        let mut tool_call = tool_call.clone();
        crate::vault::scrub_json(&self.scrubber, &mut tool_call);
        let tool_call = &bound_payload(&tool_call);
        let title = title.map(|t| {
            let t = self.scrubber.scrub(t).unwrap_or_else(|| t.to_owned());
            truncate(&t, 200)
        });
        let title = title.as_deref();
        let expires_in = Duration::from_secs(self.policy.approval_timeout_secs);
        let key = self.approval_key(request_id);
        let result = async {
            let mut w = self.ex.db.worker().await?;
            let approval = w
                .create_approval(&NewApproval {
                    user: self.rec.user_id,
                    instance: self.rec.run.instance_id,
                    run: self.rec.run.id,
                    request_id: &key,
                    title,
                    options: &options_json,
                    tool_call,
                    expires_in,
                })
                .await?;
            let id = approval.approval.id;
            let notice = Notice {
                instance: Some(self.rec.run.instance_id),
                run: Some(self.rec.run.id),
                plan: self.rec.run.plan_id,
                approval: Some(id),
                thread_id: Some(self.rec.run.id.to_string()),
                collapse_id: Some(id.to_string()),
                ttl: Some(expires_in),
                dedupe_key: Some(format!("approval:{id}")),
                // 正文是 agent 给工具调用起的标题。
                ai_generated: title.is_some(),
                ..Notice::new(
                    PushKind::Approval,
                    "需要你的批准",
                    truncate(title.unwrap_or("agent 请求执行一个操作"), 100),
                )
            };
            notify(&mut w, self.rec.user_id, &notice).await?;
            w.commit().await
        }
        .await;
        result.map_err(|e| Outcome::Retry(e.to_string()))?;
        self.pending.insert(request_id.to_owned());
        if self.state == RunState::Running {
            self.transition(RunState::WaitingApproval, title.map(|t| truncate(t, 200)))
                .await?;
        }
        // 等用户的时间可能很长：让出执行名额，别的运行可以先跑。
        if self.slot.take().is_some() {
            self.slot_released = true;
        }
        Ok(())
    }

    async fn on_resolved(
        &mut self,
        request_id: &str,
        by: DecisionSource,
        option: Option<&str>,
    ) -> Option<Outcome> {
        let was_pending = self.pending.remove(request_id);
        self.delivered.remove(request_id);
        let key = self.approval_key(request_id);
        if was_pending && by != DecisionSource::User {
            let state = match by {
                DecisionSource::Timeout => ApprovalState::Expired,
                _ => ApprovalState::Cancelled,
            };
            let result = async {
                let mut w = self.ex.db.worker().await?;
                w.settle_approval(
                    self.rec.run.id,
                    &key,
                    state,
                    option,
                    &format!("{by:?}").to_lowercase(),
                )
                .await?;
                w.commit().await
            }
            .await;
            if let Err(e) = result {
                warn!(run = %self.rec.run.id, error = %e, "settling the approval failed");
            }
        }
        if by == DecisionSource::Timeout {
            match self.policy.on_approval_timeout {
                ApprovalTimeoutAction::Skip => {}
                ApprovalTimeoutAction::Fail => {
                    self.cancel_turn().await;
                    return Some(Outcome::Failed("approval timed out".into()));
                }
                ApprovalTimeoutAction::PausePlan => {
                    if let Some(plan) = self.rec.run.plan_id {
                        let paused = async {
                            let mut w = self.ex.db.worker().await?;
                            w.set_plan_paused(plan, true).await?;
                            w.commit().await
                        }
                        .await;
                        if let Err(e) = paused {
                            warn!(%plan, error = %e, "pausing the plan failed");
                        }
                    }
                    self.cancel_turn().await;
                    return Some(Outcome::Failed(
                        "approval timed out; the plan was paused".into(),
                    ));
                }
            }
        }
        if self.pending.is_empty()
            && self.state.is_waiting()
            && let Err(o) = self.transition(RunState::Running, None).await
        {
            return Some(o);
        }
        None
    }

    /// 查用户的决定，转给 shim。
    async fn poll_approvals(&mut self) -> Result<(), Outcome> {
        let pending: Vec<String> = self
            .pending
            .iter()
            .filter(|r| !self.delivered.contains(*r))
            .cloned()
            .collect();
        for request_id in pending {
            let key = self.approval_key(&request_id);
            let rec = async {
                let mut w = self.ex.db.worker().await?;
                let r = w.approval_for_request(self.rec.run.id, &key).await?;
                w.rollback().await?;
                Ok::<_, store::Error>(r)
            }
            .await
            .map_err(|e| Outcome::Retry(e.to_string()))?;
            let Some(rec) = rec else { continue };
            if matches!(
                rec.approval.state,
                ApprovalState::Approved | ApprovalState::Rejected
            ) {
                // 先拿回执行名额（满了就下次再看），再唤醒沙箱：等审批期间可能被空闲回收暂停了。
                if self.slot_released {
                    match self.ex.slots.clone().try_acquire_owned() {
                        Ok(permit) => {
                            self.slot = Some(permit);
                            self.slot_released = false;
                        }
                        Err(_) => return Ok(()),
                    }
                }
                self.ex
                    .lifecycle
                    .ensure_running(self.rec.run.instance_id)
                    .await
                    .map_err(|e| Outcome::Retry(format!("waking the instance: {e}")))?;
                self.send(ShimCommand::PermissionDecision {
                    request_id: request_id.clone(),
                    option_id: rec.decided_option,
                })
                .await;
                // 只发一次；shim 回 permission_resolved(by=user) 后从 pending 里移除、回到运行中。
                self.delivered.insert(request_id);
            }
        }
        Ok(())
    }

    /// 续租，顺便检查预算。
    async fn on_renew(&mut self) -> Option<Outcome> {
        let result = async {
            let mut w = self.ex.db.worker().await?;
            let held = w
                .renew_lease(self.rec.run.id, &self.ex.node_id, self.ex.cfg.lease)
                .await?;
            if !held {
                let state = w.run_record(self.rec.run.id).await?.run.state;
                w.rollback().await?;
                return Ok::<_, store::Error>(Err(state));
            }
            let tokens = w
                .instance_usage_since(self.rec.run.instance_id, self.usage_since)
                .await?;
            w.set_run_usage(self.rec.run.id, tokens, self.steps).await?;
            w.commit().await?;
            Ok(Ok(tokens))
        }
        .await;
        if matches!(result, Ok(Ok(_))) {
            self.lease_ok_until = Instant::now() + self.ex.cfg.lease;
        }
        match result {
            Ok(Ok(tokens)) => {
                if let Some(max) = self.rec.budget.max_tokens
                    && tokens > max
                {
                    self.cancel_turn().await;
                    return Some(Outcome::Failed(format!(
                        "token budget exceeded ({tokens} > {max})"
                    )));
                }
                None
            }
            Ok(Err(RunState::Cancelled)) => {
                info!(run = %self.rec.run.id, "run was cancelled, stopping the agent");
                self.cancel_turn().await;
                Some(Outcome::Cancelled)
            }
            Ok(Err(_)) => {
                warn!(run = %self.rec.run.id, "lease was taken over, letting go");
                self.session.process.kill().await;
                Some(Outcome::LeaseLost)
            }
            Err(e) if Instant::now() >= self.lease_ok_until => {
                // 一直续不上，租约已经过期，别的副本随时会接手：停下 agent，不和它同时跑。
                warn!(run = %self.rec.run.id, error = %e, "lease expired without a renewal, stopping");
                self.session.process.kill().await;
                Some(Outcome::LeaseLost)
            }
            Err(e) => {
                // 数据库暂时不可用：租约还有余量，下次再续。
                warn!(run = %self.rec.run.id, error = %e, "lease renewal failed");
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capped_buffers_keep_the_head_on_char_boundaries() {
        let mut s = String::new();
        push_capped(&mut s, "你好世界", 7);
        assert_eq!(s, "你好");
        push_capped(&mut s, "abc", 7);
        assert_eq!(s, "你好a");
        push_capped(&mut s, "zzz", 7);
        assert_eq!(s, "你好a");
    }

    #[test]
    fn event_payloads_are_bounded() {
        let long = "x".repeat(MAX_EVENT_STRING * 3);
        let v = bound_payload(
            &json!({ "type": "tool_call_update", "raw": { "output": long }, "n": 3 }),
        );
        let out = v["raw"]["output"].as_str().unwrap();
        assert!(out.len() < MAX_EVENT_STRING + 32 && out.ends_with("…[truncated]"));
        assert_eq!(v["n"], 3);
        // 很多个不长的字符串加起来太大：整条换成占位。
        let many: Vec<String> = (0..64).map(|_| "y".repeat(MAX_EVENT_STRING)).collect();
        let v = bound_payload(&json!({ "type": "plan", "entries": many }));
        assert_eq!(v["truncated"], true);
        assert_eq!(v["type"], "plan");
        assert!(serde_json::to_vec(&v).unwrap().len() < 200);
    }
}
