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
mod board;
mod credentials;
mod device_relay;
mod egress;
mod error;
mod events;
mod grants;
mod hooks;
mod im_channels;
mod inbox;
mod instances;
mod live_activities;
mod llmgw;
mod outbox;
mod plans;
mod project_dispatch;
mod project_invites;
mod project_lifecycle;
mod project_members;
mod project_reads;
mod projects;
mod reports;
mod runs;
mod schema;
mod search;
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
pub use artifacts::{ArtifactScope, MAX_LISTED_ARTIFACTS, NewArtifact, StoredArtifact};
pub use board::{
    BOARD_ARCHIVE_RETENTION, BoardFilter, NewBoardPost, check_board_body, normalize_board_tags,
};
pub use credentials::{NewCredential, SealedCredential};
pub use device_relay::{
    ClaimedCall, DEVICE_CALL_CHANNEL, DEVICE_CHANNEL, DeviceCallRecord, LINK_FRESH, NewDeviceCall,
    NewLink,
};
pub use egress::{AskMeta, EgressAsk, EgressLogEntry, EgressNotice};
pub use error::{Error, ProjectCap, Result};
pub use events::EVENTS_CHANNEL;
pub use hooks::{HookActivity, HookLock, HookTarget, MAX_HOOKS_PER_PLAN};
pub use im_channels::{ImChannelChange, ImSlot, ImWebhook, NewImChannel, SealedImChannel};
pub use inbox::NewInboxItem;
pub use instances::{
    InstanceChange, InstanceRuntime, NewInstance, Peer, RestoringSandbox, RetiredWorkspace,
    WorkspaceArchive,
};
pub use live_activities::{LiveActivity, LiveSettle};
pub use llmgw::{GatewayInstance, GatewayRoute};
pub use outbox::{NewOutboxItem, OutboxItem};
pub use plans::{DueTrigger, NewPlan, RetiredPlans};
pub use project_invites::{
    Accepted, Consent, CreatedInvite, InviteCaps, InviteKey, JoinAgent, JoinTerms,
};
pub use project_lifecycle::DeletedProject;
pub use project_members::{Exit, Withdrawn};
pub use project_reads::{ProjectRunFilter, ProjectTx};
pub use projects::{ProjectRecord, SoloAgent};
pub use reports::{NewReport, ReportRecord};
pub use runs::{
    ANSWER_TIMEOUT_REASON, ASKER_GONE_REASON, INTERRUPTED_REASON, ModelCall, NewRun, RunChange,
    RunFilter, RunRecord, Urgent,
};
pub use schema::MigrationStatus;
pub use search::SearchReserve;
pub use sessions::{LoginCode, SessionRecord, SessionState};
pub use usage::{NewUsage, UsageBucket, UsageFilter, UsageGroup};
pub use users::AccountSummary;
pub use vault::{NewVaultItem, NewVaultRequest, SealedVaultItem, VaultItemChange};

/// 业务事务里单条语句的上限：防止慢查询拖住连接池。
const TENANT_STATEMENT_TIMEOUT: &str = "15s";
/// 后台任务的语句上限（分区维护、批量扫描可能慢一些）。
const WORKER_STATEMENT_TIMEOUT: &str = "60s";

/// 这一版程序能把项目运行隔离到哪一级（8.16，迁移 0055 的 runs_isolation）：1 是只领专属于这个项目的实例上的项目运行
/// （整个沙箱只属于这个项目）；混用实例的项目运行要 2 级，还没有程序做得到。`Db::worker` 把它设进
/// `thinktin.isolation`，库里拿项目运行的租约时核对；上一版的程序不设，库里就一个项目运行都不让它拿。
pub const ISOLATION_LEVEL: u8 = 1;

/// 这一版程序的项目协议（8.17，迁移 0060）：2 是跨主人的运行树、项目授权、项目里的协作工具。`Db::worker` 把它设进
/// `thinktin.project_protocol`；写项目运行、项目授权，拿项目运行的租约都要 2（8.16 的程序不设，碰不到 8.17 的项目运行）。
pub const PROJECT_PROTOCOL: u8 = 2;

/// 连接的 application_name：带着隔离级别和项目协议（派单开关打开之前，运维按它数还有没有老副本连着，
/// [`Db::legacy_sessions`]）。
pub const APPLICATION_NAME: &str = "thinktin/i1p2";

