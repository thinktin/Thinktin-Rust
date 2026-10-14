//! 计划与触发器（7.1）。触发规则在这里校验（能解析、不比档位允许的更频繁、还会触发），
//! 下一次触发时间算好再存；建计划时签发它自己的运行授权。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use orchestrator::schedule::Schedule;
use proto::domain::{
    CatchUp, GrantScope, InstanceId, Plan, PlanAuthor, PlanId, PlanPolicy, ScheduleSpec, Trigger,
    TriggerId,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use store::{NewPlan, Tenant, Tx};

use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

const MAX_TRIGGERS: usize = 10;

#[derive(Serialize)]
pub struct PlanView {
    #[serde(flatten)]
    plan: Plan,
    triggers: Vec<Trigger>,
}

/// 校验触发规则，返回下一次触发时间。
fn next_fire(s: &AppState, spec: &ScheduleSpec, now: DateTime<Utc>) -> ApiResult<DateTime<Utc>> {
    let schedule = Schedule::parse(spec).map_err(|e| ApiError::invalid(e.to_string()))?;
    if !matches!(spec, ScheduleSpec::Once { .. }) {
        schedule
            .check_min_interval(now, s.cfg.min_trigger_interval)
            .map_err(|e| ApiError::invalid(e.to_string()))?;
    }
    schedule
        .next_after(now)
        .ok_or_else(|| ApiError::invalid("the schedule never fires after now"))
}

fn check_policy(policy: &PlanPolicy) -> ApiResult<()> {
    if policy.approval_timeout_secs < 60 || policy.approval_timeout_secs > 7 * 24 * 3600 {
        return Err(ApiError::invalid(
            "approval_timeout_secs must be 60 s to 7 days",
        ));
    }
    let b = &policy.budget;
    if b.max_duration_secs == 0 || b.max_duration_secs > 24 * 3600 {
        return Err(ApiError::invalid(
            "budget.max_duration_secs must be 1 s to 24 h",
        ));
    }
    if policy.preauthorized_tools.len() > 32 {
        return Err(ApiError::invalid("too many preauthorized tools"));
    }
    Ok(())
}

async fn view(t: &mut Tx<Tenant>, plan: Plan) -> ApiResult<PlanView> {
    let triggers = t.triggers(plan.id).await?;
    Ok(PlanView { plan, triggers })
}

#[derive(Deserialize)]
pub struct CreateReq {
    instance_id: InstanceId,
    title: String,
    goal: String,
    #[serde(default)]
    policy: PlanPolicy,
    #[serde(default)]
    catch_up: CatchUp,
    #[serde(default)]
    triggers: Vec<ScheduleSpec>,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<PlanView>)> {
    check_len("title", req.title.trim(), 1, 100)?;
    check_len("goal", req.goal.trim(), 1, 8000)?;
    check_policy(&req.policy)?;
    if req.triggers.len() > MAX_TRIGGERS {
        return Err(ApiError::invalid(format!(
            "at most {MAX_TRIGGERS} triggers"
        )));
    }
    let now = Utc::now();
    let fires = req
        .triggers
        .iter()
        .map(|spec| next_fire(&s, spec, now))
        .collect::<ApiResult<Vec<_>>>()?;
    let mut t = s.db.tenant(who.user).await?;
    let plan = t
        .create_plan(&NewPlan {
            instance_id: req.instance_id,
            title: req.title.trim().into(),
            goal: req.goal.trim().into(),
            policy: req.policy,
            catch_up: req.catch_up,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await?;
    // 计划自己的运行授权：退出登录不影响，删除计划时吊销。
    let scope = GrantScope {
        platform_tools: s.cfg.default_platform_tools.clone(),
        ..GrantScope::default()
    };
    let grant = t
        .create_run_grant(req.instance_id, Some(plan.id), &scope, s.cfg.grant_ttl)
        .await?;
    t.set_plan_grant(plan.id, grant.id).await?;
    for (spec, next) in req.triggers.iter().zip(fires) {
        t.add_trigger(plan.id, spec, Some(next)).await?;
    }
    t.audit(
        &who.actor(),
        "plan.create",
        Some(&plan.id.to_string()),
        &json!({}),
    )
    .await?;
    let v = view(&mut t, plan).await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(v)))
}

#[derive(Deserialize)]
pub struct ListQuery {
    instance_id: Option<String>,
}

pub async fn list(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let instance = q
        .instance_id
        .as_deref()
        .map(|i| parse_id::<InstanceId>(i, "instance"))
        .transpose()?;
    let mut t = s.db.tenant(who.user).await?;
    let plans = t.plans(instance).await?;
    t.rollback().await?;
    Ok(Json(json!({ "plans": plans })))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<PlanView>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    let plan = t.plan(id).await?;
    let v = view(&mut t, plan).await?;
    t.rollback().await?;
    Ok(Json(v))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    title: Option<String>,
    goal: Option<String>,
    policy: Option<PlanPolicy>,
    catch_up: Option<CatchUp>,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<PlanView>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    let cur = t.plan(id).await?;
    let title = req.title.unwrap_or(cur.title);
    let goal = req.goal.unwrap_or(cur.goal);
    let policy = req.policy.unwrap_or(cur.policy);
    check_len("title", title.trim(), 1, 100)?;
    check_len("goal", goal.trim(), 1, 8000)?;
    check_policy(&policy)?;
    let plan = t
        .update_plan(
            id,
            title.trim(),
            goal.trim(),
            &policy,
            req.catch_up.unwrap_or(cur.catch_up),
        )
        .await?;
    t.audit(
        &who.actor(),
        "plan.update",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    let v = view(&mut t, plan).await?;
    t.commit().await?;
    Ok(Json(v))
}

pub async fn pause(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<PlanView>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    t.set_plan_paused(id, true).await?;
    let plan = t.plan(id).await?;
    let v = view(&mut t, plan).await?;
    t.commit().await?;
    Ok(Json(v))
}

/// 恢复：暂停期间错过的不补，从现在起重新算下一次触发。
pub async fn resume(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<PlanView>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let now = Utc::now();
    let mut t = s.db.tenant(who.user).await?;
    t.set_plan_paused(id, false).await?;
    for trig in t.triggers(id).await? {
        if trig.enabled {
            let next = Schedule::parse(&trig.spec)
                .ok()
                .and_then(|sch| sch.next_after(now));
            t.set_trigger_enabled(trig.id, true, next).await?;
        }
    }
    let plan = t.plan(id).await?;
    let v = view(&mut t, plan).await?;
    t.commit().await?;
    Ok(Json(v))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_plan(id).await?;
    t.revoke_plan_grants(id, "plan deleted").await?;
    t.audit(
        &who.actor(),
        "plan.delete",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct TriggerReq {
    spec: ScheduleSpec,
}

pub async fn add_trigger(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<TriggerReq>,
) -> ApiResult<(StatusCode, Json<Trigger>)> {
    let id: PlanId = parse_id(&id, "plan")?;
    let next = next_fire(&s, &req.spec, Utc::now())?;
    let mut t = s.db.tenant(who.user).await?;
    if t.triggers(id).await?.len() >= MAX_TRIGGERS {
        return Err(ApiError::invalid(format!(
            "at most {MAX_TRIGGERS} triggers"
        )));
    }
    let trig = t.add_trigger(id, &req.spec, Some(next)).await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(trig)))
}

pub async fn delete_trigger(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: TriggerId = parse_id(&id, "trigger")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_trigger(id).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
