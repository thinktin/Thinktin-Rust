//! 产出物（8.4）：按实例、按运行树列出，下载（解密后返回），删除。

use axum::Json;
use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::Response;
use proto::api::ErrorCode;
use proto::domain::{Artifact, ArtifactId, InstanceId, RunId};
use serde::Deserialize;
use serde_json::{Value, json};

use super::parse_id;
use crate::{ApiError, ApiResult, AppState, Authed};

fn store(s: &AppState) -> ApiResult<&orchestrator::artifacts::ArtifactStore> {
    s.artifacts
        .as_deref()
        .ok_or_else(|| ApiError::new(ErrorCode::Unavailable, "artifact storage is not configured"))
}

#[derive(Deserialize)]
pub struct ListQuery {
    limit: Option<i64>,
}

pub async fn for_instance(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    t.instance(id).await?;
    let list = t
        .instance_artifacts(id, q.limit.unwrap_or(100).clamp(1, 500))
        .await?;
    t.rollback().await?;
    Ok(Json(json!({ "artifacts": list })))
}

pub async fn for_run(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: RunId = parse_id(&id, "run")?;
    let mut t = s.db.tenant(who.user).await?;
    let run = t.run(id).await?;
    let list: Vec<Artifact> = t
        .tree_artifacts(run.root_run_id)
        .await?
        .into_iter()
        .map(|a| a.artifact)
        .collect();
    t.rollback().await?;
    Ok(Json(json!({ "artifacts": list })))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Artifact>> {
    let id: ArtifactId = parse_id(&id, "artifact")?;
    let mut t = s.db.tenant(who.user).await?;
    let a = t.artifact(id).await?;
    t.rollback().await?;
    Ok(Json(a.artifact))
}

/// 下载：解密后原样返回。按附件下载，避免浏览器把 agent 产出的 HTML 当页面执行。
pub async fn content(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let id: ArtifactId = parse_id(&id, "artifact")?;
    let mut t = s.db.tenant(who.user).await?;
    let a = t.artifact(id).await?;
    t.rollback().await?;
    let bytes = store(&s)?.read(&a).await.map_err(ApiError::internal)?;
    let mut resp = Response::new(Body::from(bytes));
    let headers = resp.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&a.artifact.content_type)
            .unwrap_or(HeaderValue::from_static("application/octet-stream")),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static("attachment"),
    );
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    Ok(resp)
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: ArtifactId = parse_id(&id, "artifact")?;
    let store = store(&s)?;
    let mut t = s.db.tenant(who.user).await?;
    let key = t.delete_artifact(id).await?;
    t.commit().await?;
    // 索引先删；内容删除失败只会留下无法再被引用的密文。
    if let Err(e) = store.delete_blob(&key).await {
        tracing::warn!(error = %e, "deleting artifact content failed");
    }
    Ok(StatusCode::NO_CONTENT)
}
