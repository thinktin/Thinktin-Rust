//! 用户（4.1）。登录发生在有租户之前，所以建号、按手机号查找只在后台角色上。

use chrono::{DateTime, Utc};
use proto::domain::{User, UserId, UserStatus};
use uuid::Uuid;

use crate::{Result, Tenant, Tx, Worker, parse};

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    phone: String,
    display_name: Option<String>,
    status: String,
    created_at: DateTime<Utc>,
}

impl Row {
    fn into_user(self) -> Result<User> {
        Ok(User {
            id: self.id.into(),
            phone: self.phone,
            display_name: self.display_name,
            status: parse(&self.status)?,
            created_at: self.created_at,
        })
    }
}

macro_rules! columns {
    () => {
        "id, phone, display_name, status, created_at"
    };
}

impl Tx<Worker> {
    /// 按手机号（已规范化的 E.164）找到账号，没有就新建。返回账号和是否新建。
    /// 冻结的账号照样返回，由调用方决定能不能登录。
    pub async fn upsert_user_by_phone(&mut self, phone: &str) -> Result<(User, bool)> {
        let inserted: Option<Row> = sqlx::query_as(concat!(
            "INSERT INTO users (id, phone) VALUES ($1, $2) \
             ON CONFLICT (phone) WHERE status <> 'deleted' DO NOTHING \
             RETURNING ",
            columns!()
        ))
        .bind(UserId::new().0)
        .bind(phone)
        .fetch_optional(self.conn())
        .await?;
        if let Some(row) = inserted {
            return Ok((row.into_user()?, true));
        }
        // 并发插入时 DO NOTHING 会等对方提交；读已提交隔离级别下这里能看到对方的行。
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE phone = $1 AND status <> 'deleted'"
        ))
        .bind(phone)
        .fetch_one(self.conn())
        .await?;
        Ok((row.into_user()?, false))
    }

    pub async fn user(&mut self, id: UserId) -> Result<User> {
        let row: Row = sqlx::query_as(concat!("SELECT ", columns!(), " FROM users WHERE id = $1"))
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        row.into_user()
    }

    /// 冻结、解冻、注销。
    pub async fn set_user_status(&mut self, id: UserId, status: UserStatus) -> Result<()> {
        let done = sqlx::query(
            "UPDATE users SET status = $2, \
               frozen_at = CASE WHEN $2 = 'frozen' THEN now() ELSE NULL END, \
               deleted_at = CASE WHEN $2 = 'deleted' THEN now() ELSE deleted_at END \
             WHERE id = $1 AND status <> 'deleted'",
        )
        .bind(id.0)
        .bind(status.as_str())
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(crate::Error::NotFound);
        }
        Ok(())
    }
}

impl Tx<Worker> {
    /// 保存用户的包裹 DEK（第一次存 key 时由密钥库生成）。已经有了返回冲突。
    pub async fn insert_user_key(
        &mut self,
        user: UserId,
        kms_key_id: &str,
        wrapped_dek: &[u8],
    ) -> Result<()> {
        sqlx::query("INSERT INTO user_keys (user_id, kms_key_id, wrapped_dek) VALUES ($1, $2, $3)")
            .bind(user.0)
            .bind(kms_key_id)
            .bind(wrapped_dek)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 用户的包裹 DEK：（KMS 主密钥 id，密文）。
    pub async fn user_key(&mut self, user: UserId) -> Result<Option<(String, Vec<u8>)>> {
        Ok(
            sqlx::query_as("SELECT kms_key_id, wrapped_dek FROM user_keys WHERE user_id = $1")
                .bind(user.0)
                .fetch_optional(self.conn())
                .await?,
        )
    }

    /// 注销账号（4.1）：吊销全部会话、设备、运行授权，删掉包裹的 DEK（密文随之无法解密，即“注销即销毁”），
    /// 清掉 key 密文，实例标记删除（沙箱由生命周期管理回收），账号标记注销（手机号可以重新注册）。
    pub async fn erase_account(&mut self, id: UserId) -> Result<()> {
        self.set_user_status(id, UserStatus::Deleted).await?;
        self.revoke_user_sessions(id, "account_deleted").await?;
        self.revoke_user_grants(id, "account_deleted").await?;
        sqlx::query("DELETE FROM user_keys WHERE user_id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        sqlx::query(
            "UPDATE credentials SET deleted_at = coalesce(deleted_at, now()), disabled = true, sealed = ''::bytea, \
               updated_at = now() WHERE user_id = $1",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        sqlx::query("DELETE FROM model_routes WHERE user_id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        sqlx::query(
            "UPDATE instances SET state = 'deleted', deleted_at = coalesce(deleted_at, now()), updated_at = now() \
             WHERE user_id = $1",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "UPDATE runs SET state = 'cancelled', state_reason = 'account deleted', lease_owner = NULL, \
               lease_expires_at = NULL, finished_at = now(), updated_at = now() \
             WHERE user_id = $1 AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        sqlx::query("UPDATE plans SET status = 'deleted', updated_at = now() WHERE user_id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        sqlx::query("UPDATE triggers SET enabled = false, updated_at = now() WHERE user_id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}

impl Tx<Tenant> {
    /// 当前用户自己。
    pub async fn me(&mut self) -> Result<User> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE id = app_user_id()"
        ))
        .fetch_one(self.conn())
        .await?;
        row.into_user()
    }

    pub async fn set_display_name(&mut self, name: Option<&str>) -> Result<()> {
        sqlx::query("UPDATE users SET display_name = $1 WHERE id = app_user_id()")
            .bind(name)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}