/// “全部停止”吊销授权时记的原因（4.6）：项目里的常设授权因为它被吊销的，主人在项目里点“恢复”之前不重新签发（8.17）。
pub const STOP_ALL_REASON: &str = "stop_all";

/// 新工作区的 id（领养、换工作区时用；和 control 里领养时的写法一样）。
pub fn new_workspace_id() -> String {
    format!("ws-{}", uuid::Uuid::now_v7().simple())
}

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
            .connect_with(options.application_name(APPLICATION_NAME))
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

    /// 后台任务的事务（绕过 RLS）。带着这一版能隔离到哪一级（[`ISOLATION_LEVEL`]）和项目协议（[`PROJECT_PROTOCOL`]）：
    /// 库里写项目运行、项目授权，拿项目运行的租约时核对。
    pub async fn worker(&self) -> Result<Tx<Worker>> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "SELECT set_config('role', 'thinktin_worker', true), set_config('statement_timeout', $1, true), \
             set_config('thinktin.isolation', $2, true), set_config('thinktin.project_protocol', $3, true)",
        )
        .bind(WORKER_STATEMENT_TIMEOUT)
        .bind(ISOLATION_LEVEL.to_string())
        .bind(PROJECT_PROTOCOL.to_string())
        .execute(&mut *tx)
        .await?;
        Ok(Tx { tx, role: Worker })
    }

    /// 打开派单开关之前看还有没有老副本连着（8.17，只作参考）：同一个登录账号、同一个库里，连接名不是这一版的
    /// [`APPLICATION_NAME`] 的连接，按连接名数。在登录账号自己的连接上查，不切角色（切到 worker 以后看不到别的连接的
    /// 状态）。模型网关、中继用别的登录账号，不算在里面。
    pub async fn legacy_sessions(&self) -> Result<Vec<(String, i64)>> {
        Ok(sqlx::query_as(
            "SELECT coalesce(a.application_name, ''), count(*)::bigint FROM pg_stat_activity a \
              WHERE a.datname = current_database() \
                AND a.usesysid = (SELECT oid FROM pg_roles WHERE rolname = session_user) \
                AND a.pid <> pg_backend_pid() AND a.application_name IS DISTINCT FROM $1 \
              GROUP BY 1 ORDER BY 1",
        )
        .bind(APPLICATION_NAME)
        .fetch_all(&self.pool)
        .await?)
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

    /// 项目成员的只读事务（8.15）：thinktin_member、READ ONLY、REPEATABLE READ（详情的几句查询看同一个快照）。只设
    /// app.user_id：读得到哪些项目由库里的 member_projects() 按它算，没有“当前项目”这种设置。
    pub async fn member(&self, user: UserId) -> Result<ProjectTx> {
        let mut tx = self
            .pool
            .begin_with("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .await?;
        sqlx::query(
            "SELECT set_config('role', 'thinktin_member', true), set_config('app.user_id', $1, true), \
             set_config('statement_timeout', $2, true)",
        )
        .bind(user.to_string())
        .bind(TENANT_STATEMENT_TIMEOUT)
        .execute(&mut *tx)
        .await?;
        Ok(ProjectTx::new(tx, user))
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

    /// 事务里的保存点：一条语句被库里拒绝后事务就作废了，要接着用这个事务（比如一批里只让一项失败）就先建保存点，
    /// 失败时 [`Self::rollback_to_savepoint`]，成功时 [`Self::release_savepoint`]。名字是固定的标识符。
    pub async fn savepoint(&mut self, name: &'static str) -> Result<()> {
        sqlx::query(sqlx::AssertSqlSafe(format!("SAVEPOINT {name}")))
            .execute(self.conn())
            .await?;
        Ok(())
    }

    pub async fn release_savepoint(&mut self, name: &'static str) -> Result<()> {
        sqlx::query(sqlx::AssertSqlSafe(format!("RELEASE SAVEPOINT {name}")))
            .execute(self.conn())
            .await?;
        Ok(())
    }

    pub async fn rollback_to_savepoint(&mut self, name: &'static str) -> Result<()> {
        sqlx::query(sqlx::AssertSqlSafe(format!("ROLLBACK TO SAVEPOINT {name}")))
            .execute(self.conn())
            .await?;
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
