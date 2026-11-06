//! 项目（8.13–8.15）：建单人项目、列表、详情、改名改目标、删、归档、加 agent、撤 agent、预算、退出、移出、邀请。
//! 跨用户的写经 `orchestrator::projects`（worker 事务，store 里核对成员关系），读走只读的成员事务（8.15）；动作人只来自
//! 登录态。
//!
//! 状态码：不是成员 404（不说项目在不在，库里拒绝的也按 404，见 [`project_error`]）；成员调只有创建者能用的接口 403；
//! 人数、agent 数、待处理邀请到了上限 409 `project_member_limit` / `project_agent_limit` / `project_invite_limit`；
//! 邀请人一天的数到了 429。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use orchestrator::projects;
use proto::domain::{
    InstanceId, MAX_PROJECT_AGENTS, MAX_PROJECT_GOAL_CHARS, PROJECT_INVITE_LINK_PREFIX,
    ProjectBudget, ProjectDetail, ProjectId, ProjectInviteId, UserId,
};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Consent, InviteCaps, JoinAgent, SoloAgent};

use super::{check_len, parse_id};
use crate::error::project_error;
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

/// 成员确认过加入说明（`"consent": true`）才算。`consent_version` 是 App 显示的那一版说明（[`proto::domain::PROJECT_CONSENT_VERSION`]），
/// 不带的按第 1 版算：老的 App 没显示专属、混用的说明，库里按版本过旧拒绝（422），提示升级。
pub(crate) fn consent(given: bool, version: Option<u32>) -> Option<Consent> {
    given.then_some(Consent {
        version: version.unwrap_or(1),
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

/// 请求里的一个 agent（8.16）：已有的 botin（`instance_id`）或当场创建一个专属的（`adopt`），二选一。
///
/// - `dedicated`：已有的标成专属于这个项目，要同时带 `reset_workspace: true`（它的记忆、文件清空，换全新的工作区）；
/// - `ack_shared_memory`：不标专属的（混用）要用户确认过“私人记忆可能被带进项目”，跨用户项目里才要，而且要服务端收混用的；
/// - `is_lead`：只有建单人项目时用。
#[derive(Deserialize)]
pub struct AgentReq {
    pub instance_id: Option<InstanceId>,
    pub adopt: Option<AdoptReq>,
    #[serde(default)]
    pub dedicated: bool,
    #[serde(default)]
    pub reset_workspace: bool,
    #[serde(default)]
    pub ack_shared_memory: bool,
    #[serde(default)]
    pub is_lead: bool,
}

/// 当场创建的 botin：和 `POST /v1/instances` 一样的三项。
#[derive(Deserialize)]
pub struct AdoptReq {
    agent_id: String,
    harness: Option<String>,
    name: String,
}

impl AgentReq {
    /// 加入、加 agent 时的一项：二选一不对的、标专属没带 `reset_workspace` 的 422；要创建的按模板查好（agent 不认识、
    /// 名字不对的和领养一样报错）。
    pub(crate) fn join(&self, s: &AppState) -> ApiResult<JoinAgent> {
        match (self.instance_id, &self.adopt) {
            (Some(id), None) => {
                if self.dedicated && !self.reset_workspace {
                    return Err(ApiError::invalid(
                        "dedicating an existing agent clears its memory and files (reset_workspace: true)",
                    ));
                }
                Ok(JoinAgent::Existing {
                    id,
                    dedicate: self.dedicated,
                    ack_shared_memory: self.ack_shared_memory,
                })
            }
            (None, Some(a)) => Ok(JoinAgent::Adopt(control::new_instance(
                s.templates.as_ref(),
                control::AdoptSpec {
                    agent_id: &a.agent_id,
                    harness: a.harness.as_deref(),
                    name: &a.name,
                },
            )?)),
            _ => Err(ApiError::invalid(
                "each agent needs exactly one of instance_id and adopt",
            )),
        }
    }
}

/// 一组加入、加 agent 的项：个数先查（创建要按模板查，免得白查）。
pub(crate) fn join_agents(s: &AppState, agents: &[AgentReq]) -> ApiResult<Vec<JoinAgent>> {
    check_agent_count(agents.len())?;
    agents.iter().map(|a| a.join(s)).collect()
}

/// 账号的 botin 数上限（`[api.limits] instances_per_user`，0 不限）：当场创建的也算。
pub(crate) fn max_instances(s: &AppState) -> u64 {
    u64::from(s.limits().config().instances_per_user)
}

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let list = projects::my_projects(&s.db, who.user)
        .await
        .map_err(project_error)?;
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
    // 单人项目只放自己已有的 botin，不标专属（标专属、当场创建走加 agent 的接口）。
    let mut seen = std::collections::HashSet::new();
    let mut agents: Vec<SoloAgent> = Vec::with_capacity(req.agents.len());
    for (i, a) in req.agents.iter().enumerate() {
        let Some(id) = a.instance_id.filter(|_| a.adopt.is_none() && !a.dedicated) else {
            return Err(ApiError::invalid(
                "a new project takes your existing agents (dedicate or create one with POST /v1/projects/{id}/agents)",
            ));
        };
        if !seen.insert(id) {
            return Err(ApiError::invalid("an agent is listed twice"));
        }
        agents.push(SoloAgent {
            instance_id: id,
            is_lead: a.is_lead,
            position: i as u32,
        });
    }
    let mut t = s.db.tenant(who.user).await?;
    let id = t.create_solo_project(name, &req.goal, &agents).await?;
    t.commit().await?;
    let detail = projects::detail(&s.db, who.user, id)
        .await
        .map_err(project_error)?;
    Ok((StatusCode::CREATED, Json(detail)))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    Ok(Json(
        projects::detail(&s.db, who.user, id)
            .await
            .map_err(project_error)?,
    ))
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
    projects::update(&s.db, who.user, &who.actor(), id, name, req.goal.as_deref())
        .await
        .map_err(project_error)?;
    Ok(Json(
        projects::detail(&s.db, who.user, id)
            .await
            .map_err(project_error)?,
    ))
}

/// 删项目（只有创建者，共享过的也能删，8.15）：软删除，马上谁都读不到，密钥马上删掉，内容过一会儿由后台清理；还在的
/// 成员收到 `project_deleted`。不能撤销。
pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    // worker 在一个事务里核对身份（成员 403、外人和删过的 404）、停掉项目里的运行、撤回还没处理的邀请、删掉。
    projects::delete(&s.db, who.user, &who.actor(), id, true)
        .await
        .map_err(project_error)?;
    Ok(StatusCode::NO_CONTENT)
}

/// 归档（只有创建者）：项目变成只读，停掉里面的运行和授权；重复归档照样 200。
pub async fn archive(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    projects::archive(&s.db, who.user, &who.actor(), id)
        .await
        .map_err(project_error)?;
    Ok(Json(
        projects::detail(&s.db, who.user, id)
            .await
            .map_err(project_error)?,
    ))
}

/// 取消归档（只有创建者）：停掉的运行不会重新开始。
pub async fn unarchive(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    projects::unarchive(&s.db, who.user, &who.actor(), id)
        .await
        .map_err(project_error)?;
    Ok(Json(
        projects::detail(&s.db, who.user, id)
            .await
            .map_err(project_error)?,
    ))
}

#[derive(Deserialize)]
pub struct AddAgentsReq {
    agents: Vec<AgentReq>,
    #[serde(default)]
    consent: bool,
    consent_version: Option<u32>,
}

/// 往项目里加自己的 agent：已有的（可以标专属）或当场创建专属的（见 [`AgentReq`]）。成员要 `"consent": true` 和
/// `consent_version`（创建者不用）。跨用户项目里不标专属的要服务端收混用的（不收 409 `agent_not_isolated`）。
pub async fn add_agents(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<AddAgentsReq>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let agents = join_agents(&s, &req.agents)?;
    projects::add_agents(
        &s.db,
        s.kms.clone(),
        who.user,
        &who.actor(),
        id,
        &agents,
        consent(req.consent, req.consent_version),
        s.cfg.mixed_project_agents,
        max_instances(&s),
    )
    .await
    .map_err(project_error)?;
    Ok(Json(
        projects::detail(&s.db, who.user, id)
            .await
            .map_err(project_error)?,
    ))
}

#[derive(Deserialize)]
pub struct AgentChange {
    dedicated: bool,
    #[serde(default)]
    reset_workspace: bool,
}

/// 把项目里自己的一个 agent 标成专属于这个项目（8.16）：`{"dedicated": true, "reset_workspace": true}`，它的记忆、文件
/// 清空，以后不接私人任务。只能标、不能取消（要放回私人：撤下以后 `POST /v1/instances/{id}/release`）。
/// 不是成员、agent 不在项目里 404；别人的 agent 403；它还有没做完的事 409 `conflict`；专属于别的项目 409 `instance_dedicated`。
pub async fn update_agent(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, instance)): Path<(String, String)>,
    ApiJson(req): ApiJson<AgentChange>,
) -> ApiResult<Json<ProjectDetail>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let instance: InstanceId = parse_id(&instance, "agent")?;
    if !req.dedicated {
        return Err(ApiError::invalid(
            "an agent cannot be undedicated in place: withdraw it, then release it (POST /v1/instances/{id}/release)",
        ));
    }
    if !req.reset_workspace {
        return Err(ApiError::invalid(
            "dedicating an existing agent clears its memory and files (reset_workspace: true)",
        ));
    }
    projects::dedicate_agent(&s.db, s.kms.clone(), who.user, &who.actor(), id, instance)
        .await
        .map_err(project_error)?;
    Ok(Json(
        projects::detail(&s.db, who.user, id)
            .await
            .map_err(project_error)?,
    ))
}

