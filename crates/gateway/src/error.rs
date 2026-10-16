//! 接口错误：统一成 [`ErrorBody`]，内部错误只记日志，不把细节返回给客户端。

use axum::Json;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use proto::api::{ErrorBody, ErrorCode};
use tracing::error;

#[derive(Debug)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
    pub retry_after_secs: Option<u64>,
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retry_after_secs: None,
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Invalid, message)
    }

    pub fn not_found(what: &str) -> Self {
        Self::new(ErrorCode::NotFound, format!("{what} not found"))
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Conflict, message)
    }

    /// 内部错误：细节进日志，客户端只看到笼统的说法。
    pub fn internal(err: impl std::fmt::Display) -> Self {
        error!(error = %err, "internal error");
        Self::new(ErrorCode::Internal, "internal error")
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = StatusCode::from_u16(self.code.http_status())
            .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        let mut resp = (
            status,
            Json(ErrorBody {
                code: self.code,
                message: self.message,
                retry_after_secs: self.retry_after_secs,
            }),
        )
            .into_response();
        if let Some(secs) = self.retry_after_secs {
            resp.headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(secs));
        }
        resp
    }
}

impl From<store::Error> for ApiError {
    fn from(e: store::Error) -> Self {
        match e {
            store::Error::NotFound => Self::new(ErrorCode::NotFound, "not found"),
            store::Error::Conflict(m) => Self::conflict(m),
            store::Error::Invalid(m) => Self::invalid(m),
            store::Error::InvalidTransition { from, to } => {
                Self::conflict(format!("run is {from}, cannot become {to}"))
            }
            store::Error::LeaseLost { .. } => Self::conflict("changed concurrently, retry"),
            other => Self::internal(other),
        }
    }
}

impl From<auth::service::AuthError> for ApiError {
    fn from(e: auth::service::AuthError) -> Self {
        use auth::service::AuthError;
        match e {
            AuthError::TooManyCodes { retry_after_secs } => Self {
                retry_after_secs: Some(retry_after_secs),
                ..Self::new(ErrorCode::RateLimited, "too many codes requested")
            },
            AuthError::SignupLimited { retry_after_secs } => Self {
                retry_after_secs: Some(retry_after_secs),
                ..Self::new(
                    ErrorCode::RateLimited,
                    "too many new accounts from this network, try again later",
                )
            },
            AuthError::Store(s) => s.into(),
            AuthError::Token(t) => Self::internal(t),
            AuthError::Sms(s) => {
                error!(error = %s, "sms delivery failed");
                Self::new(
                    ErrorCode::Unavailable,
                    "could not send the code, try again later",
                )
            }
            other => Self::new(other.code(), other.to_string()),
        }
    }
}

impl From<crate::limits::Limited> for ApiError {
    fn from(l: crate::limits::Limited) -> Self {
        Self {
            retry_after_secs: Some(l.0),
            ..Self::new(ErrorCode::RateLimited, "too many requests, slow down")
        }
    }
}

impl From<control::Error> for ApiError {
    fn from(e: control::Error) -> Self {
        use control::Error;
        match e {
            Error::UnknownAgent(a) => Self::new(ErrorCode::NotFound, format!("unknown agent {a}")),
            Error::UnknownVersion { .. } | Error::Withdrawn { .. } | Error::Invalid(_) => {
                Self::invalid(e.to_string())
            }
            Error::Deleted => Self::not_found("instance"),
            Error::Busy => Self::conflict(e.to_string()),
            Error::Store(s) => s.into(),
            Error::Timeout(_) | Error::Sandbox(_) => {
                error!(error = %e, "sandbox operation failed");
                Self::new(
                    ErrorCode::Unavailable,
                    "sandbox is unavailable, try again later",
                )
            }
        }
    }
}
