//! 可观测性（WBS 2.8）：Prometheus 指标。业务模块用 `metrics` 宏记，这里装全局的记录器、
//! 记每个 HTTP 请求，在单独的端口上提供 `/metrics`（只给内网的抓取方，不经负载均衡）。
//!
//! 日志方面：每次运行的日志挂在 `run` span 下（编排模块），密钥类的值都有打码的调试输出（见 docs/security-audit.md）。

use std::sync::OnceLock;
use std::time::Instant;

use axum::Router;
use axum::extract::{MatchedPath, Request};
use axum::middleware::Next;
use axum::response::Response;
use axum::routing::get;
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder, PrometheusHandle};
use tracing::warn;

/// 时长类指标的分桶（秒）：从毫秒级的接口到几小时的运行。
const BUCKETS: &[f64] = &[
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 300.0, 900.0,
    3600.0, 7200.0,
];

static HANDLE: OnceLock<Option<PrometheusHandle>> = OnceLock::new();

/// 全局记录器（进程里只装一次）。装不上（已经有别的记录器）时为空，指标宏照常调用、什么都不记。
pub fn handle() -> Option<PrometheusHandle> {
    HANDLE
        .get_or_init(|| {
            PrometheusBuilder::new()
                .set_buckets_for_metric(Matcher::Suffix("_seconds".into()), BUCKETS)
                .and_then(PrometheusBuilder::install_recorder)
                .map_err(|e| warn!(error = %e, "metrics recorder not installed"))
                .ok()
        })
        .clone()
}

/// 每个请求记一次：按路由模板（不按具体 id）、方法、状态码。
pub async fn track(req: Request, next: Next) -> Response {
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|p| p.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".into());
    let method = req.method().as_str().to_owned();
    let started = Instant::now();
    let resp = next.run(req).await;
    let status = resp.status().as_u16().to_string();
    metrics::counter!(
        "thinktin_http_requests_total",
        "route" => route.clone(),
        "method" => method,
        "status" => status
    )
    .increment(1);
    metrics::histogram!("thinktin_http_request_seconds", "route" => route)
        .record(started.elapsed().as_secs_f64());
    resp
}

/// `/metrics`。
pub fn router(handle: PrometheusHandle) -> Router {
    Router::new().route(
        "/metrics",
        get(move || {
            let handle = handle.clone();
            async move { handle.render() }
        }),
    )
}
