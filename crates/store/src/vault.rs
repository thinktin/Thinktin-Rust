//! 密码保险箱（WBS 9.11）：条目的密文和 agent 发起的填写请求。
//!
//! 库里只有密钥库用用户 DEK 封好的密文（账号和密码一起），这里的读接口除了显式取密文的几个，
//! 都不返回密文。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    InstanceId, RunId, UserId, VaultItem, VaultItemId, VaultRequest, VaultRequestId,
    VaultRequestStatus,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse, secs};

/// 新的保险箱条目。`sealed` 是密钥库用这个用户的 DEK 封好的账号和密码。
#[derive(Clone)]
pub struct NewVaultItem {
    /// 由调用方先生成：密文的附加认证数据里带着它。
    pub id: VaultItemId,
    pub name: String,
    pub purpose: String,
    pub sealed: Vec<u8>,
    pub has_username: bool,
    pub instance_ids: Vec<InstanceId>,
}

impl std::fmt::Debug for NewVaultItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewVaultItem")
            .field("id", &self.id)
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

/// 改条目：给了才改。`sealed` 是重新封好的账号和密码，连同有没有账号。
#[derive(Clone, Default)]
pub struct VaultItemChange {
    pub purpose: Option<String>,
    pub instance_ids: Option<Vec<InstanceId>>,
    pub sealed: Option<(Vec<u8>, bool)>,
}

/// 一个条目连同密文（解密只在要用的地方做）。
#[derive(Clone)]
pub struct SealedVaultItem {
    pub item: VaultItem,
    pub sealed: Vec<u8>,
}

impl std::fmt::Debug for SealedVaultItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SealedVaultItem")
            .field("item", &self.item)
            .finish_non_exhaustive()
    }
}

/// agent 发起的填写请求。
#[derive(Debug, Clone)]
pub struct NewVaultRequest {
    pub instance_id: InstanceId,
    pub run_id: Option<RunId>,
    pub name: String,
    pub purpose: String,
    pub fields: Vec<String>,
    pub expires_in: Duration,
}

#[derive(sqlx::FromRow)]
struct ItemRow {
    id: Uuid,
    name: String,
    purpose: String,
    has_username: bool,
    instance_ids: Vec<Uuid>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    last_used_at: Option<DateTime<Utc>>,
}

impl ItemRow {
    fn into_item(self) -> VaultItem {
        VaultItem {
            id: self.id.into(),
            name: self.name,
            purpose: self.purpose,
            has_username: self.has_username,
            instance_ids: self.instance_ids.into_iter().map(Into::into).collect(),
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_used_at: self.last_used_at,
        }
    }
}

#[derive(sqlx::FromRow)]
struct SealedRow {
    #[sqlx(flatten)]
    item: ItemRow,
    sealed: Vec<u8>,
}

impl SealedRow {
    fn into_sealed(self) -> SealedVaultItem {
        SealedVaultItem {
            item: self.item.into_item(),
            sealed: self.sealed,
        }
    }
}

macro_rules! item_columns {
    () => {
        "id, name, purpose, has_username, instance_ids, created_at, updated_at, last_used_at"
    };
}

#[derive(sqlx::FromRow)]
struct RequestRow {
    id: Uuid,
    instance_id: Uuid,
    run_id: Option<Uuid>,
    name: String,
    purpose: String,
    fields: Vec<String>,
    status: String,
    item_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    resolved_at: Option<DateTime<Utc>>,
}

impl RequestRow {
    fn into_request(self) -> Result<VaultRequest> {
        Ok(VaultRequest {
            id: self.id.into(),
            instance_id: self.instance_id.into(),
            run_id: self.run_id.map(Into::into),
            name: self.name,
            purpose: self.purpose,
            fields: self.fields,
            status: parse(&self.status)?,
            item_id: self.item_id.map(Into::into),
            created_at: self.created_at,
            expires_at: self.expires_at,
            resolved_at: self.resolved_at,
        })
    }
}

/// 过了期限还没处理的请求读出来是 `expired`（不用后台任务去改）。
macro_rules! request_columns {
    () => {
        "id, instance_id, run_id, name, purpose, fields, \
         CASE WHEN status = 'pending' AND expires_at <= now() THEN 'expired' ELSE status END AS status, \
         item_id, created_at, expires_at, resolved_at"
    };
}

