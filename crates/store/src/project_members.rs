//! 项目成员和项目 agent 的变化（8.14，docs/progress/drafts/projects-8.14-plan.md 第 2.6 节）：加 agent、撤回 agent、退出、
//! 移出、设预算，实例删了以后把它从项目里撤下。都在 `Tx<Worker>` 里，按 D3 的顺序加锁：用户行 → 项目锁 → 自己的成员行 →
//! 别人的成员行 → 项目 agent 行 → 运行 → 实例（令牌代数）。
//!
//! 撤回、退出、移出时先停掉这个项目里的运行、吊销项目里的授权（8.14 还没有项目运行，都是 0 行；8.17 起才有），同一个实例的
//! 私人运行和授权不动。

use std::collections::{HashMap, HashSet};

use proto::domain::{
    InstanceId, MAX_PROJECT_AGENTS, MAX_TOKEN_LIMIT, ProjectBudget, ProjectId, ProjectRole,
    ProjectStatus, UserId,
};
use uuid::Uuid;

use crate::instances::NewInstance;
use crate::project_invites::{Consent, JoinAgent};
use crate::projects::LockedUser;
use crate::{Error, ProjectCap, Result, Tx, Worker, signed, to_json, unsigned};

/// 撤回了一个项目 agent。
#[derive(Debug, Clone)]
pub struct Withdrawn {
    pub project: ProjectId,
    pub project_name: String,
    pub creator: UserId,
    /// agent 的主人。
    pub owner: UserId,
    pub owner_name: Option<String>,
    /// 实例的名字。
    pub name: String,
    /// 之前已经撤下了：这次什么也没改。
    pub already_left: bool,
    pub runs_cancelled: u64,
    pub grants_revoked: u64,
}

/// 一个成员离开了项目（自己退出或被移出）。
#[derive(Debug, Clone)]
pub struct Exit {
    pub project: ProjectId,
    pub project_name: String,
    pub creator: UserId,
    pub member: UserId,
    pub member_name: Option<String>,
    /// false：之前已经离开了，这次什么也没改。
    pub changed: bool,
    pub runs_cancelled: u64,
    pub grants_revoked: u64,
}

/// 请求里的 agent：1 到 30 个（当场领养的也算），已有的不重复。
pub(crate) fn check_join_agents(agents: &[JoinAgent]) -> Result<()> {
    if agents.is_empty() || agents.len() as u64 > MAX_PROJECT_AGENTS {
        return Err(Error::Invalid(format!(
            "choose 1 to {MAX_PROJECT_AGENTS} agents"
        )));
    }
    let mut seen = HashSet::new();
    for a in agents {
        if let JoinAgent::Existing { id, .. } = a
            && !seen.insert(*id)
        {
            return Err(Error::Invalid("an agent is listed twice".into()));
        }
    }
    Ok(())
}

/// 列出来的已有实例：（id，标不标专属，确认过混用的提示）。
fn existing_flags(agents: &[JoinAgent]) -> impl Iterator<Item = (Uuid, bool, bool)> + '_ {
    agents.iter().filter_map(|a| match a {
        JoinAgent::Existing {
            id,
            dedicate,
            ack_shared_memory,
        } => Some((id.0, *dedicate, *ack_shared_memory)),
        JoinAgent::Adopt(_) => None,
    })
}

/// 成员的预算：两个都要有，各自 1 到 [`MAX_TOKEN_LIMIT`]，每天的不超过总的。
pub(crate) fn check_budget(daily: u64, total: u64) -> Result<()> {
    if !(1..=MAX_TOKEN_LIMIT).contains(&daily) || !(1..=MAX_TOKEN_LIMIT).contains(&total) {
        return Err(Error::Invalid(format!(
            "token limits must be between 1 and {MAX_TOKEN_LIMIT}"
        )));
    }
    if daily > total {
        return Err(Error::Invalid(
            "the daily token limit cannot exceed the total".into(),
        ));
    }
    Ok(())
}

