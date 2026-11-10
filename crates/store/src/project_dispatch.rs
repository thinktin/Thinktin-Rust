//! 派单（8.17，迁移 0060）：可执行的项目运行、项目授权只从这里写。库里的开关（一行，默认关）在老副本都退出以后由运维
//! 打开（`thinktin-server admin project-dispatch on`）；写入时的栅栏核对开关、协议、agent 还在。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    GrantId, InstanceId, MAX_QUEUED_PROJECT_RUNS, MAX_TOKEN_LIMIT, ProjectId, ProjectRole,
    ProjectStatus, Run, RunBudget, RunId, RunSource, UserId, UserStatus,
};
use uuid::Uuid;

use crate::grants::StandingGrant;
use crate::{Error, NewRun, Result, Tx, Worker, unsigned};

/// 等主人确认的项目任务（8.17，主人按了“全部停止”以后派来的）：运行的 `wait_code`。
pub const OWNER_CONFIRM_WAIT: &str = "owner_confirm";
/// 等主人确认最多等这么久，过了兜底取消。
pub const OWNER_CONFIRM_HOURS: i64 = 24;

/// 派出去的一个项目任务（[`Tx::create_project_task`]）。
#[derive(Debug, Clone)]
pub struct Dispatched {
    pub run: Run,
    /// 运行和 botin 的主人。
    pub owner: UserId,
    /// 这次新签的常设授权（记审计）。
    pub grant_issued: Option<GrantId>,
    /// 主人按了“全部停止”，这个任务先等主人确认（提醒主人）。
    pub needs_confirmation: bool,
}

/// 派单的目标核对通过以后：用哪个授权、主人、还剩多少预算。
#[derive(Debug, Clone)]
pub(crate) struct Target {
    pub instance: InstanceId,
    pub owner: UserId,
    pub grant: GrantId,
    pub issued: bool,
    pub paused: bool,
    /// 还能花多少 token（成员预算和 botin 限额里最紧的一个）；None 是不限。
    pub budget_left: Option<u64>,
}

/// 派单的目标为什么不行（调用方各自换成错误或者给 agent 的说明）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TargetRefusal {
    /// 不在项目里了（撤下了、实例删了）。
    Gone,
    /// 不是专属于这个项目的。
    NotIsolated,
    /// 主人的账号不能用了、主人不在项目里了。
    Unavailable,
    /// 排着的项目任务太多了。
    Busy,
    /// 预算、限额用完了。
    Budget,
}

impl TargetRefusal {
    pub(crate) fn into_error(self) -> Error {
        match self {
            Self::Gone => Error::Invalid("that agent is no longer in the project".into()),
            Self::NotIsolated => Error::AgentNotIsolated,
            Self::Unavailable => Error::AgentUnavailable,
            Self::Busy => Error::AgentBusy,
            Self::Budget => Error::BudgetReached,
        }
    }
}

/// 项目里一个运行（调用平台工具的 agent）核对过的身份（8.17）：用户行、项目锁、这个运行都锁着。只在 store 里建。
#[derive(Debug, Clone)]
pub(crate) struct ProjectAgentActor {
    pub instance: InstanceId,
    pub owner: UserId,
    pub grant: Option<GrantId>,
    pub lead: bool,
    pub budget: RunBudget,
    pub users: Vec<crate::projects::LockedUser>,
}

/// 项目里的运行要开一个子运行（委派、提问）。
#[derive(Debug, Clone)]
pub struct ProjectChild<'a> {
    /// `Delegate` 或 `Ask`。
    pub source: RunSource,
    /// 存进库里的原文（委派是“标题\n\n任务”，提问是问题），不带平台的说明和名字（启动时再加）。
    pub prompt: &'a str,
    /// 链上这种子运行最多几层。
    pub max_depth: usize,
    /// 一次运行最多开几个这种子运行。
    pub max_siblings: usize,
    pub max_attempts: u32,
    /// 提问：最晚什么时候答完。
    pub answer_deadline: Option<DateTime<Utc>>,
    /// 同一个运行问同一个 agent 一模一样的问题、还没交还的，就是那一个。
    pub dedupe: bool,
    /// 委派的子授权最长多久（不超过父授权）。
    pub grant_ttl: Duration,
}

/// 开子运行的结果。
#[derive(Debug, Clone)]
pub enum ProjectChildResult {
    /// 新开的；`held`：目标的主人按了“全部停止”，等主人确认。
    Created { run: Run, held: bool },
    /// 同一个问题还没交还的那一个。
    Existing(Run),
    /// 不行（给 agent 的说明由编排层写）。
    Refused(ChildRefusal),
}

