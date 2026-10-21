//! 出箱（7.5）和审计日志（5.6）。
//!
//! 要发的通知和状态变更写在同一个事务里，投递器另外领取、发送，发送失败按时间重试：
//! 状态变了通知一定会发，事务回滚了通知也不会发出去。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::UserId;
use serde_json::Value;
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, secs};

#[derive(Debug, Clone)]
pub struct NewOutboxItem {
    /// push / im / internal。
    pub kind: String,
    pub payload: Value,
    /// 同一个用户的同一个键只入箱一次（比如 `run_finished:<运行 id>`）。
    pub dedupe_key: Option<String>,
    /// 最早什么时候发；None 为立即。
    pub available_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OutboxItem {
    pub id: i64,
    pub user_id: UserId,
    pub kind: String,
    pub payload: Value,
    /// 含这一次。
    pub attempts: u32,
    pub created_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct Row {
    id: i64,
    user_id: Uuid,
    kind: String,
    payload: Value,
    attempts: i32,
    created_at: DateTime<Utc>,
}

async fn insert(conn: &mut sqlx::PgConnection, user: UserId, item: &NewOutboxItem) -> Result<bool> {
    // 业务角色对出箱没有读权限，所以不用 RETURNING。
    let done = sqlx::query(
        "INSERT INTO outbox (user_id, kind, payload, dedupe_key, available_at) \
         VALUES ($1, $2, $3, $4, coalesce($5, now())) ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING",
    )
    .bind(user.0)
    .bind(&item.kind)
    .bind(&item.payload)
    .bind(&item.dedupe_key)
    .bind(item.available_at)
    .execute(conn)
    .await?;
    Ok(done.rows_affected() == 1)
}

async fn audit(
    conn: &mut sqlx::PgConnection,
    user: Option<UserId>,
    actor: &str,
    action: &str,
    target: Option<&str>,
    detail: &Value,
) -> Result<()> {
    sqlx::query(
        "INSERT INTO audit_log (user_id, actor, action, target, detail) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(user.map(|u| u.0))
    .bind(actor)
    .bind(action)
    .bind(target)
    .bind(detail)
    .execute(conn)
    .await?;
    Ok(())
}

impl Tx<Tenant> {
    /// 入箱。返回 false 表示同一个去重键已经入过箱。
    pub async fn enqueue_outbox(&mut self, item: &NewOutboxItem) -> Result<bool> {
        let user = self.user();
        insert(self.conn(), user, item).await
    }

    /// 记一条安全审计（不记对话内容、不记 key 明文）。`actor` 形如 `user:<设备 id>`。
    pub async fn audit(
        &mut self,
        actor: &str,
        action: &str,
        target: Option<&str>,
        detail: &Value,
    ) -> Result<()> {
        let user = self.user();
        audit(self.conn(), Some(user), actor, action, target, detail).await
    }
}

impl Tx<Worker> {
    pub async fn enqueue_outbox(&mut self, user: UserId, item: &NewOutboxItem) -> Result<bool> {
        insert(self.conn(), user, item).await
    }

    /// 删掉送达（或放弃）超过 `older_than` 的条目：载荷里有推送的标题和正文，不长期留着。
    /// 收件箱里有同样的内容，用户自己能看、能删。
    pub async fn purge_delivered_outbox(&mut self, older_than: Duration) -> Result<u64> {
        let done = sqlx::query(
            "DELETE FROM outbox WHERE delivered_at < now() - make_interval(secs => $1)",
        )
        .bind(secs(older_than))
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    pub async fn audit(
        &mut self,
        user: Option<UserId>,
        actor: &str,
        action: &str,
        target: Option<&str>,
        detail: &Value,
    ) -> Result<()> {
        audit(self.conn(), user, actor, action, target, detail).await
    }

    /// 领取到期、没被别人锁着的出箱条目，锁 `lock_for` 这么久（投递器崩溃后自动放开）。
    pub async fn claim_outbox(
        &mut self,
        owner: &str,
        lock_for: Duration,
        limit: i64,
    ) -> Result<Vec<OutboxItem>> {
        self.claim_outbox_of(owner, lock_for, limit, None).await
    }

    /// 同上，只领这几种（投递器只领自己会处理的：滚动发布时老版本不认识的新种类留给新版本）。
    pub async fn claim_outbox_of(
        &mut self,
        owner: &str,
        lock_for: Duration,
        limit: i64,
        kinds: Option<&[&str]>,
    ) -> Result<Vec<OutboxItem>> {
        let kinds: Option<Vec<String>> = kinds.map(|k| k.iter().map(|s| (*s).to_owned()).collect());
        let rows: Vec<Row> = sqlx::query_as(
            "UPDATE outbox SET locked_by = $1, locked_until = now() + make_interval(secs => $2), \
               attempts = attempts + 1 \
             WHERE id IN (SELECT id FROM outbox \
                          WHERE delivered_at IS NULL AND available_at <= now() \
                            AND (locked_until IS NULL OR locked_until < now()) \
                            AND ($4::text[] IS NULL OR kind = ANY ($4)) \
                          ORDER BY id LIMIT $3 FOR UPDATE SKIP LOCKED) \
             RETURNING id, user_id, kind, payload, attempts, created_at",
        )
        .bind(owner)
        .bind(secs(lock_for))
        .bind(limit)
        .bind(kinds)
        .fetch_all(self.conn())
        .await?;
        let mut items = rows
            .into_iter()
            .map(|r| {
                Ok(OutboxItem {
                    id: r.id,
                    user_id: r.user_id.into(),
                    kind: r.kind,
                    payload: r.payload,
                    attempts: u32::try_from(r.attempts)
                        .map_err(|_| Error::Corrupt("negative attempts".into()))?,
                    created_at: r.created_at,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        items.sort_by_key(|i| i.id);
        Ok(items)
    }

    /// 发送前续一下锁：一批是按顺序发的，前面的推送服务慢，后面条目的锁可能已经过期、
    /// 被别的投递器领走了。返回 false 表示锁不在手里，这条交给对方，别再发一遍。
    pub async fn extend_outbox_lock(
        &mut self,
        id: i64,
        owner: &str,
        lock_for: Duration,
    ) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE outbox SET locked_until = now() + make_interval(secs => $3) \
             WHERE id = $1 AND locked_by = $2 AND delivered_at IS NULL AND locked_until > now()",
        )
        .bind(id)
        .bind(owner)
        .bind(secs(lock_for))
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 处理完了：发送成功，或者放弃（`error` 记下放弃的原因）。
    pub async fn finish_outbox(&mut self, id: i64, owner: &str, error: Option<&str>) -> Result<()> {
        self.settle_outbox(
            "UPDATE outbox SET delivered_at = now(), last_error = $3, locked_by = NULL, locked_until = NULL \
             WHERE id = $1 AND locked_by = $2 AND delivered_at IS NULL",
            id,
            owner,
            error,
            None,
        )
        .await
    }

    /// 这次没发出去，`at` 之后再试。
    pub async fn retry_outbox(
        &mut self,
        id: i64,
        owner: &str,
        error: &str,
        at: DateTime<Utc>,
    ) -> Result<()> {
        self.settle_outbox(
            "UPDATE outbox SET available_at = $4, last_error = $3, locked_by = NULL, locked_until = NULL \
             WHERE id = $1 AND locked_by = $2 AND delivered_at IS NULL",
            id,
            owner,
            Some(error),
            Some(at),
        )
        .await
    }

    /// 自己的限流：`at` 之后再发，不算一次尝试（领取时加的那次退回去）。
    pub async fn defer_outbox(
        &mut self,
        id: i64,
        owner: &str,
        reason: &str,
        at: DateTime<Utc>,
    ) -> Result<()> {
        self.settle_outbox(
            "UPDATE outbox SET available_at = $4, last_error = $3, attempts = greatest(attempts - 1, 0), \
               locked_by = NULL, locked_until = NULL \
             WHERE id = $1 AND locked_by = $2 AND delivered_at IS NULL",
            id,
            owner,
            Some(reason),
            Some(at),
        )
        .await
    }

    async fn settle_outbox(
        &mut self,
        sql: &'static str,
        id: i64,
        owner: &str,
        error: Option<&str>,
        at: Option<DateTime<Utc>>,
    ) -> Result<()> {
        let mut q = sqlx::query(sql).bind(id).bind(owner).bind(error);
        if at.is_some() {
            q = q.bind(at);
        }
        let done = q.execute(self.conn()).await?;
        if done.rows_affected() == 0 {
            // 锁过期后被别的投递器领走了：交给对方处理。
            return Err(Error::LeaseLost {
                owner: owner.to_owned(),
            });
        }
        Ok(())
    }
}
