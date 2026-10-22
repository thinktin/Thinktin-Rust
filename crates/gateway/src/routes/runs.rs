//! 运行：给实例下任务、查看、取消、运行树。

use auth::service::Principal;
use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use proto::domain::{InstanceId, PlanId, Run, RunId, RunKind, RunSource};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{NewRun, RunFilter, Tenant, Tx};

use super::{check_len, default_scope, parse_id};
use crate::{ApiJson, ApiResult, AppState, Authed};

#[derive(Deserialize)]
pub struct CreateReq {
    prompt: String,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<Run>)> {
    let id: InstanceId = parse_id(&id, "instance")?;
    check_len("prompt", req.prompt.trim(), 1, 32_000)?;
    // 消息里有保险箱里的密码（客户端没拦下来，11.6）：存库前换成引用，agent 和模型都看不到。
    let prompt = super::vault::scrub_user_text(&s, who.user, req.prompt.trim()).await;
    let mut t = s.db.tenant(who.user).await?;
    let instance = t.instance(id).await?;
    ensure_instance_grant(&s, &mut t, &who, id).await?;
    let run = t
        .create_run(&NewRun::new(
            id,
            RunSource::User,
            prompt,
            instance.agent_version,
        ))
        .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(run)))
}

/// 用户发起的运行用实例的授权。“全部停止”（4.6）吊销了它、或者它过期了：用户再发起时重新签发。
pub(crate) async fn ensure_instance_grant(
    s: &AppState,
    t: &mut Tx<Tenant>,
    who: &Principal,
    instance: InstanceId,
) -> ApiResult<()> {
    let has_grant = t
        .run_grants(instance)
        .await?
        .iter()
        .any(|g| g.plan_id.is_none() && g.parent_id.is_none());
    if !has_grant {
        let grant = t
            .create_run_grant(instance, None, &default_scope(s), s.cfg.grant_ttl)
            .await?;
        t.audit(
            &who.actor(),
            "grant.reissue",
            Some(&grant.id.to_string()),
            &json!({ "instance": instance }),
        )
        .await?;
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct ListQuery {
    before: Option<String>,
    limit: Option<i64>,
}

pub async fn list(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let before = q
        .before
        .as_deref()
        .map(|b| parse_id::<RunId>(b, "run"))
        .transpose()?;
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    let mut t = s.db.tenant(who.user).await?;
    t.instance(id).await?;
    let runs = t.runs(id, before, limit).await?;
    t.rollback().await?;
    Ok(Json(json!({ "runs": runs })))
}

#[derive(Deserialize)]
pub struct ListAllQuery {
    plan_id: Option<String>,
    /// 只要没结束的（排队、运行、等待、退避）：抽屉里的“进行中”、实时活动用。
    #[serde(default)]
    active: bool,
    /// 只要根运行（不要流水线的步骤、委派的子任务）：计划的运行历史一次触发一行。
    #[serde(default)]
    roots: bool,
    before: Option<String>,
    limit: Option<i64>,
}

/// 跨实例的运行列表（11.8）：某个计划的、没结束的，新的在前，`before` 往下翻。不查计划存不存在：删了的计划的
/// 运行照样看得到，别人的计划和不存在的一样是空的。
pub async fn list_all(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<ListAllQuery>,
) -> ApiResult<Json<Value>> {
    let plan = q
        .plan_id
        .as_deref()
        .map(|p| parse_id::<PlanId>(p, "plan"))
        .transpose()?;
    let before = q
        .before
        .as_deref()
        .map(|b| parse_id::<RunId>(b, "run"))
        .transpose()?;
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    let mut t = s.db.tenant(who.user).await?;
    let runs = t
        .list_runs(
            RunFilter {
                plan,
                active: q.active,
                roots: q.roots,
            },
            before,
            limit,
        )
        .await?;
    t.rollback().await?;
    Ok(Json(json!({ "runs": runs })))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Run>> {
    let id: RunId = parse_id(&id, "run")?;
    let mut t = s.db.tenant(who.user).await?;
    let run = t.run(id).await?;
    t.rollback().await?;
    Ok(Json(run))
}

#[derive(Deserialize)]
pub struct CancelQuery {
    /// 停掉整棵运行树（8.2）。
    #[serde(default)]
    tree: bool,
}

pub async fn cancel(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    Query(q): Query<CancelQuery>,
) -> ApiResult<Json<Run>> {
    let id: RunId = parse_id(&id, "run")?;
    let mut t = s.db.tenant(who.user).await?;
    // 流水线根运行自己不跑 agent，停它就是停整条流水线：不然步骤运行还在接着跑。
    let target = t.run(id).await?;
    let whole_tree =
        q.tree || (target.kind == RunKind::Pipeline && target.root_run_id == target.id);
    if whole_tree {
        let root = target.root_run_id;
        t.cancel_run_tree(root, "stopped by user").await?;
        let run = t.run(root).await?;
        t.append_event(
            run.instance_id,
            Some(run.id),
            "run.state",
            &json!({ "state": run.state, "reason": "stopped by user", "tree": true }),
        )
        .await?;
        t.commit().await?;
        return Ok(Json(run));
    }
    let run = t.cancel_run(id, None).await?;
    t.append_event(
        run.instance_id,
        Some(run.id),
        "run.state",
        &json!({ "state": run.state, "reason": run.state_reason }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(run))
}

pub async fn tree(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: RunId = parse_id(&id, "run")?;
    let mut t = s.db.tenant(who.user).await?;
    let run = t.run(id).await?;
    let runs = t.run_tree(run.root_run_id).await?;
    t.rollback().await?;
    Ok(Json(json!({ "root": run.root_run_id, "runs": runs })))
}

/// 实时活动、推送开启的令牌（10.6）：ActivityKit 给的十六进制串。
pub(super) fn check_live_token(token: &str) -> ApiResult<()> {
    if !(32..=512).contains(&token.len()) || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(crate::ApiError::invalid(
            "token must be the hex push token ActivityKit gave the app",
        ));
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct LiveActivityReq {
    token: String,
}

impl LiveActivityReq {
    pub(super) fn token(&self) -> &str {
        &self.token
    }
}

/// App 开了这个运行的实时活动（10.6），或者远程开启的那个拿到了令牌：登记它的推送令牌（这台设备的），
/// 之后运行的状态变了、结束了就推送更新。换了令牌（新的实时活动）：现在的状态再发一次；同一个令牌再报一次什么都不变
/// （连着失败放弃了的从头来）。运行结束 10 分钟以上的 422。
pub async fn register_live_activity(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<LiveActivityReq>,
) -> ApiResult<StatusCode> {
    let run: RunId = parse_id(&id, "run")?;
    check_live_token(&req.token)?;
    let mut t = s.db.tenant(who.user).await?;
    t.register_live_activity(who.device, run, &req.token, orchestrator::live::MAX_OPEN)
        .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// App 关掉了这个运行的实时活动（用户划掉了、App 自己结束了）：不再推送。
pub async fn end_live_activity(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let run: RunId = parse_id(&id, "run")?;
    let mut t = s.db.tenant(who.user).await?;
    t.end_live_activity(who.device, run).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