impl Tx<Worker> {
    /// 项目里还在的 agent 有几个（实例删了的不算），以及 `ids` 里哪些已经在项目里。
    pub(crate) async fn live_agents(
        &mut self,
        project: ProjectId,
        ids: &[Uuid],
    ) -> Result<(u64, HashSet<Uuid>)> {
        let (n, live): (i64, Vec<Uuid>) = sqlx::query_as(
            "SELECT count(*), coalesce(array_agg(a.instance_id) FILTER (WHERE a.instance_id = ANY($2)), '{}') \
               FROM project_agents a JOIN instances i ON i.id = a.instance_id AND i.state <> 'deleted' \
              WHERE a.project_id = $1 AND a.left_at IS NULL",
        )
        .bind(project.0)
        .bind(ids)
        .fetch_one(self.conn())
        .await?;
        Ok((unsigned(n, "agents")?, live.into_iter().collect()))
    }

    /// 加入、加 agent 时当场领养新实例（8.16）：按用户加咨询锁数实例（和领养同一个键），加上这次要领养的超过上限的
    /// `InstanceLimit`。D3 里在咨询锁那一层：调用方在锁邀请行、agent 行之前调。
    pub(crate) async fn reserve_adopts(
        &mut self,
        user: UserId,
        agents: &[JoinAgent],
        max_instances: u64,
    ) -> Result<()> {
        let adopts = agents
            .iter()
            .filter(|a| matches!(a, JoinAgent::Adopt(_)))
            .count() as u64;
        if adopts == 0 {
            return Ok(());
        }
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("instances/{user}"))
            .execute(self.conn())
            .await?;
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM instances WHERE user_id = $1 AND state <> 'deleted'",
        )
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        if max_instances > 0 && unsigned(n, "instances")? + adopts > max_instances {
            return Err(Error::InstanceLimit { max: max_instances });
        }
        Ok(())
    }

    /// 把 `user` 的这些 agent 放进项目（8.16，加入和加 agent 共用）。`shared`：跨用户的项目（混用实例要允许、要确认）。
    /// 已经在项目里的跳过。顺序（D3 之后）：数 agent → 要标专属的实例的出网请求 → 按 id 顺序锁自己的实例（标专属的
    /// FOR UPDATE，别的 FOR SHARE，和删实例互斥）→ 标专属（换工作区）→ 领养 → 写 agent 行。返回真正放进去的。
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn place_agents(
        &mut self,
        user: UserId,
        project: ProjectId,
        agents: &[JoinAgent],
        shared: bool,
        mixed_allowed: bool,
        consented: bool,
    ) -> Result<Vec<InstanceId>> {
        let existing: Vec<(Uuid, bool, bool)> = existing_flags(agents).collect();
        let adopts: Vec<&NewInstance> = agents
            .iter()
            .filter_map(|a| match a {
                JoinAgent::Adopt(n) => Some(n),
                JoinAgent::Existing { .. } => None,
            })
            .collect();
        let ids: Vec<Uuid> = existing.iter().map(|(id, _, _)| *id).collect();
        let (live, already) = self.live_agents(project, &ids).await?;
        let new: Vec<(Uuid, bool, bool)> = existing
            .into_iter()
            .filter(|(id, _, _)| !already.contains(id))
            .collect();
        // 列出来的都要是自己没删的实例（已经在项目里的也查，和以前一样）；要标专属的是这次新放进去的。
        let mut all: Vec<(Uuid, bool)> = ids
            .iter()
            .map(|id| (*id, new.iter().any(|(n, d, _)| n == id && *d)))
            .collect();
        all.sort_unstable_by_key(|(id, _)| *id);
        let mut sorted = new.clone();
        sorted.sort_unstable_by_key(|(id, _, _)| *id);
        for (id, dedicate) in &all {
            if *dedicate {
                self.prelock_egress(InstanceId(*id)).await?;
            }
        }
        // 自己没删的实例；不是的 Invalid，不说是谁的（和邀请找不到区分开：App 要让用户换一个 agent）。
        let mut spaces = HashMap::new();
        for (id, dedicate) in &all {
            let sql = if *dedicate {
                "SELECT workspace_project_id FROM instances                   WHERE id = $1 AND user_id = $2 AND state <> 'deleted' FOR UPDATE"
            } else {
                "SELECT workspace_project_id FROM instances                   WHERE id = $1 AND user_id = $2 AND state <> 'deleted' FOR SHARE"
            };
            let space: Option<Option<Uuid>> = sqlx::query_scalar(sql)
                .bind(id)
                .bind(user.0)
                .fetch_optional(self.conn())
                .await?;
            let Some(space) = space else {
                return Err(Error::Invalid(
                    "choose your own agents (one of them is not yours or was deleted)".into(),
                ));
            };
            spaces.insert(*id, space);
        }
        // 已经在项目里、这次要标专属、还不是专属于这个项目的：放进来的时候不改，要用改 agent 的接口（8.16 评审：不能
        // 悄悄当成成功）。
        for (id, dedicate, _) in existing_flags(agents) {
            if dedicate && already.contains(&id) && spaces[&id] != Some(project.0) {
                return Err(Error::Invalid(
                    "this agent is already in the project; dedicate it with PATCH /v1/projects/{id}/agents/{instance_id}"
                        .into(),
                ));
            }
        }
        if new.is_empty() && adopts.is_empty() {
            return Ok(vec![]);
        }
        if live + (new.len() + adopts.len()) as u64 > MAX_PROJECT_AGENTS {
            return Err(Error::ProjectLimit(ProjectCap::Agents));
        }
        for (id, dedicate, ack) in &sorted {
            let space = spaces[id];
            if space == Some(project.0) {
                continue;
            }
            // 专属于别的项目、这次不标专属：说清楚是专属于别处（不是“项目只收专属的”）。
            if space.is_some() && !*dedicate {
                return Err(Error::InstanceDedicated);
            }
            if *dedicate {
                let instance = InstanceId(*id);
                self.free_instance_check(instance, Some(project)).await?;
                self.retire_workspace(instance, Some(project), "dedicate")
                    .await?;
                sqlx::query(
                    "UPDATE run_grants SET revoked_at = now(), revoke_reason = 'instance_dedicated'                       WHERE instance_id = $1 AND project_id IS NULL AND revoked_at IS NULL",
                )
                .bind(id)
                .execute(self.conn())
                .await?;
            } else if shared {
                if !mixed_allowed {
                    return Err(Error::AgentNotIsolated);
                }
                if !ack {
                    return Err(Error::Invalid(
                        "confirm that the agent's private memory may reach the project".into(),
                    ));
                }
            }
        }
        let mut placed: Vec<(Uuid, bool)> = new.iter().map(|(id, _, ack)| (*id, *ack)).collect();
        for n in adopts {
            let id = InstanceId::new();
            sqlx::query(
                "INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id, limits,                    workspace_project_id, peer_access)                  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, false)",
            )
            .bind(id.0)
            .bind(user.0)
            .bind(&n.agent_id)
            .bind(&n.agent_version)
            .bind(&n.harness)
            .bind(&n.name)
            .bind(&n.workspace_id)
            .bind(to_json(&n.limits)?)
            .bind(project.0)
            .execute(self.conn())
            .await?;
            self.append_event(
                id,
                None,
                "instance.state",
                &serde_json::json!({ "state": "provisioning" }),
            )
            .await?;
            placed.push((id.0, false));
        }
        self.put_agents(project, user, &placed, consented).await?;
        Ok(placed.into_iter().map(|(id, _)| InstanceId(id)).collect())
    }

    /// 把 `user` 的这些实例放进项目（排在最后）：离开过的原地恢复，不删了重建；不是负责人；专属标记由触发器按实例算。
    /// `consented`：成员加的 agent 记下确认时间（创建者自己的不用确认）；每个 agent 的 bool：确认过混用的提示。
    pub(crate) async fn put_agents(
        &mut self,
        project: ProjectId,
        user: UserId,
        ids: &[(Uuid, bool)],
        consented: bool,
    ) -> Result<()> {
        let base: i32 = sqlx::query_scalar(
            "SELECT coalesce(max(position), -1) + 1 FROM project_agents WHERE project_id = $1",
        )
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        for (n, (id, ack)) in ids.iter().enumerate() {
            let position = base.saturating_add(i32::try_from(n).unwrap_or(i32::MAX));
            let done = sqlx::query(
                "INSERT INTO project_agents (project_id, instance_id, user_id, position, consented_at, \
                   shared_memory_ack_at) \
                 VALUES ($1, $2, $3, $4, CASE WHEN $5 THEN now() END, CASE WHEN $6 THEN now() END) \
                 ON CONFLICT (project_id, instance_id) DO UPDATE SET left_at = NULL, is_lead = false, \
                   added_at = now(), consented_at = EXCLUDED.consented_at, position = EXCLUDED.position, \
                   shared_memory_ack_at = EXCLUDED.shared_memory_ack_at \
                 WHERE project_agents.left_at IS NOT NULL",
            )
            .bind(project.0)
            .bind(id)
            .bind(user.0)
            .bind(position)
            .bind(consented)
            .bind(ack)
            .execute(self.conn())
            .await?;
            if done.rows_affected() != 1 {
                return Err(Error::Conflict(
                    "the agent is already in the project".into(),
                ));
            }
        }
        Ok(())
    }

    /// 往项目里加自己的 agent（成员要带上这一版的确认；创建者不用）：已有的（可以同时标专属）、当场领养的（专属）。
    /// 已经在项目里的跳过；返回真正加进去的。总数超过 30（实例删了的不算）回 `ProjectLimit(Agents)`；共享过的项目里
    /// 加混用实例按 `mixed_allowed` 和确认（8.16）。
    pub async fn add_project_agents(
        &mut self,
        user: UserId,
        project: ProjectId,
        agents: &[JoinAgent],
        consent: Option<Consent>,
        mixed_allowed: bool,
        max_instances: u64,
    ) -> Result<Vec<InstanceId>> {
        check_join_agents(agents)?;
        let actor = self
            .project_actor(user, project, &[], &[ProjectStatus::Active])
            .await?;
        let member = actor.role == ProjectRole::Member;
        if member {
            consent
                .ok_or_else(|| Error::Invalid("confirm what the project shares first".into()))?
                .check()?;
        }
        self.reserve_adopts(user, agents, max_instances).await?;
        // 不先锁已有的 agent 行：worker 写项目 agent 都在项目锁里，而租户删实例是先改实例行、再改 agent 行；这里先锁
        // agent 行再等实例的共享锁，就会和它互相等。
        let shared: bool =
            sqlx::query_scalar("SELECT shared_at IS NOT NULL FROM projects WHERE id = $1")
                .bind(project.0)
                .fetch_one(self.conn())
                .await?;
        self.place_agents(user, project, agents, shared, mixed_allowed, member)
            .await
    }

    /// 把项目里自己的一个 agent 标成专属于这个项目（8.16，docs/projects.md 第 6 节）：它的工作区换成全新的（私人的记忆、
    /// 文件清空），私人的运行授权吊销，以后不接私人任务。只有 agent 的主人（别人的 NotPermitted）；不在项目里的 NotFound；
    /// 实例上还有别的事 `Conflict("instance_not_free: …")`。已经是专属的什么也不做，返回 false。项目的密钥由调用方先建好。
    pub async fn dedicate_project_agent(
        &mut self,
        user: UserId,
        project: ProjectId,
        instance: InstanceId,
    ) -> Result<bool> {
        self.project_actor(user, project, &[], &[ProjectStatus::Active])
            .await?;
        let owner = |row: Option<Uuid>| match row {
            None => Err(Error::NotFound),
            Some(o) if o != user.0 => Err(Error::NotPermitted(
                "only the agent's owner can dedicate it".into(),
            )),
            Some(_) => Ok(()),
        };
        let agent_owner = "SELECT user_id FROM project_agents                             WHERE project_id = $1 AND instance_id = $2 AND left_at IS NULL";
        let row: Option<Uuid> = sqlx::query_scalar(agent_owner)
            .bind(project.0)
            .bind(instance.0)
            .fetch_optional(self.conn())
            .await?;
        owner(row)?;
        // D3 之后：出网请求 → 实例（和用户决定出网请求同序），锁了实例再核对一次 agent 行。
        self.prelock_egress(instance).await?;
        let rt = self.lock_instance(instance).await?;
        if rt.state == proto::domain::InstanceState::Deleted {
            return Err(Error::NotFound);
        }
        let row: Option<Uuid> = sqlx::query_scalar(agent_owner)
            .bind(project.0)
            .bind(instance.0)
            .fetch_optional(self.conn())
            .await?;
        owner(row)?;
        if rt.workspace_project_id == Some(project) {
            return Ok(false);
        }
        self.free_instance_check(instance, Some(project)).await?;
        self.retire_workspace(instance, Some(project), "dedicate")
            .await?;
        sqlx::query(
            "UPDATE run_grants SET revoked_at = now(), revoke_reason = 'instance_dedicated'               WHERE instance_id = $1 AND project_id IS NULL AND revoked_at IS NULL",
        )
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        // 专属标记由触发器按实例算（动一下这一行）。
        sqlx::query(
            "UPDATE project_agents SET dedicated = true               WHERE project_id = $1 AND instance_id = $2 AND left_at IS NULL",
        )
        .bind(project.0)
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        Ok(true)
    }

    /// `user` 的这些实例的模型路由（含备用路由）用到哪些厂商：加入、加 agent 时记进审计（内容会发给谁）。
    pub async fn instance_vendors(
        &mut self,
        user: UserId,
        agents: &[InstanceId],
    ) -> Result<Vec<String>> {
        let ids: Vec<Uuid> = agents.iter().map(|a| a.0).collect();
        Ok(sqlx::query_scalar(
            "SELECT DISTINCT c.vendor FROM ( \
               SELECT credential_id, user_id FROM model_routes WHERE user_id = $1 AND instance_id = ANY($2) \
               UNION SELECT credential_id, user_id FROM model_route_fallbacks \
                      WHERE user_id = $1 AND instance_id = ANY($2) \
             ) r JOIN credentials c ON c.id = r.credential_id AND c.user_id = r.user_id ORDER BY 1",
        )
        .bind(user.0)
        .bind(&ids)
        .fetch_all(self.conn())
        .await?)
    }
}

