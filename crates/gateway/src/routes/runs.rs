//! 运行：给实例下任务、查看、取消、运行树。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use proto::domain::{InstanceId, Run, RunId, RunSource};
use serde::Deserialize;
use serde_json::{Value, json};
use store::NewRun;

use super::{check_len, parse_id};
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
    let mut t = s.db.tenant(who.user).await?;
    let instance = t.instance(id).await?;
    let run = t
        .create_run(&NewRun::new(
            id,
            RunSource::User,
            req.prompt.trim(),
            instance.agent_version,
        ))
        .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(run)))
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

pub async fn cancel(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Run>> {
    let id: RunId = parse_id(&id, "run")?;
    let mut t = s.db.tenant(who.user).await?;
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
