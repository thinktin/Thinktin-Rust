//! 客户端错误：按 [`proto::api::ErrorCode`] 分类，原生端据此决定重新登录、退避重试还是提示用户。

use proto::api::ErrorCode;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ClientError {
    /// 网络不通、超时：稍后重试，离线时用缓存。
    #[error("network: {message}")]
    Network { message: String },
    /// 没有登录，或登录已失效（刷新令牌被吊销、被重复使用、设备被远程下线）：回到登录页。
    #[error("signed out")]
    SignedOut,
    /// 客户端版本太老：提示升级。
    #[error("upgrade required")]
    UpgradeRequired,
    /// 账号被冻结（风控、运维，4.6）：提示联系客服。登录状态保留，解冻后接着用。
    #[error("account frozen")]
    AccountFrozen,
    /// 服务端返回的错误。`code` 是 [`ErrorCode`] 的字符串形式（not_found、conflict、invalid……）。
    #[error("{code}: {message}")]
    Api {
        status: u16,
        code: String,
        message: String,
        retry_after_secs: Option<u64>,
    },
    /// 响应解析失败（服务端和客户端版本不匹配）。
    #[error("bad response: {message}")]
    Decode { message: String },
    /// 本地缓存读写失败。
    #[error("cache: {message}")]
    Cache { message: String },
    /// 调用方传的参数不对（id 格式、枚举取值）。
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
    /// client-core 内部错误（后台任务异常退出）。
    #[error("internal: {message}")]
    Internal { message: String },
}

impl ClientError {
    pub fn network(e: impl std::fmt::Display) -> Self {
        Self::Network {
            message: e.to_string(),
        }
    }

    pub fn decode(e: impl std::fmt::Display) -> Self {
        Self::Decode {
            message: e.to_string(),
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
            message,
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
            message: e.to_string(),
        }
    }
}

pub type Result<T, E = ClientError> = std::result::Result<T, E>;
