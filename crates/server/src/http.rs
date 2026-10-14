//! 运维接口和所有接口共用的中间件。业务接口由接入网关模块（5.1）挂到这里。

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, http::header};
use proto::api::{self, ErrorBody, ErrorCode, ServerInfo};
use store::Db;

use crate::{READY_PING_TIMEOUT, ShutdownListener};

/// 这次请求协商出的接口版本，处理函数按它决定响应的形状。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // 业务接口（5.1）接入后使用
pub struct ApiVersion(pub u32);

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub shutdown: ShutdownListener,
}

/// 运维接口，加上（启用时的）客户端接口 `api`。
pub fn router(state: AppState, api: Option<Router>) -> Router {
    let ops = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/version", get(version))
        .with_state(state);
    ops.merge(api.unwrap_or_default())
        .fallback(not_found)
        .layer(middleware::from_fn(api_version))
        .layer(middleware::from_fn(crate::observability::track))
}

pub fn error(code: ErrorCode, message: impl Into<String>) -> Response {
    let status =
        StatusCode::from_u16(code.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(ErrorBody::new(code, message))).into_response()
}

/// 存活检查：进程能响应就算活着（停机过程中也是）。
async fn healthz() -> &'static str {
    "ok"
}

/// 就绪检查：停机中、数据库连不上都报 503，负载均衡据此摘除。
async fn readyz(State(state): State<AppState>) -> Response {
    if state.shutdown.is_shutting_down() {
        return error(ErrorCode::Unavailable, "shutting down");
    }
    match tokio::time::timeout(READY_PING_TIMEOUT, state.db.ping()).await {
        Ok(Ok(())) => "ready".into_response(),
        Ok(Err(e)) => {
            tracing::warn!(error = %e, "readiness: database ping failed");
            error(ErrorCode::Unavailable, "database unavailable")
        }
        Err(_) => error(ErrorCode::Unavailable, "database ping timed out"),
    }
}

async fn version() -> Json<ServerInfo> {
    Json(ServerInfo::current(env!("CARGO_PKG_VERSION")))
}

async fn not_found() -> Response {
    error(ErrorCode::NotFound, "no such endpoint")
}

/// 接口版本协商（见 proto::api）：太老的客户端拿到 426，其余在响应头里回实际采用的版本。
async fn api_version(req: Request, next: Next) -> Response {
    let declared = req
        .headers()
        .get(api::VERSION_HEADER)
        .map(|v| v.to_str().ok().and_then(|s| s.trim().parse::<u32>().ok()));
    let negotiated = match declared {
        None => api::negotiate(None),
        Some(Some(v)) => api::negotiate(Some(v)),
        Some(None) => {
            return error(
                ErrorCode::Invalid,
                format!("{} must be a positive integer", api::VERSION_HEADER),
            );
        }
    };
    let mut resp = match negotiated {
        Ok(v) => {
            let mut req = req;
            req.extensions_mut().insert(ApiVersion(v));
            next.run(req).await
        }
        Err(e) => error(ErrorCode::UpgradeRequired, e.to_string()),
    };
    let version = negotiated.unwrap_or(api::API_VERSION);
    resp.headers_mut()
        .insert(api::VERSION_HEADER, HeaderValue::from(version));
    resp.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    resp
}
