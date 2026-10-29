//! 计划的 webhook（WBS 7.1 的事件部分）：外面的服务往一个只有用户知道的地址 POST，平台按这个计划起一次运行。
//!
//! - 地址里的令牌库里只存 SHA-256，按哈希找；建、换的时候由调用方生成令牌、只给用户看一次。
//! - 用户管理（建、列、停用、换令牌、删）走业务角色（行级安全）；收事件时还不知道是谁，按令牌哈希用后台角色找到
//!   webhook、计划和用户，再核对计划在用、实例没删、账号没冻结。
//! - 限流按库里的运行数：每个 webhook 最近一小时起了几次、排着几个，每个用户最近一小时一共起了几次（多副本也准）。

use chrono::{DateTime, Utc};
use proto::domain::{GrantId, Plan, PlanHook, PlanHookId, PlanId, UserId};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, unsigned};

/// 一个计划最多这么多个 webhook。
pub const MAX_HOOKS_PER_PLAN: usize = 5;

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    plan_id: Uuid,
    enabled: bool,
    consented_at: DateTime<Utc>,
    last_event_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
}

impl Row {
    fn into_hook(self) -> PlanHook {
        PlanHook {
            id: self.id.into(),
            plan_id: self.plan_id.into(),
            enabled: self.enabled,
            consented_at: self.consented_at,
            last_event_at: self.last_event_at,
            created_at: self.created_at,
        }
    }
}

macro_rules! columns {
    () => {
        "id, plan_id, enabled, consented_at, last_event_at, created_at"
    };
}

/// 收到事件时找到的 webhook 和要起运行的计划。
#[derive(Debug, Clone)]
pub struct HookTarget {
    pub hook: PlanHook,
    pub user_id: UserId,
    pub plan: Plan,
    /// 实例当前锁定的模板版本。
    pub agent_version: String,
    pub run_grant_id: Option<GrantId>,
}

/// 这个 webhook、这个用户最近起的运行（限流用）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HookActivity {
    pub hook_last_hour: u64,
    pub user_last_hour: u64,
    pub hook_queued: u64,
}

