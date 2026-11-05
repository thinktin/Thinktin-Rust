//! 跨用户项目（8.14）：邀请、加入、撤回、退出、移出、拉黑。每个函数一个 worker 事务：调 store（它自己加锁、核对成员
//! 关系）、记审计、发回执，一起提交。动作人（`user`）只能来自登录态，`actor` 是记进审计的 `user:<设备 id>`。
//!
//! 审计：跨用户的动作给每个相关的人各记一条；审计里不记手机号，给一个人的那条不记另一个人的实例 id、模型厂商。
//! 回执都是 [`PushKind::Info`] 加 [`notice_subtype`] 的子类型；发给可能不认识的人的邀请通知不带邀请人能写的字。

use std::time::Duration;

use notify::PushKind;
use proto::domain::{
    BlockedUser, InstanceId, PROJECT_CONSENT_VERSION, PROJECT_INVITE_LINK_TTL_SECS,
    PROJECT_INVITE_PHONE_TTL_SECS, ProjectBudget, ProjectDetail, ProjectId, ProjectInvite,
    ProjectInviteId, ProjectInvitePreview, ProjectSummary, UserId, notice_subtype,
};
use serde_json::json;
use store::{Accepted, Consent, Db, Exit, InviteCaps, InviteKey, JoinTerms, Withdrawn};

use crate::outbox::{Notice, notify};
use crate::texts;

const PHONE_TTL: Duration = Duration::from_secs(PROJECT_INVITE_PHONE_TTL_SECS);
const LINK_TTL: Duration = Duration::from_secs(PROJECT_INVITE_LINK_TTL_SECS);

fn project_notice(project: ProjectId, title: &str, body: String, subtype: &str) -> Notice {
    let mut n = Notice::new(PushKind::Info, title, body).subtype(subtype);
    n.project = Some(project);
    n
}

/// 我是成员的进行中的项目。
pub async fn my_projects(db: &Db, user: UserId) -> store::Result<Vec<ProjectSummary>> {
    let mut w = db.worker().await?;
    let out = w.my_projects(user).await?;
    w.rollback().await?;
    Ok(out)
}

/// 项目详情（只给成员）。
pub async fn detail(db: &Db, user: UserId, project: ProjectId) -> store::Result<ProjectDetail> {
    let mut w = db.worker().await?;
    let out = w.project_detail(user, project).await?;
    w.rollback().await?;
    Ok(out)
}

/// 改项目的名字、目标（只有创建者）。
pub async fn update(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    name: Option<&str>,
    goal: Option<&str>,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.update_project(user, project, name, goal).await?;
    w.audit(
        Some(user),
        actor,
        "project.update",
        Some(&project.to_string()),
        &json!({ "project": project, "name": name.is_some(), "goal": goal.is_some() }),
    )
    .await?;
    w.commit().await
}

/// 按手机号邀请（`phone` 已经规范成 E.164）。不管号码是谁的，返回的都一样；该通知的人才收到通知。
pub async fn invite_phone(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    phone: &str,
    caps: InviteCaps,
) -> store::Result<ProjectInvite> {
    let mut w = db.worker().await?;
    // 加锁之前按号码查到收件人：store 按 D3 先锁他的用户行。
    let recipient = w.user_by_phone(phone).await?.map(|u| u.id);
    let created = w
        .create_phone_invite(user, project, phone, recipient, caps, PHONE_TTL)
        .await?;
    let invite = created.invite.id;
    if created.created {
        w.audit(
            Some(user),
            actor,
            "project.invite.create",
            Some(&project.to_string()),
            &json!({ "project": project, "invite": invite, "kind": "phone" }),
        )
        .await?;
    }
    if let Some(to) = created.deliver_to.filter(|_| created.created) {
        let locale = w.user_locale(to).await?;
        let (title, body) = texts::project_invite(locale);
        let mut notice = project_notice(
            project,
            title,
            body.to_owned(),
            notice_subtype::PROJECT_INVITE,
        );
        notice.project_invite = Some(invite);
        notice.dedupe_key = Some(format!("project_invite:{invite}"));
        notice.collapse_id = Some(format!("project_invite:{invite}"));
        notice.ttl = Some(PHONE_TTL);
        notify(&mut w, to, &notice).await?;
    }
    w.commit().await?;
    Ok(created.invite)
}