impl Tx<Tenant> {
    /// 新建条目。同名的已经有了返回冲突；能用它的实例必须是自己的、没删除的。
    pub async fn create_vault_item(&mut self, new: &NewVaultItem) -> Result<VaultItem> {
        for i in &new.instance_ids {
            self.instance(*i).await?;
        }
        let ids: Vec<Uuid> = new.instance_ids.iter().map(|i| i.0).collect();
        let row: ItemRow = sqlx::query_as(concat!(
            "INSERT INTO vault_items (id, user_id, name, purpose, sealed, has_username, instance_ids) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6) RETURNING ",
            item_columns!()
        ))
        .bind(new.id.0)
        .bind(&new.name)
        .bind(&new.purpose)
        .bind(&new.sealed)
        .bind(new.has_username)
        .bind(&ids)
        .fetch_one(self.conn())
        .await
        .map_err(|e| match Error::from(e) {
            Error::Conflict(_) => {
                Error::Conflict(format!("a vault item named {} already exists", new.name))
            }
            other => other,
        })?;
        Ok(row.into_item())
    }

    pub async fn vault_items(&mut self) -> Result<Vec<VaultItem>> {
        let rows: Vec<ItemRow> = sqlx::query_as(concat!(
            "SELECT ",
            item_columns!(),
            " FROM vault_items ORDER BY name"
        ))
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(ItemRow::into_item).collect())
    }

    pub async fn vault_item_count(&mut self) -> Result<u64> {
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM vault_items")
            .fetch_one(self.conn())
            .await?;
        crate::unsigned(n, "vault item count")
    }

    /// 条目连同密文（看详情时解开账号、改密码时合并）。
    pub async fn sealed_vault_item(&mut self, id: VaultItemId) -> Result<SealedVaultItem> {
        let row: SealedRow = sqlx::query_as(concat!(
            "SELECT ",
            item_columns!(),
            ", sealed FROM vault_items WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        Ok(row.into_sealed())
    }

    /// 按名字找条目连同密文。
    pub async fn sealed_vault_item_named(&mut self, name: &str) -> Result<SealedVaultItem> {
        let row: SealedRow = sqlx::query_as(concat!(
            "SELECT ",
            item_columns!(),
            ", sealed FROM vault_items WHERE name = $1"
        ))
        .bind(name)
        .fetch_one(self.conn())
        .await?;
        Ok(row.into_sealed())
    }

    pub async fn update_vault_item(
        &mut self,
        id: VaultItemId,
        change: &VaultItemChange,
    ) -> Result<VaultItem> {
        if let Some(list) = &change.instance_ids {
            for i in list {
                self.instance(*i).await?;
            }
        }
        let ids: Option<Vec<Uuid>> = change
            .instance_ids
            .as_ref()
            .map(|l| l.iter().map(|i| i.0).collect());
        let (sealed, has_username) = match &change.sealed {
            Some((s, u)) => (Some(s.as_slice()), Some(*u)),
            None => (None, None),
        };
        let row: ItemRow = sqlx::query_as(concat!(
            "UPDATE vault_items SET purpose = coalesce($2, purpose), \
               instance_ids = coalesce($3, instance_ids), sealed = coalesce($4, sealed), \
               has_username = coalesce($5, has_username), updated_at = now() \
             WHERE id = $1 RETURNING ",
            item_columns!()
        ))
        .bind(id.0)
        .bind(change.purpose.as_deref())
        .bind(ids)
        .bind(sealed)
        .bind(has_username)
        .fetch_one(self.conn())
        .await?;
        Ok(row.into_item())
    }

    pub async fn delete_vault_item(&mut self, id: VaultItemId) -> Result<()> {
        let done = sqlx::query("DELETE FROM vault_items WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// agent 请用户填账号密码。同名的请求还在等就复用它（返回 false 表示没新建）。
    /// 过期没处理的同名请求先关掉，再新建。
    pub async fn create_vault_request(
        &mut self,
        new: &NewVaultRequest,
    ) -> Result<(VaultRequest, bool)> {
        sqlx::query(
            "UPDATE vault_requests SET status = 'expired', resolved_at = now() \
             WHERE name = $1 AND status = 'pending' AND expires_at <= now()",
        )
        .bind(&new.name)
        .execute(self.conn())
        .await?;
        let inserted: Option<RequestRow> = sqlx::query_as(concat!(
            "INSERT INTO vault_requests (id, user_id, instance_id, run_id, name, purpose, fields, expires_at) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6, now() + make_interval(secs => $7)) \
             ON CONFLICT (user_id, name) WHERE status = 'pending' DO NOTHING RETURNING ",
            request_columns!()
        ))
        .bind(VaultRequestId::new().0)
        .bind(new.instance_id.0)
        .bind(new.run_id.map(|r| r.0))
        .bind(&new.name)
        .bind(&new.purpose)
        .bind(&new.fields)
        .bind(secs(new.expires_in))
        .fetch_optional(self.conn())
        .await?;
        if let Some(row) = inserted {
            return Ok((row.into_request()?, true));
        }
        let row: RequestRow = sqlx::query_as(concat!(
            "SELECT ",
            request_columns!(),
            " FROM vault_requests WHERE name = $1 AND status = 'pending'"
        ))
        .bind(&new.name)
        .fetch_one(self.conn())
        .await?;
        Ok((row.into_request()?, false))
    }

    /// 填写请求，新的在前。`pending_only` 时只要还在等的（没过期的）。
    pub async fn vault_requests(&mut self, pending_only: bool) -> Result<Vec<VaultRequest>> {
        let rows: Vec<RequestRow> = sqlx::query_as(concat!(
            "SELECT ",
            request_columns!(),
            " FROM vault_requests \
             WHERE NOT $1 OR (status = 'pending' AND expires_at > now()) \
             ORDER BY created_at DESC LIMIT 100"
        ))
        .bind(pending_only)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(RequestRow::into_request).collect()
    }

    pub async fn vault_request(&mut self, id: VaultRequestId) -> Result<VaultRequest> {
        let row: RequestRow = sqlx::query_as(concat!(
            "SELECT ",
            request_columns!(),
            " FROM vault_requests WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_request()
    }

    /// 处理请求：填好了（`item` 是存进去的条目）或者拒绝。已经处理过、过期了返回冲突。
    pub async fn resolve_vault_request(
        &mut self,
        id: VaultRequestId,
        item: Option<VaultItemId>,
    ) -> Result<VaultRequest> {
        let status = if item.is_some() {
            VaultRequestStatus::Fulfilled
        } else {
            VaultRequestStatus::Declined
        };
        let row: Option<RequestRow> = sqlx::query_as(concat!(
            "UPDATE vault_requests SET status = $2, item_id = $3, resolved_at = now() \
             WHERE id = $1 AND status = 'pending' AND expires_at > now() RETURNING ",
            request_columns!()
        ))
        .bind(id.0)
        .bind(status.as_str())
        .bind(item.map(|i| i.0))
        .fetch_optional(self.conn())
        .await?;
        match row {
            Some(r) => r.into_request(),
            None => {
                let current = self.vault_request(id).await?;
                Err(Error::Conflict(format!(
                    "the request is already {}",
                    current.status
                )))
            }
        }
    }
}

impl Tx<Worker> {
    /// 运行要用的条目连同密文（9.11）：只给这个实例能用的；按名字顺序。找不到的名字不报错，调用方比对。
    pub async fn vault_items_for_instance(
        &mut self,
        user: UserId,
        instance: InstanceId,
        names: &[String],
    ) -> Result<Vec<SealedVaultItem>> {
        let rows: Vec<SealedRow> = sqlx::query_as(concat!(
            "SELECT ",
            item_columns!(),
            ", sealed FROM vault_items \
             WHERE user_id = $1 AND name = ANY($3) \
               AND (cardinality(instance_ids) = 0 OR $2 = ANY(instance_ids)) \
             ORDER BY name"
        ))
        .bind(user.0)
        .bind(instance.0)
        .bind(names)
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(SealedRow::into_sealed).collect())
    }

    /// 用户全部条目的密文：从运行日志里抹掉这些值（9.11）。
    pub async fn user_vault_items(&mut self, user: UserId) -> Result<Vec<SealedVaultItem>> {
        let rows: Vec<SealedRow> = sqlx::query_as(concat!(
            "SELECT ",
            item_columns!(),
            ", sealed FROM vault_items WHERE user_id = $1 ORDER BY name"
        ))
        .bind(user.0)
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(SealedRow::into_sealed).collect())
    }

    /// 记下条目最近一次被用的时间。
    pub async fn touch_vault_items(&mut self, ids: &[VaultItemId]) -> Result<()> {
        let ids: Vec<Uuid> = ids.iter().map(|i| i.0).collect();
        sqlx::query("UPDATE vault_items SET last_used_at = now() WHERE id = ANY($1)")
            .bind(&ids)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}
