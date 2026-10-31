//! 共享看板（8.10）：用户的 agent 写的进展、决定、待别人处理的事。App 里能看、能写、能归档、能删。

use auth::service::Principal;
use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use proto::domain::{BoardPost, BoardPostId};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{BoardFilter, NewBoardPost, check_board_body, normalize_board_tags};

use super::parse_id;
use crate::{ApiJson, ApiResult, AppState, Authed};

#[derive(Deserialize)]
pub struct ListQuery {
    /// 只看带这个标签的。
    tag: Option<String>,
    /// 看归档了的（默认看没归档的）。
    #[serde(default)]
    archived: bool,
    before: Option<String>,
    limit: Option<i64>,
}

/// 新的在前，`before` 往下翻。
pub async fn list(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let before = q
        .before
        .as_deref()
        .map(|b| parse_id::<BoardPostId>(b, "board post"))
        .transpose()?;
    let tag = match q.tag.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
        Some(t) => Some(normalize_board_tags(&[t.to_owned()])?.remove(0)),
        None => None,
    };
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    let mut t = s.db.tenant(who.user).await?;
    let posts = t
        .board_posts(&BoardFilter {
            tag,
            archived: q.archived,
            before,
            limit,
        })
        .await?;
    t.rollback().await?;
    Ok(Json(json!({ "posts": posts })))
}

#[derive(Deserialize)]
pub struct PostReq {
    body: String,
    #[serde(default)]
    tags: Vec<String>,
}

/// 用户自己写一条（作者是用户；满了最早的自动归档）。保险箱里的密码换成引用再存（11.6）：看板上的内容
/// 所有 agent 都读得到。
pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<PostReq>,
) -> ApiResult<(StatusCode, Json<BoardPost>)> {
    check_board_body(&req.body)?;
    let tags = normalize_board_tags(&req.tags)?;
    // 换成引用以后可能变长：再查一次长度。
    let body = super::vault::scrub_user_text(&s, who.user, req.body.trim()).await;
    let body = check_board_body(&body)?;
    let mut t = s.db.tenant(who.user).await?;
    let (post, _) = t
        .post_to_board(&NewBoardPost {
            body,
            tags,
            ..NewBoardPost::default()
        })
        .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(post)))
}

pub async fn archive(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<BoardPost>> {
    set_archived(s, who, id, true).await
}

/// 取消归档：没归档的已经满了时 422，先归档别的。
pub async fn unarchive(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<BoardPost>> {
    set_archived(s, who, id, false).await
}

async fn set_archived(
    s: AppState,
    who: Principal,
    id: String,
    archived: bool,
) -> ApiResult<Json<BoardPost>> {
    let id: BoardPostId = parse_id(&id, "board post")?;
    let mut t = s.db.tenant(who.user).await?;
    let post = t.set_board_post_archived(id, archived).await?;
    t.commit().await?;
    Ok(Json(post))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: BoardPostId = parse_id(&id, "board post")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_board_post(id).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