impl Tx<Worker> {
    /// 撤回项目里的一个 agent：主人或创建者能做（别的成员 NotPermitted，外人 NotFound）。项目归档了也能撤。
    pub async fn withdraw_project_agent(
        &mut self,
        user: UserId,
        project: ProjectId,
        instance: InstanceId,
    ) -> Result<Withdrawn> {
        let (owner, name): (Uuid, String) = sqlx::query_as(
            "SELECT a.user_id, i.name FROM project_agents a JOIN instances i ON i.id = a.instance_id \
              WHERE a.project_id = $1 AND a.instance_id = $2",
        )
        .bind(project.0)
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        let owner = UserId(owner);
        let actor = self
            .project_actor(
                user,
                project,
                &[owner],
                &[ProjectStatus::Active, ProjectStatus::Archived],
            )
            .await?;
        if user != owner && actor.role != ProjectRole::Creator {
            return Err(Error::NotPermitted(
                "only the agent's owner or the project creator can withdraw it".into(),
            ));
        }
        if owner != user {
            sqlx::query(
                "SELECT 1 FROM project_members WHERE project_id = $1 AND user_id = $2 FOR NO KEY UPDATE",
            )
            .bind(project.0)
            .bind(owner.0)
            .execute(self.conn())
            .await?;
        }
        let live: bool = sqlx::query_scalar(
            "SELECT left_at IS NULL FROM project_agents WHERE project_id = $1 AND instance_id = $2 \
             FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        let mut out = Withdrawn {
            project,
            project_name: self.project_name(project).await?,
            creator: actor.creator,
            owner,
            owner_name: actor.locked(owner).and_then(|u| u.display_name.clone()),
            name,
            already_left: !live,
            runs_cancelled: 0,
            grants_revoked: 0,
        };
        if !live {
            return Ok(out);
        }
        let reason = "withdrawn from the project";
        out.runs_cancelled = self
            .cancel_project_agent_runs(project, instance, reason)
            .await?;
        out.grants_revoked = self
            .revoke_project_agent_grants(project, instance, reason)
            .await?;
        sqlx::query(
            "UPDATE project_agents SET is_lead = false, left_at = now() \
              WHERE project_id = $1 AND instance_id = $2 AND left_at IS NULL",
        )
        .bind(project.0)
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        Ok(out)
    }

