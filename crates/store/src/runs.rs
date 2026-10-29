//! 运行与执行租约（7.3、7.4）。
//!
//! 状态迁移一律按 [`RunState::can_transition`] 校验，并在锁住的行上比较当前状态，
//! 并发的取消、超时接管不会被覆盖。执行中的运行由持有租约的副本推进：
//! 租约过期（副本崩溃）后别的副本用 [`Tx::take_over_expired`] 接管。
//! SQL 里直接写了结束状态 `('succeeded', 'failed', 'cancelled')`，和 [`RunState::is_terminal`] 一致（有测试核对）。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    GrantId, InstanceId, PlanHookId, PlanId, Run, RunBudget, RunId, RunKind, RunSource, RunState,
    TriggerId, UserId,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, from_json, parse, secs, to_json, unsigned};

/// 新运行。用 [`NewRun::new`] 建，再按需填计划、父运行等字段。
#[derive(Debug, Clone)]
pub struct NewRun {
    pub kind: RunKind,
    pub instance_id: InstanceId,
    pub source: RunSource,
    pub prompt: String,
    /// 启动时锁定的 agent 模板版本。
    pub agent_version: String,
    pub plan_id: Option<PlanId>,
    pub trigger_id: Option<TriggerId>,
    /// 计划运行的名义触发时间；同一计划同一时间只会有一个运行。
    pub fire_time: Option<DateTime<Utc>>,
    pub parent_run_id: Option<RunId>,
    /// 流水线子运行对应的步骤。
    pub step_key: Option<String>,
    pub run_grant_id: Option<GrantId>,
    pub budget: RunBudget,
    /// 抖动后的最早开始时间；None 为立即。
    pub not_before: Option<DateTime<Utc>>,
    pub max_attempts: u32,
    /// 问队友的问题（8.11）：最晚什么时候答完，过了后台取消它，提问方得到“对方没回答”。
    pub answer_deadline: Option<DateTime<Utc>>,
    /// 用户的紧急消息要打断的运行（8.12），由 [`Tx::queue_urgent_run`] 填。
    pub interrupts_run_id: Option<RunId>,
    /// 用户的紧急消息（8.12），由 [`Tx::queue_urgent_run`] 填。
    pub urgent: bool,
    /// 哪个计划 webhook 收到事件起的（7.1）。
    pub hook_id: Option<PlanHookId>,
}

impl NewRun {
    pub fn new(
        instance_id: InstanceId,
        source: RunSource,
        prompt: impl Into<String>,
        agent_version: impl Into<String>,
    ) -> Self {
        Self {
            kind: RunKind::Agent,
            instance_id,
            source,
            prompt: prompt.into(),
            agent_version: agent_version.into(),
            plan_id: None,
            trigger_id: None,
            fire_time: None,
            parent_run_id: None,
            step_key: None,
            run_grant_id: None,
            budget: RunBudget::default(),
            not_before: None,
            max_attempts: 3,
            answer_deadline: None,
            interrupts_run_id: None,
            urgent: false,
            hook_id: None,
        }
    }
}

/// 问队友超时（8.11）：后台取消没按时答完的提问时写的状态说明，交还给提问方时据此说“对方没回答”。
pub const ANSWER_TIMEOUT_REASON: &str = "no answer in time";
/// 提问方不在了（被取消、失败）：它的提问没人要了。
pub const ASKER_GONE_REASON: &str = "the asker stopped";
/// 用户发来紧急消息打断了这个运行（8.12）。新消息的运行据此在开头说明“你刚才在做……被打断了”。
pub const INTERRUPTED_REASON: &str = "interrupted by a new message";

/// 用户的紧急消息怎么送的（8.12）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Urgent {
    /// 实例空闲：排在它别的排队消息前面。
    Free,
    /// 有运行正在执行：它的执行器续租时看到，停下这一轮、结束运行，新消息接着跑。
    Interrupting(RunId),
    /// 占着实例的运行停在等待里（等子任务、等 key、等电脑、退避）、没人在执行：直接取消了（连同子孙）。
    Stopped(RunId),
    /// 已经有一条紧急消息在等着打断了：排在那条后面。
    Behind(RunId),
}

/// 状态迁移时一并写入的内容。
#[derive(Debug, Clone, Default)]
pub struct RunChange {
    /// 状态说明（比如等的是哪个审批、为什么失败）。
    pub reason: Option<String>,
    pub summary: Option<String>,
    pub error: Option<String>,
    /// 进入退避时：下次最早什么时候重试。
    pub not_before: Option<DateTime<Utc>>,
    /// 放掉执行租约（进入长时间等待、退避时）。进入结束状态总是放掉。
    pub release_lease: bool,
    /// 进入等待电脑、等待 key（7.11）时：最晚等到什么时候，过了按计划策略结束。
    pub wait_deadline: Option<DateTime<Utc>>,
    /// 等的是什么（`proto::domain::wait_code`）。每次换状态都按它覆盖：不给就清掉。
    pub wait_code: Option<&'static str>,
}

/// 跨实例列运行（11.8）：某个计划的、还没结束的、只要根运行（不要流水线的步骤、委派的子任务）。
#[derive(Debug, Clone, Copy, Default)]
pub struct RunFilter {
    pub plan: Option<PlanId>,
    pub active: bool,
    pub roots: bool,
}

/// 后台看到的运行：带租约、预算等执行细节。
#[derive(Debug, Clone, PartialEq)]
pub struct RunRecord {
    pub run: Run,
    pub user_id: UserId,
    pub trigger_id: Option<TriggerId>,
    pub fire_time: Option<DateTime<Utc>>,
    pub agent_version: String,
    pub run_grant_id: Option<GrantId>,
    pub budget: RunBudget,
    pub max_attempts: u32,
    pub steps: u32,
    pub not_before: DateTime<Utc>,
    pub lease_owner: Option<String>,
    pub lease_expires_at: Option<DateTime<Utc>>,
    /// 这是用户打断这个运行时发的紧急消息（8.12）。
    pub interrupts_run_id: Option<RunId>,
    /// 这条排队的消息已经在上一个运行里捎带给 agent 看过（8.12）。
    pub announced_at: Option<DateTime<Utc>>,
}

/// 模型网关记下的一次模型调用（只有结果，没有内容）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelCall {
    /// 厂商返回的状态码；网关自己拒绝的是它回给 agent 的状态码；连不上是 0。
    pub status: u16,
    /// `complete`、`upstream_status`、`unavailable`（没有能用的 key，请求没发出去）……
    pub outcome: String,
    pub at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    kind: String,
    step_key: Option<String>,
    user_id: Uuid,
    instance_id: Uuid,
    plan_id: Option<Uuid>,
    trigger_id: Option<Uuid>,
    fire_time: Option<DateTime<Utc>>,
    parent_run_id: Option<Uuid>,
    root_run_id: Uuid,
    source: String,
    prompt: String,
    state: String,
    state_reason: Option<String>,
    attempt: i32,
    max_attempts: i32,
    not_before: DateTime<Utc>,
    lease_owner: Option<String>,
    lease_expires_at: Option<DateTime<Utc>>,
    agent_version: String,
    run_grant_id: Option<Uuid>,
    budget: serde_json::Value,
    tokens_used: i64,
    steps: i32,
    summary: Option<String>,
    error: Option<String>,
    created_at: DateTime<Utc>,
    started_at: Option<DateTime<Utc>>,
    finished_at: Option<DateTime<Utc>>,
    wait_code: Option<String>,
    interrupts_run_id: Option<Uuid>,
    announced_at: Option<DateTime<Utc>>,
}

