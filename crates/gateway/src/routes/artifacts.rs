//! 产出物（8.4）：按实例、按运行树列出，下载（解密后返回），删除。

use axum::Json;
use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::Response;
use proto::api::ErrorCode;
use proto::domain::{Artifact, ArtifactId, InstanceId, RunId};
use proto::labels;
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
    t.run(id).await?;
    // 和 agent 看到的一样：回答队友问题的运行只列这个问题里的，别的列整棵树（含各个问题里的，8.11）。
    let (root, whole) = t.artifact_scope(id).await?;
    let list: Vec<Artifact> = t
        .tree_artifacts(root, whole)
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

/// 文本类产出物：下载时末尾能加显式标识。内容类型是 agent 给的，文件扩展名也算：
/// agent 不能靠把 `.md` 标成别的类型来躲开标识。
fn is_labelable_text(content_type: &str, name: &str) -> bool {
    let base = content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    matches!(base.as_str(), "text/plain" | "text/markdown")
        || matches!(ext.as_str(), "txt" | "md" | "markdown")
}

/// 下载：解密后返回。按附件下载，避免浏览器把 agent 产出的 HTML 当页面执行。
/// 产出物是 agent 生成的（16.3）：响应头带隐式标识的元数据，纯文本和 Markdown 末尾加显式标识。
pub async fn content(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let id: ArtifactId = parse_id(&id, "artifact")?;
    let mut t = s.db.tenant(who.user).await?;
    let a = t.artifact(id).await?;
    let locale = t.user_locale(who.user).await?;
    t.rollback().await?;
    let mut bytes = store(&s)?.read(&a).await.map_err(ApiError::internal)?;
    if s.cfg.label_downloads && is_labelable_text(&a.artifact.content_type, &a.artifact.name) {
        bytes.extend_from_slice(labels::text_footer_in(locale, &s.cfg.content_producer).as_bytes());
    }
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
    if s.cfg.label_downloads {
        let meta =
            labels::AigcMetadata::generated(&s.cfg.content_producer, &a.artifact.id.to_string());
        if let Ok(v) = serde_json::to_string(&meta)
            .map_err(|_| ())
            .and_then(|j| HeaderValue::from_str(&j).map_err(|_| ()))
        {
            headers.insert("x-aigc", v);
        }
    }
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
