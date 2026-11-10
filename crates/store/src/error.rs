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
    /// 实例专属于一个项目（8.16）：不接私人任务、不能派进别的项目（库里的约束 `instance_dedicated`）。接口回 409
    /// `instance_dedicated`。
    #[error("the instance is dedicated to a project")]
    InstanceDedicated,
    /// 派进跨用户项目的 agent 不是专属的，现在不收（8.16）：接口回 409 `agent_not_isolated`。
    #[error("the agent is not dedicated to this project")]
    AgentNotIsolated,
    /// 领养新实例（加入项目时当场领养专属的，8.16）超过了账号的实例数上限：接口回 409 `instance_limit`。
    #[error("instance limit {max}")]
    InstanceLimit { max: u64 },
    /// 项目里的这个 botin 现在接不了活（8.17）：主人的账号不能用了、主人不在项目里了；创建者给别人的 botin 派任务、开始
    /// 流水线时，主人的预算或限额用完了也是这个（不告诉是哪种）。接口回 409 `agent_unavailable`。
    #[error("the agent cannot take project work now")]
    AgentUnavailable,
    /// 这个 botin 排着的项目任务到了上限（8.17）：接口回 409 `agent_busy`。
    #[error("the agent has too many queued project tasks")]
    AgentBusy,
    /// 主人在项目里的预算或者给这个 botin 设的限额用完了（8.17，只在创建者给自己的 botin 派任务、开始流水线时）：接口回
    /// 409 `budget_reached`。
    #[error("the project budget for this agent is used up")]
    BudgetReached,
    /// 派单开关还关着（8.17，库里的约束 `project_dispatch_off`）：项目任务还没开，接口回 503。
    #[error("project dispatch is switched off")]
    DispatchOff,
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
        // 8.16 的触发器按约束名报的（`RAISE … CONSTRAINT`）。
        match db.constraint() {
            Some("instance_dedicated" | "instances_dedicated_no_peers") => {
                return Error::InstanceDedicated;
            }
            Some("instance_not_free") => {
                return Error::Conflict(format!("instance_not_free: {}", db.message()));
            }
            // 8.17 的派单栅栏（迁移 0060）。
            Some("project_dispatch_off") => return Error::DispatchOff,
            Some("project_agent_gone") => {
                return Error::Conflict(format!("project_agent_gone: {}", db.message()));
            }
            Some("project_delegate_not_lead") => {
                return Error::NotPermitted(db.message().to_owned());
            }
            _ => {}
        }
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