/// 撤回项目里的一个 agent（主人或创建者）。
pub async fn withdraw_agent(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, instance)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    let instance: InstanceId = parse_id(&instance, "agent")?;
    projects::withdraw_agent(&s.db, who.user, &who.actor(), id, instance)
        .await
        .map_err(project_error)?;
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
    projects::set_budget(&s.db, who.user, &who.actor(), id, &budget)
        .await
        .map_err(project_error)?;
    Ok(Json(budget))
}

/// 退出项目（创建者不能退出：409）。
pub async fn leave(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: ProjectId = parse_id(&id, "project")?;
    projects::leave(&s.db, who.user, &who.actor(), id)
        .await
        .map_err(project_error)?;
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
    projects::remove_member(&s.db, who.user, &who.actor(), id, member)
        .await
        .map_err(project_error)?;
    Ok(StatusCode::NO_CONTENT)
}

/// 项目的邀请（只有创建者）。
pub async fn invites(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let list = projects::invites(&s.db, who.user, id)
        .await
        .map_err(project_error)?;
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
                    .await
                    .map_err(project_error)?;
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
            .await
            .map_err(project_error)?;
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
    projects::revoke_invite(&s.db, who.user, &who.actor(), id, invite)
        .await
        .map_err(project_error)?;
    Ok(StatusCode::NO_CONTENT)
}