macro_rules! columns {
    () => {
        "id, kind, step_key, user_id, instance_id, plan_id, trigger_id, fire_time, parent_run_id, root_run_id, source, prompt, \
         state, state_reason, attempt, max_attempts, not_before, lease_owner, lease_expires_at, agent_version, \
         run_grant_id, budget, tokens_used, steps, summary, error, created_at, started_at, finished_at, wait_code, \
         interrupts_run_id, announced_at"
    };
}

/// 这一版程序认识的运行来源。后台领取、接管运行时只要这些：新版本加了来源（比如 8.11 的 ask），回滚到
/// 老版本时老副本跳过它解析不了的运行，不会卡在队头上谁都领不走（见 docs/release.md 第 3 节）。
fn known_sources() -> Vec<&'static str> {
    RunSource::ALL.iter().map(|s| s.as_str()).collect()
}

fn small(v: i32, what: &str) -> Result<u32> {
    u32::try_from(v).map_err(|_| Error::Corrupt(format!("negative {what}: {v}")))
}

impl Row {
    fn into_record(self) -> Result<RunRecord> {
        let state: RunState = parse(&self.state)?;
        // 只有等 key、等电脑、等子任务（只等回答，8.11）时有：上一版的副本既不写也不清，别处忘了清也看不到旧值。
        let wait_code = self.wait_code.filter(|_| {
            matches!(
                state,
                RunState::WaitingQuota | RunState::WaitingDevice | RunState::WaitingChildren
            )
        });
        let run = Run {
            id: self.id.into(),
            kind: parse(&self.kind)?,
            instance_id: self.instance_id.into(),
            plan_id: self.plan_id.map(Into::into),
            parent_run_id: self.parent_run_id.map(Into::into),
            root_run_id: self.root_run_id.into(),
            step_key: self.step_key,
            source: parse(&self.source)?,
            prompt: self.prompt,
            state,
            state_reason: self.state_reason,
            attempt: small(self.attempt, "attempt")?,
            tokens_used: unsigned(self.tokens_used, "tokens_used")?,
            summary: self.summary,
            error: self.error,
            created_at: self.created_at,
            started_at: self.started_at,
            finished_at: self.finished_at,
            wait_code,
        };
        Ok(RunRecord {
            run,
            user_id: self.user_id.into(),
            trigger_id: self.trigger_id.map(Into::into),
            fire_time: self.fire_time,
            agent_version: self.agent_version,
            run_grant_id: self.run_grant_id.map(Into::into),
            budget: from_json(self.budget, "run budget")?,
            max_attempts: small(self.max_attempts, "max_attempts")?,
            steps: small(self.steps, "steps")?,
            not_before: self.not_before,
            lease_owner: self.lease_owner,
            lease_expires_at: self.lease_expires_at,
            interrupts_run_id: self.interrupts_run_id.map(Into::into),
            announced_at: self.announced_at,
        })
    }

    fn into_run(self) -> Result<Run> {
        Ok(self.into_record()?.run)
    }
}

impl<R> Tx<R> {
    /// 插入运行。计划运行的 (plan_id, fire_time) 已存在时返回 None（多副本重复扫描到同一次触发）。
    async fn insert_run(&mut self, user: UserId, new: &NewRun) -> Result<Option<Run>> {
        let id = RunId::new();
        let root = match new.parent_run_id {
            None => id,
            Some(parent) => {
                let root: Option<Uuid> =
                    sqlx::query_scalar("SELECT root_run_id FROM runs WHERE id = $1")
                        .bind(parent.0)
                        .fetch_optional(self.conn())
                        .await?;
                root.ok_or_else(|| Error::Invalid(format!("parent run {parent} not found")))?
                    .into()
            }
        };
        let row: Option<Row> = sqlx::query_as(concat!(
            "INSERT INTO runs (id, user_id, instance_id, plan_id, trigger_id, fire_time, parent_run_id, root_run_id, \
               source, prompt, agent_version, run_grant_id, budget, not_before, max_attempts, kind, step_key, \
               answer_deadline, interrupts_run_id, urgent, hook_id) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, coalesce($14, now()), $15, $16, $17, $18, \
               $19, $20, $21) \
             ON CONFLICT (plan_id, fire_time) WHERE plan_id IS NOT NULL AND fire_time IS NOT NULL DO NOTHING \
             RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(user.0)
        .bind(new.instance_id.0)
        .bind(new.plan_id.map(|p| p.0))
        .bind(new.trigger_id.map(|t| t.0))
        .bind(new.fire_time)
        .bind(new.parent_run_id.map(|p| p.0))
        .bind(root.0)
        .bind(new.source.as_str())
        .bind(&new.prompt)
        .bind(&new.agent_version)
        .bind(new.run_grant_id.map(|g| g.0))
        .bind(to_json(&new.budget)?)
        .bind(new.not_before)
        .bind(i32::try_from(new.max_attempts.max(1)).unwrap_or(i32::MAX))
        .bind(new.kind.as_str())
        .bind(&new.step_key)
        .bind(new.answer_deadline)
        .bind(new.interrupts_run_id.map(|r| r.0))
        .bind(new.urgent)
        .bind(new.hook_id.map(|h| h.0))
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_run).transpose()
    }

    pub async fn run(&mut self, id: RunId) -> Result<Run> {
        let row: Row = sqlx::query_as(concat!("SELECT ", columns!(), " FROM runs WHERE id = $1"))
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        row.into_run()
    }

    /// 一棵运行树（根和所有子孙），按创建时间排序。
    pub async fn run_tree(&mut self, root: RunId) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE root_run_id = $1 ORDER BY created_at, id"
        ))
        .bind(root.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }
}

/// 占着实例的 agent 运行（实例上同时只有一个）：取消它时实例的沙箱令牌代数加一，签给它的令牌作废，
/// agent 留在沙箱里的后台进程不能接着用模型网关。只有它一个，不会误伤别的运行的令牌。
macro_rules! bump_epochs_where {
    ($filter:literal) => {
        concat!(
            "UPDATE instances SET token_epoch = token_epoch + 1 WHERE id IN ( \
               SELECT instance_id FROM runs WHERE ",
            $filter,
            " AND kind = 'agent' AND state IN ('starting', 'running', 'waiting_approval', \
               'waiting_device', 'waiting_quota', 'waiting_children', 'backoff'))"
        )
    };
}

