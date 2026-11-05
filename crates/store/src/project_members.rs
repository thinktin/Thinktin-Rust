//! 项目成员和项目 agent 的变化（8.14，docs/progress/drafts/projects-8.14-plan.md 第 2.6 节）：加 agent；撤回、退出、移出
//! 在后面的提交。都在 `Tx<Worker>` 里，按 D3 的顺序加锁。

use std::collections::HashSet;

use proto::domain::{
    InstanceId, MAX_PROJECT_AGENTS, MAX_TOKEN_LIMIT, ProjectId, ProjectRole, ProjectStatus, UserId,
};
use uuid::Uuid;

use crate::project_invites::Consent;
use crate::{Error, ProjectCap, Result, Tx, Worker, unsigned};

/// 请求里的 agent：1 到 30 个、不重复。
pub(crate) fn check_agent_ids(agents: &[InstanceId]) -> Result<Vec<Uuid>> {
    if agents.is_empty() || agents.len() as u64 > MAX_PROJECT_AGENTS {
        return Err(Error::Invalid(format!(
            "choose 1 to {MAX_PROJECT_AGENTS} agents"
        )));
    }
    let mut seen = HashSet::new();
    if !agents.iter().all(|a| seen.insert(*a)) {
        return Err(Error::Invalid("an agent is listed twice".into()));
    }
    Ok(agents.iter().map(|a| a.0).collect())
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

    /// `ids` 都是 `user` 自己没删的实例（加共享锁，和删实例互斥）；不是的 NotFound，不说是谁的。
    pub(crate) async fn lock_own_instances(&mut self, user: UserId, ids: &[Uuid]) -> Result<()> {
        let mut sorted = ids.to_vec();
        sorted.sort_unstable();
        let found: Vec<Uuid> = sqlx::query_scalar(
            "SELECT id FROM instances WHERE id = ANY($1) AND user_id = $2 AND state <> 'deleted' \
              ORDER BY id FOR SHARE",
        )
        .bind(&sorted)
        .bind(user.0)
        .fetch_all(self.conn())
        .await?;
        if found.len() != sorted.len() {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 把 `user` 的这些实例放进项目（排在最后）：离开过的原地恢复，不删了重建；不是负责人、不是专属。`consented`：
    /// 成员加的 agent 记下确认时间（创建者自己的不用确认）。
    pub(crate) async fn put_agents(
        &mut self,
        project: ProjectId,
        user: UserId,
        ids: &[Uuid],
        consented: bool,
    ) -> Result<()> {
        let base: i32 = sqlx::query_scalar(
            "SELECT coalesce(max(position), -1) + 1 FROM project_agents WHERE project_id = $1",
        )
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        for (n, id) in ids.iter().enumerate() {
            let position = base.saturating_add(i32::try_from(n).unwrap_or(i32::MAX));
            let done = sqlx::query(
                "INSERT INTO project_agents (project_id, instance_id, user_id, position, consented_at) \
                 VALUES ($1, $2, $3, $4, CASE WHEN $5 THEN now() END) \
                 ON CONFLICT (project_id, instance_id) DO UPDATE SET left_at = NULL, is_lead = false, \
                   dedicated = false, added_at = now(), consented_at = EXCLUDED.consented_at, \
                   position = EXCLUDED.position \
                 WHERE project_agents.left_at IS NOT NULL",
            )
            .bind(project.0)
            .bind(id)
            .bind(user.0)
            .bind(position)
            .bind(consented)
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

    /// 往项目里加自己的 agent（成员要带上这一版的确认；创建者不用）。已经在项目里的跳过；返回真正加进去的。
    /// 总数超过 30（实例删了的不算）回 `ProjectLimit(Agents)`。
    pub async fn add_project_agents(
        &mut self,
        user: UserId,
        project: ProjectId,
        agents: &[InstanceId],
        consent: Option<Consent>,
    ) -> Result<Vec<InstanceId>> {
        let ids = check_agent_ids(agents)?;
        let actor = self
            .project_actor(user, project, &[], &[ProjectStatus::Active])
            .await?;
        let member = actor.role == ProjectRole::Member;
        if member {
            consent
                .ok_or_else(|| Error::Invalid("confirm what the project shares first".into()))?
                .check()?;
        }
        // D3 第 7 步：项目 agent 行，再第 9 步：实例。
        sqlx::query(
            "SELECT 1 FROM project_agents WHERE project_id = $1 AND instance_id = ANY($2) \
              ORDER BY instance_id FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .bind(&ids)
        .execute(self.conn())
        .await?;
        let (live, already) = self.live_agents(project, &ids).await?;
        self.lock_own_instances(user, &ids).await?;
        let new: Vec<Uuid> = ids.into_iter().filter(|i| !already.contains(i)).collect();
        if new.is_empty() {
            return Ok(vec![]);
        }
        if live + new.len() as u64 > MAX_PROJECT_AGENTS {
            return Err(Error::ProjectLimit(ProjectCap::Agents));
        }
        self.put_agents(project, user, &new, member).await?;
        Ok(new.into_iter().map(InstanceId).collect())
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
