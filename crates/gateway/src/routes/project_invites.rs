//! 被邀请的一方（8.14）：发给我的邀请、凭链接令牌预览、接受、拒绝；拉黑。
//!
//! 链接令牌只放在请求正文里（不进网址路径，免得进访问日志）；格式不对的直接 404，和找不到、用过、过期、撤回的回一样的
//! 内容。按 id 的接口只认手机号邀请，链接邀请的 id 在这里永远 404。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use orchestrator::projects;
use proto::domain::{ProjectDetail, ProjectInviteId, ProjectInvitePreview, UserId};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{InviteKey, JoinTerms};

use super::parse_id;
use super::projects::{AgentReq, consent, cross_user, join_agents, max_instances};
use crate::error::project_error;
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 找不到邀请：所有情况一样的回答。
fn no_invite(e: store::Error) -> ApiError {
    match e {
        store::Error::NotFound => ApiError::not_found("invite"),
        other => other.into(),
    }
}

fn token_hash(token: &str) -> ApiResult<[u8; 32]> {
    auth::secrets::InviteToken::parse(token)
        .map(|t| t.hash())
        .map_err(|_| ApiError::not_found("invite"))
}

/// 预览里按配置填的：收不收非专属的 agent（`[api] mixed_project_agents`）。
fn with_config(s: &AppState, mut p: ProjectInvitePreview) -> ProjectInvitePreview {
    p.mixed_agents_allowed = s.cfg.mixed_project_agents;
    p
}

pub async fn mine(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    cross_user(&s)?;
    let list = projects::invites_for(&s.db, who.user).await?;
    Ok(Json(json!({ "invites": list })))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<ProjectInvitePreview>> {
    cross_user(&s)?;
    let id: ProjectInviteId = parse_id(&id, "invite")?;
    let p = projects::preview(&s.db, who.user, InviteKey::Phone(id))
        .await
        .map_err(no_invite)?;
    Ok(Json(with_config(&s, p)))
}

#[derive(Deserialize)]
pub struct ResolveReq {
    token: String,
}

/// 凭链接令牌看邀请（App 打开 `thinktin://join/<令牌>` 时）。
pub async fn resolve(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<ResolveReq>,
) -> ApiResult<Json<ProjectInvitePreview>> {
    cross_user(&s)?;
    let hash = token_hash(&req.token)?;
    let p = projects::preview(&s.db, who.user, InviteKey::Link(&hash))
        .await
        .map_err(no_invite)?;
    Ok(Json(with_config(&s, p)))
}

/// 加入时带上的：agent（见 [`AgentReq`]：已有的、标专属的、当场创建的）、预算、确认过的说明和它的版本。
#[derive(Deserialize)]
pub struct JoinReq {
    agents: Vec<AgentReq>,
    daily_token_limit: u64,
    total_token_limit: u64,
    #[serde(default)]
    consent: bool,
    /// App 显示的加入说明的版本；不带的按第 1 版算（老的 App），422。
    consent_version: Option<u32>,
    /// 只有凭链接接受时带。
    token: Option<String>,
}

impl JoinReq {
    fn terms(&self, s: &AppState) -> ApiResult<JoinTerms> {
        let consent = consent(self.consent, self.consent_version).ok_or_else(|| {
            ApiError::invalid("confirm what joining shares with the project (consent: true)")
        })?;
        Ok(JoinTerms {
            agents: join_agents(s, &self.agents)?,
            daily_token_limit: self.daily_token_limit,
            total_token_limit: self.total_token_limit,
            consent,
            mixed_allowed: s.cfg.mixed_project_agents,
            max_instances: max_instances(s),
        })
    }
}

async fn join(
    s: &AppState,
    who: &auth::service::Principal,
    key: InviteKey<'_>,
    terms: &JoinTerms,
) -> ApiResult<(StatusCode, Json<ProjectDetail>)> {
    let a = projects::accept(&s.db, s.kms.clone(), who.user, &who.actor(), key, terms)
        .await
        .map_err(no_invite)?;
    let detail = projects::detail(&s.db, who.user, a.project)
        .await
        .map_err(project_error)?;
    let status = if a.created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(detail)))
}

/// 接受发给我的手机号邀请：第一次 201，再接受一次 200（不改什么）。
pub async fn accept(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<JoinReq>,
) -> ApiResult<(StatusCode, Json<ProjectDetail>)> {
    cross_user(&s)?;
    let id: ProjectInviteId = parse_id(&id, "invite")?;
    let terms = req.terms(&s)?;
    join(&s, &who, InviteKey::Phone(id), &terms).await
}

/// 凭链接令牌接受。
pub async fn accept_link(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<JoinReq>,
) -> ApiResult<(StatusCode, Json<ProjectDetail>)> {
    cross_user(&s)?;
    let hash = token_hash(req.token.as_deref().unwrap_or_default())?;
    let terms = req.terms(&s)?;
    join(&s, &who, InviteKey::Link(&hash), &terms).await
}

#[derive(Deserialize, Default)]
pub struct DeclineReq {
    #[serde(default)]
    block: bool,
}

/// 拒绝发给我的手机号邀请；`{"block": true}` 顺便拉黑邀请人（邀请人那边看不出来）。正文可以不带。
pub async fn decline(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    body: axum::body::Bytes,
) -> ApiResult<StatusCode> {
    let id: ProjectInviteId = parse_id(&id, "invite")?;
    let block = if body.iter().all(u8::is_ascii_whitespace) {
        false
    } else {
        serde_json::from_slice::<DeclineReq>(&body)
            .map_err(|e| ApiError::invalid(e.to_string()))?
            .block
    };
    projects::decline(&s.db, who.user, &who.actor(), id, block)
        .await
        .map_err(no_invite)?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn blocks(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let list = projects::blocks(&s.db, who.user).await?;
    Ok(Json(json!({ "blocks": list })))
}

/// 拉黑（没有这个人 404）。
pub async fn block(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: UserId = parse_id(&id, "user")?;
    projects::block(&s.db, who.user, &who.actor(), id).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn unblock(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: UserId = parse_id(&id, "user")?;
    projects::unblock(&s.db, who.user, &who.actor(), id).await?;
    Ok(StatusCode::NO_CONTENT)
}
