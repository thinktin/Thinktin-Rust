//! 项目（8.13、8.14）：建单人项目、列表、详情、改名改目标、删（没共享过的）、加 agent、撤 agent、预算、退出、移出、
//! 邀请。跨用户的写和按成员关系的读都经 `orchestrator::projects`（worker 事务，store 里核对成员关系）；动作人只来自登录态。
//!
//! 状态码：不是成员 404（不说项目在不在）；成员调只有创建者能用的接口 403；人数、agent 数、待处理邀请到了上限 409
//! `project_member_limit` / `project_agent_limit` / `project_invite_limit`；邀请人一天的数到了 429。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use orchestrator::projects;
use proto::domain::{
    InstanceId, MAX_PROJECT_AGENTS, MAX_PROJECT_GOAL_CHARS, PROJECT_CONSENT_VERSION,
    PROJECT_INVITE_LINK_PREFIX, ProjectBudget, ProjectDetail, ProjectId, ProjectInviteId, UserId,
};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Consent, InviteCaps, SoloAgent};

use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 跨用户项目的总开关（`[api] cross_user_projects`，15.7 安全评审之前默认关）：关着时邀请、预览、接受都 404。
pub(crate) fn cross_user(s: &AppState) -> ApiResult<()> {
    if s.cfg.cross_user_projects {
        Ok(())
    } else {
        Err(ApiError::not_found("route"))
    }
}

/// 邀请的上限（`[api.limits]`，0 不限）。
pub(crate) fn invite_caps(s: &AppState) -> InviteCaps {
    let c = s.limits().config();
    InviteCaps {
        per_inviter_per_day: u64::from(c.invites_per_day),
        per_phone_per_day: u64::from(c.invites_per_phone_per_day),
    }
}

/// 成员确认过加入说明（`"consent": true`）才算。
pub(crate) fn consent(given: bool) -> Option<Consent> {
    given.then_some(Consent {
        version: PROJECT_CONSENT_VERSION,
    })
}

fn check_goal(goal: &str) -> ApiResult<()> {
    check_len("goal", goal, 0, MAX_PROJECT_GOAL_CHARS)
}

fn check_agent_count(n: usize) -> ApiResult<()> {
    if n == 0 || n as u64 > MAX_PROJECT_AGENTS {
        return Err(ApiError::invalid(format!(
            "choose 1-{MAX_PROJECT_AGENTS} agents"
        )));
    }
    Ok(())
}

/// 请求里的一个 agent（是对象，8.16 往里加“专属”等字段）。
#[derive(Deserialize)]
pub struct AgentReq {
    pub instance_id: InstanceId,
    #[serde(default)]
    pub is_lead: bool,
}

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let list = projects::my_projects(&s.db, who.user).await?;
    Ok(Json(json!({ "projects": list })))
}

#[derive(Deserialize)]
pub struct CreateReq {
    name: String,
    #[serde(default)]
    goal: String,
    agents: Vec<AgentReq>,
}

/// 建单人项目（自己的租户事务）：创建者是自己，agent 都是自己的实例。
pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<ProjectDetail>)> {
    let name = req.name.trim();
    check_len("name", name, 1, 64)?;
    check_goal(&req.goal)?;
    check_agent_count(req.agents.len())?;
    let mut seen = std::collections::HashSet::new();
    if !req.agents.iter().all(|a| seen.insert(a.instance_id)) {
        return Err(ApiError::invalid("an agent is listed twice"));
    }
    let agents: Vec<SoloAgent> = req
        .agents
        .iter()
        .enumerate()
        .map(|(i, a)| SoloAgent {
            instance_id: a.instance_id,
            is_lead: a.is_lead,
            position: i as u32,
        })
        .collect();
    let mut t = s.db.tenant(who.user).await?;
    let id = t.create_solo_project(name, &req.goal, &agents).await?;
    t.commit().await?;
    let detail = projects::detail(&s.db, who.user, id).await?;
    Ok((StatusCode::CREATED, Json(detail)))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    Ok(Json(projects::detail(&s.db, who.user, id).await?))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    name: Option<String>,
    goal: Option<String>,
}