/// 邀请链接：调用方生成令牌、只把它交给邀请人一次，这里只存它的哈希。
pub async fn invite_link(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    token_hash: &[u8; 32],
    caps: InviteCaps,
) -> store::Result<ProjectInvite> {
    let mut w = db.worker().await?;
    let invite = w
        .create_link_invite(user, project, token_hash, caps, LINK_TTL)
        .await?;
    w.audit(
        Some(user),
        actor,
        "project.invite.create",
        Some(&project.to_string()),
        &json!({ "project": project, "invite": invite.id, "kind": "link" }),
    )
    .await?;
    w.commit().await?;
    Ok(invite)
}

/// 项目的邀请（只有创建者看得到）。
pub async fn invites(
    db: &Db,
    user: UserId,
    project: ProjectId,
) -> store::Result<Vec<ProjectInvite>> {
    let mut w = db.worker().await?;
    let out = w.project_invites(user, project).await?;
    w.rollback().await?;
    Ok(out)
}

/// 撤回邀请（只有创建者）。
pub async fn revoke_invite(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    invite: ProjectInviteId,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    if w.revoke_invite(user, project, invite).await? {
        w.audit(
            Some(user),
            actor,
            "project.invite.revoke",
            Some(&project.to_string()),
            &json!({ "project": project, "invite": invite }),
        )
        .await?;
    }
    w.commit().await
}

/// 发给我的手机号邀请。
pub async fn invites_for(db: &Db, user: UserId) -> store::Result<Vec<ProjectInvitePreview>> {
    let mut w = db.worker().await?;
    let out = w.invites_for(user).await?;
    w.rollback().await?;
    Ok(out)
}

/// 加入前看邀请。
pub async fn preview(
    db: &Db,
    user: UserId,
    key: InviteKey<'_>,
) -> store::Result<ProjectInvitePreview> {
    let mut w = db.worker().await?;
    let out = w.invite_preview(user, key).await?;
    w.rollback().await?;
    Ok(out)
}

/// 接受邀请、加入项目。第一次加入时告诉创建者。
pub async fn accept(
    db: &Db,
    user: UserId,
    actor: &str,
    key: InviteKey<'_>,
    terms: &JoinTerms,
) -> store::Result<Accepted> {
    let mut w = db.worker().await?;
    let a = w.accept_invite(user, key, terms).await?;
    if a.created {
        let target = a.project.to_string();
        w.audit(
            Some(user),
            actor,
            "project.join",
            Some(&target),
            &json!({
                "project": a.project,
                "invite": a.invite,
                "instances": a.agents,
                "vendors": a.vendors,
                "daily_token_limit": terms.daily_token_limit,
                "total_token_limit": terms.total_token_limit,
                "consent_version": PROJECT_CONSENT_VERSION,
            }),
        )
        .await?;
        w.audit(
            Some(a.creator),
            actor,
            "project.member_joined",
            Some(&target),
            &json!({ "project": a.project, "invite": a.invite, "member": user }),
        )
        .await?;
        let locale = w.user_locale(a.creator).await?;
        let (title, body) = texts::project_joined(
            locale,
            a.member_name.as_deref(),
            &a.project_name,
            a.agents.len(),
        );
        let mut notice = project_notice(a.project, title, body, notice_subtype::PROJECT_JOINED);
        notice.dedupe_key = Some(format!("project_joined:{}", a.invite));
        notify(&mut w, a.creator, &notice).await?;
    }
    w.commit().await?;
    Ok(a)
}

/// 拒绝发给我的邀请；`block` 顺便拉黑邀请人。
pub async fn decline(
    db: &Db,
    user: UserId,
    actor: &str,
    invite: ProjectInviteId,
    block: bool,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.decline_invite(user, invite, block).await?;
    let action = if block {
        "user.block"
    } else {
        "project.invite.decline"
    };
    w.audit(
        Some(user),
        actor,
        action,
        None,
        &json!({ "invite": invite }),
    )
    .await?;
    w.commit().await
}

