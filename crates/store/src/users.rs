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
