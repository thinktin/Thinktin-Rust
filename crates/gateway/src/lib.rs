//! 接入网关（WBS 5.1–5.3、9.8）：客户端的 REST 接口和实例事件流（WebSocket，按序号续传）。
//!
//! - 鉴权：`Authorization: Bearer <访问令牌>`，每个请求核对会话（[`auth::service::AuthService::authenticate`]）。
//! - 所有业务查询都在用户的租户事务里做，RLS 兜底：即使漏了条件也看不到别人的数据。
//! - 错误统一成 [`proto::api::ErrorBody`]。

pub mod error;
mod extract;
mod hub;
mod routes;

use std::ops::Deref;
use std::sync::Arc;
use std::time::Duration;

use auth::service::AuthService;
use axum::Router;
use control::Templates;
use keyvault::Kms;
use store::Db;

pub use error::{ApiError, ApiResult};
pub use extract::{ApiJson, Authed};
pub use hub::EventHub;

#[derive(Debug, Clone)]
pub struct GatewayConfig {
    /// 新签发的运行授权的有效期。
    pub grant_ttl: Duration,
    /// 领养实例、建计划时默认给 agent 的平台工具。
    pub default_platform_tools: Vec<String>,
    /// 计划触发的最小间隔（按档位）。
    pub min_trigger_interval: Duration,
    /// 事件流心跳间隔（同时重新核对会话）。
    pub ws_heartbeat: Duration,
    /// 每次从库里取多少条事件。
    pub events_page: i64,
}

impl Default for GatewayConfig {
    fn default() -> Self {
        Self {
            grant_ttl: Duration::from_secs(90 * 24 * 3600),
            default_platform_tools: Vec::new(),
            min_trigger_interval: Duration::from_secs(5 * 60),
            ws_heartbeat: Duration::from_secs(25),
            events_page: 200,
        }
    }
}

pub struct Inner {
    pub db: Db,
    pub auth: Arc<AuthService>,
    pub templates: Arc<dyn Templates>,
    /// 用户 DEK 的包裹密钥（保存 key 时用；解密只在模型网关）。
    pub kms: Arc<dyn Kms>,
    pub hub: EventHub,
    /// 产出物存储；没配置时下载接口返回不可用。
    pub artifacts: Option<Arc<orchestrator::artifacts::ArtifactStore>>,
    pub cfg: GatewayConfig,
}

#[derive(Clone)]
pub struct AppState(Arc<Inner>);

impl AppState {
    pub fn new(inner: Inner) -> Self {
        Self(Arc::new(inner))
    }
}

impl Deref for AppState {
    type Target = Inner;
    fn deref(&self) -> &Inner {
        &self.0
    }
}

/// 全部 `/v1` 接口。
pub fn router(state: AppState) -> Router {
    routes::router().with_state(state)
}
