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
}

macro_rules! columns {
    () => {
        "id, kind, step_key, user_id, instance_id, plan_id, trigger_id, fire_time, parent_run_id, root_run_id, source, prompt, \
         state, state_reason, attempt, max_attempts, not_before, lease_owner, lease_expires_at, agent_version, \
         run_grant_id, budget, tokens_used, steps, summary, error, created_at, started_at, finished_at"
    };
}

fn small(v: i32, what: &str) -> Result<u32> {
    u32::try_from(v).map_err(|_| Error::Corrupt(format!("negative {what}: {v}")))
}

impl Row {
    fn into_record(self) -> Result<RunRecord> {
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
            state: parse(&self.state)?,
            state_reason: self.state_reason,
            attempt: small(self.attempt, "attempt")?,
            tokens_used: unsigned(self.tokens_used, "tokens_used")?,
            summary: self.summary,
            error: self.error,
            created_at: self.created_at,
            started_at: self.started_at,
            finished_at: self.finished_at,
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

    /// 用户取消。执行中的副本续租失败后停下 agent 这一轮。
    pub async fn cancel_run(&mut self, id: RunId, reason: Option<&str>) -> Result<Run> {
        let state: String = sqlx::query_scalar("SELECT state FROM runs WHERE id = $1 FOR UPDATE")
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
        let row: Row = sqlx::query_as(concat!(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, lease_owner = NULL, lease_expires_at = NULL, \
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
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, lease_owner = NULL, lease_expires_at = NULL, \
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

    /// 取消实例上所有没结束的运行（删除实例时），连同根在这个实例上的运行树里、在别的实例上跑的步骤。
    /// 返回取消的个数。
    pub async fn cancel_instance_runs(
        &mut self,
        instance: InstanceId,
        reason: &str,
    ) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, lease_owner = NULL, lease_expires_at = NULL, \
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
}

impl Tx<Worker> {
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
    /// 排队中且实例空闲的，或者退避到期且没人持有租约的。账号冻结的不领。
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
                   OR (r.state = 'backoff' AND (r.lease_owner IS NULL OR r.lease_expires_at < now()))) \
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
                "UPDATE runs SET state = 'starting', attempt = attempt + 1, lease_owner = $2, \
                   lease_expires_at = now() + make_interval(secs => $3), updated_at = now() \
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

    /// 推进状态。要求租约在 `owner` 手里、迁移合法；从排队或退避进入启动中算一次新的尝试。
    pub async fn transition_run(
        &mut self,
        id: RunId,
        owner: &str,
        to: RunState,
        change: &RunChange,
    ) -> Result<RunRecord> {
        let (state, lease_owner): (String, Option<String>) =
            sqlx::query_as("SELECT state, lease_owner FROM runs WHERE id = $1 FOR UPDATE")
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
               attempt = attempt + CASE WHEN $7 THEN 1 ELSE 0 END, \
               lease_owner = CASE WHEN $8 THEN NULL ELSE lease_owner END, \
               lease_expires_at = CASE WHEN $8 THEN NULL ELSE lease_expires_at END, \
               started_at = CASE WHEN $2 = 'running' THEN coalesce(started_at, now()) ELSE started_at END, \
               finished_at = CASE WHEN $9 THEN now() ELSE finished_at END, \
               updated_at = now() \
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
               AND not_before <= now() ORDER BY not_before LIMIT $1 FOR UPDATE SKIP LOCKED"
        ))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_record).collect()
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
               updated_at = now() \
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
        let done = sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = $2, lease_owner = NULL, lease_expires_at = NULL, \
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
