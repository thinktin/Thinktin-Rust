//! 项目里的任务、负责人、botin 的限额、项目看板、删产出物（WBS 8.17）的写操作，网关调这里。每个函数一个 worker 事务：
//! 调 store（它核对身份、加锁）、记审计、发提醒，一起提交。动作人（`user`）只能来自登录态，`actor` 是记进审计的
//! `user:<设备 id>`。
//!
//! - 创建者派的任务、成员手动写的看板条目里有自己保险箱里的值的拒绝（422，App 也先查一遍，这里是硬挡）：项目里别的
//!   成员和他们的 botin 看得到这些文字。
//! - 主人按过“全部停止”的 botin 收到的任务先等主人确认（[`store::OWNER_CONFIRM_WAIT`]），主人收到一条提醒；确认、拒绝
//!   以后提醒算已读。

use std::sync::Arc;
use std::time::Duration;

use keyvault::Kms;
use proto::domain::{ArtifactId, BoardPostId, InstanceId, ProjectId, RunId, RunState, UserId};
use serde_json::json;
use store::{AgentLimits, BoardWriter, Db, NewProjectBoardPost};

/// 派任务、确认任务时签发的常设授权的有效期（和用户发起运行时的授权一样）。
pub const TASK_GRANT_TTL: Duration = crate::projects::PROJECT_GRANT_TTL;

/// 文字里有这个用户保险箱里的值（8.17）：项目里的文字别的成员看得到，不收。读不到保险箱时按没有算（App 也查，模型网关
/// 转发前还会再抹一遍）。
pub async fn contains_own_secret(db: &Db, kms: Arc<dyn Kms>, user: UserId, texts: &[&str]) -> bool {
    let scrubber = crate::vault::user_scrubber(db, kms, user).await;
    !scrubber.is_empty() && texts.iter().any(|t| scrubber.scrub(t).is_some())
}

fn secret_refused(what: &str) -> store::Error {
    store::Error::Invalid(format!(
        "the {what} contains one of your saved secrets; project members can read it, so remove it first"
    ))
}

/// 取消、确认以后给每个结束了的运行记一条状态事件（执行器续租时也会发现）。
async fn log_cancelled(
    w: &mut store::Tx<store::Worker>,
    runs: &[(RunId, InstanceId)],
    reason: &str,
) -> store::Result<()> {
    for (run, instance) in runs {
        w.append_event(
            *instance,
            Some(*run),
            "run.state",
            &json!({ "state": RunState::Cancelled, "reason": reason }),
        )
        .await?;
    }
    Ok(())
}

/// 创建者给项目里的 botin 派一个任务（`to` 没给的派给负责人）。返回新的运行。主人按过“全部停止”的，任务先等主人确认，
/// 主人收到提醒。审计：创建者一条 `project.task`；常设授权是这次签的，给主人记一条 `grant.issue`。
pub async fn create_task(
    db: &Db,
    kms: Arc<dyn Kms>,
    creator: UserId,
    actor: &str,
    p: ProjectId,
    to: Option<InstanceId>,
    prompt: &str,
) -> store::Result<RunId> {
    if contains_own_secret(db, kms, creator, &[prompt]).await {
        return Err(secret_refused("task"));
    }
    let mut w = db.worker().await?;
    let d = w
        .create_project_task(creator, p, to, prompt, TASK_GRANT_TTL)
        .await?;
    let target = d.run.instance_id.to_string();
    w.audit(
        Some(creator),
        actor,
        "project.task",
        Some(&p.to_string()),
        &json!({ "run_id": d.run.id, "held": d.needs_confirmation, "own_agent": d.owner == creator }),
    )
    .await?;
    if let Some(grant) = d.grant_issued {
        w.audit(
            Some(d.owner),
            "system",
            "grant.issue",
            Some(&target),
            &json!({ "grant_id": grant, "project_id": p, "reason": "project task" }),
        )
        .await?;
    }
    if d.needs_confirmation {
        let project = w.project_name(p).await?;
        let botin = w.instance_name(d.run.instance_id).await?;
        crate::projects::notify_held(
            &mut w,
            d.owner,
            p,
            &project,
            d.run.id,
            d.run.instance_id,
            &botin,
        )
        .await?;
    }
    w.commit().await?;
    Ok(d.run.id)
}

/// 在项目里停掉一个任务连同它的整棵子树（创建者任何一个，主人自己 botin 的）。审计 `project.run.cancel`。
pub async fn cancel_run(
    db: &Db,
    user: UserId,
    actor: &str,
    p: ProjectId,
    run: RunId,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    let (role, cancelled) = w.cancel_project_run(user, p, run).await?;
    log_cancelled(&mut w, &cancelled, "stopped in the project").await?;
    for (_, instance) in &cancelled {
        w.settle_owner_confirm_inbox(*instance).await?;
    }
    w.audit(
        Some(user),
        actor,
        "project.run.cancel",
        Some(&p.to_string()),
        &json!({ "run_id": run, "role": role, "cancelled": cancelled.len() }),
    )
    .await?;
    w.commit().await
}

