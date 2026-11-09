//! 项目里的任务、负责人、botin 限额、删产出物（WBS 8.17）。写经 `orchestrator::project_tasks`（worker 事务，store 里核对
//! 身份、加锁），返回的东西按调用者的成员视图重读。动作人只来自登录态。
//!
//! 状态码：不是成员、项目删了、东西不在这个项目里 404（归档了的项目写也 404）；成员调只有创建者能用的 403；派单开关关着
//! 503 `unavailable`；botin 不是专属的 409 `agent_not_isolated`；主人冻结了、退出了 409 `agent_unavailable`；排的任务太多
//! 409 `agent_busy`；主人的预算用完了 409 `budget_reached`；任务里有自己保险箱里的值 422。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use orchestrator::project_tasks;
use proto::domain::{
    ArtifactId, InstanceId, ProjectBudget, ProjectDetail, ProjectId, ProjectRun, RunId,
};
use serde::Deserialize;
use store::AgentLimits;

use super::{check_len, parse_id};
use crate::error::project_error;
use crate::{ApiJson, ApiResult, AppState, Authed};

/// 任务最长这么多字。
const MAX_TASK_CHARS: usize = 32_000;

async fn project_run(
    s: &AppState,
    who: &auth::service::Principal,
    p: ProjectId,
    run: RunId,
) -> ApiResult<ProjectRun> {
    let mut m = s.db.member(who.user).await.map_err(project_error)?;
    let r = m.project_run(p, run).await.map_err(project_error)?;
    m.finish().await?;
    Ok(r)
}

#[derive(Deserialize)]
pub struct TaskReq {
    prompt: String,
    /// 派给哪个 botin；不给的派给负责人。
    #[serde(default)]
    instance_id: Option<InstanceId>,
}

/// 创建者给项目里的 botin 派一个任务（botin 是别人的也行，花的算 botin 主人的）：201 和成员看到的这个任务。主人按过
/// “全部停止”的，任务先等主人确认（`state` 是 `queued`，主人收到提醒）。没有负责人又没给 `instance_id`、不是项目里的
/// botin 422。
pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<TaskReq>,
) -> ApiResult<(StatusCode, Json<ProjectRun>)> {
    let p: ProjectId = parse_id(&id, "project")?;
    let prompt = req.prompt.trim();
    check_len("prompt", prompt, 1, MAX_TASK_CHARS)?;
    let run = project_tasks::create_task(
        &s.db,
        s.kms.clone(),
        who.user,
        &who.actor(),
        p,
        req.instance_id,
        prompt,
    )
    .await
    .map_err(project_error)?;
    Ok((
        StatusCode::CREATED,
        Json(project_run(&s, &who, p, run).await?),
    ))
}

/// 停掉一个任务连同它的整棵子树（委派出去的、问出去的）：创建者哪个都行，成员只能停自己 botin 的（403）；已经结束的 409。
pub async fn cancel(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, run)): Path<(String, String)>,
) -> ApiResult<Json<ProjectRun>> {
    let p: ProjectId = parse_id(&id, "project")?;
    let run: RunId = parse_id(&run, "run")?;
    project_tasks::cancel_run(&s.db, who.user, &who.actor(), p, run)
        .await
        .map_err(project_error)?;
    Ok(Json(project_run(&s, &who, p, run).await?))
}

#[derive(Deserialize)]
pub struct ConfirmReq {
    /// true“做”：这个 botin 在项目里等确认的任务都开始，之后派来的不再问；false“不做”：只取消这一个。
    accept: bool,
}

/// 主人回答等确认的任务（按过“全部停止”以后派给自己 botin 的）。不是自己 botin 的 403；不在等确认的 409。
pub async fn confirm(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, run)): Path<(String, String)>,
    ApiJson(req): ApiJson<ConfirmReq>,
) -> ApiResult<Json<ProjectRun>> {
    let p: ProjectId = parse_id(&id, "project")?;
    let run: RunId = parse_id(&run, "run")?;
    project_tasks::confirm_task(&s.db, who.user, &who.actor(), p, run, req.accept)
        .await
        .map_err(project_error)?;
    Ok(Json(project_run(&s, &who, p, run).await?))
}

#[derive(Deserialize)]
pub struct LeadReq {
    /// 新的负责人；null 是不要负责人。
    instance_id: Option<InstanceId>,
}

/// 创建者设负责人。有别人加入过的项目只能是专属于它的 botin（409 `agent_not_isolated`）；不是项目里的 botin 422。
pub async fn set_lead(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<LeadReq>,
) -> ApiResult<Json<ProjectDetail>> {
    let p: ProjectId = parse_id(&id, "project")?;
    project_tasks::set_lead(&s.db, who.user, &who.actor(), p, req.instance_id)
        .await
        .map_err(project_error)?;
    Ok(Json(
        orchestrator::projects::detail(&s.db, who.user, p)
            .await
            .map_err(project_error)?,
    ))
}

/// botin 的限额和成员的预算一样的 JSON：`{"daily_token_limit": n|null, "total_token_limit": n|null}`。
fn limits_json(l: AgentLimits) -> ProjectBudget {
    ProjectBudget {
        daily_token_limit: l.daily_token_limit,
        total_token_limit: l.total_token_limit,
    }
}

/// 主人设的这个 botin 在项目里的 token 限额（只有主人：别人的 403）。
pub async fn limits(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, instance)): Path<(String, String)>,
) -> ApiResult<Json<ProjectBudget>> {
    let p: ProjectId = parse_id(&id, "project")?;
    let instance: InstanceId = parse_id(&instance, "agent")?;
    let l = project_tasks::agent_limits(&s.db, who.user, p, instance)
        .await
        .map_err(project_error)?;
    Ok(Json(limits_json(l)))
}

/// 主人给自己派进项目的 botin 设 token 限额（每天的、总的；null 是不限）：别人派的活按它和主人在项目里的预算取紧的挡。
/// 每天的不能超过总的（422）。
pub async fn set_limits(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, instance)): Path<(String, String)>,
    ApiJson(req): ApiJson<ProjectBudget>,
) -> ApiResult<Json<ProjectBudget>> {
    let p: ProjectId = parse_id(&id, "project")?;
    let instance: InstanceId = parse_id(&instance, "agent")?;
    let limits = AgentLimits {
        daily_token_limit: req.daily_token_limit,
        total_token_limit: req.total_token_limit,
    };
    project_tasks::set_agent_limits(&s.db, who.user, &who.actor(), p, instance, limits)
        .await
        .map_err(project_error)?;
    Ok(Json(limits_json(limits)))
}

/// 删项目里的一个产出物（创建者，或者产出物的主人；别人 403）。
pub async fn delete_artifact(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, artifact)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let p: ProjectId = parse_id(&id, "project")?;
    let artifact: ArtifactId = parse_id(&artifact, "artifact")?;
    project_tasks::delete_artifact(&s.db, who.user, &who.actor(), p, artifact)
        .await
        .map_err(project_error)?;
    Ok(StatusCode::NO_CONTENT)
}
