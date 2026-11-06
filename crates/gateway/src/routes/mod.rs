//! `/v1` 接口。

mod account;
mod agents;
mod approvals;
mod artifacts;
mod board;
mod credentials;
mod device_messages;
mod events;
mod hooks;
mod im_channels;
mod inbox;
mod instances;
mod plans;
mod project_invites;
mod project_runs;
mod projects;
mod reports;
mod runs;
mod teams;
mod usage;
mod vault;
mod vendors;

use axum::Router;
use axum::http::{HeaderValue, header};
use axum::response::Response;
use axum::routing::{delete, get, patch, post, put};
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
        .route(
            "/v1/devices/current/live-activity-start",
            put(account::set_live_activity_start).delete(account::clear_live_activity_start),
        )
        .route("/v1/devices/{id}", delete(account::revoke_device))
        // 手机和电脑之间的消息（14.1）
        .route(
            "/v1/devices/current/messages",
            get(device_messages::pending),
        )
        .route(
            "/v1/devices/current/messages/ack",
            post(device_messages::ack),
        )
        .route("/v1/devices/{id}/messages", post(device_messages::send))
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
        .route("/v1/instances/{id}/release", post(instances::release))
        .route("/v1/instances/{id}/egress", get(instances::egress))
        .route(
            "/v1/instances/{id}/egress/hosts/{host}",
            delete(instances::remove_egress_host),
        )
        .route("/v1/egress-requests", get(instances::egress_requests))
        .route(
            "/v1/egress-requests/{id}/decide",
            post(instances::decide_egress_request),
        )
        .route(
            "/v1/instances/{id}/routes",
            get(instances::routes).put(instances::set_routes),
        )
        // 运行
        .route(
            "/v1/instances/{id}/runs",
            get(runs::list).post(runs::create),
        )
        .route("/v1/runs", get(runs::list_all))
        .route("/v1/runs/{id}", get(runs::get))
        .route("/v1/runs/{id}/cancel", post(runs::cancel))
        .route("/v1/runs/{id}/tree", get(runs::tree))
        .route(
            "/v1/runs/{id}/live-activity",
            put(runs::register_live_activity).delete(runs::end_live_activity),
        )
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
        // 计划的 webhook（7.1 事件触发）：管理要登录，收事件不要（令牌在地址里）
        .route("/v1/plans/{id}/hooks", get(hooks::list).post(hooks::create))
        .route("/v1/hooks/{id}", patch(hooks::update).delete(hooks::delete))
        .route("/v1/hooks/{id}/rotate", post(hooks::rotate))
        .route("/v1/webhooks/{token}", post(hooks::receive))
        // 审批（4.7）
        .route("/v1/approvals", get(approvals::list))
        .route("/v1/approvals/{id}", get(approvals::get))
        .route("/v1/approvals/{id}/decide", post(approvals::decide))
        // 模型 key（9.8）和预置厂商（9.12）
        // 密码保险箱（9.11）
        .route("/v1/vault", get(vault::list).post(vault::create))
        .route("/v1/vault/requests", get(vault::requests))
        .route("/v1/vault/requests/{id}/fulfill", post(vault::fulfill))
        .route("/v1/vault/requests/{id}/decline", post(vault::decline))
        .route(
            "/v1/vault/{id}",
            get(vault::get).patch(vault::update).delete(vault::delete),
        )
        // IM 渠道（10.5）
        .route(
            "/v1/im-channels",
            get(im_channels::list).post(im_channels::create),
        )
        .route(
            "/v1/im-channels/{id}",
            axum::routing::patch(im_channels::update).delete(im_channels::delete),
        )
        .route(
            "/v1/im-channels/{id}/webhook",
            put(im_channels::replace_webhook),
        )
        .route("/v1/im-channels/{id}/test", post(im_channels::test))
        // 内容举报（5.5）
        .route("/v1/reports", get(reports::list).post(reports::create))
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
        // 共享看板（8.10）
        .route("/v1/board", get(board::list).post(board::create))
        .route("/v1/board/{id}", delete(board::delete))
        .route("/v1/board/{id}/archive", post(board::archive))
        .route("/v1/board/{id}/unarchive", post(board::unarchive))
        // 事件流（5.2、5.3）
        .route("/v1/instances/{id}/events", get(events::page))
        .route("/v1/instances/{id}/events/ws", get(events::stream))
        .merge(projects_router())
}

