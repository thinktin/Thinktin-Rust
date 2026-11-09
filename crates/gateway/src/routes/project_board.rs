//! 项目看板（WBS 8.17）：归项目所有，成员在 App 里、成员的 botin 用看板工具都能写，成员都能读。读走成员的只读事务，写经
//! `orchestrator::project_tasks`（worker）。不是成员、项目删了、条目不在这个项目里的 404（归档了的项目写也 404）；归档、
//! 删别人写的（不是创建者）403；每人每天手动写 50 条，超了 429；有自己保险箱里的值的 422。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use orchestrator::project_tasks;
use proto::domain::{BoardPostId, ProjectBoardPost, ProjectId};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{BoardFilter, check_board_body, normalize_board_tags};

use super::parse_id;
use crate::error::project_error;
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 一次最多读这么多条（默认 20）。
const MAX_READ: i64 = 50;

async fn post_view(
    s: &AppState,
    who: &auth::service::Principal,
    p: ProjectId,
    post: BoardPostId,
) -> ApiResult<ProjectBoardPost> {
    let mut m = s.db.member(who.user).await.map_err(project_error)?;
    let v = m.project_board_post(p, post).await.map_err(project_error)?;
    m.finish().await?;
    Ok(v)
}

#[derive(Deserialize)]
pub struct ListQuery {
    tag: Option<String>,
    #[serde(default)]
    archived: bool,
    before: Option<String>,
    limit: Option<i64>,
}

/// 新的在前，`before` 往下翻；可以只看带某个标签的、只看归档了的。
pub async fn list(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let p: ProjectId = parse_id(&id, "project")?;
    let before = q
        .before
        .as_deref()
        .map(|b| {
            b.parse::<BoardPostId>()
                .map_err(|_| ApiError::invalid("invalid before"))
        })
        .transpose()?;
    let tag = match q.tag.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
        Some(t) => Some(normalize_board_tags(&[t.to_owned()])?.remove(0)),
        None => None,
    };
    let filter = BoardFilter {
        tag,
        archived: q.archived,
        before,
        limit: q.limit.unwrap_or(20).clamp(1, MAX_READ),
    };
    let mut m = s.db.member(who.user).await.map_err(project_error)?;
    let posts = m.project_board(p, &filter).await.map_err(project_error)?;
    m.finish().await?;
    Ok(Json(json!({ "posts": posts })))
}

#[derive(Deserialize)]
pub struct PostReq {
    body: String,
    #[serde(default)]
    tags: Vec<String>,
}

/// 成员自己写一条（作者是本人；满了最早的自动归档）：201 和这一条。
pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<PostReq>,
) -> ApiResult<(StatusCode, Json<ProjectBoardPost>)> {
    let p: ProjectId = parse_id(&id, "project")?;
    let body = check_board_body(&req.body)?;
    let tags = normalize_board_tags(&req.tags)?;
    let post = project_tasks::post_to_board(&s.db, s.kms.clone(), who.user, p, body, tags)
        .await
        .map_err(project_error)?;
    Ok((
        StatusCode::CREATED,
        Json(post_view(&s, &who, p, post).await?),
    ))
}

async fn set_archived(
    s: AppState,
    who: auth::service::Principal,
    id: String,
    post: String,
    archived: bool,
) -> ApiResult<Json<ProjectBoardPost>> {
    let p: ProjectId = parse_id(&id, "project")?;
    let post: BoardPostId = parse_id(&post, "board post")?;
    project_tasks::set_board_post_archived(&s.db, who.user, p, post, archived)
        .await
        .map_err(project_error)?;
    Ok(Json(post_view(&s, &who, p, post).await?))
}

/// 归档（创建者，或者作者：自己写的、自己的 botin 写的）。
pub async fn archive(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, post)): Path<(String, String)>,
) -> ApiResult<Json<ProjectBoardPost>> {
    set_archived(s, who, id, post, true).await
}

/// 取消归档；没归档的已经满了 422（先归档别的）。
pub async fn unarchive(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, post)): Path<(String, String)>,
) -> ApiResult<Json<ProjectBoardPost>> {
    set_archived(s, who, id, post, false).await
}

/// 删掉一条（创建者，或者作者）。
pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, post)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let p: ProjectId = parse_id(&id, "project")?;
    let post: BoardPostId = parse_id(&post, "board post")?;
    project_tasks::delete_board_post(&s.db, who.user, &who.actor(), p, post)
        .await
        .map_err(project_error)?;
    Ok(StatusCode::NO_CONTENT)
}
