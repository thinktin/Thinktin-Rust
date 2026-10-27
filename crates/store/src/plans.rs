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

/// 删除实例和引用它的计划步骤互斥用的咨询锁（[`Tx::share_instances`]）。
fn instance_plans_key(instance: InstanceId) -> String {
    format!("instance_plans/{instance}")
}

/// 删除实例时处理掉的计划（[`Tx::retire_instance_plans`]）。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RetiredPlans {
    /// 实例自己的计划：标记删除，触发器停掉。
    pub deleted: Vec<PlanId>,
    /// 别的实例的流水线计划、有一步在这个实例上：暂停，等用户改了步骤再恢复。
    pub paused: Vec<PlanId>,
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
    revision: i32,
    awaiting_confirmation: bool,
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
            revision: u32::try_from(self.revision).unwrap_or_default(),
            awaiting_confirmation: self.awaiting_confirmation,
        })
    }
}

macro_rules! plan_columns {
    () => {
        "id, instance_id, title, goal, policy, catch_up, status, created_by, created_at, revision, \
         awaiting_confirmation"
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
    disabled_reason: Option<String>,
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
            disabled_reason: self.disabled_reason,
        })
    }
}

macro_rules! trigger_columns {
    () => {
        "id, plan_id, spec, enabled, next_fire_at, last_fire_at, disabled_reason"
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
             ORDER BY created_at LIMIT 1000"
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
            "UPDATE plans SET title = $2, goal = $3, policy = $4, catch_up = $5, revision = revision + 1, \
               updated_at = now() \
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

    /// agent 新建或修改了计划：暂停、版本号加一、等用户确认。
    pub async fn request_plan_confirmation(&mut self, id: PlanId) -> Result<Plan> {
        let row: PlanRow = sqlx::query_as(concat!(
            "UPDATE plans SET status = 'paused', awaiting_confirmation = true, revision = revision + 1, \
               updated_at = now() WHERE id = $1 AND status <> 'deleted' RETURNING ",
            plan_columns!()
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_plan()
    }

    /// 用户确认 agent 安排的计划。`revision` 是用户看到的版本：之后又被改过就拒绝，让用户看了新内容再确认。
    pub async fn confirm_plan(&mut self, id: PlanId, revision: u32) -> Result<Plan> {
        let row: PlanRow = sqlx::query_as(concat!(
            "SELECT ",
            plan_columns!(),
            " FROM plans WHERE id = $1 AND status <> 'deleted' FOR UPDATE"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        if !row.awaiting_confirmation {
            return Err(Error::Conflict(
                "the plan is not waiting for confirmation".into(),
            ));
        }
        if i64::from(row.revision) != i64::from(revision) {
            return Err(Error::Conflict(
                "the plan changed after you reviewed it; reload it and confirm again".into(),
            ));
        }
        let row: PlanRow = sqlx::query_as(concat!(
            "UPDATE plans SET status = 'active', awaiting_confirmation = false, updated_at = now() \
             WHERE id = $1 RETURNING ",
            plan_columns!()
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_plan()
    }

    /// 实例上 agent 建的、没删除的计划数。
    pub async fn agent_plan_count(&mut self, instance: InstanceId) -> Result<u64> {
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM plans WHERE instance_id = $1 AND created_by = 'agent' AND status <> 'deleted'",
        )
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        Ok(u64::try_from(n).unwrap_or_default())
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
    /// 实例拿共享锁再查（[`Tx::share_instances`]）：和删除实例互斥。调用方要在锁计划行之前先调一次
    /// `share_instances`（这里再拿是重入，不用等）。
    pub async fn set_plan_steps(&mut self, plan: PlanId, steps: &[PlanStep]) -> Result<()> {
        order_steps(steps).map_err(Error::Invalid)?;
        self.share_instances(steps.iter().map(|s| s.instance_id))
            .await?;
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

    /// 删除实例时一并处理它的计划（11.9）：它自己的计划标记删除、触发器停掉；别的实例的流水线计划有一步在它上面的
    /// 暂停（用户改了步骤再恢复）。要在这个事务锁别的东西之前、取消实例的运行之前调。
    ///
    /// - 先拿这个实例的排他咨询锁：往计划里加它上面的步骤、恢复或确认有一步在它上面的计划的拿共享锁再查
    ///   （[`Tx::share_instances`]），不会在这里查过之后才提交，留下一个在跑、步骤却在已删除实例上的流水线。
    /// - 再按 id 顺序一次锁住要改的计划，然后改计划、停触发器：和删除计划、恢复、确认（计划 → 触发器）同一个顺序；
    ///   两个实例的流水线互相有一步在对方上时同时删除，也是按同一个顺序排队，不会死锁。
    /// - 停触发器和调度的 `FOR UPDATE` 互斥：正在触发的那一次提交以后才轮到这里，它建的运行接着被取消。
    ///
    /// 已经生成的运行不在这里处理。
    pub async fn retire_instance_plans(&mut self, instance: InstanceId) -> Result<RetiredPlans> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(instance_plans_key(instance))
            .execute(self.conn())
            .await?;
        // plan_steps 没有按实例的索引：按计划查（主键前缀）。
        sqlx::query(
            "SELECT p.id FROM plans p \
             WHERE p.status <> 'deleted' \
               AND (p.instance_id = $1 OR (p.status = 'active' \
                    AND EXISTS (SELECT 1 FROM plan_steps s WHERE s.plan_id = p.id AND s.instance_id = $1))) \
             ORDER BY p.id FOR NO KEY UPDATE",
        )
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        let deleted: Vec<Uuid> = sqlx::query_scalar(
            "UPDATE plans SET status = 'deleted', updated_at = now() \
             WHERE instance_id = $1 AND status <> 'deleted' RETURNING id",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        let paused: Vec<Uuid> = sqlx::query_scalar(
            "UPDATE plans p SET status = 'paused', updated_at = now() \
             WHERE p.status = 'active' AND p.instance_id <> $1 \
               AND EXISTS (SELECT 1 FROM plan_steps s WHERE s.plan_id = p.id AND s.instance_id = $1) \
             RETURNING p.id",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        sqlx::query(
            "UPDATE triggers SET enabled = false, updated_at = now() WHERE enabled AND plan_id = ANY($1)",
        )
        .bind(&deleted)
        .execute(self.conn())
        .await?;
        Ok(RetiredPlans {
            deleted: deleted.into_iter().map(PlanId).collect(),
            paused: paused.into_iter().map(PlanId).collect(),
        })
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
        // 重新打开时停用的原因一起清掉。
        let done = sqlx::query(
            "UPDATE triggers SET enabled = $2, next_fire_at = $3, \
               disabled_reason = CASE WHEN $2 THEN NULL ELSE disabled_reason END, updated_at = now() \
             WHERE id = $1",
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
    /// 给这些实例拿共享咨询锁到事务结束（11.9）：拿到以后再查实例没删除、写引用它们的计划步骤或者恢复计划，
    /// 删除实例（[`Tx::retire_instance_plans`] 拿排他锁）要等这个事务提交，提交后它能看到这里写的步骤。
    /// 用咨询锁不用实例行锁：删除接着要锁计划、触发器和运行，执行器是先锁运行再更新实例行的，在实例行上排队会成环。
    /// 拿锁之前这个事务不能已经锁着计划行（删除拿着排他锁时要锁计划）。
    pub async fn share_instances(
        &mut self,
        instances: impl IntoIterator<Item = InstanceId>,
    ) -> Result<()> {
        let mut ids: Vec<Uuid> = instances.into_iter().map(|i| i.0).collect();
        ids.sort_unstable();
        ids.dedup();
        for id in ids {
            sqlx::query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))")
                .bind(instance_plans_key(InstanceId(id)))
                .execute(self.conn())
                .await?;
        }
        Ok(())
    }

    /// 计划里第一个在已删除的实例上的步骤（11.9）：有的话恢复、确认前要先改步骤。步骤的实例先拿共享锁
    /// （[`Tx::share_instances`]），所以要在锁计划行之前调；查完到提交之间这些实例删不掉。
    pub async fn deleted_step(&mut self, plan: PlanId) -> Result<Option<String>> {
        let instances: Vec<Uuid> =
            sqlx::query_scalar("SELECT DISTINCT instance_id FROM plan_steps WHERE plan_id = $1")
                .bind(plan.0)
                .fetch_all(self.conn())
                .await?;
        self.share_instances(instances.into_iter().map(InstanceId))
            .await?;
        Ok(sqlx::query_scalar(
            "SELECT s.key FROM plan_steps s JOIN instances i ON i.id = s.instance_id \
             WHERE s.plan_id = $1 AND i.state = 'deleted' ORDER BY s.position LIMIT 1",
        )
        .bind(plan.0)
        .fetch_optional(self.conn())
        .await?)
    }

    /// 后台停用一个触发器，记下原因（[`proto::domain::TRIGGER_INVALID_RULE`]）。已经因为同一个原因停用了的返回
    /// `false`（只通知一次）。
    pub async fn disable_trigger(&mut self, id: TriggerId, reason: &str) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE triggers SET enabled = false, next_fire_at = NULL, disabled_reason = $2, updated_at = now() \
             WHERE id = $1 AND disabled_reason IS DISTINCT FROM $2",
        )
        .bind(id.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

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

    /// 暂停或恢复计划。审批超时的 `pause_plan` 策略由后台调用。等用户确认的计划不能恢复（用 `confirm_plan`）。
    pub async fn set_plan_paused(&mut self, id: PlanId, paused: bool) -> Result<()> {
        let done = sqlx::query(
            "UPDATE plans SET status = CASE WHEN $2 THEN 'paused' ELSE 'active' END, updated_at = now() \
             WHERE id = $1 AND status <> 'deleted' AND ($2 OR NOT awaiting_confirmation)",
        )
        .bind(id.0)
        .bind(paused)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            if self.plan(id).await?.awaiting_confirmation {
                return Err(Error::Conflict(
                    "the plan is waiting for confirmation; confirm the version you reviewed".into(),
                ));
            }
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 几个计划的触发器（列表一次取完），按计划、创建时间。
    pub async fn triggers_of(&mut self, plans: &[PlanId]) -> Result<Vec<Trigger>> {
        let ids: Vec<Uuid> = plans.iter().map(|p| p.0).collect();
        let rows: Vec<TriggerRow> = sqlx::query_as(concat!(
            "SELECT ",
            trigger_columns!(),
            " FROM triggers WHERE plan_id = ANY($1) ORDER BY plan_id, created_at"
        ))
        .bind(&ids)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(TriggerRow::into_trigger).collect()
    }

    /// 几个计划的流水线步骤（列表一次取完），每个计划内按声明顺序。
    pub async fn plan_steps_of(&mut self, plans: &[PlanId]) -> Result<Vec<(PlanId, PlanStep)>> {
        let ids: Vec<Uuid> = plans.iter().map(|p| p.0).collect();
        let rows: Vec<(Uuid, String, Uuid, String, Vec<String>)> = sqlx::query_as(
            "SELECT plan_id, key, instance_id, prompt, depends_on FROM plan_steps WHERE plan_id = ANY($1) \
             ORDER BY plan_id, position",
        )
        .bind(&ids)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(plan, key, instance, prompt, depends_on)| {
                (
                    plan.into(),
                    PlanStep {
                        key,
                        instance_id: instance.into(),
                        prompt,
                        depends_on,
                    },
                )
            })
            .collect())
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
    p_revision: i32,
    p_awaiting_confirmation: bool,
}

impl Tx<Worker> {
    /// 暂停用户所有在用的计划（“全部停止”，4.6）。用户逐个恢复时重新签发授权。返回暂停的个数。
    pub async fn pause_user_plans(&mut self, user: UserId) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE plans SET status = 'paused', updated_at = now() WHERE user_id = $1 AND status = 'active'",
        )
        .bind(user.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 名义触发时间不晚于 `now` 的触发器：计划在用、实例没删除。锁住返回的触发器行
    /// （SKIP LOCKED：多个副本同时扫描时各拿各的），调用方在同一个事务里生成运行、推进触发时间。
    pub async fn due_triggers(
        &mut self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<DueTrigger>> {
        let rows: Vec<DueRow> = sqlx::query_as(
            "SELECT t.user_id, i.agent_version, p.run_grant_id, \
               t.id, t.plan_id, t.spec, t.enabled, t.next_fire_at, t.last_fire_at, t.disabled_reason, \
               p.id AS p_id, p.instance_id AS p_instance_id, p.title AS p_title, p.goal AS p_goal, \
               p.policy AS p_policy, p.catch_up AS p_catch_up, p.status AS p_status, \
               p.created_by AS p_created_by, p.created_at AS p_created_at, \
               p.revision AS p_revision, p.awaiting_confirmation AS p_awaiting_confirmation \
             FROM triggers t \
             JOIN plans p ON p.id = t.plan_id \
             JOIN instances i ON i.id = p.instance_id \
             JOIN users u ON u.id = t.user_id \
             WHERE t.enabled AND t.next_fire_at <= $1 AND p.status = 'active' AND i.state <> 'deleted' \
               AND u.status = 'active' \
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
                    revision: r.p_revision,
                    awaiting_confirmation: r.p_awaiting_confirmation,
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
    /// 换掉触发规则（调度循环把长期运行的 RRULE 的 DTSTART 挪近，规则等价）。
    pub async fn set_trigger_spec(&mut self, id: TriggerId, spec: &ScheduleSpec) -> Result<()> {
        sqlx::query("UPDATE triggers SET spec = $2, updated_at = now() WHERE id = $1")
            .bind(id.0)
            .bind(to_json(spec)?)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 计划还在排队、没开始的运行有几个（只数根运行）。调度时用来合并积压的触发。
    pub async fn queued_plan_runs(&mut self, plan: PlanId) -> Result<u32> {
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM runs \
             WHERE plan_id = $1 AND parent_run_id IS NULL AND state = 'queued'",
        )
        .bind(plan.0)
        .fetch_one(self.conn())
        .await?;
        Ok(u32::try_from(n).unwrap_or(u32::MAX))
    }

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
