//! 计划的 webhook（WBS 7.1 的事件部分，docs/event-triggers.md）：用户给计划加、列、停用、换令牌、删；外面的服务
//! 往 `POST /v1/webhooks/{令牌}` 发事件，平台按这个计划起一次运行，把收到的内容交给 agent。

use auth::secrets::HookToken;
use axum::Json;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use proto::api::ErrorCode;
use proto::domain::{PlanHook, PlanHookId, PlanId, RunSource};
use serde::Deserialize;
use serde_json::{Value, json};
use store::NewRun;

use super::parse_id;
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed, ClientIp};

/// 一个事件最大这么多字节。
pub const MAX_EVENT_BYTES: usize = 64 << 10;
/// 每个 webhook 每小时最多起这么多次运行。
const MAX_PER_HOOK_PER_HOUR: u64 = 60;
/// 每个用户每小时最多由 webhook 起这么多次运行。
const MAX_PER_USER_PER_HOUR: u64 = 200;
/// 同一个 webhook 排着没开始的运行最多这么多个。
const MAX_QUEUED_PER_HOOK: u64 = 5;

/// 地址里的路径（客户端拼上自己的接口地址）。
fn hook_path(token: &HookToken) -> String {
    format!("/v1/webhooks/{}", token.as_str())
}

fn new_token() -> ApiResult<HookToken> {
    HookToken::generate().map_err(ApiError::internal)
}

#[derive(Deserialize)]
pub struct CreateReq {
    /// 用户同意把收到的内容交给 agent 和他配置的模型厂商处理（App 里先说明）。
    #[serde(default)]
    consent: bool,
}

/// 建 webhook：返回它、地址路径和令牌（令牌只这一次）。
pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let id: PlanId = parse_id(&id, "plan")?;
    if !req.consent {
        return Err(ApiError::invalid(
            "consent is required: what the webhook receives goes to the agent and the user's model vendor",
        ));
    }
    let token = new_token()?;
    let mut t = s.db.tenant(who.user).await?;
    let hook = t.create_plan_hook(id, &token.hash()).await?;
    t.audit(
        &who.actor(),
        "plan_hook.create",
        Some(&hook.id.to_string()),
        &json!({ "plan": id }),
    )
    .await?;
    t.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "hook": hook, "path": hook_path(&token), "token": token.as_str() })),
    ))
}

pub async fn list(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    t.plan(id).await?;
    let hooks = t.plan_hooks(id).await?;
    t.rollback().await?;
    Ok(Json(json!({ "hooks": hooks })))
}

/// 换令牌：旧地址马上失效，返回新的地址路径和令牌。
pub async fn rotate(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: PlanHookId = parse_id(&id, "webhook")?;
    let token = new_token()?;
    let mut t = s.db.tenant(who.user).await?;
    let hook = t.rotate_plan_hook(id, &token.hash()).await?;
    t.audit(
        &who.actor(),
        "plan_hook.rotate",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok(Json(
        json!({ "hook": hook, "path": hook_path(&token), "token": token.as_str() }),
    ))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    enabled: bool,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<PlanHook>> {
    let id: PlanHookId = parse_id(&id, "webhook")?;
    let mut t = s.db.tenant(who.user).await?;
    let before = t.plan_hook(id).await?;
    let hook = t.set_plan_hook_enabled(id, req.enabled).await?;
    if before.enabled != req.enabled {
        t.audit(
            &who.actor(),
            "plan_hook.enabled",
            Some(&id.to_string()),
            &json!({ "on": req.enabled }),
        )
        .await?;
    }
    t.commit().await?;
    Ok(Json(hook))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: PlanHookId = parse_id(&id, "webhook")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_plan_hook(id).await?;
    t.audit(
        &who.actor(),
        "plan_hook.delete",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 收到的内容是什么：JSON 或纯文本（UTF-8），别的不收。
fn content_kind(headers: &HeaderMap) -> ApiResult<&'static str> {
    let ct = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("text/plain")
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    if ct == "application/json" || ct.ends_with("+json") {
        Ok("JSON")
    } else if ct.starts_with("text/") || ct.is_empty() {
        Ok("text")
    } else {
        Err(ApiError::invalid(
            "only application/json and text/* bodies are accepted",
        ))
    }
}

/// 外面的服务发事件（不要登录，令牌在地址里）。令牌不对、webhook 停用了、计划不在用都回 404（不说是哪种）；
/// 太频繁、排着的太多回 429，发送方通常会自己重试。
pub async fn receive(
    State(s): State<AppState>,
    ClientIp(ip): ClientIp,
    Path(token): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let not_found = || ApiError::not_found("webhook");
    let Ok(token) = HookToken::parse(&token) else {
        // 乱猜令牌的按来源地址限流；正常的发送方（可能很多用户共用一个出口）不受影响。
        s.limits().anonymous(ip)?;
        return Err(not_found());
    };
    let kind = content_kind(&headers)?;
    if body.len() > MAX_EVENT_BYTES {
        return Err(ApiError::invalid(format!(
            "events are limited to {} KB",
            MAX_EVENT_BYTES >> 10
        )));
    }
    let Ok(text) = std::str::from_utf8(&body) else {
        return Err(ApiError::invalid("the body must be UTF-8"));
    };
    if kind == "JSON" && serde_json::from_slice::<Value>(&body).is_err() {
        return Err(ApiError::invalid("the body is not valid JSON"));
    }
    let hash = token.hash();
    // 先找到是谁的（不拿锁），在锁外面抹掉保险箱里的值（要解密），再拿锁核对限流、建运行。
    let mut w = s.db.worker().await?;
    let Some(found) = w.hook_target(&hash).await? else {
        w.rollback().await?;
        s.limits().anonymous(ip)?;
        return Err(not_found());
    };
    w.rollback().await?;
    let text = super::vault::scrub_user_text(&s, found.user_id, text.trim()).await;

    let mut w = s.db.worker().await?;
    let Some(target) = w.hook_target(&hash).await? else {
        return Err(not_found());
    };
    let act = w.hook_activity(target.hook.id, target.user_id).await?;
    if act.hook_queued >= MAX_QUEUED_PER_HOOK
        || act.hook_last_hour >= MAX_PER_HOOK_PER_HOUR
        || act.user_last_hour >= MAX_PER_USER_PER_HOUR
    {
        w.rollback().await?;
        return Err(ApiError {
            retry_after_secs: Some(60),
            ..ApiError::new(
                ErrorCode::RateLimited,
                "too many events for this webhook, try again later",
            )
        });
    }
    let locale = w.user_locale(target.user_id).await?;
    let plan = &target.plan;
    let prompt = orchestrator::texts::event_input(locale, &plan.goal, kind, &text);
    let mut new = NewRun::new(
        plan.instance_id,
        RunSource::Plan,
        prompt,
        target.agent_version.clone(),
    );
    new.plan_id = Some(plan.id);
    new.hook_id = Some(target.hook.id);
    new.run_grant_id = target.run_grant_id;
    new.budget = plan.policy.budget;
    let run = w
        .create_run(target.user_id, &new)
        .await?
        .ok_or_else(|| ApiError::conflict("could not start the run"))?;
    w.touch_plan_hook(target.hook.id).await?;
    w.append_event(
        plan.instance_id,
        Some(run.id),
        "hook.received",
        &json!({ "hook_id": target.hook.id, "bytes": body.len(), "content_type": kind }),
    )
    .await?;
    w.commit().await?;
    Ok((StatusCode::ACCEPTED, Json(json!({ "status": "accepted" }))))
}
