use proto::domain::RunState;

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// 没有这一行，或者 RLS 下看不到（对调用方来说两者一样，不泄露别人的数据是否存在）。
    #[error("not found")]
    NotFound,
    /// 唯一约束冲突，或者并发修改导致条件不再成立。
    #[error("conflict: {0}")]
    Conflict(String),
    /// 引用了不存在（或属于别人）的对象、违反检查约束、取值非法。
    #[error("invalid: {0}")]
    Invalid(String),
    /// 运行状态机不允许的迁移。
    #[error("run cannot go from {from} to {to}")]
    InvalidTransition { from: RunState, to: RunState },
    /// 执行租约不在调用方手里。
    #[error("lease is not held by {owner}")]
    LeaseLost { owner: String },
    /// 权限不足或违反 RLS 策略：说明代码用错了角色，属于程序错误。
    #[error("forbidden: {0}")]
    Forbidden(String),
    /// 库里的数据不符合预期（枚举取值、JSON 结构）。
    #[error("corrupt row: {0}")]
    Corrupt(String),
    /// 项目人数、agent 数、待处理邀请数到了上限（8.14）：接口回 409 `project_member_limit` / `project_agent_limit` /
    /// `project_invite_limit`。
    #[error("project limit: {0:?}")]
    ProjectLimit(ProjectCap),
    /// 按时间窗数的上限（每个邀请人 24 小时的邀请数）：接口回 429，过这么多秒再试。
    #[error("retry after {0}s")]
    RetryAfter(u64),
    /// 是成员，但这件事只有创建者（或 agent 的主人）能做：接口回 403。
    #[error("not permitted: {0}")]
    NotPermitted(String),
    #[error(transparent)]
    Migrate(#[from] sqlx::migrate::MigrateError),
    /// 数据库的迁移和程序对不上（2.9）：缺这一版要的迁移、发布过的迁移被改过、迁移执行了一半。
    #[error("{0}")]
    Schema(String),
    #[error(transparent)]
    Db(sqlx::Error),
}

/// 项目的哪一项到了上限（[`Error::ProjectLimit`]）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectCap {
    Members,
    Agents,
    PendingInvites,
}

impl From<sqlx::Error> for Error {
    fn from(e: sqlx::Error) -> Self {
        if let sqlx::Error::RowNotFound = e {
            return Error::NotFound;
        }
        let Some(db) = e.as_database_error() else {
            return Error::Db(e);
        };
        let what = || db.constraint().unwrap_or(db.message()).to_owned();
        match db.code().as_deref() {
            Some("23505") => Error::Conflict(what()),
            // 外键：复合外键挡住了跨用户引用时也走这里。
            Some("23503") => Error::Invalid(format!("reference {}", what())),
            Some("23514" | "23502" | "22P02" | "22007" | "22008") => Error::Invalid(what()),
            Some("42501") => Error::Forbidden(db.message().to_owned()),
            // 只读事务里写（项目成员的 ProjectTx，8.15）：和没有权限一样，是程序用错了事务。
            Some("25006") => Error::Forbidden(db.message().to_owned()),
            _ => Error::Db(e),
        }
    }
}

impl Error {
    /// 唯一约束冲突（调用方据此判断“已经存在”）。
    pub fn is_conflict(&self) -> bool {
        matches!(self, Error::Conflict(_))
    }
}
