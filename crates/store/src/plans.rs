//! 计划与触发器（7.1）。触发时间由 orchestrator 的 schedule 模块算好再存进来。

use chrono::{DateTime, Utc};
use proto::domain::{
    CatchUp, GrantId, InstanceId, Plan, PlanAuthor, PlanId, PlanPolicy, PlanStep, ScheduleSpec,
    Trigger, TriggerId, UserId, order_steps,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, from_json, parse, to_json};

#[derive(Debug, Clone)]
pub struct NewPlan {
    pub instance_id: InstanceId,
    pub title: String,
    pub goal: String,
    pub policy: PlanPolicy,
    pub catch_up: CatchUp,
    pub created_by: PlanAuthor,
    pub run_grant_id: Option<GrantId>,
}

/// 到点的触发器，连同它的计划。
#[derive(Debug, Clone, PartialEq)]
pub struct DueTrigger {
    pub user_id: UserId,
    /// 实例当前锁定的模板版本（运行创建时记下）。
    pub agent_version: String,
    pub trigger: Trigger,
    pub plan: Plan,
    pub run_grant_id: Option<GrantId>,
}

#[derive(sqlx::FromRow)]
struct PlanRow {
    id: Uuid,
    instance_id: Uuid,
    title: String,
    goal: String,
    policy: serde_json::Value,
    catch_up: String,
    status: String,
    created_by: String,
    created_at: DateTime<Utc>,
}

impl PlanRow {
    fn into_plan(self) -> Result<Plan> {
        Ok(Plan {
            id: self.id.into(),
            instance_id: self.instance_id.into(),
            title: self.title,
            goal: self.goal,
            policy: from_json(self.policy, "plan policy")?,
            catch_up: parse(&self.catch_up)?,
            paused: self.status == "paused",
            created_by: parse(&self.created_by)?,
            created_at: self.created_at,
        })
    }
}

macro_rules! plan_columns {
    () => {
        "id, instance_id, title, goal, policy, catch_up, status, created_by, created_at"
    };
}

#[derive(sqlx::FromRow)]
struct TriggerRow {
    id: Uuid,
    plan_id: Uuid,
    spec: serde_json::Value,
    enabled: bool,
    next_fire_at: Option<DateTime<Utc>>,
    last_fire_at: Option<DateTime<Utc>>,
}

impl TriggerRow {
    fn into_trigger(self) -> Result<Trigger> {
        Ok(Trigger {
            id: self.id.into(),
            plan_id: self.plan_id.into(),
            spec: from_json(self.spec, "trigger spec")?,
            enabled: self.enabled,
            next_fire_at: self.next_fire_at,
            last_fire_at: self.last_fire_at,
        })
    }
}

macro_rules! trigger_columns {
    () => {
        "id, plan_id, spec, enabled, next_fire_at, last_fire_at"
    };
}

impl Tx<Tenant> {
    pub async fn create_plan(&mut self, new: &NewPlan) -> Result<Plan> {
        self.instance(new.instance_id).await?;
        let row: PlanRow = sqlx::query_as(concat!(
            "INSERT INTO plans (id, user_id, instance_id, title, goal, policy, catch_up, created_by, run_grant_id) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6, $7, $8) RETURNING ",
            plan_columns!()
        ))
        .bind(PlanId::new().0)
        .bind(new.instance_id.0)
        .bind(&new.title)
        .bind(&new.goal)
        .bind(to_json(&new.policy)?)
        .bind(new.catch_up.as_str())
        .bind(new.created_by.as_str())
        .bind(new.run_grant_id.map(|g| g.0))
        .fetch_one(self.conn())
        .await?;
        row.into_plan()
    }

    /// 某个实例的计划，或者全部。
    pub async fn plans(&mut self, instance: Option<InstanceId>) -> Result<Vec<Plan>> {
        let rows: Vec<PlanRow> = sqlx::query_as(concat!(
            "SELECT ",
            plan_columns!(),
            " FROM plans WHERE status <> 'deleted' AND ($1::uuid IS NULL OR instance_id = $1) \
             ORDER BY created_at"
        ))
        .bind(instance.map(|i| i.0))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(PlanRow::into_plan).collect()
    }

