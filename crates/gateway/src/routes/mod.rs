//! `/v1` 接口。

mod account;
mod agents;
mod approvals;
mod artifacts;
mod credentials;
mod events;
mod inbox;
mod instances;
mod plans;
mod runs;
mod teams;
mod usage;
mod vendors;

use axum::Router;
use axum::routing::{delete, get, post, put};
use proto::domain::GrantScope;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        // 账号与设备（4.1、4.2）
        .route("/v1/auth/code", post(account::send_code))
        .route("/v1/auth/login", post(account::login))
        .route("/v1/auth/refresh", post(account::refresh))
        .route("/v1/auth/logout", post(account::logout))
        .route("/v1/me", get(account::me).patch(account::update_me))
        .route("/v1/me/code", post(account::send_self_code))
        .route("/v1/me/delete", post(account::delete_account))
        .route("/v1/me/stop-all", post(account::stop_all))
        .route("/v1/devices", get(account::devices))
        .route(
            "/v1/devices/sign-out-others",
            post(account::sign_out_others),
        )
        .route("/v1/devices/current/push", put(account::set_push))
        .route("/v1/devices/{id}", delete(account::revoke_device))
        // agent 目录
        .route("/v1/agents", get(agents::list))
        // 实例（6.4）
        .route("/v1/instances", get(instances::list).post(instances::adopt))
        .route(
            "/v1/instances/{id}",
            get(instances::get)
                .patch(instances::update)
                .delete(instances::delete),
        )
        .route("/v1/instances/{id}/version", post(instances::set_version))
        .route(
            "/v1/instances/{id}/routes",
            get(instances::routes).put(instances::set_routes),
        )
        // 运行
        .route(
            "/v1/instances/{id}/runs",
            get(runs::list).post(runs::create),
        )
        .route("/v1/runs/{id}", get(runs::get))
        .route("/v1/runs/{id}/cancel", post(runs::cancel))
        .route("/v1/runs/{id}/tree", get(runs::tree))
        // 计划与触发器（7.1）
        .route("/v1/plans", get(plans::list).post(plans::create))
        .route(
            "/v1/plans/{id}",
            get(plans::get).patch(plans::update).delete(plans::delete),
        )
        .route("/v1/plans/{id}/pause", post(plans::pause))
        .route("/v1/plans/{id}/resume", post(plans::resume))
        .route("/v1/plans/{id}/confirm", post(plans::confirm))
        .route("/v1/plans/{id}/triggers", post(plans::add_trigger))
        .route("/v1/triggers/{id}", delete(plans::delete_trigger))
        // 审批（4.7）
        .route("/v1/approvals", get(approvals::list))
        .route("/v1/approvals/{id}/decide", post(approvals::decide))
        // 模型 key（9.8）和预置厂商（9.12）
        .route("/v1/vendors", get(vendors::list))
        .route(
            "/v1/credentials",
            get(credentials::list).post(credentials::create),
        )
        .route(
            "/v1/credentials/{id}",
            axum::routing::patch(credentials::update).delete(credentials::delete),
        )
        .route(
            "/v1/credentials/{id}/secret",
            put(credentials::replace_secret),
        )
        // 团队（8.1）
        .route("/v1/teams", get(teams::list).post(teams::create))
        .route(
            "/v1/teams/{id}",
            get(teams::get).patch(teams::update).delete(teams::delete),
        )
        .route(
            "/v1/team-templates",
            get(teams::templates).post(teams::create_template),
        )
        .route("/v1/team-templates/{id}", delete(teams::delete_template))
        .route("/v1/team-templates/{id}/adopt", post(teams::adopt_template))
        // 产出物（8.4）
        .route("/v1/instances/{id}/artifacts", get(artifacts::for_instance))
        .route("/v1/runs/{id}/artifacts", get(artifacts::for_run))
        .route(
            "/v1/artifacts/{id}",
            get(artifacts::get).delete(artifacts::delete),
        )
        .route("/v1/artifacts/{id}/content", get(artifacts::content))
        // 用量看板（9.10）
        .route("/v1/usage", get(usage::summary))
        // 收件箱（10.4）
        .route("/v1/inbox", get(inbox::list))
        .route("/v1/inbox/read", post(inbox::mark_read))
        .route("/v1/inbox/{id}", get(inbox::get).delete(inbox::delete))
        .route("/v1/inbox/{id}/unread", post(inbox::mark_unread))
        // 事件流（5.2、5.3）
        .route("/v1/instances/{id}/events", get(events::page))
        .route("/v1/instances/{id}/events/ws", get(events::stream))
}

/// 新签发的运行授权的范围（领养实例、新建计划、“全部停止”之后重新签发）。
pub(crate) fn default_scope(s: &AppState) -> GrantScope {
    GrantScope {
        platform_tools: s.cfg.default_platform_tools.clone(),
        ..GrantScope::default()
    }
}

/// 路径里的 id 解析失败时返回 404（不区分“格式不对”和“不存在”）。
pub(crate) fn parse_id<T: std::str::FromStr>(raw: &str, what: &str) -> Result<T, crate::ApiError> {
    raw.parse().map_err(|_| crate::ApiError::not_found(what))
}

/// 检查文本长度（按字符）。
pub(crate) fn check_len(
    field: &str,
    value: &str,
    min: usize,
    max: usize,
) -> Result<(), crate::ApiError> {
    let n = value.chars().count();
    if n < min || n > max {
        return Err(crate::ApiError::invalid(format!(
            "{field} must be {min}-{max} characters"
        )));
    }
    Ok(())
}
