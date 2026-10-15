//! 请求提取：访问令牌 → 请求方；JSON 请求体解析失败也返回统一的错误结构。

use auth::service::Principal;
use axum::Json;
use axum::extract::{FromRequest, FromRequestParts, Request};
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use proto::api::ErrorCode;
use serde::de::DeserializeOwned;

use crate::{ApiError, AppState};

/// 通过核对的请求方。
pub struct Authed(pub Principal);

/// 取 `Authorization: Bearer` 里的令牌。
pub(crate) fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

impl FromRequestParts<AppState> for Authed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer(&parts.headers)
            .ok_or_else(|| ApiError::new(ErrorCode::Unauthenticated, "missing bearer token"))?;
        let who = state.auth.authenticate(token).await?;
        // 按设备、按用户限流（5.4）。
        state.limits().authed(who.user, who.device)?;
        Ok(Authed(who))
    }
}

/// 和 `Json` 一样，但解析失败时返回 [`ApiError`]。
pub struct ApiJson<T>(pub T);

impl<T: DeserializeOwned, S: Send + Sync> FromRequest<S> for ApiJson<T> {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, ApiError> {
        match Json::<T>::from_request(req, state).await {
            Ok(Json(v)) => Ok(ApiJson(v)),
            Err(rej) => Err(ApiError::invalid(rej.body_text())),
        }
    }
}