    pub async fn update_plan(
        &mut self,
        id: PlanId,
        title: &str,
        goal: &str,
        policy: &PlanPolicy,
        catch_up: CatchUp,
    ) -> Result<Plan> {
        let row: PlanRow = sqlx::query_as(concat!(
            "UPDATE plans SET title = $2, goal = $3, policy = $4, catch_up = $5, updated_at = now() \
             WHERE id = $1 AND status <> 'deleted' RETURNING ",
            plan_columns!()
        ))
        .bind(id.0)
        .bind(title)
        .bind(goal)
        .bind(to_json(policy)?)
        .bind(catch_up.as_str())
        .fetch_one(self.conn())
        .await?;
        row.into_plan()
    }

    /// 计划用的运行授权（建计划后签发，带着计划 id）。
    pub async fn set_plan_grant(&mut self, plan: PlanId, grant: GrantId) -> Result<()> {
        let done = sqlx::query(
            "UPDATE plans SET run_grant_id = $2, updated_at = now() WHERE id = $1 AND status <> 'deleted'",
        )
        .bind(plan.0)
        .bind(grant.0)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 整体替换计划的流水线步骤（空表示普通计划：到点直接在计划的实例上运行目标）。
    /// 步骤要能排成无环的依赖顺序，每一步的实例必须是自己的、没删除的。
    pub async fn set_plan_steps(&mut self, plan: PlanId, steps: &[PlanStep]) -> Result<()> {
        order_steps(steps).map_err(Error::Invalid)?;
        self.plan(plan).await?;
        for s in steps {
            self.instance(s.instance_id).await?;
        }
        sqlx::query("DELETE FROM plan_steps WHERE plan_id = $1")
            .bind(plan.0)
            .execute(self.conn())
            .await?;
        for (i, s) in steps.iter().enumerate() {
            sqlx::query(
                "INSERT INTO plan_steps (plan_id, key, user_id, instance_id, prompt, depends_on, position) \
                 VALUES ($1, $2, app_user_id(), $3, $4, $5, $6)",
            )
            .bind(plan.0)
            .bind(&s.key)
            .bind(s.instance_id.0)
            .bind(&s.prompt)
            .bind(&s.depends_on)
            .bind(i32::try_from(i).unwrap_or(i32::MAX))
            .execute(self.conn())
            .await?;
        }
        Ok(())
    }

    /// 删除计划：停掉它的触发器。已经生成的运行不受影响。
    pub async fn delete_plan(&mut self, id: PlanId) -> Result<()> {
        let done = sqlx::query(
            "UPDATE plans SET status = 'deleted', updated_at = now() WHERE id = $1 AND status <> 'deleted'",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        sqlx::query("UPDATE triggers SET enabled = false, updated_at = now() WHERE plan_id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 给计划加一个触发器。`next_fire_at` 由调用方按 spec 算好（没有下一次时为 None）。
    pub async fn add_trigger(
        &mut self,
        plan: PlanId,
        spec: &ScheduleSpec,
        next_fire_at: Option<DateTime<Utc>>,
    ) -> Result<Trigger> {
        self.plan(plan).await?;
        let row: TriggerRow = sqlx::query_as(concat!(
            "INSERT INTO triggers (id, user_id, plan_id, spec, next_fire_at) \
             VALUES ($1, app_user_id(), $2, $3, $4) RETURNING ",
            trigger_columns!()
        ))
        .bind(TriggerId::new().0)
        .bind(plan.0)
        .bind(to_json(spec)?)
        .bind(next_fire_at)
        .fetch_one(self.conn())
        .await?;
        row.into_trigger()
    }

    /// 停用或启用。启用时 `next_fire_at` 要从现在重新算，不补停用期间错过的触发。
    pub async fn set_trigger_enabled(
        &mut self,
        id: TriggerId,
        enabled: bool,
        next_fire_at: Option<DateTime<Utc>>,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE triggers SET enabled = $2, next_fire_at = $3, updated_at = now() WHERE id = $1",
        )
        .bind(id.0)
        .bind(enabled)
        .bind(next_fire_at)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    pub async fn delete_trigger(&mut self, id: TriggerId) -> Result<()> {
        let done = sqlx::query("DELETE FROM triggers WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}

/// 两种角色都能用；业务角色下 RLS 只放行当前用户的行。
impl<R> Tx<R> {
    /// 没删除的计划。
    pub async fn plan(&mut self, id: PlanId) -> Result<Plan> {
        let row: PlanRow = sqlx::query_as(concat!(
            "SELECT ",
            plan_columns!(),
            " FROM plans WHERE id = $1 AND status <> 'deleted'"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_plan()
    }

    /// 暂停或恢复计划。审批超时的 `pause_plan` 策略由后台调用。
    pub async fn set_plan_paused(&mut self, id: PlanId, paused: bool) -> Result<()> {
        let done = sqlx::query(
            "UPDATE plans SET status = CASE WHEN $2 THEN 'paused' ELSE 'active' END, updated_at = now() \
             WHERE id = $1 AND status <> 'deleted'",
        )
        .bind(id.0)
        .bind(paused)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 计划的流水线步骤，按声明顺序。
    pub async fn plan_steps(&mut self, plan: PlanId) -> Result<Vec<PlanStep>> {
        let rows: Vec<(String, Uuid, String, Vec<String>)> = sqlx::query_as(
            "SELECT key, instance_id, prompt, depends_on FROM plan_steps WHERE plan_id = $1 ORDER BY position",
        )
        .bind(plan.0)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(key, instance, prompt, depends_on)| PlanStep {
                key,
                instance_id: instance.into(),
                prompt,
                depends_on,
            })
            .collect())
    }

    pub async fn triggers(&mut self, plan: PlanId) -> Result<Vec<Trigger>> {
        let rows: Vec<TriggerRow> = sqlx::query_as(concat!(
            "SELECT ",
            trigger_columns!(),
            " FROM triggers WHERE plan_id = $1 ORDER BY created_at"
        ))
        .bind(plan.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(TriggerRow::into_trigger).collect()
    }
}

#[derive(sqlx::FromRow)]
struct DueRow {
    user_id: Uuid,
    agent_version: String,
    run_grant_id: Option<Uuid>,
    #[sqlx(flatten)]
    trigger: TriggerRow,
    p_id: Uuid,
    p_instance_id: Uuid,
    p_title: String,
    p_goal: String,
    p_policy: serde_json::Value,
    p_catch_up: String,
    p_status: String,
    p_created_by: String,
    p_created_at: DateTime<Utc>,
}

impl Tx<Worker> {
    /// 名义触发时间不晚于 `now` 的触发器：计划在用、实例没删除。锁住返回的触发器行
    /// （SKIP LOCKED：多个副本同时扫描时各拿各的），调用方在同一个事务里生成运行、推进触发时间。
    pub async fn due_triggers(
        &mut self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<DueTrigger>> {
        let rows: Vec<DueRow> = sqlx::query_as(
            "SELECT t.user_id, i.agent_version, p.run_grant_id, \
               t.id, t.plan_id, t.spec, t.enabled, t.next_fire_at, t.last_fire_at, \
               p.id AS p_id, p.instance_id AS p_instance_id, p.title AS p_title, p.goal AS p_goal, \
               p.policy AS p_policy, p.catch_up AS p_catch_up, p.status AS p_status, \
               p.created_by AS p_created_by, p.created_at AS p_created_at \
             FROM triggers t \
             JOIN plans p ON p.id = t.plan_id \
             JOIN instances i ON i.id = p.instance_id \
             WHERE t.enabled AND t.next_fire_at <= $1 AND p.status = 'active' AND i.state <> 'deleted' \
             ORDER BY t.next_fire_at \
             LIMIT $2 \
             FOR UPDATE OF t SKIP LOCKED",
        )
        .bind(now)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|r| {
                let plan = PlanRow {
                    id: r.p_id,
                    instance_id: r.p_instance_id,
                    title: r.p_title,
                    goal: r.p_goal,
                    policy: r.p_policy,
                    catch_up: r.p_catch_up,
                    status: r.p_status,
                    created_by: r.p_created_by,
                    created_at: r.p_created_at,
                }
                .into_plan()?;
                Ok(DueTrigger {
                    user_id: r.user_id.into(),
                    agent_version: r.agent_version,
                    trigger: r.trigger.into_trigger()?,
                    plan,
                    run_grant_id: r.run_grant_id.map(Into::into),
                })
            })
            .collect()
    }

    /// 处理完一次到点：记下最后一次触发的名义时间，写入下一次（None 表示不再触发）。
    pub async fn advance_trigger(
        &mut self,
        id: TriggerId,
        last_fire_at: Option<DateTime<Utc>>,
        next_fire_at: Option<DateTime<Utc>>,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE triggers SET last_fire_at = coalesce($2, last_fire_at), next_fire_at = $3, \
               updated_at = now() WHERE id = $1",
        )
        .bind(id.0)
        .bind(last_fire_at)
        .bind(next_fire_at)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}
