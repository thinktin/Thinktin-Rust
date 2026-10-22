//! 运行与执行租约（7.3、7.4）。
//!
//! 状态迁移一律按 [`RunState::can_transition`] 校验，并在锁住的行上比较当前状态，
//! 并发的取消、超时接管不会被覆盖。执行中的运行由持有租约的副本推进：
//! 租约过期（副本崩溃）后别的副本用 [`Tx::take_over_expired`] 接管。
//! SQL 里直接写了结束状态 `('succeeded', 'failed', 'cancelled')`，和 [`RunState::is_terminal`] 一致（有测试核对）。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    GrantId, InstanceId, PlanId, Run, RunBudget, RunId, RunKind, RunSource, RunState, TriggerId,
    UserId,
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
        }
    }
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
}

macro_rules! columns {
    () => {
        "id, kind, step_key, user_id, instance_id, plan_id, trigger_id, fire_time, parent_run_id, root_run_id, source, prompt, \
         state, state_reason, attempt, max_attempts, not_before, lease_owner, lease_expires_at, agent_version, \
         run_grant_id, budget, tokens_used, steps, summary, error, created_at, started_at, finished_at, wait_code"
    };
}

fn small(v: i32, what: &str) -> Result<u32> {
    u32::try_from(v).map_err(|_| Error::Corrupt(format!("negative {what}: {v}")))
}

impl Row {
    fn into_record(self) -> Result<RunRecord> {
        let state: RunState = parse(&self.state)?;
        // 只有等 key、等电脑时有：上一版的副本既不写也不清，别处忘了清也看不到旧值。
        let wait_code = self
            .wait_code
            .filter(|_| matches!(state, RunState::WaitingQuota | RunState::WaitingDevice));
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
               source, prompt, agent_version, run_grant_id, budget, not_before, max_attempts, kind, step_key) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, coalesce($14, now()), $15, $16, $17) \
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
    /// 排队中且实例空闲的，退避到期且没人持有租约的，等电脑、等 key 到了该接着跑的时候
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
                 WHERE r.kind = 'agent' AND r.not_before <= now() AND ( \
                   (r.state = 'queued' AND NOT EXISTS ( \
                      SELECT 1 FROM runs a WHERE a.instance_id = r.instance_id AND a.kind = 'agent' AND a.state IN \
                        ('starting', 'running', 'waiting_approval', 'waiting_device', 'waiting_quota', \
                         'waiting_children', 'backoff'))) \
                   OR (r.state = 'backoff' AND (r.lease_owner IS NULL OR r.lease_expires_at < now())) \
                   OR (r.state IN ('waiting_quota', 'waiting_device') AND r.lease_owner IS NULL \
                       AND (r.wait_deadline IS NULL OR r.wait_deadline > now())) \
                   OR (r.state = 'waiting_children' AND r.lease_owner IS NULL AND NOT EXISTS ( \
                       SELECT 1 FROM runs c WHERE c.parent_run_id = r.id \
                         AND c.state NOT IN ('succeeded', 'failed', 'cancelled')))) \
                 ORDER BY r.not_before, r.id LIMIT 1 \
                 FOR UPDATE OF r SKIP LOCKED",
            )
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
                            AND state NOT IN ('succeeded', 'failed', 'cancelled') \
                          ORDER BY lease_expires_at LIMIT $3 FOR UPDATE SKIP LOCKED) \
             RETURNING ",
            columns!()
        ))
        .bind(owner)
        .bind(secs(lease))
        .bind(limit)
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

    /// 已经结束、结果还没交还给父运行的委派子运行（8.7），早的在前。
    pub async fn unreported_children(&mut self, parent: RunId) -> Result<Vec<Run>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM runs WHERE parent_run_id = $1 AND source = 'delegate' AND reported_at IS NULL \
               AND state IN ('succeeded', 'failed', 'cancelled') ORDER BY created_at, id"
        ))
        .bind(parent.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_run).collect()
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
                            AND (lease_owner IS NULL OR lease_expires_at < now()) \
                          ORDER BY wait_deadline LIMIT $3 FOR UPDATE SKIP LOCKED) \
             RETURNING ",
            columns!()
        ))
        .bind(owner)
        .bind(secs(lease))
        .bind(limit)
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
