//! 用户（4.1）。登录发生在有租户之前，所以建号、按手机号查找只在后台角色上。

use chrono::{DateTime, Utc};
use proto::domain::{Locale, User, UserId, UserStatus};
use uuid::Uuid;

use crate::{Result, Tenant, Tx, Worker, parse, unsigned};

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    phone: String,
    display_name: Option<String>,
    status: String,
    locale: String,
    created_at: DateTime<Utc>,
}

impl Row {
    fn into_user(self) -> Result<User> {
        Ok(User {
            id: self.id.into(),
            phone: self.phone,
            display_name: self.display_name,
            status: parse(&self.status)?,
            locale: parse(&self.locale)?,
            created_at: self.created_at,
        })
    }
}

macro_rules! columns {
    () => {
        "id, phone, display_name, status, locale, created_at"
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

    /// 按手机号（已规范化的 E.164）找没注销的账号。
    pub async fn user_by_phone(&mut self, phone: &str) -> Result<Option<User>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE phone = $1 AND status <> 'deleted'"
        ))
        .bind(phone)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_user).transpose()
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

/// 运维查看账号（4.6）：给客服用的概况，不含对话内容。
#[derive(Debug, Clone)]
pub struct AccountSummary {
    pub user: User,
    /// 没下线的设备。
    pub devices: u64,
    /// 没删除的实例。
    pub instances: u64,
    /// 没结束的运行。
    pub active_runs: u64,
    /// 在用的计划。
    pub active_plans: u64,
    /// 有效的运行授权。
    pub active_grants: u64,
    /// 最近一次登录。
    pub last_login_at: Option<DateTime<Utc>>,
}

impl Tx<Worker> {
    pub async fn account_summary(&mut self, id: UserId) -> Result<AccountSummary> {
        let user = self.user(id).await?;
        let (devices, instances, runs, plans, grants, last_login): (
            i64,
            i64,
            i64,
            i64,
            i64,
            Option<DateTime<Utc>>,
        ) = sqlx::query_as(
            "SELECT \
               (SELECT count(*) FROM devices WHERE user_id = $1 AND revoked_at IS NULL), \
               (SELECT count(*) FROM instances WHERE user_id = $1 AND state <> 'deleted'), \
               (SELECT count(*) FROM runs WHERE user_id = $1 \
                  AND state NOT IN ('succeeded', 'failed', 'cancelled')), \
               (SELECT count(*) FROM plans WHERE user_id = $1 AND status = 'active'), \
               (SELECT count(*) FROM run_grants WHERE user_id = $1 AND revoked_at IS NULL \
                  AND expires_at > now()), \
               (SELECT max(created_at) FROM sessions WHERE user_id = $1)",
        )
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        Ok(AccountSummary {
            user,
            devices: unsigned(devices, "device count")?,
            instances: unsigned(instances, "instance count")?,
            active_runs: unsigned(runs, "run count")?,
            active_plans: unsigned(plans, "plan count")?,
            active_grants: unsigned(grants, "grant count")?,
            last_login_at: last_login,
        })
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

    /// 注销（16.4）：销毁用户的 DEK（key、保险箱和产出物的密文从此解不开），删掉用户的内容
    /// （运行、提示词、摘要、事件、收件箱、计划、审批、团队、保险箱、产出物索引、推送记录；
    /// 产出物的密文排进清理队列，由后台从对象存储删掉），
    /// 手机号和设备信息去标识化，实例标记删除（沙箱和工作区卷由巡检回收）。
    /// 审计日志和用量记录只有 id 和计数，按网络日志的要求保留。
    pub async fn erase_account(&mut self, id: UserId) -> Result<()> {
        // 先锁住用户行：和正在给这个用户插数据的事务（调度器建运行、API 请求）互斥。
        // 外键检查拿的是 KEY SHARE 锁，这里的 FOR UPDATE 会等它们提交，后面的删除能看到它们的行。
        sqlx::query("SELECT 1 FROM users WHERE id = $1 FOR UPDATE")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        self.set_user_status(id, UserStatus::Deleted).await?;
        self.revoke_user_sessions(id, "account_deleted").await?;
        self.revoke_user_grants(id, "account_deleted").await?;
        for sql in [
            "DELETE FROM user_keys WHERE user_id = $1",
            "UPDATE credentials SET deleted_at = coalesce(deleted_at, now()), disabled = true, \
               sealed = ''::bytea, label = '', anthropic_base = NULL, openai_base = NULL, \
               responses_base = NULL, updated_at = now() WHERE user_id = $1",
            "DELETE FROM model_routes WHERE user_id = $1",
            // 运行删了，审批、产出物、带运行的事件一起级联删掉（产出物的密文排进 blob_purge）。
            "DELETE FROM runs WHERE user_id = $1",
            // 按实例删，走主键索引（事件表没有以 user_id 开头的索引）。
            "DELETE FROM events WHERE instance_id IN (SELECT id FROM instances WHERE user_id = $1)",
            // 计划删了，触发器、流水线步骤级联删掉。
            "DELETE FROM plans WHERE user_id = $1",
            "DELETE FROM inbox_items WHERE user_id = $1",
            // 送达的也删：载荷里有推送的标题和正文（运行摘要、工具调用标题）。
            "DELETE FROM outbox WHERE user_id = $1",
            "DELETE FROM teams WHERE user_id = $1",
            "DELETE FROM team_templates WHERE user_id = $1",
            "DELETE FROM vault_requests WHERE user_id = $1",
            "DELETE FROM vault_items WHERE user_id = $1",
            "UPDATE instances SET state = 'deleted', name = '', deleted_at = coalesce(deleted_at, now()), \
               updated_at = now() WHERE user_id = $1",
            "UPDATE devices SET name = '', push_channel = NULL, push_token = NULL WHERE user_id = $1",
            "UPDATE users SET phone = 'deleted', display_name = NULL WHERE id = $1",
        ] {
            sqlx::query(sql).bind(id.0).execute(self.conn()).await?;
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

    /// 推送、收件箱用的语言（1.6）。
    pub async fn set_locale(&mut self, locale: Locale) -> Result<()> {
        sqlx::query("UPDATE users SET locale = $1 WHERE id = app_user_id()")
            .bind(locale.as_str())
            .execute(self.conn())
            .await?;
        Ok(())
    }
}

impl<R> Tx<R> {
    /// 用户的语言（1.6）：服务端生成推送、收件箱文案时用。找不到用户按默认语言。
    pub async fn user_locale(&mut self, user: UserId) -> Result<Locale> {
        let locale: Option<String> = sqlx::query_scalar("SELECT locale FROM users WHERE id = $1")
            .bind(user.0)
            .fetch_optional(self.conn())
            .await?;
        Ok(locale.and_then(|l| l.parse().ok()).unwrap_or_default())
    }
}

impl<R: crate::Internal> Tx<R> {
    /// 用户的包裹 DEK：（KMS 主密钥 id，密文）。
    pub async fn user_key(&mut self, user: UserId) -> Result<Option<(String, Vec<u8>)>> {
        Ok(
            sqlx::query_as("SELECT kms_key_id, wrapped_dek FROM user_keys WHERE user_id = $1")
                .bind(user.0)
                .fetch_optional(self.conn())
                .await?,
        )
    }
}