/// 往项目里加自己的 agent（成员要带上确认）。返回真正加进去的。
pub async fn add_agents(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    agents: &[InstanceId],
    consent: Option<Consent>,
) -> store::Result<Vec<InstanceId>> {
    let mut w = db.worker().await?;
    let added = w.add_project_agents(user, project, agents, consent).await?;
    if !added.is_empty() {
        let vendors = w.instance_vendors(user, &added).await?;
        w.audit(
            Some(user),
            actor,
            "project.agents.add",
            Some(&project.to_string()),
            &json!({
                "project": project,
                "instances": added,
                "vendors": vendors,
                "consent_version": consent.map(|c| c.version),
            }),
        )
        .await?;
    }
    w.commit().await?;
    Ok(added)
}

/// 撤回项目里的一个 agent（主人或创建者）。创建者撤了别人的告诉主人；主人自己撤的告诉创建者。
pub async fn withdraw_agent(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    instance: InstanceId,
) -> store::Result<Withdrawn> {
    let mut w = db.worker().await?;
    let out = w.withdraw_project_agent(user, project, instance).await?;
    if !out.already_left {
        let target = project.to_string();
        let stopped =
            json!({ "runs_cancelled": out.runs_cancelled, "grants_revoked": out.grants_revoked });
        // 主人的那条记实例；创建者撤别人的，创建者那条只记是谁的 agent。
        w.audit(
            Some(out.owner),
            actor,
            "project.agent.withdraw",
            Some(&target),
            &json!({ "project": project, "instance": instance, "by": user, "stopped": stopped }),
        )
        .await?;
        if user != out.owner {
            w.audit(
                Some(user),
                actor,
                "project.agent.withdraw",
                Some(&target),
                &json!({ "project": project, "owner": out.owner }),
            )
            .await?;
            let locale = w.user_locale(out.owner).await?;
            let (title, body) = texts::project_agent_removed(locale, &out.name, &out.project_name);
            let notice =
                project_notice(project, title, body, notice_subtype::PROJECT_AGENT_REMOVED);
            notify(&mut w, out.owner, &notice).await?;
        } else if out.owner != out.creator {
            let locale = w.user_locale(out.creator).await?;
            let (title, body) = texts::project_agent_left(
                locale,
                out.owner_name.as_deref(),
                &out.name,
                &out.project_name,
            );
            let notice = project_notice(project, title, body, notice_subtype::PROJECT_AGENT_LEFT);
            notify(&mut w, out.creator, &notice).await?;
        }
    }
    w.commit().await?;
    Ok(out)
}

/// 退出项目（创建者不能退出）。告诉创建者。
pub async fn leave(db: &Db, user: UserId, actor: &str, project: ProjectId) -> store::Result<Exit> {
    let mut w = db.worker().await?;
    let exit = w.leave_project(user, project).await?;
    let target = project.to_string();
    w.audit(
        Some(user),
        actor,
        "project.leave",
        Some(&target),
        &json!({
            "project": project,
            "runs_cancelled": exit.runs_cancelled,
            "grants_revoked": exit.grants_revoked,
        }),
    )
    .await?;
    w.audit(
        Some(exit.creator),
        actor,
        "project.member_left",
        Some(&target),
        &json!({ "project": project, "member": user }),
    )
    .await?;
    let locale = w.user_locale(exit.creator).await?;
    let (title, body) =
        texts::project_left(locale, exit.member_name.as_deref(), &exit.project_name);
    let notice = project_notice(project, title, body, notice_subtype::PROJECT_LEFT);
    notify(&mut w, exit.creator, &notice).await?;
    w.commit().await?;
    Ok(exit)
}

