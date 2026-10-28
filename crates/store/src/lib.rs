//! 数据访问层（WBS 3.2、3.3）：迁移、按角色开启的事务、各张表的仓储。
//!
//! 每个事务开头切换数据库角色：
//! - [`Db::tenant`]：`thinktin_app`，并设置当前用户，行级安全（RLS）保证只能读写这个用户的数据。
//!   业务接口一律用它；即使代码漏写了 `user_id` 条件，也读不到别人的数据。
//! - [`Db::worker`]：`thinktin_worker`，绕过 RLS，给调度、租约、出箱投递、登录流程这些后台任务用。
//!
//! 仓储方法挂在 [`Tx<Tenant>`] / [`Tx<Worker>`] 上，后台专用的操作（领取运行、扫描到点触发器）
//! 只在 `Tx<Worker>` 上有，业务接口拿不到。

mod approvals;
mod artifacts;
mod credentials;
mod device_relay;
mod error;
mod events;
mod grants;
mod im_channels;
mod inbox;
mod instances;
mod live_activities;
mod llmgw;
mod outbox;
mod plans;
mod reports;
mod runs;
mod schema;
mod sessions;
mod teams;
mod tool_calls;
mod usage;
mod users;
mod vault;

#[cfg(any(test, feature = "testing"))]
pub mod testing;

#[cfg(test)]
mod tests;

use std::time::Duration;

use proto::domain::UserId;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{PgConnection, PgPool, Postgres, Transaction};

pub use approvals::{ApprovalRecord, NewApproval, approval_key, split_approval_key};
pub use artifacts::{NewArtifact, StoredArtifact};
pub use credentials::{NewCredential, SealedCredential};
pub use device_relay::{
    ClaimedCall, DEVICE_CALL_CHANNEL, DEVICE_CHANNEL, DeviceCallRecord, LINK_FRESH, NewDeviceCall,
    NewLink,
};
pub use error::{Error, Result};
pub use events::EVENTS_CHANNEL;
pub use im_channels::{ImChannelChange, ImSlot, ImWebhook, NewImChannel, SealedImChannel};
pub use inbox::NewInboxItem;
pub use instances::{InstanceRuntime, NewInstance, RestoringSandbox, WorkspaceArchive};
pub use live_activities::{LiveActivity, LiveSettle};
pub use llmgw::{GatewayInstance, GatewayRoute};
pub use outbox::{NewOutboxItem, OutboxItem};
pub use plans::{DueTrigger, NewPlan, RetiredPlans};
pub use reports::{NewReport, ReportRecord};
pub use runs::{ModelCall, NewRun, RunChange, RunFilter, RunRecord};
pub use schema::MigrationStatus;
pub use sessions::{LoginCode, SessionRecord, SessionState};
pub use usage::{NewUsage, UsageBucket, UsageFilter, UsageGroup};
pub use users::AccountSummary;
pub use vault::{NewVaultItem, NewVaultRequest, SealedVaultItem, VaultItemChange};

/// 业务事务里单条语句的上限：防止慢查询拖住连接池。
const TENANT_STATEMENT_TIMEOUT: &str = "15s";
/// 后台任务的语句上限（分区维护、批量扫描可能慢一些）。
const WORKER_STATEMENT_TIMEOUT: &str = "60s";

#[derive(Debug, Clone)]
pub struct Db {
    pool: PgPool,
}

impl Db {
    /// 连接数据库。`max_connections` 按副本数和 Postgres 的连接上限分配。
    pub async fn connect(url: &str, max_connections: u32) -> Result<Self> {
        let options: PgConnectOptions = url.parse()?;
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(options.application_name("thinktin"))
            .await?;
        Ok(Self { pool })
    }

