//! 计划与触发器（7.1）。触发规则在这里校验（能解析、不比档位允许的更频繁、还会触发），
//! 下一次触发时间算好再存；建计划时签发它自己的运行授权。

use std::collections::HashMap;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use orchestrator::schedule::Schedule;
use proto::domain::{
    CatchUp, GrantId, InstanceId, Plan, PlanAuthor, PlanId, PlanPolicy, PlanStep, ScheduleSpec,
    Trigger, TriggerId, order_steps,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use store::{NewPlan, Tenant, Tx};

use super::{check_len, default_scope, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

const MAX_TRIGGERS: usize = 10;
const MAX_STEPS: usize = 20;

#[derive(Serialize)]
pub struct PlanView {
    #[serde(flatten)]
    plan: Plan,
    triggers: Vec<Trigger>,
    /// 流水线步骤（8.2）；为空时计划是单个 agent 的运行。
    steps: Vec<PlanStep>,
    /// 下一次按时运行的名义时间（实际可能因削峰晚几分钟）：在用的触发器里最早的；暂停了、等确认、没有会再触发的
    /// 规则时为空。
    next_fire_at: Option<DateTime<Utc>>,
    /// 规则失效、被后台停用的触发器有几个（App 提示“规则已失效”）。
    invalid_triggers: u32,
}

impl PlanView {
    fn new(plan: Plan, triggers: Vec<Trigger>, steps: Vec<PlanStep>) -> Self {
        let next_fire_at = if plan.paused || plan.awaiting_confirmation {
            None
        } else {
            triggers
                .iter()
                .filter(|t| t.enabled)
                .filter_map(|t| t.next_fire_at)
                .min()
        };
        let invalid_triggers = triggers
            .iter()
            .filter(|t| t.disabled_reason.as_deref() == Some(proto::domain::TRIGGER_INVALID_RULE))
            .count() as u32;
        Self {
            plan,
            triggers,
            steps,
            next_fire_at,
            invalid_triggers,
        }
    }
}

/// 校验触发规则，返回下一次触发时间。
fn next_fire(s: &AppState, spec: &ScheduleSpec, now: DateTime<Utc>) -> ApiResult<DateTime<Utc>> {
    let schedule = Schedule::parse_new(spec, now).map_err(|e| ApiError::invalid(e.to_string()))?;
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
    if policy.wait_timeout_secs < 60 || policy.wait_timeout_secs > 7 * 24 * 3600 {
        return Err(ApiError::invalid(
            "wait_timeout_secs must be 60 s to 7 days",
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

/// 校验流水线步骤：键的格式、提示词长度、依赖关系（实例归属在库里校验）。
fn check_steps(steps: &[PlanStep]) -> ApiResult<()> {
    if steps.len() > MAX_STEPS {
        return Err(ApiError::invalid(format!("at most {MAX_STEPS} steps")));
    }
    for st in steps {
        let ok = (1..=32).contains(&st.key.len())
            && st.key.bytes().enumerate().all(|(i, b)| {
                b.is_ascii_lowercase() || b.is_ascii_digit() || (i > 0 && (b == b'_' || b == b'-'))
            });
        if !ok {
            return Err(ApiError::invalid(format!(
                "step key {:?} must be 1-32 of a-z 0-9 _ - (starting with a letter or digit)",
                st.key
            )));
        }
        check_len("step prompt", st.prompt.trim(), 1, 8000)?;
    }
    order_steps(steps).map_err(ApiError::invalid)?;
    Ok(())
}

async fn view(t: &mut Tx<Tenant>, plan: Plan) -> ApiResult<PlanView> {
    let triggers = t.triggers(plan.id).await?;
    let steps = t.plan_steps(plan.id).await?;
    Ok(PlanView::new(plan, triggers, steps))
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
    #[serde(default)]
    steps: Vec<PlanStep>,
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
    check_steps(&req.steps)?;
    let now = Utc::now();
    let fires = req
        .triggers
        .iter()
        .map(|spec| next_fire(&s, spec, now))
        .collect::<ApiResult<Vec<_>>>()?;
    let mut t = s.db.tenant(who.user).await?;
    // 先拿实例的共享锁（和删除实例互斥，见 share_instances），再查实例、建计划。
    t.share_instances(
        std::iter::once(req.instance_id).chain(req.steps.iter().map(|st| st.instance_id)),
    )
    .await?;
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
    let grant = t
        .create_run_grant(
            req.instance_id,
            Some(plan.id),
            &default_scope(&s),
            s.cfg.grant_ttl,
        )
        .await?;
    t.set_plan_grant(plan.id, grant.id).await?;
    if !req.steps.is_empty() {
        t.set_plan_steps(plan.id, &req.steps).await?;
    }
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
    // 每个计划的触发器和步骤：一共三次查询，不是每个计划查一次。
    let ids: Vec<PlanId> = plans.iter().map(|p| p.id).collect();
    let mut triggers: HashMap<PlanId, Vec<Trigger>> = HashMap::new();
    for tr in t.triggers_of(&ids).await? {
        triggers.entry(tr.plan_id).or_default().push(tr);
    }
    let mut steps: HashMap<PlanId, Vec<PlanStep>> = HashMap::new();
    for (plan, step) in t.plan_steps_of(&ids).await? {
        steps.entry(plan).or_default().push(step);
    }
    t.rollback().await?;
    let views: Vec<PlanView> = plans
        .into_iter()
        .map(|p| {
            let id = p.id;
            PlanView::new(
                p,
                triggers.remove(&id).unwrap_or_default(),
                steps.remove(&id).unwrap_or_default(),
            )
        })
        .collect();
    Ok(Json(json!({ "plans": views })))
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
    /// 整体替换；给空数组就变回单个 agent 的计划。
    steps: Option<Vec<PlanStep>>,
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
    if let Some(steps) = &req.steps {
        check_steps(steps)?;
        // 锁计划行（update_plan）之前拿步骤实例的共享锁：和删除实例互斥，见 share_instances。
        t.share_instances(steps.iter().map(|st| st.instance_id))
            .await?;
    }
    let plan = t
        .update_plan(
            id,
            title.trim(),
            goal.trim(),
            &policy,
            req.catch_up.unwrap_or(cur.catch_up),
        )
        .await?;
    if let Some(steps) = &req.steps {
        t.set_plan_steps(id, steps).await?;
    }
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

/// 暂停期间错过的不补，从现在起重新算每个触发器的下一次触发。
async fn reschedule(t: &mut store::Tx<store::Tenant>, id: PlanId) -> ApiResult<()> {
    let now = Utc::now();
    for trig in t.triggers(id).await? {
        if trig.enabled {
            match Schedule::parse(&trig.spec) {
                Ok(sch) => {
                    t.set_trigger_enabled(trig.id, true, sch.next_after(now))
                        .await?
                }
                // 规则解析不了了（时区没了之类）：停用，说明原因，通知用户删掉重新加。
                Err(_) => {
                    if t.disable_trigger(trig.id, proto::domain::TRIGGER_INVALID_RULE)
                        .await?
                    {
                        let plan = t.plan(id).await?;
                        let locale = t.user_locale(t.user()).await?;
                        let notice = orchestrator::scheduler::trigger_disabled_notice(
                            locale, &plan, trig.id,
                        );
                        orchestrator::outbox::notify_tenant(t, &notice).await?;
                    }
                }
            }
        }
    }
    Ok(())
}

/// 恢复用户自己暂停的计划。agent 新建、修改过、等确认的计划要用 `confirm`（409）。
/// 流水线有一步在已删除的实例上（删除实例时暂停了它，11.9）：先改步骤才能恢复、确认。要在事务一开始调
/// （deleted_step 先拿步骤实例的共享锁，之后才能锁计划行）。
async fn refuse_deleted_steps(t: &mut store::Tx<store::Tenant>, id: PlanId) -> ApiResult<()> {
    match t.deleted_step(id).await? {
        Some(key) => Err(ApiError::conflict(format!(
            "step {key} runs on a deleted instance; change the steps first"
        ))),
        None => Ok(()),
    }
}

pub async fn resume(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<PlanView>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    refuse_deleted_steps(&mut t, id).await?;
    t.set_plan_paused(id, false).await?;
    let plan = t.plan(id).await?;
    // “全部停止”（4.6）吊销了计划的授权，或者授权过期了：恢复时重新签发。
    if let Some(grant) =
        ensure_plan_grant(&s, &mut t, &plan, "replaced when the plan was resumed").await?
    {
        t.audit(
            &who.actor(),
            "grant.reissue",
            Some(&grant.to_string()),
            &json!({ "plan": id }),
        )
        .await?;
    }
    reschedule(&mut t, id).await?;
    let v = view(&mut t, plan).await?;
    t.commit().await?;
    Ok(Json(v))
}

/// 计划没有能用的正式授权时签发一个：用户确认 agent 写的计划（换掉 agent 签的子授权）、
/// “全部停止”之后恢复计划、授权过期。范围沿用原来的授权；原来的还有效就吊销。返回新授权。
async fn ensure_plan_grant(
    s: &AppState,
    t: &mut Tx<Tenant>,
    plan: &Plan,
    reason: &str,
) -> ApiResult<Option<GrantId>> {
    let current = t.plan_grant(plan.id).await?;
    if current
        .as_ref()
        .is_some_and(|g| g.parent_id.is_none() && g.is_active(Utc::now()))
    {
        return Ok(None);
    }
    let scope = current
        .as_ref()
        .map_or_else(|| default_scope(s), |g| g.scope.clone());
    let grant = t
        .create_run_grant(plan.instance_id, Some(plan.id), &scope, s.cfg.grant_ttl)
        .await?;
    t.set_plan_grant(plan.id, grant.id).await?;
    if let Some(old) = current {
        t.revoke_run_grant(old.id, reason).await?;
    }
    Ok(Some(grant.id))
}

#[derive(Deserialize)]
pub struct ConfirmReq {
    /// 用户看到的版本（计划详情里的 `revision`）。
    revision: u32,
}

/// 确认 agent 新建或修改的计划。确认的是用户看到的那个版本：之后又被 agent 改过就 409，重新看了再确认。
/// 确认后计划开始按时运行；agent 签的子授权（跟着发起调用的运行、不续期）换成用户签发的授权。
pub async fn confirm(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<ConfirmReq>,
) -> ApiResult<Json<PlanView>> {
    let id: PlanId = parse_id(&id, "plan")?;
    let mut t = s.db.tenant(who.user).await?;
    refuse_deleted_steps(&mut t, id).await?;
    let plan = t.confirm_plan(id, req.revision).await?;
    ensure_plan_grant(
        &s,
        &mut t,
        &plan,
        "replaced when the user confirmed the plan",
    )
    .await?;
    reschedule(&mut t, id).await?;
    t.audit(
        &who.actor(),
        "plan.confirm",
        Some(&id.to_string()),
        &json!({ "revision": req.revision }),
    )
    .await?;
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
