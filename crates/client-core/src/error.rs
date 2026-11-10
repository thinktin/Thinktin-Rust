//! 客户端错误：按 [`proto::api::ErrorCode`] 分类，原生端据此决定重新登录、退避重试还是提示用户。

use proto::api::ErrorCode;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ClientError {
    /// 网络不通、超时：稍后重试，离线时用缓存。
    #[error("network: {detail}")]
    Network { detail: String },
    /// 没有登录，或登录已失效（刷新令牌被吊销、被重复使用、设备被远程下线）：回到登录页。
    #[error("signed out")]
    SignedOut,
    /// 客户端版本太老：提示升级。
    #[error("upgrade required")]
    UpgradeRequired,
    /// 账号被冻结（风控、运维，4.6）：提示联系客服。登录状态保留，解冻后接着用。
    #[error("account frozen")]
    AccountFrozen,
    /// 服务端返回的错误。`code` 是服务端给的错误码原样（[`ErrorCode`] 的字符串形式：not_found、conflict、invalid……），
    /// 这个版本不认识的码（服务端以后加的）也原样放进来，按 `status` 给通用提示。以 `_limit` 结尾的是数量到了上限
    /// （409，比如 `instance_limit`：删掉一个实例再领养；项目的 `project_member_limit`（10 个人）、`project_agent_limit`
    /// （30 个 agent）、`project_invite_limit`（20 个待处理的邀请））。8.16 的两个 409：`instance_dedicated`（这个 botin
    /// 专属于一个项目：不接私人消息、不进计划、不能放进别的项目）、`agent_not_isolated`（项目只收专属的 botin：标专属或
    /// 当场创建一个）。8.17 派项目任务、开始流水线时的三个 409：`agent_unavailable`（别人的 botin 现在接不了活：主人的账号
    /// 不能用了，或者主人的预算、限额用完了，不告诉是哪种）、`agent_busy`（它排着的项目任务太多，等一会儿）、
    /// `budget_reached`（只有自己的 botin：自己在项目里的预算或给它设的限额用完了）；项目的派单在服务端
    /// 还没打开时 503 `unavailable`；项目看板每人每天写满 50 条 429 `rate_limited`。
    #[error("{code}: {detail}")]
    Api {
        status: u16,
        code: String,
        /// 说明（服务端给的、或者 client-core 写的）。不叫 `message`：Kotlin 的异常类自带 `message`，同名会冲突。
        detail: String,
        retry_after_secs: Option<u64>,
    },
    /// 响应解析失败（服务端和客户端版本不匹配）。
    #[error("bad response: {detail}")]
    Decode { detail: String },
    /// 本地缓存读写失败。
    #[error("cache: {detail}")]
    Cache { detail: String },
    /// 消息里有像密码、key 的内容（11.6），没有发出去：提示用户存进保险箱，消息里换成引用
    /// （`detect_secrets`、`save_secret_from_message`），或者用户确认后带 `allow_secrets` 重发。
    #[error("the message looks like it contains {count} password(s) or key(s)")]
    ContainsSecrets { count: u32 },
    /// 调用方传的参数不对（id 格式、枚举取值）。
    #[error("invalid argument: {detail}")]
    InvalidArgument { detail: String },
    /// client-core 内部错误（后台任务异常退出）。
    #[error("internal: {detail}")]
    Internal { detail: String },
}

impl ClientError {
    pub fn network(e: impl std::fmt::Display) -> Self {
        Self::Network {
            detail: e.to_string(),
        }
    }

    pub fn decode(e: impl std::fmt::Display) -> Self {
        Self::Decode {
            detail: e.to_string(),
        }
    }

    pub fn api(
        status: u16,
        code: ErrorCode,
        message: String,
        retry_after_secs: Option<u64>,
    ) -> Self {
        let code = serde_json::to_value(code)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_else(|| "internal".into());
        Self::Api {
            status,
            code,
            detail: message,
            retry_after_secs,
        }
    }

    /// 退避后可以原样重试。
    pub fn retryable(&self) -> bool {
        match self {
            Self::Network { .. } => true,
            Self::Api { code, .. } => {
                matches!(code.as_str(), "rate_limited" | "unavailable" | "internal")
            }
            _ => false,
        }
    }

    /// 服务端说“没有这个对象”。
    pub fn is_not_found(&self) -> bool {
        matches!(self, Self::Api { code, .. } if code == "not_found")
    }
}

impl From<rusqlite::Error> for ClientError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Cache {
            detail: e.to_string(),
        }
    }
}

pub type Result<T, E = ClientError> = std::result::Result<T, E>;