    pub fn from_pool(pool: PgPool) -> Self {
        Self { pool }
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// 就绪检查。
    pub async fn ping(&self) -> Result<()> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    /// 以某个用户的身份开启事务（受 RLS 约束）。
    pub async fn tenant(&self, user: UserId) -> Result<Tx<Tenant>> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "SELECT set_config('role', 'thinktin_app', true), set_config('app.user_id', $1, true), \
             set_config('statement_timeout', $2, true)",
        )
        .bind(user.to_string())
        .bind(TENANT_STATEMENT_TIMEOUT)
        .execute(&mut *tx)
        .await?;
        Ok(Tx {
            tx,
            role: Tenant { user },
        })
    }

    /// 后台任务的事务（绕过 RLS）。
    pub async fn worker(&self) -> Result<Tx<Worker>> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "SELECT set_config('role', 'thinktin_worker', true), set_config('statement_timeout', $1, true)",
        )
        .bind(WORKER_STATEMENT_TIMEOUT)
        .execute(&mut *tx)
        .await?;
        Ok(Tx { tx, role: Worker })
    }

    /// 模型网关的事务：只读路由数据、写用量（绕过 RLS，但表权限很窄）。
    pub async fn llmgw(&self) -> Result<Tx<Llmgw>> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "SELECT set_config('role', 'thinktin_llmgw', true), set_config('statement_timeout', $1, true)",
        )
        .bind(TENANT_STATEMENT_TIMEOUT)
        .execute(&mut *tx)
        .await?;
        Ok(Tx { tx, role: Llmgw })
    }

    /// 设备中继的事务（14.1）：核对设备会话、维护电脑的在线状态、领取和回填工具调用、收发消息
    /// （绕过 RLS，但表权限很窄）。
    pub async fn relay(&self) -> Result<Tx<Relay>> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "SELECT set_config('role', 'thinktin_relay', true), set_config('statement_timeout', $1, true)",
        )
        .bind(TENANT_STATEMENT_TIMEOUT)
        .execute(&mut *tx)
        .await?;
        Ok(Tx { tx, role: Relay })
    }
}

/// 一个数据库事务，带着它的角色。没有提交就丢弃时回滚。
pub struct Tx<R> {
    tx: Transaction<'static, Postgres>,
    role: R,
}

/// 业务接口：当前用户。
#[derive(Debug, Clone, Copy)]
pub struct Tenant {
    user: UserId,
}

/// 后台任务。
#[derive(Debug, Clone, Copy)]
pub struct Worker;

/// 模型网关。
#[derive(Debug, Clone, Copy)]
pub struct Llmgw;

/// 设备中继。
#[derive(Debug, Clone, Copy)]
pub struct Relay;

/// 平台内部的角色（后台任务、模型网关）：能读 key 的密文和用户的包裹 DEK、写用量。
pub trait Internal {}
impl Internal for Worker {}
impl Internal for Llmgw {}

/// 能核对设备会话的角色（登录流程、设备中继）。
pub trait SessionCheck {}
impl SessionCheck for Worker {}
impl SessionCheck for Relay {}

impl<R> Tx<R> {
    /// 数据库的当前时间（事务开始的时间）：和库里记下的时间比较时用，不受各副本时钟偏差影响。
    pub async fn db_now(&mut self) -> Result<chrono::DateTime<chrono::Utc>> {
        Ok(sqlx::query_scalar("SELECT now()")
            .fetch_one(self.conn())
            .await?)
    }

    pub async fn commit(self) -> Result<()> {
        self.tx.commit().await?;
        Ok(())
    }

    pub async fn rollback(self) -> Result<()> {
        self.tx.rollback().await?;
        Ok(())
    }

    fn conn(&mut self) -> &mut PgConnection {
        &mut self.tx
    }
}

impl Tx<Tenant> {
    pub fn user(&self) -> UserId {
        self.role.user
    }
}

/// 数据库里的非负计数转成无符号数；负数说明数据坏了。
fn unsigned(v: i64, what: &str) -> Result<u64> {
    u64::try_from(v).map_err(|_| Error::Corrupt(format!("negative {what}: {v}")))
}

fn signed(v: u64, what: &str) -> Result<i64> {
    i64::try_from(v).map_err(|_| Error::Invalid(format!("{what} too large: {v}")))
}

fn parse<T: std::str::FromStr>(s: &str) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    s.parse().map_err(|e: T::Err| Error::Corrupt(e.to_string()))
}

fn from_json<T: serde::de::DeserializeOwned>(v: serde_json::Value, what: &str) -> Result<T> {
    serde_json::from_value(v).map_err(|e| Error::Corrupt(format!("{what}: {e}")))
}

fn to_json<T: serde::Serialize>(v: &T) -> Result<serde_json::Value> {
    serde_json::to_value(v).map_err(|e| Error::Invalid(e.to_string()))
}

/// 时长转成 Postgres 能直接和 timestamptz 相加的秒数。
fn secs(d: Duration) -> f64 {
    d.as_secs_f64()
}
