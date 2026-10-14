//! 运行授权（4.3、4.6）：实例代表用户干活的权限，和设备会话无关，只在平台内部使用。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{GrantId, GrantScope, InstanceId, PlanId, RunGrant, UserId};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, from_json, secs, to_json};

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    user_id: Uuid,
    instance_id: Uuid,
    plan_id: Option<Uuid>,
    parent_id: Option<Uuid>,
    scope: serde_json::Value,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    last_used_at: Option<DateTime<Utc>>,
    revoked_at: Option<DateTime<Utc>>,
    revoke_reason: Option<String>,
}

impl Row {
    fn into_grant(self) -> Result<(UserId, RunGrant)> {
        Ok((
            self.user_id.into(),
            RunGrant {
                id: self.id.into(),
                instance_id: self.instance_id.into(),
                plan_id: self.plan_id.map(Into::into),
                parent_id: self.parent_id.map(Into::into),
                scope: from_json(self.scope, "grant scope")?,
                created_at: self.created_at,
                expires_at: self.expires_at,
                last_used_at: self.last_used_at,
                revoked_at: self.revoked_at,
                revoke_reason: self.revoke_reason,
            },
        ))
    }
}

macro_rules! columns {
    () => {
        "id, user_id, instance_id, plan_id, parent_id, scope, created_at, expires_at, last_used_at, \
         revoked_at, revoke_reason"
    };
}

impl Tx<Tenant> {
    /// 签发运行授权（领养实例、创建计划时）。
    pub async fn create_run_grant(
        &mut self,
        instance: InstanceId,
        plan: Option<PlanId>,
        scope: &GrantScope,
        ttl: Duration,
    ) -> Result<RunGrant> {
        self.instance(instance).await?;
        if let Some(plan) = plan {
            // run_grants.plan_id 没有外键（计划也引用授权），这里核对计划属于自己、挂在同一个实例上。
            if self.plan(plan).await?.instance_id != instance {
                return Err(Error::Invalid("plan belongs to another instance".into()));
            }
        }
        let user = self.user();
        insert(self, user, instance, plan, None, scope, ttl).await
    }

    /// 实例的有效授权。
    pub async fn run_grants(&mut self, instance: InstanceId) -> Result<Vec<RunGrant>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM run_grants WHERE instance_id = $1 AND revoked_at IS NULL AND expires_at > now() \
             ORDER BY created_at"
        ))
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(|r| Ok(r.into_grant()?.1)).collect()
    }
}

async fn insert<R>(
    tx: &mut Tx<R>,
    user: UserId,
    instance: InstanceId,
    plan: Option<PlanId>,
    parent: Option<GrantId>,
    scope: &GrantScope,
    ttl: Duration,
) -> Result<RunGrant> {
    let row: Row = sqlx::query_as(concat!(
        "INSERT INTO run_grants (id, user_id, instance_id, plan_id, parent_id, scope, expires_at) \
         VALUES ($1, $2, $3, $4, $5, $6, now() + make_interval(secs => $7)) RETURNING ",
        columns!()
    ))
    .bind(GrantId::new().0)
    .bind(user.0)
    .bind(instance.0)
    .bind(plan.map(|p| p.0))
    .bind(parent.map(|p| p.0))
    .bind(to_json(scope)?)
    .bind(secs(ttl))
    .fetch_one(tx.conn())
    .await?;
    Ok(row.into_grant()?.1)
}

/// 两种角色都能用；业务角色下 RLS 只放行当前用户的授权。
impl<R> Tx<R> {
    /// 吊销一个授权和从它收窄出来的全部子授权。返回吊销的个数（已吊销的不算）。
    pub async fn revoke_run_grant(&mut self, id: GrantId, reason: &str) -> Result<u64> {
        let done = sqlx::query(
            "WITH RECURSIVE tree AS ( \
               SELECT id FROM run_grants WHERE id = $1 \
               UNION SELECT g.id FROM run_grants g JOIN tree t ON g.parent_id = t.id) \
             UPDATE run_grants SET revoked_at = now(), revoke_reason = $2 \
             WHERE id IN (SELECT id FROM tree) AND revoked_at IS NULL",
        )
        .bind(id.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 吊销计划的授权（删除计划时）。
    pub async fn revoke_plan_grants(&mut self, plan: PlanId, reason: &str) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE run_grants SET revoked_at = now(), revoke_reason = $2 \
             WHERE plan_id = $1 AND revoked_at IS NULL",
        )
        .bind(plan.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 吊销实例的全部授权（停用、删除实例）。
    pub async fn revoke_instance_grants(
        &mut self,
        instance: InstanceId,
        reason: &str,
    ) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE run_grants SET revoked_at = now(), revoke_reason = $2 \
             WHERE instance_id = $1 AND revoked_at IS NULL",
        )
        .bind(instance.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Worker> {
    pub async fn run_grant(&mut self, id: GrantId) -> Result<(UserId, RunGrant)> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM run_grants WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_grant()
    }

    /// 从父授权收窄出子授权（子运行、委派）：范围不能超出父授权，有效期不超过父授权。
    pub async fn create_child_grant(
        &mut self,
        parent: GrantId,
        instance: InstanceId,
        scope: &GrantScope,
        ttl: Duration,
    ) -> Result<RunGrant> {
        let (user, p) = self.run_grant(parent).await?;
        if !p.is_active(Utc::now()) {
            return Err(Error::Invalid(format!(
                "parent grant {parent} is not active"
            )));
        }
        if !p.scope.contains(scope) {
            return Err(Error::Invalid(
                "child scope exceeds the parent grant".into(),
            ));
        }
        let remaining = (p.expires_at - Utc::now()).to_std().unwrap_or_default();
        insert(
            self,
            user,
            instance,
            p.plan_id,
            Some(parent),
            scope,
            ttl.min(remaining),
        )
        .await
    }

    /// 记一次使用（换沙箱令牌时）。顶层授权在剩余有效期不足 `renew_below` 时顺延到 `ttl`（有活动自动续期）；
    /// 子授权不续期，跟着父授权走。已吊销、已过期的不动，返回 None。
    pub async fn touch_run_grant(
        &mut self,
        id: GrantId,
        renew_below: Duration,
        ttl: Duration,
    ) -> Result<Option<(UserId, RunGrant)>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE run_grants SET last_used_at = now(), \
               expires_at = CASE WHEN parent_id IS NULL AND expires_at < now() + make_interval(secs => $2) \
                                 THEN now() + make_interval(secs => $3) ELSE expires_at END \
             WHERE id = $1 AND revoked_at IS NULL AND expires_at > now() RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(secs(renew_below))
        .bind(secs(ttl))
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_grant).transpose()
    }

    /// 实例当前可用的顶层授权（用户直接发起的运行用它换沙箱令牌），取最新的一个。
    pub async fn active_grant_for_instance(
        &mut self,
        instance: InstanceId,
    ) -> Result<Option<GrantId>> {
        let id: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM run_grants WHERE instance_id = $1 AND parent_id IS NULL AND plan_id IS NULL \
               AND revoked_at IS NULL AND expires_at > now() ORDER BY created_at DESC LIMIT 1",
        )
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        Ok(id.map(Into::into))
    }

    /// 吊销用户的全部授权（冻结、“全部停止”、注销）。
    pub async fn revoke_user_grants(&mut self, user: UserId, reason: &str) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE run_grants SET revoked_at = now(), revoke_reason = $2 \
             WHERE user_id = $1 AND revoked_at IS NULL",
        )
        .bind(user.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}