/// 项目、邀请与加入（8.14）、项目里的内容（8.15）：别人能看到的东西，响应一律不缓存（`Cache-Control: no-store`），
/// 离开、被移出之后设备上的缓存里也不留。
fn projects_router() -> Router<AppState> {
    Router::new()
        .route("/v1/projects", get(projects::list).post(projects::create))
        .route(
            "/v1/projects/{id}",
            get(projects::get)
                .patch(projects::update)
                .delete(projects::delete),
        )
        .route("/v1/projects/{id}/archive", post(projects::archive))
        .route("/v1/projects/{id}/unarchive", post(projects::unarchive))
        .route("/v1/projects/{id}/agents", post(projects::add_agents))
        .route(
            "/v1/projects/{id}/agents/{instance_id}",
            delete(projects::withdraw_agent).patch(projects::update_agent),
        )
        .route("/v1/projects/{id}/budget", put(projects::set_budget))
        .route("/v1/projects/{id}/leave", post(projects::leave))
        .route(
            "/v1/projects/{id}/members/{user_id}",
            delete(projects::remove_member),
        )
        .route(
            "/v1/projects/{id}/invites",
            get(projects::invites).post(projects::create_invite),
        )
        .route(
            "/v1/projects/{id}/invites/{invite_id}",
            delete(projects::revoke_invite),
        )
        .route("/v1/projects/{id}/runs", get(project_runs::runs))
        .route("/v1/projects/{id}/runs/{run_id}", get(project_runs::run))
        .route(
            "/v1/projects/{id}/runs/{run_id}/tree",
            get(project_runs::tree),
        )
        .route(
            "/v1/projects/{id}/runs/{run_id}/events",
            get(project_runs::events),
        )
        .route("/v1/projects/{id}/artifacts", get(project_runs::artifacts))
        .route(
            "/v1/projects/{id}/artifacts/{artifact_id}",
            get(project_runs::artifact),
        )
        .route(
            "/v1/projects/{id}/artifacts/{artifact_id}/content",
            get(project_runs::content),
        )
        // 团队模板的新名字（8.15）：同一张表，领养回项目详情。
        .route(
            "/v1/project-templates",
            get(teams::templates).post(teams::create_template),
        )
        .route("/v1/project-templates/{id}", delete(teams::delete_template))
        .route(
            "/v1/project-templates/{id}/adopt",
            post(teams::adopt_project_template),
        )
        .route("/v1/project-invites", get(project_invites::mine))
        .route(
            "/v1/project-invites/resolve",
            post(project_invites::resolve),
        )
        .route(
            "/v1/project-invites/accept",
            post(project_invites::accept_link),
        )
        .route("/v1/project-invites/{id}", get(project_invites::get))
        .route(
            "/v1/project-invites/{id}/accept",
            post(project_invites::accept),
        )
        .route(
            "/v1/project-invites/{id}/decline",
            post(project_invites::decline),
        )
        .route("/v1/blocks", get(project_invites::blocks))
        .route(
            "/v1/blocks/{user_id}",
            put(project_invites::block).delete(project_invites::unblock),
        )
        .layer(axum::middleware::map_response(no_store))
}

async fn no_store(mut resp: Response) -> Response {
    resp.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    resp
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

/// 区分“没带”和“带了 null”：带了的（包括 null）都是 `Some`（配合 `#[serde(default, deserialize_with = "present")]`）。
pub(crate) fn present<'de, D, T>(d: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    <Option<T> as serde::Deserialize>::deserialize(d).map(Some)
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
