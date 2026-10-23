//! 收件箱（10.4）：全部通知（运行结果、审批、计划确认），带已读状态。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use proto::domain::InboxItemId;
use serde::Deserialize;
use serde_json::{Value, json};

use super::parse_id;
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 一次最多标记多少条。
const MAX_MARK: usize = 500;

#[derive(Deserialize)]
pub struct ListQuery {
    before: Option<String>,
    limit: Option<i64>,
    #[serde(default)]
    unread: bool,
}

pub async fn list(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let before = q
        .before
        .as_deref()
        .map(|b| parse_id::<InboxItemId>(b, "inbox item"))
        .transpose()?;
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    let mut t = s.db.tenant(who.user).await?;
    let items = t.inbox(before, limit, q.unread).await?;
    let unread = t.inbox_unread().await?;
    t.rollback().await?;
    Ok(Json(json!({ "items": items, "unread": unread })))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: InboxItemId = parse_id(&id, "inbox item")?;
    let mut t = s.db.tenant(who.user).await?;
    let item = t.inbox_item(id).await?;
    t.rollback().await?;
    Ok(Json(json!(item)))
}

#[derive(Deserialize)]
pub struct ReadReq {
    /// 只标这些。
    ids: Option<Vec<InboxItemId>>,
    /// 不给 `ids` 时：标到这一条（含）为止的全部；也不给就是全部。
    up_to: Option<InboxItemId>,
}

pub async fn mark_read(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<ReadReq>,
) -> ApiResult<Json<Value>> {
    if req.ids.as_ref().is_some_and(|ids| ids.len() > MAX_MARK) {
        return Err(ApiError::invalid(format!("at most {MAX_MARK} ids")));
    }
    if req.ids.is_some() && req.up_to.is_some() {
        return Err(ApiError::invalid("give ids or up_to, not both"));
    }
    let mut t = s.db.tenant(who.user).await?;
    let marked = t.mark_inbox_read(req.ids.as_deref(), req.up_to).await?;
    let unread = t.inbox_unread().await?;
    t.commit().await?;
    Ok(Json(json!({ "marked": marked, "unread": unread })))
}

pub async fn mark_unread(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: InboxItemId = parse_id(&id, "inbox item")?;
    let mut t = s.db.tenant(who.user).await?;
    t.mark_inbox_unread(id).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: InboxItemId = parse_id(&id, "inbox item")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_inbox_item(id).await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