/// 改名字、目标（只有创建者；共享了的也能改）。
pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let name = req.name.as_deref().map(str::trim);
    if let Some(n) = name {
        check_len("name", n, 1, 64)?;
    }
    if let Some(g) = &req.goal {
        check_goal(g)?;
    }
    projects::update(&s.db, who.user, &who.actor(), id, name, req.goal.as_deref()).await?;
    Ok(Json(projects::detail(&s.db, who.user, id).await?))
}

/// 删项目：只有没共享过的单人项目（共享过的 409，8.15 起改成软删除）。
pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    // worker 在一个事务里核对身份（成员 403、外人 404、共享过的 409）、撤回还没处理的邀请、删掉。
    projects::delete(&s.db, who.user, &who.actor(), id, false).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct AddAgentsReq {
    agents: Vec<AgentReq>,
    #[serde(default)]
    consent: bool,
}

/// 往项目里加自己的 agent。成员要 `"consent": true`（创建者不用）。
pub async fn add_agents(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<AddAgentsReq>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    check_agent_count(req.agents.len())?;
    let agents: Vec<InstanceId> = req.agents.iter().map(|a| a.instance_id).collect();
    projects::add_agents(
        &s.db,
        who.user,
        &who.actor(),
        id,
        &agents,
        consent(req.consent),
    )
    .await?;
    Ok(Json(projects::detail(&s.db, who.user, id).await?))
}

/// 撤回项目里的一个 agent（主人或创建者）。
pub async fn withdraw_agent(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, instance)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    let instance: InstanceId = parse_id(&instance, "agent")?;
    projects::withdraw_agent(&s.db, who.user, &who.actor(), id, instance).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 设我在项目里的预算（成员两个都要有）。
pub async fn set_budget(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(budget): ApiJson<ProjectBudget>,
) -> ApiResult<Json<ProjectBudget>> {
    let id: ProjectId = parse_id(&id, "project")?;
    projects::set_budget(&s.db, who.user, &who.actor(), id, &budget).await?;
    Ok(Json(budget))
}

/// 退出项目（创建者不能退出：409）。
pub async fn leave(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    projects::leave(&s.db, who.user, &who.actor(), id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 创建者移出一个成员（已经离开的照样 204）。
pub async fn remove_member(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, member)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    let member: UserId = parse_id(&member, "member")?;
    projects::remove_member(&s.db, who.user, &who.actor(), id, member).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 项目的邀请（只有创建者）。
pub async fn invites(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let list = projects::invites(&s.db, who.user, id).await?;
    Ok(Json(json!({ "invites": list })))
}

#[derive(Deserialize)]
pub struct InviteReq {
    phone: Option<String>,
    #[serde(default)]
    link: bool,
}

/// 发邀请：`{"phone": "..."}`（不管号码是谁的，回的都是 201 和同样的内容）或 `{"link": true}`（令牌只在这一次返回）。
pub async fn create_invite(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<InviteReq>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    cross_user(&s)?;
    let id: ProjectId = parse_id(&id, "project")?;
    match (req.phone, req.link) {
        (Some(phone), false) => {
            let e164 = auth::secrets::normalize_phone(&phone)
                .map_err(|_| ApiError::invalid("invalid phone number"))?;
            let invite =
                projects::invite_phone(&s.db, who.user, &who.actor(), id, &e164, invite_caps(&s))
                    .await?;
            Ok((StatusCode::CREATED, Json(json!({ "invite": invite }))))
        }
        (None, true) => {
            let token = auth::secrets::InviteToken::generate().map_err(ApiError::internal)?;
            let invite = projects::invite_link(
                &s.db,
                who.user,
                &who.actor(),
                id,
                &token.hash(),
                invite_caps(&s),
            )
            .await?;
            Ok((
                StatusCode::CREATED,
                Json(json!({
                    "invite": invite,
                    "token": token.as_str(),
                    "link": format!("{PROJECT_INVITE_LINK_PREFIX}{}", token.as_str()),
                })),
            ))
        }
        _ => Err(ApiError::invalid(
            "give either a phone number or link: true",
        )),
    }
}

/// 撤回邀请（只有创建者）。
pub async fn revoke_invite(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, invite)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    let invite: ProjectInviteId = parse_id(&invite, "invite")?;
    projects::revoke_invite(&s.db, who.user, &who.actor(), id, invite).await?;
    Ok(StatusCode::NO_CONTENT)
}