/// 主人回答等确认的任务（按过“全部停止”以后派来的）：`accept` 签一个新的常设授权，这个 botin 在这个项目里所有等确认的
/// 任务都开始排队（暂停解除）；拒绝只取消这一个。审计：`project.task.confirm`，签了授权的再记 `grant.reissue`。
pub async fn confirm_task(
    db: &Db,
    owner: UserId,
    actor: &str,
    p: ProjectId,
    run: RunId,
    accept: bool,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    let (runs, grant) = w
        .confirm_project_task(owner, p, run, accept, TASK_GRANT_TTL)
        .await?;
    let instance = w.run(run).await?.instance_id;
    if !accept {
        log_cancelled(
            &mut w,
            &runs.iter().map(|r| (*r, instance)).collect::<Vec<_>>(),
            "the owner declined the task",
        )
        .await?;
    }
    w.settle_owner_confirm_inbox(instance).await?;
    w.audit(
        Some(owner),
        actor,
        "project.task.confirm",
        Some(&p.to_string()),
        &json!({ "run_id": run, "accept": accept, "runs": runs.len() }),
    )
    .await?;
    if let Some(grant) = grant {
        w.audit(
            Some(owner),
            actor,
            "grant.reissue",
            Some(&instance.to_string()),
            &json!({ "grant_id": grant, "project_id": p, "reason": "confirmed a project task" }),
        )
        .await?;
    }
    w.commit().await
}

/// 创建者设负责人（`None` 是不要负责人）。审计 `project.lead`：创建者一条，旧的、新的负责人的主人（不是创建者的）各一条。
pub async fn set_lead(
    db: &Db,
    user: UserId,
    actor: &str,
    p: ProjectId,
    lead: Option<InstanceId>,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    let change = w.set_project_lead(user, p, lead).await?;
    let detail = json!({
        "old": change.old.map(|(i, _)| i),
        "new": change.new.map(|(i, _)| i),
    });
    w.audit(
        Some(user),
        actor,
        "project.lead",
        Some(&p.to_string()),
        &detail,
    )
    .await?;
    let mut owners: Vec<UserId> = [change.old, change.new]
        .into_iter()
        .flatten()
        .map(|(_, o)| o)
        .filter(|o| *o != user)
        .collect();
    owners.sort_by_key(|o| o.0);
    owners.dedup();
    for owner in owners {
        w.audit(
            Some(owner),
            actor,
            "project.lead",
            Some(&p.to_string()),
            &detail,
        )
        .await?;
    }
    w.commit().await
}

/// 主人给自己派进项目的 botin 设 token 限额（每天的、总的，`None` 是不限）。审计 `project.agent_limits`。
pub async fn set_agent_limits(
    db: &Db,
    owner: UserId,
    actor: &str,
    p: ProjectId,
    instance: InstanceId,
    limits: AgentLimits,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.set_project_agent_limits(owner, p, instance, limits)
        .await?;
    w.audit(
        Some(owner),
        actor,
        "project.agent_limits",
        Some(&instance.to_string()),
        &json!({
            "project_id": p,
            "daily_token_limit": limits.daily_token_limit,
            "total_token_limit": limits.total_token_limit,
        }),
    )
    .await?;
    w.commit().await
}

/// 主人设的这个 botin 的限额（只有主人看得到）。
pub async fn agent_limits(
    db: &Db,
    owner: UserId,
    p: ProjectId,
    instance: InstanceId,
) -> store::Result<AgentLimits> {
    let mut w = db.worker().await?;
    let limits = w.project_agent_limits(owner, p, instance).await?;
    w.rollback().await?;
    Ok(limits)
}

/// 成员往项目看板上写一条（正文、标签先查过）。返回新条目。
pub async fn post_to_board(
    db: &Db,
    kms: Arc<dyn Kms>,
    user: UserId,
    p: ProjectId,
    body: String,
    tags: Vec<String>,
) -> store::Result<BoardPostId> {
    if contains_own_secret(db, kms, user, &[&body]).await {
        return Err(secret_refused("post"));
    }
    let mut w = db.worker().await?;
    let (id, _) = w
        .post_to_project_board(
            BoardWriter::Member(user),
            p,
            &NewProjectBoardPost { body, tags },
        )
        .await?;
    w.commit().await?;
    Ok(id)
}

/// 归档、取消归档项目看板上的一条（创建者，或者作者）。
pub async fn set_board_post_archived(
    db: &Db,
    user: UserId,
    p: ProjectId,
    post: BoardPostId,
    archived: bool,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.set_project_board_post_archived(user, p, post, archived)
        .await?;
    w.commit().await
}

/// 删项目看板上的一条（创建者，或者作者）。审计 `project.board_post.delete`。
pub async fn delete_board_post(
    db: &Db,
    user: UserId,
    actor: &str,
    p: ProjectId,
    post: BoardPostId,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.delete_project_board_post(user, p, post).await?;
    w.audit(
        Some(user),
        actor,
        "project.board_post.delete",
        Some(&p.to_string()),
        &json!({ "post_id": post }),
    )
    .await?;
    w.commit().await
}

/// 删项目里的一个产出物（创建者，或者产出物的主人；对象存储里的内容由后台清理）。审计 `project.artifact.delete`。
pub async fn delete_artifact(
    db: &Db,
    user: UserId,
    actor: &str,
    p: ProjectId,
    artifact: ArtifactId,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.delete_project_artifact(user, p, artifact).await?;
    w.audit(
        Some(user),
        actor,
        "project.artifact.delete",
        Some(&p.to_string()),
        &json!({ "artifact_id": artifact }),
    )
    .await?;
    w.commit().await
}

/// 这个人现在能不能在项目里派任务（`ProjectDetail.can_dispatch`）：是创建者、项目开着、派单开关开着。
pub async fn can_dispatch(db: &Db, detail: &proto::domain::ProjectDetail) -> store::Result<bool> {
    if detail.summary.role != proto::domain::ProjectRole::Creator
        || detail.summary.status != proto::domain::ProjectStatus::Active
    {
        return Ok(false);
    }
    let mut w = db.worker().await?;
    let on = w.project_dispatch_enabled().await?;
    w.rollback().await?;
    Ok(on)
}