impl Tx<Tenant> {
    /// 给计划加一个 webhook（用户同意把收到的内容交给 agent 和模型厂商之后）。带步骤的计划（流水线）先不支持。
    pub async fn create_plan_hook(&mut self, plan: PlanId, token_hash: &[u8]) -> Result<PlanHook> {
        let p = self.plan(plan).await?;
        if !self.plan_steps(plan).await?.is_empty() {
            return Err(Error::Invalid(
                "webhooks only work on single-agent plans for now".into(),
            ));
        }
        if self.plan_hooks(plan).await?.len() >= MAX_HOOKS_PER_PLAN {
            return Err(Error::Invalid(format!(
                "at most {MAX_HOOKS_PER_PLAN} webhooks per plan"
            )));
        }
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO plan_hooks (id, user_id, plan_id, token_hash, consented_at) \
             VALUES ($1, app_user_id(), $2, $3, now()) RETURNING ",
            columns!()
        ))
        .bind(PlanHookId::new().0)
        .bind(p.id.0)
        .bind(token_hash)
        .fetch_one(self.conn())
        .await?;
        Ok(row.into_hook())
    }

    pub async fn plan_hooks(&mut self, plan: PlanId) -> Result<Vec<PlanHook>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM plan_hooks WHERE plan_id = $1 ORDER BY created_at, id"
        ))
        .bind(plan.0)
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(Row::into_hook).collect())
    }

    pub async fn plan_hook(&mut self, id: PlanHookId) -> Result<PlanHook> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM plan_hooks WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        Ok(row.into_hook())
    }

    /// 停用、启用。
    pub async fn set_plan_hook_enabled(
        &mut self,
        id: PlanHookId,
        enabled: bool,
    ) -> Result<PlanHook> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE plan_hooks SET enabled = $2 WHERE id = $1 RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(enabled)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_hook).ok_or(Error::NotFound)
    }

    /// 换令牌：旧地址马上失效。
    pub async fn rotate_plan_hook(
        &mut self,
        id: PlanHookId,
        token_hash: &[u8],
    ) -> Result<PlanHook> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE plan_hooks SET token_hash = $2 WHERE id = $1 RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(token_hash)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_hook).ok_or(Error::NotFound)
    }

    pub async fn delete_plan_hook(&mut self, id: PlanHookId) -> Result<()> {
        let done = sqlx::query("DELETE FROM plan_hooks WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}

impl Tx<Worker> {
    /// 按令牌哈希找 webhook：启用着、计划在用（没暂停、没删、不在等确认）、实例没删、账号没冻结的才算。锁住
    /// webhook 这一行到事务结束：同一个 webhook 同时来的事件排队数，限流不会被并发穿透。
    pub async fn hook_target(&mut self, token_hash: &[u8]) -> Result<Option<HookTarget>> {
        #[derive(sqlx::FromRow)]
        struct Found {
            id: Uuid,
            plan_id: Uuid,
            enabled: bool,
            consented_at: DateTime<Utc>,
            last_event_at: Option<DateTime<Utc>>,
            created_at: DateTime<Utc>,
            user_id: Uuid,
            agent_version: String,
            run_grant_id: Option<Uuid>,
        }
        let found: Option<Found> = sqlx::query_as(
            "SELECT h.id, h.plan_id, h.enabled, h.consented_at, h.last_event_at, h.created_at, h.user_id, \
               i.agent_version, p.run_grant_id \
             FROM plan_hooks h \
             JOIN plans p ON p.id = h.plan_id \
             JOIN instances i ON i.id = p.instance_id \
             JOIN users u ON u.id = h.user_id \
             WHERE h.token_hash = $1 AND h.enabled AND p.status = 'active' AND NOT p.awaiting_confirmation \
               AND i.state <> 'deleted' AND u.status = 'active' \
             FOR UPDATE OF h",
        )
        .bind(token_hash)
        .fetch_optional(self.conn())
        .await?;
        let Some(f) = found else {
            return Ok(None);
        };
        let plan = self.plan(f.plan_id.into()).await?;
        Ok(Some(HookTarget {
            hook: Row {
                id: f.id,
                plan_id: f.plan_id,
                enabled: f.enabled,
                consented_at: f.consented_at,
                last_event_at: f.last_event_at,
                created_at: f.created_at,
            }
            .into_hook(),
            user_id: f.user_id.into(),
            plan,
            agent_version: f.agent_version,
            run_grant_id: f.run_grant_id.map(Into::into),
        }))
    }

    /// 这个 webhook、这个用户最近一小时起的运行，和这个 webhook 排着没开始的。
    pub async fn hook_activity(&mut self, hook: PlanHookId, user: UserId) -> Result<HookActivity> {
        let (hook_hour, user_hour, queued): (i64, i64, i64) = sqlx::query_as(
            "SELECT \
               (SELECT count(*) FROM runs WHERE hook_id = $1 AND created_at > now() - interval '1 hour'), \
               (SELECT count(*) FROM runs WHERE user_id = $2 AND hook_id IS NOT NULL \
                  AND created_at > now() - interval '1 hour'), \
               (SELECT count(*) FROM runs WHERE hook_id = $1 AND state = 'queued')",
        )
        .bind(hook.0)
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        Ok(HookActivity {
            hook_last_hour: unsigned(hook_hour, "hook runs")?,
            user_last_hour: unsigned(user_hour, "hook runs")?,
            hook_queued: unsigned(queued, "queued hook runs")?,
        })
    }

    /// 记下 webhook 最后一次收到事件的时间。
    pub async fn touch_plan_hook(&mut self, hook: PlanHookId) -> Result<()> {
        sqlx::query("UPDATE plan_hooks SET last_event_at = now() WHERE id = $1")
            .bind(hook.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}
