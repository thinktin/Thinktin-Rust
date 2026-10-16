//! 团队与团队模板（8.1）。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use proto::domain::{
    Team, TeamId, TeamMember, TeamRole, TeamTemplate, TeamTemplateId, TeamTemplateSpec,
    TemplateMember,
};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{check_len, default_scope, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

const MAX_MEMBERS: usize = 12;

fn check_members(members: &[TeamMember]) -> ApiResult<()> {
    if members.is_empty() || members.len() > MAX_MEMBERS {
        return Err(ApiError::invalid(format!(
            "a team has 1-{MAX_MEMBERS} members"
        )));
    }
    Ok(())
}

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let teams = t.teams().await?;
    t.rollback().await?;
    Ok(Json(json!({ "teams": teams })))
}

#[derive(Deserialize)]
pub struct CreateReq {
    name: String,
    members: Vec<TeamMember>,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<Team>)> {
    check_len("name", req.name.trim(), 1, 64)?;
    check_members(&req.members)?;
    let mut t = s.db.tenant(who.user).await?;
    let team = t.create_team(req.name.trim(), &req.members).await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(team)))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Team>> {
    let id: TeamId = parse_id(&id, "team")?;
    let mut t = s.db.tenant(who.user).await?;
    let team = t.team(id).await?;
    t.rollback().await?;
    Ok(Json(team))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    name: Option<String>,
    members: Option<Vec<TeamMember>>,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<Team>> {
    let id: TeamId = parse_id(&id, "team")?;
    if let Some(n) = &req.name {
        check_len("name", n.trim(), 1, 64)?;
    }
    if let Some(m) = &req.members {
        check_members(m)?;
    }
    let mut t = s.db.tenant(who.user).await?;
    let team = t
        .update_team(
            id,
            req.name.as_deref().map(str::trim),
            req.members.as_deref(),
        )
        .await?;
    t.commit().await?;
    Ok(Json(team))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: TeamId = parse_id(&id, "team")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_team(id).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn templates(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let list = t.team_templates().await?;
    t.rollback().await?;
    Ok(Json(json!({ "templates": list })))
}

#[derive(Deserialize)]
pub struct TemplateReq {
    name: String,
    /// 直接给出成员，或者从现有团队生成。
    spec: Option<TeamTemplateSpec>,
    team_id: Option<TeamId>,
}

pub async fn create_template(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<TemplateReq>,
) -> ApiResult<(StatusCode, Json<TeamTemplate>)> {
    check_len("name", req.name.trim(), 1, 64)?;
    let mut t = s.db.tenant(who.user).await?;
    let spec = match (req.spec, req.team_id) {
        (Some(spec), None) => spec,
        (None, Some(team)) => {
            let team = t.team(team).await?;
            let mut members = Vec::new();
            for m in team.members {
                let i = t.instance(m.instance_id).await?;
                members.push(TemplateMember {
                    agent_id: i.agent_id,
                    harness: Some(i.harness),
                    name: i.name,
                    role: m.role,
                });
            }
            TeamTemplateSpec { members }
        }
        _ => return Err(ApiError::invalid("give exactly one of spec or team_id")),
    };
    if spec.members.is_empty() || spec.members.len() > MAX_MEMBERS {
        return Err(ApiError::invalid(format!(
            "a template has 1-{MAX_MEMBERS} members"
        )));
    }
    for m in &spec.members {
        check_len("member name", &m.name, 1, 64)?;
        if s.templates.current(&m.agent_id).is_none() {
            return Err(ApiError::invalid(format!("unknown agent {}", m.agent_id)));
        }
    }
    let tpl = t.create_team_template(req.name.trim(), &spec).await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(tpl)))
}

pub async fn delete_template(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: TeamTemplateId = parse_id(&id, "template")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_team_template(id).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct AdoptReq {
    name: Option<String>,
}

/// 按模板领养一整个团队：每个成员领养一个新实例（带运行授权），再编成团队。
pub async fn adopt_template(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<AdoptReq>,
) -> ApiResult<(StatusCode, Json<Team>)> {
    let id: TeamTemplateId = parse_id(&id, "template")?;
    let mut t = s.db.tenant(who.user).await?;
    let tpl = t.team_template(id).await?;
    t.rollback().await?;
    let mut members = Vec::new();
    for (i, m) in tpl.spec.members.iter().enumerate() {
        let instance = control::adopt(
            &s.db,
            s.templates.as_ref(),
            who.user,
            &who.actor(),
            &m.agent_id,
            m.harness.as_deref(),
            &m.name,
        )
        .await?;
        let mut t = s.db.tenant(who.user).await?;
        t.create_run_grant(instance.id, None, &default_scope(&s), s.cfg.grant_ttl)
            .await?;
        t.commit().await?;
        members.push(TeamMember {
            instance_id: instance.id,
            role: if m.role == TeamRole::Lead {
                TeamRole::Lead
            } else {
                TeamRole::Member
            },
            position: u32::try_from(i).unwrap_or(u32::MAX),
        });
    }
    let name = req.name.unwrap_or(tpl.name);
    check_len("name", name.trim(), 1, 64)?;
    let mut t = s.db.tenant(who.user).await?;
    let team = t.create_team(name.trim(), &members).await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(team)))
}