/// 子运行为什么开不了。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChildRefusal {
    DispatchOff,
    /// 只有负责人能委派。
    NotLead,
    TargetGone,
    TargetNotIsolated,
    AgentUnavailable,
    AgentBusy,
    BudgetReached,
    /// 委派、提问给自己。
    SelfTarget,
    /// 链太深了。
    TooDeep,
    /// 目标已经在这条链上（会互相等）。
    OnChain,
    /// 目标正在（直接或经别的 agent）等这个运行。
    WaitsForCaller,
    /// 这个运行开的这种子运行太多了。
    TooMany,
    /// 负责人的授权和目标的没有共同的工具。
    NoScope,
}

impl From<TargetRefusal> for ChildRefusal {
    fn from(r: TargetRefusal) -> Self {
        match r {
            TargetRefusal::Gone => Self::TargetGone,
            TargetRefusal::NotIsolated => Self::TargetNotIsolated,
            TargetRefusal::Unavailable => Self::AgentUnavailable,
            TargetRefusal::Busy => Self::AgentBusy,
            TargetRefusal::Budget => Self::BudgetReached,
        }
    }
}

/// 主人设的这个 botin 在项目里的 token 限额（8.17，每天的、总的；None 是不限）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AgentLimits {
    pub daily_token_limit: Option<u64>,
    pub total_token_limit: Option<u64>,
}

/// 设置负责人前后的负责人（agent、主人），给审计和提醒用。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LeadChange {
    pub old: Option<(InstanceId, UserId)>,
    pub new: Option<(InstanceId, UserId)>,
}

fn limit(v: Option<i64>, what: &str) -> Result<Option<u64>> {
    v.map(|n| unsigned(n, what)).transpose()
}

impl Tx<Worker> {
    /// 派单开关开着没有。
    pub async fn project_dispatch_enabled(&mut self) -> Result<bool> {
        Ok(
            sqlx::query_scalar("SELECT enabled FROM project_dispatch WHERE id")
                .fetch_optional(self.conn())
                .await?
                .unwrap_or(false),
        )
    }

    /// 开、关派单开关，记下谁、为什么。关的时候等已经过了栅栏、还没提交的派单（栅栏 `FOR SHARE` 读这一行），之后
    /// 再取消没结束的项目运行（[`Tx::projects_with_unfinished_runs`]），不会漏掉在途的。
    pub async fn set_project_dispatch(
        &mut self,
        enabled: bool,
        by: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE project_dispatch SET enabled = $1, changed_at = now(), changed_by = $2, reason = $3 WHERE id",
        )
        .bind(enabled)
        .bind(by)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 没结束的项目运行有多少个（运维看派单开关时用）。
    pub async fn unfinished_project_runs(&mut self) -> Result<u64> {
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM runs WHERE project_id IS NOT NULL \
               AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .fetch_one(self.conn())
        .await?;
        unsigned(n, "unfinished project runs")
    }

