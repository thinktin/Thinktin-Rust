//! 收件箱（10.4）：全部通知持久化，带已读状态。推送可能丢，收件箱不会。

use chrono::{DateTime, Utc};
use proto::domain::{
    ApprovalId, InboxItem, InboxItemId, InstanceId, PlanId, RunId, UserId, VaultRequestId,
    valid_subtype,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker};

#[derive(Debug, Clone, Default)]
pub struct NewInboxItem {
    /// run_finished / run_failed / approval / computer_approval / vault_request / plan_confirm / info
    pub kind: String,
    pub title: String,
    pub body: String,
    pub instance_id: Option<InstanceId>,
    pub run_id: Option<RunId>,
    pub plan_id: Option<PlanId>,
    pub approval_id: Option<ApprovalId>,
    pub dedupe_key: Option<String>,
    /// 正文是 agent 生成的。
    pub ai_generated: bool,
    /// 是哪一种提醒（`proto::domain::notice_subtype`）。
    pub subtype: Option<String>,
    pub vault_request_id: Option<VaultRequestId>,
}

macro_rules! columns {
    () => {
        "id, instance_id, run_id, plan_id, approval_id, kind, title, body, ai_generated, read_at, created_at, \
         subtype, vault_request_id"
    };
}

type Row = (
    Uuid,
    Option<Uuid>,
    Option<Uuid>,
    Option<Uuid>,
    Option<Uuid>,
    String,
    String,
    String,
    bool,
    Option<DateTime<Utc>>,
    DateTime<Utc>,
    Option<String>,
    Option<Uuid>,
);

fn item(r: Row) -> InboxItem {
    let (
        id,
        instance,
        run,
        plan,
        approval,
        kind,
        title,
        body,
        ai_generated,
        read_at,
        created_at,
        subtype,
        vault_request,
    ) = r;
    InboxItem {
        id: InboxItemId(id),
        instance_id: instance.map(InstanceId),
        run_id: run.map(RunId),
        plan_id: plan.map(PlanId),
        approval_id: approval.map(ApprovalId),
        kind,
        title,
        body,
        ai_generated,
        read: read_at.is_some(),
        created_at,
        subtype,
        vault_request_id: vault_request.map(VaultRequestId),
    }
}

impl<R> Tx<R> {
    /// 写一条收件箱。返回 None 表示同一个去重键已经写过。
    /// 业务角色只能写自己的（RLS 检查 `user`）。
    pub async fn insert_inbox(
        &mut self,
        user: UserId,
        new: &NewInboxItem,
    ) -> Result<Option<InboxItemId>> {
        if let Some(s) = &new.subtype
            && !valid_subtype(s)
        {
            return Err(Error::Invalid(format!("bad notice subtype {s:?}")));
        }
        let id = InboxItemId::new();
        let done = sqlx::query(
            "INSERT INTO inbox_items \
               (id, user_id, instance_id, run_id, plan_id, approval_id, kind, title, body, dedupe_key, ai_generated, \
                subtype, vault_request_id) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) \
             ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING",
        )
        .bind(id.0)
        .bind(user.0)
        .bind(new.instance_id.map(|i| i.0))
        .bind(new.run_id.map(|r| r.0))
        .bind(new.plan_id.map(|p| p.0))
        .bind(new.approval_id.map(|a| a.0))
        .bind(&new.kind)
        .bind(&new.title)
        .bind(&new.body)
        .bind(new.dedupe_key.as_deref())
        .bind(new.ai_generated)
        .bind(new.subtype.as_deref())
        .bind(new.vault_request_id.map(|v| v.0))
        .execute(self.conn())
        .await?;
        Ok((done.rows_affected() == 1).then_some(id))
    }

    /// 保险箱请求处理完（填了、拒绝了）后，对应的收件箱条目算已读。
    pub async fn settle_vault_request_inbox(&mut self, request: VaultRequestId) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE inbox_items SET read_at = now() WHERE vault_request_id = $1 AND read_at IS NULL",
        )
        .bind(request.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 审批处理完（批准、拒绝、超时、运行结束）后，对应的收件箱条目算已读。
    pub async fn settle_approval_inbox(&mut self, approval: ApprovalId) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE inbox_items SET read_at = now() WHERE approval_id = $1 AND read_at IS NULL",
        )
        .bind(approval.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Worker> {
    /// 用户收件箱里没读的条数（推送的角标，10.7）。
    pub async fn unread_inbox_count(&mut self, user: UserId) -> Result<u32> {
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM inbox_items WHERE user_id = $1 AND read_at IS NULL",
        )
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        Ok(u32::try_from(n).unwrap_or(u32::MAX))
    }
}

impl Tx<Tenant> {
    /// 新的在前。`before` 是上一页最后一条的 id（id 按时间递增）。
    pub async fn inbox(
        &mut self,
        before: Option<InboxItemId>,
        limit: i64,
        unread_only: bool,
    ) -> Result<Vec<InboxItem>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM inbox_items \
             WHERE ($1::uuid IS NULL OR id < $1) AND (NOT $2 OR read_at IS NULL) \
             ORDER BY id DESC LIMIT $3"
        ))
        .bind(before.map(|b| b.0))
        .bind(unread_only)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(item).collect())
    }

    pub async fn inbox_item(&mut self, id: InboxItemId) -> Result<InboxItem> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM inbox_items WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        Ok(item(row))
    }

    pub async fn inbox_unread(&mut self) -> Result<i64> {
        Ok(
            sqlx::query_scalar("SELECT count(*) FROM inbox_items WHERE read_at IS NULL")
                .fetch_one(self.conn())
                .await?,
        )
    }

    /// 标记已读：给 `ids` 就只标这些；否则标到 `up_to`（含）为止的全部，
    /// 这样客户端“全部已读”时不会把刚到、还没看到的新条目也标掉。返回标记的条数。
    pub async fn mark_inbox_read(
        &mut self,
        ids: Option<&[InboxItemId]>,
        up_to: Option<InboxItemId>,
    ) -> Result<u64> {
        let done = match ids {
            Some(ids) => {
                let ids: Vec<Uuid> = ids.iter().map(|i| i.0).collect();
                sqlx::query(
                    "UPDATE inbox_items SET read_at = now() WHERE id = ANY($1) AND read_at IS NULL",
                )
                .bind(ids)
                .execute(self.conn())
                .await?
            }
            None => {
                sqlx::query(
                    "UPDATE inbox_items SET read_at = now() \
                     WHERE read_at IS NULL AND ($1::uuid IS NULL OR id <= $1)",
                )
                .bind(up_to.map(|u| u.0))
                .execute(self.conn())
                .await?
            }
        };
        Ok(done.rows_affected())
    }

    pub async fn mark_inbox_unread(&mut self, id: InboxItemId) -> Result<()> {
        let done = sqlx::query("UPDATE inbox_items SET read_at = NULL WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    pub async fn delete_inbox_item(&mut self, id: InboxItemId) -> Result<()> {
        let done = sqlx::query("DELETE FROM inbox_items WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}