impl<R> Tx<R> {
    /// 按 id 顺序锁住这些运行和它们所有的子孙（到事务结束）：取消一整棵树之前先锁运行、再改实例（令牌代数），
    /// 和执行器（先锁自己的运行、再改实例）同一个顺序，不会互相等死。
    async fn lock_run_tree(&mut self, root: RunId) -> Result<()> {
        self.lock_run_trees(&[root.0]).await
    }

    async fn lock_run_trees(&mut self, roots: &[Uuid]) -> Result<()> {
        sqlx::query(
            "WITH RECURSIVE tree AS ( \
               SELECT unnest($1::uuid[]) AS id \
               UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) \
             SELECT id FROM runs WHERE id IN (SELECT id FROM tree) ORDER BY id FOR NO KEY UPDATE",
        )
        .bind(roots)
        .fetch_all(self.conn())
        .await?;
        Ok(())
    }

    /// 取消这些提问（8.11，调用方已经锁住了它们），连同回答方为回答它们开的子孙；`reasons` 和 `ids`
    /// 一一对应，是每个提问的状态说明。令牌代数加一，执行中的回答方续租时停下。返回取消的提问。
    async fn cancel_asks(&mut self, ids: &[Uuid], reasons: &[&str]) -> Result<Vec<Run>> {
        self.lock_run_trees(ids).await?;
        sqlx::query(concat!(
            "WITH RECURSIVE tree AS ( \
               SELECT unnest($1::uuid[]) AS id \
               UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) ",
            bump_epochs_where!("id IN (SELECT id FROM tree)")
        ))
        .bind(ids)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "WITH RECURSIVE tree AS ( \
               SELECT id FROM runs WHERE parent_run_id = ANY($1) \
               UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) \
             UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() \
             WHERE id IN (SELECT id FROM tree) AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(ids)
        .bind("the question it was answering was withdrawn")
        .execute(self.conn())
        .await?;
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "UPDATE runs SET state = 'cancelled', state_reason = v.ask_reason, wait_code = NULL, \
               lease_owner = NULL, lease_expires_at = NULL, finished_at = now(), updated_at = now() \
             FROM unnest($1::uuid[], $2::text[]) AS v(ask_id, ask_reason) \
             WHERE runs.id = v.ask_id AND runs.state NOT IN ('succeeded', 'failed', 'cancelled') RETURNING ",
            columns!()
        ))
        .bind(ids)
        .bind(reasons)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }
}

impl<R> Tx<R> {
    /// 按用户串行化“谁在等谁”的检查和新建子运行（委派、提问，8.8、8.11）：两个 agent 同时互相问，
    /// 检查时都还看不到对方的子运行，不加锁会都通过。关掉实例的交流开关时也拿这把锁（见
    /// [`Tx::accepts_questions`]）。锁到事务结束。
    pub async fn lock_run_waits(&mut self, user: UserId) -> Result<()> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("run_waits/{user}"))
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 实例还在、开着“允许其他 agent 查我、问我”（8.11）：建提问之前在 [`Tx::lock_run_waits`] 里再查一次，
    /// 关开关的请求拿着同一把锁，两边不会错过。
    pub async fn accepts_questions(&mut self, instance: InstanceId) -> Result<bool> {
        let open: Option<bool> = sqlx::query_scalar(
            "SELECT peer_access FROM instances WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        Ok(open.unwrap_or(false))
    }
}

impl Tx<Tenant> {
    /// 用户发起的运行（或用户手动触发计划）。
    pub async fn create_run(&mut self, new: &NewRun) -> Result<Run> {
        self.instance(new.instance_id).await?;
        let user = self.user();
        self.insert_run(user, new)
            .await?
            .ok_or_else(|| Error::Conflict("run for this plan fire time already exists".into()))
    }