    /// 退出项目（创建者不能退出，只能删项目）。退出以后就看不到这个项目了：再退一次 NotFound。
    pub async fn leave_project(&mut self, user: UserId, project: ProjectId) -> Result<Exit> {
        let actor = self
            .project_actor(
                user,
                project,
                &[],
                &[ProjectStatus::Active, ProjectStatus::Archived],
            )
            .await?;
        if actor.role == ProjectRole::Creator {
            return Err(Error::Conflict(
                "the creator cannot leave; delete the project instead".into(),
            ));
        }
        let me = actor.locked(user).cloned();
        self.exit_member(project, actor.creator, user, me.as_ref(), "left")
            .await
    }

    /// 创建者把一个成员移出项目。移出创建者 Invalid；从没加入过的 NotFound；已经离开的照样成功（不改）。
    pub async fn remove_project_member(
        &mut self,
        user: UserId,
        project: ProjectId,
        member: UserId,
    ) -> Result<Exit> {
        let actor = self
            .project_actor(user, project, &[member], &[ProjectStatus::Active])
            .await?;
        actor.require_creator("remove members")?;
        if member == actor.creator {
            return Err(Error::Invalid("the creator cannot be removed".into()));
        }
        let live: bool = sqlx::query_scalar(
            "SELECT left_at IS NULL FROM project_members WHERE project_id = $1 AND user_id = $2 \
             FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .bind(member.0)
        .fetch_one(self.conn())
        .await?;
        let them = actor.locked(member).cloned();
        if !live {
            return Ok(Exit {
                project,
                project_name: self.project_name(project).await?,
                creator: actor.creator,
                member,
                member_name: them.as_ref().and_then(|u| u.display_name.clone()),
                changed: false,
                runs_cancelled: 0,
                grants_revoked: 0,
            });
        }
        self.exit_member(project, actor.creator, member, them.as_ref(), "removed")
            .await
    }

    /// 成员离开（调用方已经锁好用户行、项目锁和他的成员行）：先处理邀请（D3 第 5 步：他发出的作废，8.14 只有创建者邀请，
    /// 这里是 0 行，离开只标记、外键的级联不会触发；发给他号码的标不送达，不然被移出的人拿着他还是成员时收到的旧邀请就能
    /// 自己回来），再是他在项目里的 agent 行 → 运行 → 授权 → agent 标离开 → 成员行标离开。
    async fn exit_member(
        &mut self,
        project: ProjectId,
        creator: UserId,
        member: UserId,
        locked: Option<&LockedUser>,
        reason: &str,
    ) -> Result<Exit> {
        let member_name = locked.and_then(|u| u.display_name.clone());
        sqlx::query(
            "UPDATE project_invites SET status = 'revoked', settled_at = now() \
              WHERE project_id = $1 AND inviter_id = $2 AND status = 'pending'",
        )
        .bind(project.0)
        .bind(member.0)
        .execute(self.conn())
        .await?;
        // 发给他号码的：标不送达（和拉黑一样，邀请人那边照样是待接受、到期过期，看不出这个号码是谁的）。
        let to_me: Vec<Uuid> = sqlx::query_scalar(
            "UPDATE project_invites SET suppressed_at = now() \
              WHERE project_id = $1 AND kind = 'phone' AND invitee_phone = $2 \
                AND status = 'pending' AND suppressed_at IS NULL RETURNING id",
        )
        .bind(project.0)
        .bind(locked.map(|u| u.phone.as_str()))
        .fetch_all(self.conn())
        .await?;
        self.read_invite_items(member, &to_me).await?;
        sqlx::query(
            "SELECT 1 FROM project_agents WHERE project_id = $1 AND user_id = $2 AND left_at IS NULL \
              ORDER BY instance_id FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .bind(member.0)
        .execute(self.conn())
        .await?;
        let why = if reason == "left" {
            "left the project"
        } else {
            "removed from the project"
        };
        let runs_cancelled = self
            .cancel_project_member_runs(project, member, why)
            .await?;
        let grants_revoked = self
            .revoke_project_member_grants(project, member, why)
            .await?;
        sqlx::query(
            "UPDATE project_agents SET is_lead = false, left_at = now() \
              WHERE project_id = $1 AND user_id = $2 AND left_at IS NULL",
        )
        .bind(project.0)
        .bind(member.0)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "UPDATE project_members SET left_at = now(), left_reason = $3 \
              WHERE project_id = $1 AND user_id = $2 AND left_at IS NULL",
        )
        .bind(project.0)
        .bind(member.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        // 退出以后这个项目的提醒（回执除外）就看不到了：标已读，角标不留着（D23；他的用户行锁着）。
        self.read_project_notices(project, &[member], false).await?;
        Ok(Exit {
            project,
            project_name: self.project_name(project).await?,
            creator,
            member,
            member_name,
            changed: true,
            runs_cancelled,
            grants_revoked,
        })
    }

    /// 设我在项目里的预算（每个人管自己的 agent）。成员两个都要有、各自 1 到上限、每天的不超过总的；创建者可以不限。
    pub async fn set_project_budget(
        &mut self,
        user: UserId,
        project: ProjectId,
        budget: &ProjectBudget,
    ) -> Result<()> {
        let actor = self
            .project_actor(user, project, &[], &[ProjectStatus::Active])
            .await?;
        match (budget.daily_token_limit, budget.total_token_limit) {
            (Some(d), Some(t)) => check_budget(d, t)?,
            (d, t) if actor.role == ProjectRole::Creator => {
                for v in [d, t].into_iter().flatten() {
                    if !(1..=MAX_TOKEN_LIMIT).contains(&v) {
                        return Err(Error::Invalid(format!(
                            "token limits must be between 1 and {MAX_TOKEN_LIMIT}"
                        )));
                    }
                }
            }
            _ => {
                return Err(Error::Invalid(
                    "members set both a daily and a total token limit".into(),
                ));
            }
        }
        sqlx::query(
            "UPDATE project_members SET daily_token_limit = $3, total_token_limit = $4 \
              WHERE project_id = $1 AND user_id = $2",
        )
        .bind(project.0)
        .bind(user.0)
        .bind(
            budget
                .daily_token_limit
                .map(|v| signed(v, "token limit"))
                .transpose()?,
        )
        .bind(
            budget
                .total_token_limit
                .map(|v| signed(v, "token limit"))
                .transpose()?,
        )
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 实例删了以后（租户事务提交之后）把它从所有项目里撤下：共享项目的行租户改不了。运行、授权在删实例时已经停了
    /// （它们带着主人的 user_id）。可以重复调；实例没删返回 0。
    pub async fn retire_deleted_instance(
        &mut self,
        user: UserId,
        instance: InstanceId,
    ) -> Result<u64> {
        let deleted: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM instances WHERE id = $1 AND user_id = $2 AND state = 'deleted')",
        )
        .bind(instance.0)
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        if !deleted {
            return Ok(0);
        }
        let mut projects: Vec<ProjectId> = sqlx::query_scalar::<_, Uuid>(
            "SELECT project_id FROM project_agents WHERE instance_id = $1 AND left_at IS NULL",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?
        .into_iter()
        .map(ProjectId)
        .collect();
        if projects.is_empty() {
            return Ok(0);
        }
        self.lock_projects(&mut projects).await?;
        let ids: Vec<Uuid> = projects.iter().map(|p| p.0).collect();
        Ok(sqlx::query(
            "UPDATE project_agents SET is_lead = false, left_at = now() \
              WHERE project_id = ANY($1) AND instance_id = $2 AND left_at IS NULL",
        )
        .bind(&ids)
        .bind(instance.0)
        .execute(self.conn())
        .await?
        .rows_affected())
    }

    /// 后台兜底：实例已经删了、还挂在项目里的 agent 撤下。项目锁被别人拿着的跳过（不等），下一轮再说。返回撤下几个。
    pub async fn retire_deleted_project_agents(&mut self, batch: u64) -> Result<u64> {
        let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
            "SELECT a.project_id, a.instance_id FROM project_agents a \
               JOIN instances i ON i.id = a.instance_id AND i.state = 'deleted' \
              WHERE a.left_at IS NULL ORDER BY a.project_id, a.instance_id LIMIT $1",
        )
        .bind(signed(batch, "batch")?)
        .fetch_all(self.conn())
        .await?;
        let mut done = 0;
        let mut last: Option<(Uuid, bool)> = None;
        for (project, instance) in rows {
            let locked = match last {
                Some((p, ok)) if p == project => ok,
                _ => {
                    let ok: bool = sqlx::query_scalar(
                        "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))",
                    )
                    .bind(format!("project/{}", ProjectId(project)))
                    .fetch_one(self.conn())
                    .await?;
                    last = Some((project, ok));
                    ok
                }
            };
            if !locked {
                continue;
            }
            done += sqlx::query(
                "UPDATE project_agents SET is_lead = false, left_at = now() \
                  WHERE project_id = $1 AND instance_id = $2 AND left_at IS NULL",
            )
            .bind(project)
            .bind(instance)
            .execute(self.conn())
            .await?
            .rows_affected();
        }
        Ok(done)
    }

    pub(crate) async fn project_name(&mut self, project: ProjectId) -> Result<String> {
        Ok(
            sqlx::query_scalar("SELECT name FROM projects WHERE id = $1")
                .bind(project.0)
                .fetch_one(self.conn())
                .await?,
        )
    }
}
