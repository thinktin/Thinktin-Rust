//! 项目里的运行和产出物（8.15）：成员只读。读走 `Db::member` 开的只读成员事务，库里的 project_* 函数只给白名单里的
//! 字段和事件；自己的运行的私人字段照旧走 `/v1/runs/{id}`。不是存活成员、项目删了、东西不在这个项目里的，一律 404。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::response::Response;
use orchestrator::artifacts::ArtifactError;
use proto::domain::{
    ArtifactId, InstanceId, ProjectArtifact, ProjectId, ProjectRun, ProjectRunEvents, RunId,
};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{ProjectRunFilter, ProjectTx};

use super::artifacts::{download_response, store as artifact_store};
use super::parse_id;
use crate::error::project_error;
use crate::{ApiError, ApiResult, AppState, Authed};

/// 查询参数里的 id：格式不对 422（路径里的才按找不到算）。
fn query_id<T: std::str::FromStr>(raw: Option<&str>, what: &str) -> ApiResult<Option<T>> {
    raw.map(|r| {
        r.parse()
            .map_err(|_| ApiError::invalid(format!("invalid {what}")))
    })
    .transpose()
}

async fn member(s: &AppState, who: &auth::service::Principal) -> ApiResult<ProjectTx> {
    s.db.member(who.user).await.map_err(project_error)
}

#[derive(Deserialize)]
pub struct RunsQuery {
    instance_id: Option<String>,
    before: Option<String>,
    limit: Option<i64>,
}

/// 项目的运行，新的在前：可以只看一个 agent 的，`before` 往下翻（一页 1 到 200，默认 50）。
pub async fn runs(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    Query(q): Query<RunsQuery>,
) -> ApiResult<Json<Value>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let filter = ProjectRunFilter {
        instance: query_id::<InstanceId>(q.instance_id.as_deref(), "instance_id")?,
        before: query_id::<RunId>(q.before.as_deref(), "before")?,
        limit: q.limit.unwrap_or(50).clamp(1, 200) as u32,
    };
    let mut m = member(&s, &who).await?;
    let runs = m.project_runs(id, &filter).await.map_err(project_error)?;
    m.finish().await?;
    Ok(Json(json!({ "runs": runs })))
}

pub async fn run(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, run)): Path<(String, String)>,
) -> ApiResult<Json<ProjectRun>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let run: RunId = parse_id(&run, "run")?;
    let mut m = member(&s, &who).await?;
    let r = m.project_run(id, run).await.map_err(project_error)?;
    m.finish().await?;
    Ok(Json(r))
}

/// 运行所在的整棵树（流水线的步骤、委派的子任务），先建的在前。
pub async fn tree(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, run)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let run: RunId = parse_id(&run, "run")?;
    let mut m = member(&s, &who).await?;
    let runs = m.project_run_tree(id, run).await.map_err(project_error)?;
    m.finish().await?;
    Ok(Json(json!({ "runs": runs })))
}

#[derive(Deserialize)]
pub struct EventsQuery {
    limit: Option<i64>,
}

/// 运行最近的事件（成员能看的种类和字段），旧的在前（1 到 500 条，默认 200）；更早的没给时 `truncated`。
pub async fn events(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, run)): Path<(String, String)>,
    Query(q): Query<EventsQuery>,
) -> ApiResult<Json<ProjectRunEvents>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let run: RunId = parse_id(&run, "run")?;
    let limit = q.limit.unwrap_or(200).clamp(1, 500) as u32;
    let mut m = member(&s, &who).await?;
    let events = m
        .project_run_events(id, run, limit)
        .await
        .map_err(project_error)?;
    m.finish().await?;
    Ok(Json(events))
}

#[derive(Deserialize)]
pub struct ArtifactsQuery {
    before: Option<String>,
    limit: Option<i64>,
}

/// 项目的产出物，新的在前（一页 1 到 200，默认 50）。
pub async fn artifacts(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    Query(q): Query<ArtifactsQuery>,
) -> ApiResult<Json<Value>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let before = query_id::<ArtifactId>(q.before.as_deref(), "before")?;
    let limit = q.limit.unwrap_or(50).clamp(1, 200) as u32;
    let mut m = member(&s, &who).await?;
    let list = m
        .project_artifacts(id, before, limit)
        .await
        .map_err(project_error)?;
    m.finish().await?;
    Ok(Json(json!({ "artifacts": list })))
}

pub async fn artifact(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, artifact)): Path<(String, String)>,
) -> ApiResult<Json<ProjectArtifact>> {
    let id: ProjectId = parse_id(&id, "project")?;
    let artifact: ArtifactId = parse_id(&artifact, "artifact")?;
    let mut m = member(&s, &who).await?;
    let a = m
        .project_artifact(id, artifact)
        .await
        .map_err(project_error)?;
    m.finish().await?;
    Ok(Json(a))
}

/// 下载项目产出物：一句 SQL 里核对还是存活成员、项目没删、密钥还在，再解密。响应头、标识和私人的下载一样。
/// 项目删了（密钥没了）的和读不到的一样 404。
pub async fn content(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, artifact)): Path<(String, String)>,
) -> ApiResult<Response> {
    let id: ProjectId = parse_id(&id, "project")?;
    let artifact: ArtifactId = parse_id(&artifact, "artifact")?;
    let (a, bytes, locale) = match artifact_store(&s)?
        .read_for_member(who.user, id, artifact)
        .await
    {
        Ok(v) => v,
        Err(ArtifactError::Gone | ArtifactError::Store(store::Error::NotFound)) => {
            return Err(ApiError::not_found("artifact"));
        }
        Err(ArtifactError::Store(e)) => return Err(project_error(e)),
        Err(e) => return Err(ApiError::internal(e)),
    };
    Ok(download_response(&s, locale, &a, bytes))
}