    /// 实例的运行，新的在前；`before` 用于翻页。
    pub async fn runs(
        &mut self,
        instance: InstanceId,
        before: Option<RunId>,
        limit: i64,
    ) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE instance_id = $1 AND ($2::uuid IS NULL OR id < $2) \
             ORDER BY id DESC LIMIT $3"
        ))
        .bind(instance.0)
        .bind(before.map(|r| r.0))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }

    /// 这个用户的运行（跨实例），新的在前，`before` 往下翻。四种组合各是一条固定的语句，分别用得上
    /// runs_plan、runs_user_active、runs_user_recent 这几个索引；“没结束”的写法要和索引的条件一模一样。
    pub async fn list_runs(
        &mut self,
        f: RunFilter,
        before: Option<RunId>,
        limit: i64,
    ) -> Result<Vec<Run>> {
        macro_rules! list {
            ($where:literal) => {
                concat!(
                    "SELECT ",
                    columns!(),
                    " FROM runs WHERE user_id = app_user_id() AND ",
                    $where,
                    " AND ($2::bool OR parent_run_id IS NULL) \
                     AND id < coalesce($3::uuid, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) \
                     ORDER BY id DESC LIMIT $4"
                )
            };
        }
        let sql = match (f.plan.is_some(), f.active) {
            (true, true) => {
                list!("plan_id = $1 AND state NOT IN ('succeeded', 'failed', 'cancelled')")
            }
            (true, false) => list!("plan_id = $1"),
            (false, true) => {
                list!("$1::uuid IS NULL AND state NOT IN ('succeeded', 'failed', 'cancelled')")
            }
            (false, false) => list!("$1::uuid IS NULL"),
        };
        let rows: Vec<Row> = sqlx::query_as(sql)
            .bind(f.plan.map(|p| p.0))
            .bind(!f.roots)
            .bind(before.map(|r| r.0))
            .bind(limit)
            .fetch_all(self.conn())
            .await?;
        rows.into_iter().map(Row::into_run).collect()
    }

    /// 用户取消。执行中的副本续租失败后停下 agent 这一轮。
    pub async fn cancel_run(&mut self, id: RunId, reason: Option<&str>) -> Result<Run> {
        // FOR NO KEY UPDATE 而不是 FOR UPDATE：执行器写运行日志时先更新实例行（事件序号），再插入引用这个运行的
        // 事件，外键检查要在运行行上拿 KEY SHARE 锁。FOR UPDATE 和它冲突，而这里接着要更新同一个实例行（作废令牌），
        // 两边互相等成死锁；NO KEY UPDATE 不挡外键检查。
        let state: String =
            sqlx::query_scalar("SELECT state FROM runs WHERE id = $1 FOR NO KEY UPDATE")
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        let from: RunState = parse(&state)?;
        if !from.can_transition(RunState::Cancelled) {
            return Err(Error::InvalidTransition {
                from,
                to: RunState::Cancelled,
            });
        }
        sqlx::query(bump_epochs_where!("id = $1"))
            .bind(id.0)
            .execute(self.conn())
            .await?;
        let row: Row = sqlx::query_as(concat!(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() WHERE id = $1 RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(reason.unwrap_or("cancelled by user"))
        .fetch_one(self.conn())
        .await?;
        row.into_run()
    }
}

impl Tx<Tenant> {
    /// 停掉整棵运行树（8.2）：根和所有没结束的子孙一起取消。返回取消的个数。
    pub async fn cancel_run_tree(&mut self, root: RunId, reason: &str) -> Result<u64> {
        sqlx::query(bump_epochs_where!("root_run_id = $1"))
            .bind(root.0)
            .execute(self.conn())
            .await?;
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() \
             WHERE root_run_id = $1 AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(root.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            // 区分“树不存在”和“都已经结束”。
            self.run(root).await?;
        }
        Ok(done.rows_affected())
    }

    /// 实例关了“允许其他 agent 查我、问我”（8.11）：别人问它、还没答完的问题都取消（连同它为回答开的子孙），
    /// 提问方拿到“没问成”。返回取消的提问。
    pub async fn cancel_asks_to(&mut self, instance: InstanceId, reason: &str) -> Result<Vec<Run>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT id FROM runs WHERE instance_id = $1 AND source = 'ask' \
               AND state NOT IN ('succeeded', 'failed', 'cancelled') ORDER BY id FOR NO KEY UPDATE",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let reasons = vec![reason; ids.len()];
        self.cancel_asks(&ids, &reasons).await
    }

    /// 用户的紧急消息（8.12，打断重来）：建运行，按实例上现在的情况处理占着实例的那个运行（见 [`Urgent`]）。
    /// 紧急消息之间先来后到；没有在等的紧急消息时，新的排在这个实例别的排队运行前面，去打断占着实例的那个。
    /// 按实例加锁，同时来的两条不会都去打断。停在等待里的运行被取消时，返回值里有它，调用方给它记运行日志。
    pub async fn queue_urgent_run(&mut self, new: &NewRun) -> Result<(Run, Urgent)> {
        let instance = new.instance_id;
        self.instance(instance).await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("interrupts/{instance}"))
            .execute(self.conn())
            .await?;
        let mut new = new.clone();
        new.urgent = true;
        // 实例上没结束的 agent 运行都锁上，排队的也锁：正被领取（排队 → 启动中、还没提交）的那个要等领取的
        // 事务提交，这里才看得到它已经占着实例了。
        #[derive(sqlx::FromRow)]
        struct Active {
            id: Uuid,
            state: String,
            live: bool,
            urgent: bool,
            not_before: DateTime<Utc>,
            interrupts_run_id: Option<Uuid>,
        }
        let active: Vec<Active> = sqlx::query_as(
            "SELECT id, state, lease_owner IS NOT NULL AND lease_expires_at > now() AS live, urgent, not_before, \
               interrupts_run_id \
             FROM runs WHERE instance_id = $1 AND kind = 'agent' \
               AND state NOT IN ('succeeded', 'failed', 'cancelled') \
             ORDER BY id FOR NO KEY UPDATE",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        let holder = active
            .iter()
            .find(|r| r.state != "queued")
            .map(|r| (r.id, r.live));
        let queued_urgent = || active.iter().filter(|r| r.urgent && r.state == "queued");
        let waiting = queued_urgent()
            .max_by_key(|r| (r.not_before, r.id))
            .map(|r| (r.id, r.not_before));
        // 已经有紧急消息在等着打断占着实例的那个了：新的排在紧急消息后面就行。没有的话（比如占着实例的是
        // 在紧急消息之后才领走的），新的去打断它。
        let targeted =
            holder.is_some_and(|(h, _)| queued_urgent().any(|r| r.interrupts_run_id == Some(h)));
        if let Some((_, at)) = waiting {
            new.not_before = Some(at + chrono::Duration::microseconds(1));
        } else {
            let front: DateTime<Utc> = sqlx::query_scalar(
                "SELECT least(now(), min(not_before) - interval '1 millisecond') FROM runs \
                 WHERE instance_id = $1 AND state = 'queued'",
            )
            .bind(instance.0)
            .fetch_one(self.conn())
            .await?;
            new.not_before = Some(front);
        }
        let urgent = match (holder, waiting) {
            (Some(_), Some((first, _))) if targeted => Urgent::Behind(first.into()),
            (None, Some((first, _))) => Urgent::Behind(first.into()),
            (None, None) => Urgent::Free,
            (Some((id, true)), _) => {
                new.interrupts_run_id = Some(id.into());
                Urgent::Interrupting(id.into())
            }
            (Some((id, false)), _) => {
                // 没人在执行它（租约放掉了或者过期了）：没有 agent 要停，直接取消，新消息马上能跑。
                self.lock_run_tree(id.into()).await?;
                sqlx::query(concat!(
                    "WITH RECURSIVE tree AS ( \
                       SELECT $1::uuid AS id \
                       UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) ",
                    bump_epochs_where!("id IN (SELECT id FROM tree)")
                ))
                .bind(id)
                .execute(self.conn())
                .await?;
                sqlx::query(
                    "WITH RECURSIVE tree AS ( \
                       SELECT $1::uuid AS id \
                       UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) \
                     UPDATE runs SET state = 'cancelled', \
                       state_reason = CASE WHEN id = $1 THEN $2 ELSE $3 END, \
                       wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
                       finished_at = now(), updated_at = now() \
                     WHERE id IN (SELECT id FROM tree) AND state NOT IN ('succeeded', 'failed', 'cancelled')",
                )
                .bind(id)
                .bind(INTERRUPTED_REASON)
                .bind("the parent run was interrupted")
                .execute(self.conn())
                .await?;
                new.interrupts_run_id = Some(id.into());
                Urgent::Stopped(id.into())
            }
        };
        let user = self.user();
        let run = self
            .insert_run(user, &new)
            .await?
            .ok_or_else(|| Error::Conflict("run already exists".into()))?;
        Ok((run, urgent))
    }

    /// 占着实例的运行（8.9 查进度用）。
    pub async fn instance_holder(&mut self, instance: InstanceId) -> Result<Option<Run>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE instance_id = $1 AND kind = 'agent' AND state IN ('starting', 'running', \
               'waiting_approval', 'waiting_device', 'waiting_quota', 'waiting_children', 'backoff')"
        ))
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_run).transpose()
    }

    /// 实例上最近一个跑过、已经结束的 agent 运行（8.9 查进度用；排队时就被取消的不算）。
    pub async fn last_finished_run(&mut self, instance: InstanceId) -> Result<Option<Run>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE instance_id = $1 AND kind = 'agent' AND started_at IS NOT NULL \
               AND state IN ('succeeded', 'failed', 'cancelled') ORDER BY finished_at DESC NULLS LAST, id DESC LIMIT 1"
        ))
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_run).transpose()
    }

    /// 运行的预算（agent 在运行里新建计划时，计划沿用这个预算）。
    pub async fn run_budget(&mut self, id: RunId) -> Result<RunBudget> {
        let budget: serde_json::Value = sqlx::query_scalar("SELECT budget FROM runs WHERE id = $1")
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        from_json(budget, "run budget")
    }

    /// 一次运行里某种事件的条数（限制 agent 在一次运行里反复改计划、发提醒）。
    pub async fn run_event_count(&mut self, id: RunId, kind: &str) -> Result<u64> {
        let n: i64 =
            sqlx::query_scalar("SELECT count(*) FROM events WHERE run_id = $1 AND kind = $2")
                .bind(id.0)
                .bind(kind)
                .fetch_one(self.conn())
                .await?;
        Ok(u64::try_from(n).unwrap_or_default())
    }

    /// 取消实例上所有没结束的运行（删除实例时），连同根在这个实例上的运行树里、在别的实例上跑的步骤。
    /// 返回取消的个数。
    pub async fn cancel_instance_runs(
        &mut self,
        instance: InstanceId,
        reason: &str,
    ) -> Result<u64> {
        sqlx::query(bump_epochs_where!(
            "(instance_id = $1 \
              OR root_run_id IN (SELECT id FROM runs WHERE instance_id = $1 AND parent_run_id IS NULL))"
        ))
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() \
             WHERE (instance_id = $1 \
                    OR root_run_id IN (SELECT id FROM runs WHERE instance_id = $1 AND parent_run_id IS NULL)) \
               AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(instance.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 等的事情可能发生了（7.11：补上或换了 key、改了模型路由，电脑上线）：在 `state` 里等着的运行
    /// 马上可以重新领起来接着跑。还是不行的话执行器会让它接着等。返回唤醒的个数。
    pub async fn wake_waiting_runs(&mut self, state: RunState) -> Result<u64> {
        let user = self.user();
        let done = sqlx::query(
            "UPDATE runs SET not_before = now(), updated_at = now() \
             WHERE user_id = $1 AND state = $2 AND lease_owner IS NULL AND not_before > now()",
        )
        .bind(user.0)
        .bind(state.as_str())
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Worker> {
    /// 取消用户所有没结束的运行（冻结、“全部停止”，4.6）：执行中的副本续租失败后停下 agent，
    /// 这些实例的令牌代数加一，已经发出的沙箱令牌马上作废（模型网关不再放行）。返回取消的个数。
    pub async fn cancel_user_runs(&mut self, user: UserId, reason: &str) -> Result<u64> {
        sqlx::query(bump_epochs_where!("user_id = $1"))
            .bind(user.0)
            .execute(self.conn())
            .await?;
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() \
             WHERE user_id = $1 AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(user.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 后台建运行（计划到点、流水线、委派）。同一计划同一触发时间已有运行时返回 None。
    pub async fn create_run(&mut self, user: UserId, new: &NewRun) -> Result<Option<Run>> {
        self.insert_run(user, new).await
    }

    pub async fn run_record(&mut self, id: RunId) -> Result<RunRecord> {
        let row: Row = sqlx::query_as(concat!("SELECT ", columns!(), " FROM runs WHERE id = $1"))
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        row.into_record()
    }

    /// 领取下一个可以开始的运行，进入“启动中”并拿到租约：
    /// 排队中且实例空闲的（实例上排着用户的紧急消息时先领紧急的，8.12），退避到期且没人持有租约的，等电脑、等 key 到了该接着跑的时候
    /// （等的事情发生了、到了下次试探的时间，还没超时），或者委派的子运行都结束了的父运行（8.7）。
    /// 账号冻结的不领。
    /// 从等待里接着跑不占重试次数：尝试次数和上限一起加一。
    /// 两个副本同时领到同一实例的两个运行时，后提交的一方撞上“一个实例一个运行”的唯一索引，
    /// 这里退回保存点换下一个。
    pub async fn claim_next_run(
        &mut self,
        owner: &str,
        lease: Duration,
    ) -> Result<Option<RunRecord>> {
        for _ in 0..8 {
            let id: Option<Uuid> = sqlx::query_scalar(
                "SELECT r.id FROM runs r JOIN users u ON u.id = r.user_id AND u.status = 'active' \
                 WHERE r.kind = 'agent' AND r.source = ANY($1) AND r.not_before <= now() AND ( \
                   (r.state = 'queued' AND NOT EXISTS ( \
                      SELECT 1 FROM runs a WHERE a.instance_id = r.instance_id AND a.kind = 'agent' AND a.state IN \
                        ('starting', 'running', 'waiting_approval', 'waiting_device', 'waiting_quota', \
                         'waiting_children', 'backoff')) \
                    AND (r.urgent OR NOT EXISTS ( \
                      SELECT 1 FROM runs u WHERE u.instance_id = r.instance_id AND u.urgent AND u.state = 'queued'))) \
                   OR (r.state = 'backoff' AND (r.lease_owner IS NULL OR r.lease_expires_at < now())) \
                   OR (r.state IN ('waiting_quota', 'waiting_device') AND r.lease_owner IS NULL \
                       AND (r.wait_deadline IS NULL OR r.wait_deadline > now())) \
                   OR (r.state = 'waiting_children' AND r.lease_owner IS NULL AND NOT EXISTS ( \
                       SELECT 1 FROM runs c WHERE c.parent_run_id = r.id \
                         AND c.state NOT IN ('succeeded', 'failed', 'cancelled')))) \
                 ORDER BY r.not_before, r.id LIMIT 1 \
                 FOR UPDATE OF r SKIP LOCKED",
            )
            .bind(known_sources())
            .fetch_optional(self.conn())
            .await?;
            let Some(id) = id else {
                return Ok(None);
            };
            sqlx::query("SAVEPOINT claim").execute(self.conn()).await?;
            let claimed: Result<Row> = sqlx::query_as(concat!(
                "UPDATE runs SET state = 'starting', attempt = attempt + 1, \
                   max_attempts = max_attempts + CASE WHEN state IN ('waiting_quota', 'waiting_device', \
                     'waiting_children') THEN 1 ELSE 0 END, \
                   lease_owner = $2, lease_expires_at = now() + make_interval(secs => $3), \
                   wait_code = NULL, updated_at = now() \
                 WHERE id = $1 RETURNING ",
                columns!()
            ))
            .bind(id)
            .bind(owner)
            .bind(secs(lease))
            .fetch_one(self.conn())
            .await
            .map_err(Into::into);
            match claimed {
                Ok(row) => {
                    sqlx::query("RELEASE SAVEPOINT claim")
                        .execute(self.conn())
                        .await?;
                    return row.into_record().map(Some);
                }
                Err(Error::Conflict(_)) => {
                    sqlx::query("ROLLBACK TO SAVEPOINT claim")
                        .execute(self.conn())
                        .await?;
                }
                Err(e) => return Err(e),
            }
        }
        Ok(None)
    }

    /// 续租。返回 false 表示租约已经不在手里（被接管、运行已结束或被取消），应停止执行。
    pub async fn renew_lease(&mut self, id: RunId, owner: &str, lease: Duration) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE runs SET lease_expires_at = now() + make_interval(secs => $3) \
             WHERE id = $1 AND lease_owner = $2 AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(id.0)
        .bind(owner)
        .bind(secs(lease))
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 拿某个运行的租约（等待结束后唤醒它）：没人持有、已过期或本来就是自己的才拿得到。
    pub async fn acquire_lease(
        &mut self,
        id: RunId,
        owner: &str,
        lease: Duration,
    ) -> Result<Option<RunRecord>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE runs SET lease_owner = $2, lease_expires_at = now() + make_interval(secs => $3), \
               updated_at = now() \
             WHERE id = $1 AND state NOT IN ('succeeded', 'failed', 'cancelled') \
               AND (lease_owner IS NULL OR lease_owner = $2 OR lease_expires_at < now()) \
             RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(owner)
        .bind(secs(lease))
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_record).transpose()
    }

    /// 接管租约过期的运行（持有它的副本崩溃或卡住）。返回的运行由调用方决定恢复、退避还是失败。
    pub async fn take_over_expired(
        &mut self,
        owner: &str,
        lease: Duration,
        limit: i64,
    ) -> Result<Vec<RunRecord>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "UPDATE runs SET lease_owner = $1, lease_expires_at = now() + make_interval(secs => $2), \
               updated_at = now() \
             WHERE id IN (SELECT id FROM runs WHERE lease_owner IS NOT NULL AND lease_expires_at < now() \
                            AND state NOT IN ('succeeded', 'failed', 'cancelled') AND source = ANY($4) \
                          ORDER BY lease_expires_at LIMIT $3 FOR UPDATE SKIP LOCKED) \
             RETURNING ",
            columns!()
        ))
        .bind(owner)
        .bind(secs(lease))
        .bind(limit)
        .bind(known_sources())
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_record).collect()
    }

    /// 停掉 `run` 下面所有没结束的子孙运行（父运行失败了，委派出去的子任务没人要了，8.7）。
    /// 执行中的子孙续租时发现被取消，停下 agent；令牌代数加一，沙箱令牌马上作废。返回取消的个数。
    pub async fn cancel_descendants(&mut self, run: RunId, reason: &str) -> Result<u64> {
        sqlx::query(concat!(
            "WITH RECURSIVE tree AS ( \
               SELECT id FROM runs WHERE parent_run_id = $1 \
               UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) ",
            bump_epochs_where!("id IN (SELECT id FROM tree)")
        ))
        .bind(run.0)
        .execute(self.conn())
        .await?;
        let done = sqlx::query(
            "WITH RECURSIVE tree AS ( \
               SELECT id FROM runs WHERE parent_run_id = $1 \
               UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id) \
             UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() \
             WHERE id IN (SELECT id FROM tree) AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(run.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 运行树里除了 `except` 以外的运行已经用掉的 token（8.6：整棵树共用根运行的预算）。
    pub async fn tree_tokens_except(&mut self, root: RunId, except: RunId) -> Result<u64> {
        let n: i64 = sqlx::query_scalar(
            "SELECT coalesce(sum(tokens_used), 0)::bigint FROM runs WHERE root_run_id = $1 AND id <> $2",
        )
        .bind(root.0)
        .bind(except.0)
        .fetch_one(self.conn())
        .await?;
        unsigned(n, "tree tokens")
    }

    /// 委派出去的子运行（8.7），早的在前。
    pub async fn delegated_runs(&mut self, parent: RunId) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE parent_run_id = $1 AND source = 'delegate' ORDER BY created_at, id"
        ))
        .bind(parent.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }

    /// 还没交还的同一个问题（8.11）：同一次运行里问同一个队友一模一样的问题（agent 重试），它还没答完、或者
    /// 答了还没交给 agent 时就是它，不再问一遍；交给 agent 以后（哪怕这一轮还没处理完）再问就是真的再问一次。
    pub async fn open_ask(
        &mut self,
        parent: RunId,
        instance: InstanceId,
        prompt: &str,
    ) -> Result<Option<Run>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE parent_run_id = $1 AND source = 'ask' AND instance_id = $2 AND prompt = $3 \
               AND (state NOT IN ('succeeded', 'failed', 'cancelled') OR (handed_at IS NULL AND reported_at IS NULL)) \
             ORDER BY created_at, id LIMIT 1"
        ))
        .bind(parent.0)
        .bind(instance.0)
        .bind(prompt)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_run).transpose()
    }

    /// 问队友的子运行（8.11），早的在前。
    pub async fn ask_runs(&mut self, parent: RunId) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE parent_run_id = $1 AND source = 'ask' ORDER BY created_at, id"
        ))
        .bind(parent.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }

    /// 已经结束、结果还没交还给父运行的子运行：委派的子任务（8.7）和问队友的问题（8.11），早的在前。
    pub async fn unreported_children(&mut self, parent: RunId) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE parent_run_id = $1 AND source IN ('delegate', 'ask') AND reported_at IS NULL \
               AND state IN ('succeeded', 'failed', 'cancelled') ORDER BY created_at, id"
        ))
        .bind(parent.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }

    /// 带着这些子运行结果的消息已经发给了父运行的 agent（8.7、8.11）：之后再交就是续跑。
    pub async fn mark_handed(&mut self, ids: &[RunId]) -> Result<()> {
        let ids: Vec<Uuid> = ids.iter().map(|r| r.0).collect();
        sqlx::query("UPDATE runs SET handed_at = coalesce(handed_at, now()) WHERE id = ANY($1)")
            .bind(&ids)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 这些子运行的结果之前交出去过（那一轮中途断了，这次是重交）。
    pub async fn handed_before(&mut self, ids: &[RunId]) -> Result<bool> {
        let ids: Vec<Uuid> = ids.iter().map(|r| r.0).collect();
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM runs WHERE id = ANY($1) AND handed_at IS NOT NULL)",
        )
        .bind(&ids)
        .fetch_one(self.conn())
        .await?)
    }

    /// 子运行的结果已经交还给父运行的 agent（8.7）。
    pub async fn mark_reported(&mut self, ids: &[RunId]) -> Result<()> {
        let ids: Vec<Uuid> = ids.iter().map(|r| r.0).collect();
        sqlx::query(
            "UPDATE runs SET reported_at = now() WHERE id = ANY($1) AND reported_at IS NULL",
        )
        .bind(&ids)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 从 `run` 往上的父运行链（含自己）：运行 id、实例、来源。委派的深度和循环检测用（8.8）。
    pub async fn run_chain(&mut self, run: RunId) -> Result<Vec<(RunId, InstanceId, RunSource)>> {
        let rows: Vec<(Uuid, Uuid, String)> = sqlx::query_as(
            "WITH RECURSIVE chain AS ( \
               SELECT id, instance_id, source, parent_run_id, 0 AS depth FROM runs WHERE id = $1 \
               UNION ALL \
               SELECT r.id, r.instance_id, r.source, r.parent_run_id, c.depth + 1 \
               FROM runs r JOIN chain c ON r.id = c.parent_run_id WHERE c.depth < 64) \
             SELECT id, instance_id, source FROM chain ORDER BY depth",
        )
        .bind(run.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|(id, instance, source)| Ok((id.into(), instance.into(), parse(&source)?)))
            .collect()
    }

    /// 锁住运行（到事务结束）：执行器结束一次尝试前，和建紧急消息互斥（8.12）。
    pub async fn lock_run(&mut self, run: RunId) -> Result<()> {
        sqlx::query("SELECT id FROM runs WHERE id = $1 FOR NO KEY UPDATE")
            .bind(run.0)
            .fetch_one(self.conn())
            .await?;
        Ok(())
    }

    /// 有用户的紧急消息在等着打断这个运行（8.12）：执行器续租时、结束一次尝试前查。
    pub async fn interrupt_pending(&mut self, run: RunId) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM runs WHERE interrupts_run_id = $1 \
               AND interrupts_run_id IS NOT NULL AND state = 'queued')",
        )
        .bind(run.0)
        .fetch_one(self.conn())
        .await?)
    }

    /// 实例上排队、还没捎带给 agent 看过的用户消息（8.12），早的在前。紧急消息不算（它们打断，不用捎带）。
    pub async fn unannounced_messages(
        &mut self,
        instance: InstanceId,
        limit: i64,
    ) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE instance_id = $1 AND state = 'queued' AND source = 'user' \
               AND announced_at IS NULL AND NOT urgent ORDER BY not_before, id LIMIT $2"
        ))
        .bind(instance.0)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
    }

    /// 这些排队的消息已经捎带给 agent 看过了（8.12）。
    pub async fn mark_announced(&mut self, ids: &[RunId]) -> Result<()> {
        let ids: Vec<Uuid> = ids.iter().map(|r| r.0).collect();
        sqlx::query(
            "UPDATE runs SET announced_at = now() WHERE id = ANY($1) AND announced_at IS NULL",
        )
        .bind(&ids)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// `run` 是不是在（直接或间接地）等 `instance`（8.8、8.11）：从 `instance` 上占着实例的运行出发，
    /// 顺着“等子运行”（没结束的子运行）和“排队等实例”（排队的运行等它实例上占着的那个）走，走得到 `run`
    /// 就是。这时 `run` 再委派给、问 `instance` 会互相等死。
    pub async fn instance_waits_for(&mut self, instance: InstanceId, run: RunId) -> Result<bool> {
        let found: bool = sqlx::query_scalar(
            "WITH RECURSIVE w(id) AS ( \
               SELECT h.id FROM runs h WHERE h.instance_id = $1 AND h.kind = 'agent' AND h.state IN \
                 ('starting', 'running', 'waiting_approval', 'waiting_device', 'waiting_quota', \
                  'waiting_children', 'backoff') \
               UNION \
               SELECT n.id FROM w JOIN runs r ON r.id = w.id \
               CROSS JOIN LATERAL ( \
                 SELECT c.id FROM runs c WHERE c.parent_run_id = r.id \
                   AND c.state NOT IN ('succeeded', 'failed', 'cancelled') \
                 UNION ALL \
                 SELECT h.id FROM runs h WHERE r.state = 'queued' AND h.instance_id = r.instance_id \
                   AND h.kind = 'agent' AND h.state IN ('starting', 'running', 'waiting_approval', \
                     'waiting_device', 'waiting_quota', 'waiting_children', 'backoff')) n) \
             SELECT EXISTS (SELECT 1 FROM w WHERE id = $2)",
        )
        .bind(instance.0)
        .bind(run.0)
        .fetch_one(self.conn())
        .await?;
        Ok(found)
    }

    /// 取消没人等了的提问（8.11），连同回答方在回答时委派、提问出去的子孙：过了回答期限的（状态说明
    /// [`ANSWER_TIMEOUT_REASON`]），提问方已经结束了的（[`ASKER_GONE_REASON`]）。令牌代数加一，执行中的
    /// 回答方续租时停下。返回取消的提问（不含子孙），调用方给它们记运行日志。
    pub async fn cancel_stale_asks(&mut self, limit: i64) -> Result<Vec<Run>> {
        let picked: Vec<(Uuid, bool)> = sqlx::query_as(
            "SELECT r.id, r.answer_deadline <= now() FROM runs r \
             WHERE r.answer_deadline IS NOT NULL AND r.state NOT IN ('succeeded', 'failed', 'cancelled') \
               AND (r.answer_deadline <= now() OR EXISTS ( \
                 SELECT 1 FROM runs p WHERE p.id = r.parent_run_id \
                   AND p.state IN ('succeeded', 'failed', 'cancelled'))) \
             ORDER BY r.answer_deadline LIMIT $1 FOR NO KEY UPDATE OF r SKIP LOCKED",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        if picked.is_empty() {
            return Ok(Vec::new());
        }
        let ids: Vec<Uuid> = picked.iter().map(|(id, _)| *id).collect();
        let reasons: Vec<&str> = picked
            .iter()
            .map(|(_, overdue)| {
                if *overdue {
                    ANSWER_TIMEOUT_REASON
                } else {
                    ASKER_GONE_REASON
                }
            })
            .collect();
        self.cancel_asks(&ids, &reasons).await
    }

    /// 等电脑、等 key 超时的运行（7.11）：拿到租约交给执行器按策略结束。没人持有租约的才拿。
    pub async fn claim_expired_waits(
        &mut self,
        owner: &str,
        lease: Duration,
        limit: i64,
    ) -> Result<Vec<RunRecord>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "UPDATE runs SET lease_owner = $1, lease_expires_at = now() + make_interval(secs => $2), \
               updated_at = now() \
             WHERE id IN (SELECT id FROM runs WHERE state IN ('waiting_quota', 'waiting_device') \
                            AND wait_deadline <= now() \
                            AND (lease_owner IS NULL OR lease_expires_at < now()) AND source = ANY($4) \
                          ORDER BY wait_deadline LIMIT $3 FOR UPDATE SKIP LOCKED) \
             RETURNING ",
            columns!()
        ))
        .bind(owner)
        .bind(secs(lease))
        .bind(limit)
        .bind(known_sources())
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_record).collect()
    }

    /// 模型网关记下的这个实例从 `since` 起最近的 `limit` 次模型调用（新的在前）：状态码和结果。
    /// 执行器据此判断 agent 是不是卡在 key 失效、额度用完上（7.11）。
    pub async fn recent_model_calls(
        &mut self,
        instance: InstanceId,
        since: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<ModelCall>> {
        let rows: Vec<(i32, String, DateTime<Utc>)> = sqlx::query_as(
            "SELECT status, outcome, created_at FROM usage_records \
             WHERE instance_id = $1 AND created_at >= $2 ORDER BY created_at DESC LIMIT $3",
        )
        .bind(instance.0)
        .bind(since)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(status, outcome, at)| ModelCall {
                status: u16::try_from(status).unwrap_or_default(),
                outcome,
                at,
            })
            .collect())
    }

    /// 推进状态。要求租约在 `owner` 手里、迁移合法；从排队或退避进入启动中算一次新的尝试。
    pub async fn transition_run(
        &mut self,
        id: RunId,
        owner: &str,
        to: RunState,
        change: &RunChange,
    ) -> Result<RunRecord> {
        // NO KEY UPDATE：不挡别的事务插入引用这个运行的事件（外键检查），见 cancel_run。
        let (state, lease_owner): (String, Option<String>) =
            sqlx::query_as("SELECT state, lease_owner FROM runs WHERE id = $1 FOR NO KEY UPDATE")
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        let from: RunState = parse(&state)?;
        if !from.can_transition(to) {
            return Err(Error::InvalidTransition { from, to });
        }
        if lease_owner.as_deref() != Some(owner) {
            return Err(Error::LeaseLost {
                owner: owner.to_owned(),
            });
        }
        let new_attempt = to == RunState::Starting && matches!(from, RunState::Backoff);
        let release = change.release_lease || to.is_terminal();
        let row: Row = sqlx::query_as(concat!(
            "UPDATE runs SET state = $2, state_reason = $3, \
               summary = coalesce($4, summary), error = coalesce($5, error), \
               not_before = coalesce($6, not_before), \
               wait_deadline = coalesce($10, wait_deadline), \
               attempt = attempt + CASE WHEN $7 THEN 1 ELSE 0 END, \
               lease_owner = CASE WHEN $8 THEN NULL ELSE lease_owner END, \
               lease_expires_at = CASE WHEN $8 THEN NULL ELSE lease_expires_at END, \
               started_at = CASE WHEN $2 = 'running' THEN coalesce(started_at, now()) ELSE started_at END, \
               finished_at = CASE WHEN $9 THEN now() ELSE finished_at END, \
               wait_code = $11, updated_at = now() \
             WHERE id = $1 RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(to.as_str())
        .bind(&change.reason)
        .bind(&change.summary)
        .bind(&change.error)
        .bind(change.not_before)
        .bind(new_attempt)
        .bind(release)
        .bind(to.is_terminal())
        .bind(change.wait_deadline)
        .bind(change.wait_code)
        .fetch_one(self.conn())
        .await?;
        row.into_record()
    }

    /// 模型网关记下的这个实例从 `since` 起的计费 token 数。同一实例同时只执行一个运行，
    /// 所以运行开始以来的用量就是这个运行的用量（预算护栏用，不依赖各家 agent 的用量格式）。
    pub async fn instance_usage_since(
        &mut self,
        instance: InstanceId,
        since: DateTime<Utc>,
    ) -> Result<u64> {
        let n: i64 = sqlx::query_scalar(
            "SELECT coalesce(sum(charged_tokens), 0)::bigint FROM usage_records \
             WHERE instance_id = $1 AND created_at >= $2",
        )
        .bind(instance.0)
        .bind(since)
        .fetch_one(self.conn())
        .await?;
        unsigned(n, "usage")
    }

    /// 写入运行的累计用量（覆盖）。
    pub async fn set_run_usage(&mut self, id: RunId, tokens: u64, steps: u32) -> Result<()> {
        sqlx::query(
            "UPDATE runs SET tokens_used = $2, steps = $3, updated_at = now() WHERE id = $1",
        )
        .bind(id.0)
        .bind(crate::signed(tokens, "tokens")?)
        .bind(i32::try_from(steps).map_err(|_| Error::Invalid("steps too large".into()))?)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 待推进的流水线运行（排队中、等子运行中），锁住返回（SKIP LOCKED：多副本各拿各的）。
    pub async fn due_pipelines(&mut self, limit: i64) -> Result<Vec<RunRecord>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE kind = 'pipeline' AND state IN ('queued', 'waiting_children') \
               AND not_before <= now() \
               AND EXISTS (SELECT 1 FROM users u WHERE u.id = runs.user_id AND u.status = 'active') \
             ORDER BY not_before, id LIMIT $1 FOR UPDATE OF runs SKIP LOCKED"
        ))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_record).collect()
    }

    /// 把这一轮处理过、还没结束的流水线排到队尾（流水线的 `not_before` 只用来给驱动器排序，
    /// 设成现在就排在这一轮没轮到的后面）：等子运行的流水线多了，后面的也能轮到，不延后处理。
    pub async fn requeue_pipelines(&mut self, ids: &[RunId]) -> Result<()> {
        let ids: Vec<Uuid> = ids.iter().map(|r| r.0).collect();
        sqlx::query(
            "UPDATE runs SET not_before = now() \
             WHERE id = ANY($1) AND kind = 'pipeline' AND state IN ('queued', 'waiting_children')",
        )
        .bind(&ids)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 直接子运行。
    pub async fn child_runs(&mut self, parent: RunId) -> Result<Vec<RunRecord>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE parent_run_id = $1 ORDER BY created_at, id"
        ))
        .bind(parent.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_record).collect()
    }

    /// 推进不持有租约的运行（流水线运行）：按状态机校验，并比较当前状态（CAS）。
    pub async fn set_unleased_state(
        &mut self,
        id: RunId,
        from: RunState,
        to: RunState,
        change: &RunChange,
    ) -> Result<RunRecord> {
        if !from.can_transition(to) {
            return Err(Error::InvalidTransition { from, to });
        }
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE runs SET state = $3, state_reason = coalesce($4, state_reason), \
               summary = coalesce($5, summary), error = coalesce($6, error), \
               started_at = CASE WHEN $3 = 'waiting_children' THEN coalesce(started_at, now()) ELSE started_at END, \
               finished_at = CASE WHEN $3 IN ('succeeded', 'failed', 'cancelled') THEN now() ELSE finished_at END, \
               wait_code = NULL, updated_at = now() \
             WHERE id = $1 AND state = $2 AND lease_owner IS NULL RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(from.as_str())
        .bind(to.as_str())
        .bind(&change.reason)
        .bind(&change.summary)
        .bind(&change.error)
        .fetch_optional(self.conn())
        .await?;
        match row {
            Some(r) => r.into_record(),
            None => {
                let now = self.run_record(id).await?.run.state;
                Err(Error::InvalidTransition { from: now, to })
            }
        }
    }

    /// 取消一个运行的所有没结束的直接子运行（失败传播）。
    pub async fn cancel_children(&mut self, parent: RunId, reason: &str) -> Result<u64> {
        sqlx::query(bump_epochs_where!("parent_run_id = $1"))
            .bind(parent.0)
            .execute(self.conn())
            .await?;
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, wait_code = NULL, lease_owner = NULL, lease_expires_at = NULL, \
               finished_at = now(), updated_at = now() \
             WHERE parent_run_id = $1 AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(parent.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 累加用量（模型网关回报的 token、agent 的步数），供预算护栏判断。
    pub async fn add_run_usage(&mut self, id: RunId, tokens: u64, steps: u32) -> Result<RunRecord> {
        let row: Row = sqlx::query_as(concat!(
            "UPDATE runs SET tokens_used = tokens_used + $2, steps = steps + $3, updated_at = now() \
             WHERE id = $1 RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(crate::signed(tokens, "tokens")?)
        .bind(i32::try_from(steps).map_err(|_| Error::Invalid("steps too large".into()))?)
        .fetch_one(self.conn())
        .await?;
        row.into_record()
    }
}