    /// 还有没结束的运行的项目（关开关以后逐个取消用）。
    pub async fn projects_with_unfinished_runs(&mut self, limit: i64) -> Result<Vec<ProjectId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT DISTINCT project_id FROM runs WHERE project_id IS NOT NULL \
               AND state NOT IN ('succeeded', 'failed', 'cancelled') LIMIT $1",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(ids.into_iter().map(ProjectId).collect())
    }

    /// 项目里一个 agent 的主人（不加锁的读：之后在锁里再核对）。
    pub(crate) async fn agent_owner(
        &mut self,
        p: ProjectId,
        instance: InstanceId,
    ) -> Result<Option<UserId>> {
        let owner: Option<Uuid> = sqlx::query_scalar(
            "SELECT user_id FROM project_agents WHERE project_id = $1 AND instance_id = $2 AND left_at IS NULL",
        )
        .bind(p.0)
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        Ok(owner.map(UserId))
    }

    /// 项目现在的负责人（agent、主人）。
    pub(crate) async fn project_lead(
        &mut self,
        p: ProjectId,
    ) -> Result<Option<(InstanceId, UserId)>> {
        let row: Option<(Uuid, Uuid)> = sqlx::query_as(
            "SELECT instance_id, user_id FROM project_agents \
              WHERE project_id = $1 AND is_lead AND left_at IS NULL",
        )
        .bind(p.0)
        .fetch_optional(self.conn())
        .await?;
        Ok(row.map(|(i, u)| (InstanceId(i), UserId(u))))
    }

    /// `instance` 是不是项目的负责人，而且能干项目的活（专属于这个项目、还在、主人还是成员、项目开着）。
    pub async fn is_project_lead(&mut self, p: ProjectId, instance: InstanceId) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM project_agents a JOIN instances i ON i.id = a.instance_id \
                              AND i.workspace_project_id = a.project_id AND i.state <> 'deleted' \
                             WHERE a.project_id = $1 AND a.instance_id = $2 AND a.is_lead AND a.left_at IS NULL \
                               AND project_agent_live(a.project_id, a.instance_id, a.user_id))",
        )
        .bind(p.0)
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?)
    }

    /// 主人在项目里还能给这个 botin 花多少 token：成员每天的、总的预算剩下的，主人给这个 botin 设的每天的、总的限额
    /// 剩下的，取最紧的一个（每天的按最近 24 小时算）。都没设是不限（None）。
    pub(crate) async fn owner_budget_left(
        &mut self,
        p: ProjectId,
        owner: UserId,
        instance: InstanceId,
    ) -> Result<Option<u64>> {
        #[allow(clippy::type_complexity)]
        let row: Option<(Option<i64>, Option<i64>, Option<i64>, Option<i64>, i64, i64, i64, i64)> =
            sqlx::query_as(
                "SELECT m.daily_token_limit, m.total_token_limit, a.daily_token_limit, a.total_token_limit, \
                        (SELECT coalesce(sum(tokens_used), 0) FROM runs \
                          WHERE project_id = $1 AND user_id = $2 AND created_at > now() - interval '1 day')::bigint, \
                        (SELECT coalesce(sum(tokens_used), 0) FROM runs \
                          WHERE project_id = $1 AND user_id = $2)::bigint, \
                        (SELECT coalesce(sum(tokens_used), 0) FROM runs \
                          WHERE project_id = $1 AND instance_id = $3 AND created_at > now() - interval '1 day')::bigint, \
                        (SELECT coalesce(sum(tokens_used), 0) FROM runs \
                          WHERE project_id = $1 AND instance_id = $3)::bigint \
                   FROM project_members m JOIN project_agents a ON a.project_id = m.project_id \
                    AND a.user_id = m.user_id AND a.instance_id = $3 \
                  WHERE m.project_id = $1 AND m.user_id = $2",
            )
            .bind(p.0)
            .bind(owner.0)
            .bind(instance.0)
            .fetch_optional(self.conn())
            .await?;
        let Some((md, mt, ad, at, mud, mut_, aud, aut)) = row else {
            return Ok(Some(0));
        };
        let pairs = [(md, mud), (mt, mut_), (ad, aud), (at, aut)];
        let mut left: Option<u64> = None;
        for (cap, used) in pairs {
            if let Some(cap) = limit(cap, "token limit")? {
                let rest = cap.saturating_sub(unsigned(used.max(0), "tokens used")?);
                left = Some(left.map_or(rest, |l| l.min(rest)));
            }
        }
        Ok(left)
    }

    /// 派单的目标核对（调用方锁着项目，目标的主人在锁住的用户里）：还在项目里、专属于这个项目、主人能用、有常设授权
    /// （“全部停止”以后是暂停：照样派，等主人确认）、排队的不多（`check_queue`）、预算没用完。
    pub(crate) async fn project_target(
        &mut self,
        p: ProjectId,
        instance: InstanceId,
        owner_status: Option<UserStatus>,
        check_queue: bool,
        ttl: Duration,
    ) -> Result<std::result::Result<Target, TargetRefusal>> {
        let row: Option<(Uuid, bool, bool, bool)> = sqlx::query_as(
            "SELECT a.user_id, i.state = 'deleted', i.workspace_project_id IS NOT DISTINCT FROM a.project_id, \
                    EXISTS (SELECT 1 FROM project_members m WHERE m.project_id = a.project_id \
                              AND m.user_id = a.user_id AND m.left_at IS NULL) \
               FROM project_agents a JOIN instances i ON i.id = a.instance_id \
              WHERE a.project_id = $1 AND a.instance_id = $2 AND a.left_at IS NULL",
        )
        .bind(p.0)
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        let Some((owner, deleted, isolated, member)) = row else {
            return Ok(Err(TargetRefusal::Gone));
        };
        let owner = UserId(owner);
        if deleted {
            return Ok(Err(TargetRefusal::Gone));
        }
        if !isolated {
            return Ok(Err(TargetRefusal::NotIsolated));
        }
        if !member || owner_status != Some(UserStatus::Active) {
            return Ok(Err(TargetRefusal::Unavailable));
        }
        let (grant, issued, paused) = match self
            .ensure_project_agent_grant(p, instance, owner, ttl)
            .await?
        {
            StandingGrant::Active { grant, issued } => (grant.id, issued, false),
            StandingGrant::Paused { revoked } => (revoked, false, true),
        };
        if check_queue {
            let queued: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM runs WHERE project_id = $1 AND instance_id = $2 AND state = 'queued'",
            )
            .bind(p.0)
            .bind(instance.0)
            .fetch_one(self.conn())
            .await?;
            if unsigned(queued, "queued runs")? >= MAX_QUEUED_PROJECT_RUNS {
                return Ok(Err(TargetRefusal::Busy));
            }
        }
        let budget_left = self.owner_budget_left(p, owner, instance).await?;
        if budget_left == Some(0) {
            return Ok(Err(TargetRefusal::Budget));
        }
        Ok(Ok(Target {
            instance,
            owner,
            grant,
            issued,
            paused,
            budget_left,
        }))
    }

    /// 创建者给项目里的 botin 派一个任务（8.17，docs/projects.md 第 5 节）：`to` 没给的派给负责人。botin 是别人的也行，
    /// 运行记在 botin 的主人名下、用主人在项目里的常设授权、预算按主人设的算。主人按了“全部停止”的，任务先等主人确认
    /// （[`Dispatched::needs_confirmation`]）。只有创建者；项目要开着；派单开关要开着。
    pub async fn create_project_task(
        &mut self,
        creator: UserId,
        p: ProjectId,
        to: Option<InstanceId>,
        prompt: &str,
        grant_ttl: Duration,
    ) -> Result<Dispatched> {
        if !self.project_dispatch_enabled().await? {
            return Err(Error::DispatchOff);
        }
        let planned = match to {
            Some(i) => self.agent_owner(p, i).await?,
            None => self.project_lead(p).await?.map(|(_, u)| u),
        };
        let also: Vec<UserId> = planned.into_iter().collect();
        let actor = self
            .project_actor(creator, p, &also, &[ProjectStatus::Active])
            .await?;
        actor.require_creator("give the project tasks")?;
        let instance = match to {
            Some(i) => i,
            None => match self.project_lead(p).await? {
                Some((i, _)) => i,
                None => {
                    return Err(Error::Invalid(
                        "the project has no lead; choose an agent for the task".into(),
                    ));
                }
            },
        };
        let owner = self.agent_owner(p, instance).await?;
        let Some(owner) = owner else {
            return Err(Error::Invalid("that agent is not in the project".into()));
        };
        let Some(locked) = actor.locked(owner) else {
            // 读主人和加锁之间换了负责人：让调用方重试。
            return Err(Error::Conflict(
                "the project changed while dispatching; try again".into(),
            ));
        };
        let status = Some(locked.status);
        let target = match self
            .project_target(p, instance, status, true, grant_ttl)
            .await?
        {
            Ok(t) => t,
            Err(refusal) => return Err(refusal.into_error()),
        };
        let agent_version: String =
            sqlx::query_scalar("SELECT agent_version FROM instances WHERE id = $1")
                .bind(instance.0)
                .fetch_one(self.conn())
                .await?;
        let mut new = NewRun::new(target.instance, RunSource::User, prompt, agent_version);
        new.run_grant_id = Some(target.grant);
        new.budget = RunBudget {
            max_tokens: target.budget_left,
            ..RunBudget::default()
        };
        let mut run = self.insert_project_run(target.owner, p, &new).await?;
        if target.paused {
            run = self.hold_for_owner(run.id).await?;
        }
        Ok(Dispatched {
            run,
            owner: target.owner,
            grant_issued: target.issued.then_some(target.grant),
            needs_confirmation: target.paused,
        })
    }

    /// 刚写进去的项目任务改成等主人确认（主人按了“全部停止”以后）：还是排队，但 `not_before` 推到很远（领不到；不用
    /// `waiting_approval`，那会占住实例，确认之前别的任务也跑不了），`wait_code` 记着在等主人，过期限兜底取消。
    pub(crate) async fn hold_for_owner(&mut self, run: RunId) -> Result<Run> {
        let row = sqlx::query(
            "UPDATE runs SET wait_code = $2, wait_deadline = now() + make_interval(hours => $3), \
               not_before = now() + interval '100 years', updated_at = now() WHERE id = $1 AND state = 'queued'",
        )
        .bind(run.0)
        .bind(OWNER_CONFIRM_WAIT)
        .bind(i32::try_from(OWNER_CONFIRM_HOURS).unwrap_or(24))
        .execute(self.conn())
        .await?;
        if row.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        self.run(run).await
    }

    /// 主人回答等确认的项目任务（8.17，按了“全部停止”以后派来的）。`accept`：签一个新的常设授权，这个 botin 在这个项目里
    /// 所有等确认的任务都换上它、改回排队（暂停就此解除，之后派来的不再问），返回这些任务。拒绝：只取消这一个，暂停
    /// 继续。不是自己 botin 的 NotPermitted；不在等确认的 Conflict。
    pub async fn confirm_project_task(
        &mut self,
        owner: UserId,
        p: ProjectId,
        run: RunId,
        accept: bool,
        grant_ttl: Duration,
    ) -> Result<(Vec<RunId>, Option<GrantId>)> {
        self.project_actor(owner, p, &[], &[ProjectStatus::Active])
            .await?;
        let row: Option<(Uuid, Uuid, String, Option<String>)> = sqlx::query_as(
            "SELECT user_id, instance_id, state, wait_code FROM runs \
              WHERE id = $1 AND project_id = $2 FOR NO KEY UPDATE",
        )
        .bind(run.0)
        .bind(p.0)
        .fetch_optional(self.conn())
        .await?;
        let Some((user, instance, state, wait)) = row else {
            return Err(Error::NotFound);
        };
        if user != owner.0 {
            return Err(Error::NotPermitted(
                "only the agent's owner can confirm its tasks".into(),
            ));
        }
        if state != "queued" || wait.as_deref() != Some(OWNER_CONFIRM_WAIT) {
            return Err(Error::Conflict(
                "this task is not waiting for your confirmation".into(),
            ));
        }
        let instance = InstanceId(instance);
        if !accept {
            sqlx::query(
                "UPDATE runs SET state = 'cancelled', state_reason = 'the owner declined the task', \
                   wait_code = NULL, wait_deadline = NULL, finished_at = now(), updated_at = now() WHERE id = $1",
            )
            .bind(run.0)
            .execute(self.conn())
            .await?;
            return Ok((vec![run], None));
        }
        let grant = self
            .issue_project_agent_grant(p, instance, owner, grant_ttl)
            .await?;
        // 委派来的子任务留着它自己的子授权（从负责人的授权收窄出来的，D5b），别的（创建者派的、问来的）换上新的常设授权。
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "UPDATE runs SET run_grant_id = CASE WHEN source = 'delegate' THEN run_grant_id ELSE $3 END, \
               wait_code = NULL, wait_deadline = NULL, not_before = now(), updated_at = now() \
             WHERE project_id = $1 AND instance_id = $2 AND state = 'queued' AND wait_code = $4 \
             RETURNING id",
        )
        .bind(p.0)
        .bind(instance.0)
        .bind(grant.id.0)
        .bind(OWNER_CONFIRM_WAIT)
        .fetch_all(self.conn())
        .await?;
        Ok((ids.into_iter().map(RunId).collect(), Some(grant.id)))
    }

    /// 等主人确认的提醒（8.17，每个任务一条）：这个 botin 上已经不在等确认的任务（确认了、拒绝了、取消了、过期了）的
    /// 提醒算已读。返回标了几条。
    pub async fn settle_owner_confirm_inbox(&mut self, instance: InstanceId) -> Result<u64> {
        Ok(sqlx::query(
            "UPDATE inbox_items SET read_at = now() \
              WHERE instance_id = $1 AND subtype = $2 AND read_at IS NULL \
                AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.id = inbox_items.run_id \
                                  AND r.state = 'queued' AND r.wait_code = $2)",
        )
        .bind(instance.0)
        .bind(OWNER_CONFIRM_WAIT)
        .execute(self.conn())
        .await?
        .rows_affected())
    }

    /// 等主人确认过了期限的项目任务取消掉（兜底，每次最多 `limit` 个，别人锁着的下一轮再来）。返回（运行，实例）。
    pub async fn cancel_unconfirmed_project_tasks(
        &mut self,
        limit: i64,
    ) -> Result<Vec<(RunId, InstanceId)>> {
        let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
            "UPDATE runs SET state = 'cancelled', state_reason = 'the owner did not confirm the task in time', \
               wait_code = NULL, wait_deadline = NULL, finished_at = now(), updated_at = now() \
             WHERE id IN (SELECT id FROM runs WHERE state = 'queued' AND wait_code = $1 \
                            AND wait_deadline < now() ORDER BY id LIMIT $2 FOR NO KEY UPDATE SKIP LOCKED) \
             RETURNING id, instance_id",
        )
        .bind(OWNER_CONFIRM_WAIT)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(r, i)| (RunId(r), InstanceId(i)))
            .collect())
    }

    /// 主人给自己派进项目的 botin 设 token 限额（8.17，每天的、总的，None 是不限）：只有主人；agent 要还在项目里。
    pub async fn set_project_agent_limits(
        &mut self,
        owner: UserId,
        p: ProjectId,
        instance: InstanceId,
        limits: AgentLimits,
    ) -> Result<()> {
        for v in [limits.daily_token_limit, limits.total_token_limit]
            .into_iter()
            .flatten()
        {
            if !(1..=MAX_TOKEN_LIMIT).contains(&v) {
                return Err(Error::Invalid(format!(
                    "token limits must be between 1 and {MAX_TOKEN_LIMIT}"
                )));
            }
        }
        if let (Some(d), Some(t)) = (limits.daily_token_limit, limits.total_token_limit)
            && d > t
        {
            return Err(Error::Invalid(
                "the daily token limit cannot exceed the total".into(),
            ));
        }
        self.project_actor(owner, p, &[], &[ProjectStatus::Active])
            .await?;
        let row: Option<Uuid> = sqlx::query_scalar(
            "SELECT user_id FROM project_agents WHERE project_id = $1 AND instance_id = $2 \
               AND left_at IS NULL FOR NO KEY UPDATE",
        )
        .bind(p.0)
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        match row {
            None => return Err(Error::NotFound),
            Some(u) if u != owner.0 => {
                return Err(Error::NotPermitted(
                    "only the agent's owner can set its limits".into(),
                ));
            }
            Some(_) => {}
        }
        sqlx::query(
            "UPDATE project_agents SET daily_token_limit = $3, total_token_limit = $4 \
              WHERE project_id = $1 AND instance_id = $2",
        )
        .bind(p.0)
        .bind(instance.0)
        .bind(limits.daily_token_limit.map(|v| v as i64))
        .bind(limits.total_token_limit.map(|v| v as i64))
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 主人给这个 botin 设的限额（只有主人看：成员的投影里没有）。不是成员、agent 不在项目里 NotFound；别人的 botin
    /// NotPermitted。
    pub async fn project_agent_limits(
        &mut self,
        owner: UserId,
        p: ProjectId,
        instance: InstanceId,
    ) -> Result<AgentLimits> {
        self.project_actor(
            owner,
            p,
            &[],
            &[ProjectStatus::Active, ProjectStatus::Archived],
        )
        .await?;
        let row: Option<(Uuid, Option<i64>, Option<i64>)> = sqlx::query_as(
            "SELECT user_id, daily_token_limit, total_token_limit FROM project_agents \
              WHERE project_id = $1 AND instance_id = $2 AND left_at IS NULL",
        )
        .bind(p.0)
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        let (who, d, t) = row.ok_or(Error::NotFound)?;
        if who != owner.0 {
            return Err(Error::NotPermitted(
                "only the agent's owner can see its limits".into(),
            ));
        }
        Ok(AgentLimits {
            daily_token_limit: limit(d, "daily token limit")?,
            total_token_limit: limit(t, "total token limit")?,
        })
    }

    /// 创建者设负责人（8.17，docs/projects.md 第 7 节）：`lead` 为 None 是不要负责人。有别人加入过的项目只能是专属于它的
    /// botin（不是的 `AgentNotIsolated`）；只有自己的项目（原来的团队）哪个都行。旧的负责人先清掉（一个项目只有一个）。
    pub async fn set_project_lead(
        &mut self,
        user: UserId,
        p: ProjectId,
        lead: Option<InstanceId>,
    ) -> Result<LeadChange> {
        let planned = match lead {
            Some(i) => self.agent_owner(p, i).await?,
            None => None,
        };
        let also: Vec<UserId> = planned.into_iter().collect();
        let actor = self
            .project_actor(user, p, &also, &[ProjectStatus::Active])
            .await?;
        actor.require_creator("choose the lead")?;
        let old = self.project_lead(p).await?;
        let new = match lead {
            None => None,
            Some(i) => {
                let row: Option<(Uuid, bool, bool)> = sqlx::query_as(
                    "SELECT a.user_id, a.dedicated, EXISTS (SELECT 1 FROM project_members m \
                              WHERE m.project_id = a.project_id AND m.user_id = a.user_id AND m.left_at IS NULL) \
                       FROM project_agents a JOIN instances ins ON ins.id = a.instance_id AND ins.state <> 'deleted' \
                      WHERE a.project_id = $1 AND a.instance_id = $2 AND a.left_at IS NULL FOR NO KEY UPDATE OF a",
                )
                .bind(p.0)
                .bind(i.0)
                .fetch_optional(self.conn())
                .await?;
                let Some((owner, dedicated, member)) = row else {
                    return Err(Error::Invalid("not an agent of this project".into()));
                };
                if !member {
                    return Err(Error::Invalid("not an agent of this project".into()));
                }
                let shared: bool =
                    sqlx::query_scalar("SELECT shared_at IS NOT NULL FROM projects WHERE id = $1")
                        .bind(p.0)
                        .fetch_one(self.conn())
                        .await?;
                if shared && !dedicated {
                    return Err(Error::AgentNotIsolated);
                }
                Some((i, UserId(owner)))
            }
        };
        if old.map(|o| o.0) == new.map(|n| n.0) {
            return Ok(LeadChange { old, new });
        }
        sqlx::query(
            "UPDATE project_agents SET is_lead = false WHERE project_id = $1 AND is_lead AND left_at IS NULL",
        )
        .bind(p.0)
        .execute(self.conn())
        .await?;
        if let Some((i, _)) = new {
            sqlx::query(
                "UPDATE project_agents SET is_lead = true WHERE project_id = $1 AND instance_id = $2 \
                   AND left_at IS NULL",
            )
            .bind(p.0)
            .bind(i.0)
            .execute(self.conn())
            .await?;
        }
        sqlx::query("UPDATE projects SET updated_at = now() WHERE id = $1")
            .bind(p.0)
            .execute(self.conn())
            .await?;
        Ok(LeadChange { old, new })
    }

    /// 核对项目里调平台工具的这个运行（8.17）：在项目 `p` 里、agent 还在、实例专属于 p、主人能用、项目开着、运行没结束。
    /// 按 D4 加锁：用户行（主人、创建者、`also`）→ 项目锁 → 这个运行。不对的 NotFound；运行已经结束 Conflict("run_over")。
    pub(crate) async fn project_agent_actor(
        &mut self,
        run: RunId,
        p: ProjectId,
        also: &[UserId],
    ) -> Result<ProjectAgentActor> {
        let row: Option<(Uuid, Uuid, Option<Uuid>)> =
            sqlx::query_as("SELECT user_id, instance_id, project_id FROM runs WHERE id = $1")
                .bind(run.0)
                .fetch_optional(self.conn())
                .await?;
        let Some((owner, instance, project)) = row else {
            return Err(Error::NotFound);
        };
        if project != Some(p.0) {
            return Err(Error::NotFound);
        }
        let (owner, instance) = (UserId(owner), InstanceId(instance));
        let creator: Uuid = sqlx::query_scalar("SELECT creator_id FROM projects WHERE id = $1")
            .bind(p.0)
            .fetch_one(self.conn())
            .await?;
        let mut ids = vec![owner, UserId(creator)];
        ids.extend_from_slice(also);
        let users = self.lock_users(&ids).await?;
        if !users
            .iter()
            .any(|u| u.id == owner && u.status == UserStatus::Active)
        {
            return Err(Error::NotFound);
        }
        self.lock_project(p).await?;
        let live: bool = sqlx::query_scalar(
            "SELECT pr.status = 'active' AND project_agent_live($1, $2, $3) \
                    AND EXISTS (SELECT 1 FROM instances i WHERE i.id = $2 AND i.workspace_project_id = $1) \
               FROM projects pr WHERE pr.id = $1",
        )
        .bind(p.0)
        .bind(instance.0)
        .bind(owner.0)
        .fetch_one(self.conn())
        .await?;
        if !live {
            return Err(Error::NotFound);
        }
        let (state, grant, budget): (String, Option<Uuid>, serde_json::Value) = sqlx::query_as(
            "SELECT state, run_grant_id, budget FROM runs WHERE id = $1 FOR NO KEY UPDATE",
        )
        .bind(run.0)
        .fetch_one(self.conn())
        .await?;
        if matches!(state.as_str(), "succeeded" | "failed" | "cancelled") {
            return Err(Error::Conflict("run_over".into()));
        }
        let lead = self.is_project_lead(p, instance).await?;
        Ok(ProjectAgentActor {
            instance,
            owner,
            grant: grant.map(GrantId),
            lead,
            budget: crate::from_json(budget, "run budget")?,
            users,
        })
    }

    /// 项目里的运行开一个子运行（8.17）：负责人委派给项目里别的 botin（谁的都行），任何 agent 问项目里别的 agent。
    /// 子运行记在目标 botin 的主人名下；委派用从负责人这次运行的授权收窄出来的子授权，提问用目标自己的常设授权（问的是
    /// 信息，不是权限）。预算：同一个主人沿用父运行的，别人的按目标主人还剩的。守着的规矩（都在项目锁里）：深度、链上
    /// 循环、谁在等谁、一个运行开的个数、排队上限、预算；目标的主人按了“全部停止”的，子运行等主人确认。
    pub async fn project_child_run(
        &mut self,
        caller: RunId,
        p: ProjectId,
        to: InstanceId,
        child: &ProjectChild<'_>,
    ) -> Result<ProjectChildResult> {
        if !self.project_dispatch_enabled().await? {
            return Ok(ProjectChildResult::Refused(ChildRefusal::DispatchOff));
        }
        let planned = self.agent_owner(p, to).await?;
        let also: Vec<UserId> = planned.into_iter().collect();
        let actor = self.project_agent_actor(caller, p, &also).await?;
        if child.source == RunSource::Delegate && !actor.lead {
            return Ok(ProjectChildResult::Refused(ChildRefusal::NotLead));
        }
        if to == actor.instance {
            return Ok(ProjectChildResult::Refused(ChildRefusal::SelfTarget));
        }
        let Some(owner) = self.agent_owner(p, to).await? else {
            return Ok(ProjectChildResult::Refused(ChildRefusal::TargetGone));
        };
        let status = actor.users.iter().find(|u| u.id == owner).map(|u| u.status);
        if status.is_none() {
            // 读主人和加锁之间换了人（不会发生：agent 行改主人要先锁项目），按不在了算。
            return Ok(ProjectChildResult::Refused(ChildRefusal::TargetGone));
        }
        let chain = self.run_chain(caller).await?;
        let depth = chain
            .iter()
            .filter(|(_, _, source)| *source == child.source)
            .count();
        if depth >= child.max_depth {
            return Ok(ProjectChildResult::Refused(ChildRefusal::TooDeep));
        }
        if chain.iter().any(|(_, instance, _)| *instance == to) {
            return Ok(ProjectChildResult::Refused(ChildRefusal::OnChain));
        }
        if child.dedupe
            && let Some(open) = self.open_ask(caller, to, child.prompt).await?
        {
            return Ok(ProjectChildResult::Existing(open));
        }
        let siblings = match child.source {
            RunSource::Ask => self.ask_runs(caller).await?.len(),
            _ => self.delegated_runs(caller).await?.len(),
        };
        if siblings >= child.max_siblings {
            return Ok(ProjectChildResult::Refused(ChildRefusal::TooMany));
        }
        if self.instance_waits_for(to, caller).await? {
            return Ok(ProjectChildResult::Refused(ChildRefusal::WaitsForCaller));
        }
        let target = match self
            .project_target(p, to, status, true, child.grant_ttl)
            .await?
        {
            Ok(t) => t,
            Err(r) => return Ok(ProjectChildResult::Refused(r.into())),
        };
        let grant = match child.source {
            RunSource::Delegate => {
                let Some(parent) = actor.grant else {
                    return Ok(ProjectChildResult::Refused(ChildRefusal::NoScope));
                };
                let (_, standing) = self.run_grant(target.grant).await?;
                match self
                    .create_project_child_grant(
                        parent,
                        p,
                        to,
                        owner,
                        &standing.scope,
                        child.grant_ttl,
                    )
                    .await
                {
                    Ok(g) => g.id,
                    Err(Error::Invalid(_)) => {
                        return Ok(ProjectChildResult::Refused(ChildRefusal::NoScope));
                    }
                    Err(e) => return Err(e),
                }
            }
            _ => target.grant,
        };
        let budget = if owner == actor.owner {
            actor.budget
        } else {
            RunBudget {
                max_tokens: target.budget_left,
                ..RunBudget::default()
            }
        };
        let agent_version: String =
            sqlx::query_scalar("SELECT agent_version FROM instances WHERE id = $1")
                .bind(to.0)
                .fetch_one(self.conn())
                .await?;
        let mut new = NewRun::new(to, child.source, child.prompt, agent_version);
        new.parent_run_id = Some(caller);
        new.run_grant_id = Some(grant);
        new.budget = budget;
        new.max_attempts = child.max_attempts;
        new.answer_deadline = child.answer_deadline;
        let mut run = self.insert_project_run(owner, p, &new).await?;
        if target.paused {
            run = self.hold_for_owner(run.id).await?;
        }
        Ok(ProjectChildResult::Created {
            run,
            held: target.paused,
        })
    }

    /// 在项目里取消一个运行连同它的整棵子树（8.17）：创建者能取消项目里任何一个，主人能取消自己 botin 的，别人
    /// NotPermitted；不在这个项目里的 NotFound；已经结束的 InvalidTransition。返回调用方的角色和取消的（运行，实例）。
    pub async fn cancel_project_run(
        &mut self,
        user: UserId,
        p: ProjectId,
        run: RunId,
    ) -> Result<(ProjectRole, Vec<(RunId, InstanceId)>)> {
        let actor = self
            .project_actor(user, p, &[], &[ProjectStatus::Active])
            .await?;
        let row: Option<(Uuid, String)> =
            sqlx::query_as("SELECT user_id, state FROM runs WHERE id = $1 AND project_id = $2")
                .bind(run.0)
                .bind(p.0)
                .fetch_optional(self.conn())
                .await?;
        let Some((owner, state)) = row else {
            return Err(Error::NotFound);
        };
        if actor.role != ProjectRole::Creator && owner != user.0 {
            return Err(Error::NotPermitted(
                "only the project creator or the agent's owner can stop this task".into(),
            ));
        }
        let state: proto::domain::RunState = crate::parse(&state)?;
        if state.is_terminal() {
            return Err(Error::InvalidTransition {
                from: state,
                to: proto::domain::RunState::Cancelled,
            });
        }
        let cancelled = self
            .cancel_project_subtree(run, "stopped in the project", true, false)
            .await?;
        Ok((actor.role, cancelled))
    }
}