/// 创建者把成员移出项目。告诉被移出的人。
pub async fn remove_member(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    member: UserId,
) -> store::Result<Exit> {
    let mut w = db.worker().await?;
    let exit = w.remove_project_member(user, project, member).await?;
    if exit.changed {
        let target = project.to_string();
        w.audit(
            Some(user),
            actor,
            "project.member.remove",
            Some(&target),
            &json!({ "project": project, "member": member }),
        )
        .await?;
        w.audit(
            Some(member),
            actor,
            "project.removed",
            Some(&target),
            &json!({
                "project": project,
                "runs_cancelled": exit.runs_cancelled,
                "grants_revoked": exit.grants_revoked,
            }),
        )
        .await?;
        let locale = w.user_locale(member).await?;
        let (title, body) = texts::project_removed(locale, &exit.project_name);
        let notice = project_notice(project, title, body, notice_subtype::PROJECT_REMOVED);
        notify(&mut w, member, &notice).await?;
    }
    w.commit().await?;
    Ok(exit)
}

/// 设我在项目里的预算。
pub async fn set_budget(
    db: &Db,
    user: UserId,
    actor: &str,
    project: ProjectId,
    budget: &ProjectBudget,
) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.set_project_budget(user, project, budget).await?;
    w.audit(
        Some(user),
        actor,
        "project.budget.set",
        Some(&project.to_string()),
        &json!({ "project": project, "budget": budget }),
    )
    .await?;
    w.commit().await
}

/// 拉黑一个人：他发来的手机号邀请不再送达。
pub async fn block(db: &Db, user: UserId, actor: &str, blocked: UserId) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.block_user(user, blocked).await?;
    w.audit(
        Some(user),
        actor,
        "user.block",
        None,
        &json!({ "blocked": blocked }),
    )
    .await?;
    w.commit().await
}

/// 取消拉黑。
pub async fn unblock(db: &Db, user: UserId, actor: &str, blocked: UserId) -> store::Result<()> {
    let mut w = db.worker().await?;
    w.unblock_user(user, blocked).await?;
    w.audit(
        Some(user),
        actor,
        "user.unblock",
        None,
        &json!({ "blocked": blocked }),
    )
    .await?;
    w.commit().await
}

/// 我拉黑的人。
pub async fn blocks(db: &Db, user: UserId) -> store::Result<Vec<BlockedUser>> {
    let mut w = db.worker().await?;
    let out = w.blocks(user).await?;
    w.rollback().await?;
    Ok(out)
}

/// 实例删了以后（租户事务提交之后）把它从项目里撤下。审计已经由删实例记了。
pub async fn retire_deleted_instance(
    db: &Db,
    user: UserId,
    instance: InstanceId,
) -> store::Result<u64> {
    let mut w = db.worker().await?;
    let n = w.retire_deleted_instance(user, instance).await?;
    w.commit().await?;
    Ok(n)
}

/// 每批这么多条。
pub const SWEEP_BATCH: u64 = 500;
/// 一轮最多这么多批，剩下的下一轮接着做。
pub const SWEEP_BATCHES: usize = 20;
/// 结束的邀请留这么久（明文手机号不久留）。
pub const INVITE_RETENTION: Duration = Duration::from_secs(30 * 24 * 3600);

/// 后台维护（每批一个事务，都不等锁）：到期的邀请标过期、实例删了还挂在项目里的 agent 撤下、结束 30 天的邀请删掉。
/// 返回处理了几条。
pub async fn sweep(db: &Db) -> store::Result<u64> {
    let mut total = 0;
    for _ in 0..SWEEP_BATCHES {
        let mut w = db.worker().await?;
        let n = w.expire_project_invites(SWEEP_BATCH).await?;
        w.commit().await?;
        total += n;
        if n < SWEEP_BATCH {
            break;
        }
    }
    let mut w = db.worker().await?;
    total += w.retire_deleted_project_agents(SWEEP_BATCH).await?;
    w.commit().await?;
    for _ in 0..SWEEP_BATCHES {
        let mut w = db.worker().await?;
        let n = w
            .purge_project_invites(INVITE_RETENTION, SWEEP_BATCH)
            .await?;
        w.commit().await?;
        total += n;
        if n < SWEEP_BATCH {
            break;
        }
    }
    Ok(total)
}
