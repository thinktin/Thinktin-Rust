//! 平台 ↔ 客户端接口的版本协商和错误模型（WBS 3.2、11.2）。
//!
//! 客户端每个请求带上 [`VERSION_HEADER`]（它说的接口版本），服务端回同一个头（实际采用的版本）：
//! - 客户端版本低于 [`MIN_SUPPORTED_API_VERSION`]：426，客户端提示升级；
//! - 客户端版本高于服务端：按服务端的版本说话，客户端按回来的版本降级（灰度发布时新客户端先于服务端）。

use serde::{Deserialize, Serialize};

/// 服务端当前的接口版本。只在不兼容的改动时加一；加字段、加接口不算。
pub const API_VERSION: u32 = 1;
/// 还支持的最老客户端版本。
pub const MIN_SUPPORTED_API_VERSION: u32 = 1;
pub const VERSION_HEADER: &str = "x-thinktin-api-version";

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("client api version {client} is older than the minimum supported {min}")]
pub struct VersionTooOld {
    pub client: u32,
    pub min: u32,
}

/// 按客户端声明的版本决定这次请求用哪个版本。没带头的（curl、健康检查）按当前版本。
pub fn negotiate(client: Option<u32>) -> Result<u32, VersionTooOld> {
    match client {
        None => Ok(API_VERSION),
        Some(v) if v < MIN_SUPPORTED_API_VERSION => Err(VersionTooOld {
            client: v,
            min: MIN_SUPPORTED_API_VERSION,
        }),
        Some(v) => Ok(v.min(API_VERSION)),
    }
}

/// 错误码：客户端按它决定怎么处理（重新登录、重试、提示），`message` 只给人看。以后会加新的码：客户端不认识的
/// 按 HTTP 状态给通用提示。数量到了上限的码都以 `_limit` 结尾（409，原样重试没用，删掉一些再建）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// 没登录或访问令牌过期：刷新令牌后重试。
    Unauthenticated,
    /// 刷新令牌失效（被吊销、被重复使用）：回到登录页。
    SessionRevoked,
    /// 账号被冻结（风控、运维，4.6）：提示联系客服。登录状态保留，解冻后接着用。
    AccountFrozen,
    Forbidden,
    NotFound,
    /// 和现有状态冲突（重复创建、并发修改、运行已结束）。
    Conflict,
    /// 请求不合法：参数、取值、状态迁移。
    Invalid,
    /// 限流：按 `retry_after_secs` 退避。
    RateLimited,
    /// 客户端太老：提示升级。
    UpgradeRequired,
    /// 暂时不可用（停机中、依赖故障）：退避重试。
    Unavailable,
    Internal,
    /// 实例数到了账号的上限（11.9）：删掉一个再领养。
    InstanceLimit,
}

impl ErrorCode {
    pub fn http_status(self) -> u16 {
        match self {
            Self::Unauthenticated | Self::SessionRevoked => 401,
            Self::AccountFrozen | Self::Forbidden => 403,
            Self::NotFound => 404,
            Self::Conflict | Self::InstanceLimit => 409,
            Self::Invalid => 422,
            Self::RateLimited => 429,
            Self::UpgradeRequired => 426,
            Self::Unavailable => 503,
            Self::Internal => 500,
        }
    }

    /// 客户端可以原样重试（退避后）。
    pub fn retryable(self) -> bool {
        matches!(self, Self::RateLimited | Self::Unavailable | Self::Internal)
    }

    /// 数量到了上限（`*_limit`）。
    pub fn is_limit(self) -> bool {
        matches!(self, Self::InstanceLimit)
    }
}

/// 所有错误响应的 JSON 结构。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: ErrorCode,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after_secs: Option<u64>,
}

impl ErrorBody {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retry_after_secs: None,
        }
    }
}

/// `GET /version`：客户端启动时拿来判断要不要提示升级。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerInfo {
    pub server_version: String,
    pub api_version: u32,
    pub min_api_version: u32,
    pub shim_protocol_version: u32,
}

impl ServerInfo {
    pub fn current(server_version: impl Into<String>) -> Self {
        Self {
            server_version: server_version.into(),
            api_version: API_VERSION,
            min_api_version: MIN_SUPPORTED_API_VERSION,
            shim_protocol_version: crate::shim::SHIM_PROTOCOL_VERSION,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiation() {
        assert_eq!(negotiate(None), Ok(API_VERSION));
        assert_eq!(negotiate(Some(API_VERSION)), Ok(API_VERSION));
        assert_eq!(
            negotiate(Some(API_VERSION + 5)),
            Ok(API_VERSION),
            "newer clients speak our version"
        );
        assert_eq!(
            negotiate(Some(0)),
            Err(VersionTooOld {
                client: 0,
                min: MIN_SUPPORTED_API_VERSION
            })
        );
    }

    #[test]
    fn error_body_json() {
        let body = ErrorBody::new(ErrorCode::SessionRevoked, "refresh token reused");
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({ "code": "session_revoked", "message": "refresh token reused" })
        );
        assert_eq!(ErrorCode::UpgradeRequired.http_status(), 426);
        assert_eq!(ErrorCode::AccountFrozen.http_status(), 403);
        assert_eq!(
            serde_json::to_value(ErrorCode::AccountFrozen).unwrap(),
            "account_frozen"
        );
        assert!(ErrorCode::Unavailable.retryable() && !ErrorCode::Invalid.retryable());
    }

    #[test]
    fn limit_codes() {
        let code = ErrorCode::InstanceLimit;
        assert_eq!(serde_json::to_value(code).unwrap(), "instance_limit");
        assert_eq!(
            serde_json::from_value::<ErrorCode>("instance_limit".into()).unwrap(),
            code
        );
        assert_eq!(code.http_status(), 409);
        assert!(code.is_limit() && !code.retryable());
        assert!(!ErrorCode::Conflict.is_limit() && !ErrorCode::RateLimited.is_limit());
    }
}
