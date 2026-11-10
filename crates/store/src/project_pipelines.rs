//! 项目流水线（WBS 8.17，迁移 0065）：创建者开始的一次性流水线，每一步可以是项目里任何一个专属 botin（不分主人）。
//!
//! - 根运行（kind、source 都是 `pipeline`，不带授权）挂在创建者自己的一个专属 botin 上：只有创建者拥有、能停掉它，别人
//!   “全部停止”、撤下 botin 都碰不到它。
//! - 每一步用那个 botin 自己在项目里的常设授权、它主人在项目里的预算（问的是活，不是权限：和提问一样，8.17 D5c）。主人按了
//!   “全部停止”的，那一步先等主人确认。
//! - 步骤开始以后不改，存成 jsonb，带上每一步 botin 的主人（驱动按 D4 的顺序先锁这些用户）。
//! - 驱动（编排层）每个根运行一个事务：[`Tx::lock_project_pipeline`] 按 D4 加锁（用户行 → 项目锁 → 根运行，别人锁着的
//!   跳过），再按依赖顺序用 [`Tx::project_step_run`] 开步骤。

use std::time::Duration;

use proto::domain::{
    InstanceId, MAX_PROJECT_PIPELINE_STEPS, PlanStep, ProjectId, ProjectPipeline,
    ProjectPipelineStep, ProjectStatus, Run, RunBudget, RunId, RunKind, RunSource, UserId,
    UserStatus, order_steps,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{Error, NewRun, ProjectTx, Result, RunRecord, Tx, Worker, from_json, to_json};

/// 流水线的标题最长这么多字。
pub const MAX_PIPELINE_TITLE_CHARS: usize = 200;
/// 流水线的目标最长这么多字。
pub const MAX_PIPELINE_GOAL_CHARS: usize = 4000;
/// 一步的要求最长这么多字。
pub const MAX_STEP_PROMPT_CHARS: usize = 8000;

/// 存进库里的一步：加上这一步 botin 的主人。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectStep {
    pub key: String,
    pub instance_id: InstanceId,
    pub user_id: UserId,
    pub prompt: String,
    #[serde(default)]
    pub depends_on: Vec<String>,
}

impl ProjectStep {
    pub fn plan_step(&self) -> PlanStep {
        PlanStep {
            key: self.key.clone(),
            instance_id: self.instance_id,
            prompt: self.prompt.clone(),
            depends_on: self.depends_on.clone(),
        }
    }
}

/// 驱动读的一条项目流水线。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectPipelineRecord {
    pub root: RunId,
    pub project_id: ProjectId,
    pub title: String,
    pub created_by: UserId,
    pub steps: Vec<ProjectStep>,
}

impl ProjectPipelineRecord {
    pub fn plan_steps(&self) -> Vec<PlanStep> {
        self.steps.iter().map(ProjectStep::plan_step).collect()
    }
}

/// 开一步的结果。
#[derive(Debug, Clone)]
pub enum ProjectStepStart {
    /// 开了；`held`：这一步 botin 的主人按了“全部停止”，先等主人确认。
    Started { run: Box<Run>, held: bool },
    /// 开不了（给根运行记的平台说明，不带对方的任何东西）。
    Refused(String),
}

/// 一步的键：1 到 32 个 a-z 0-9 _ -，字母或数字开头（和计划的步骤一样）。
pub fn valid_step_key(key: &str) -> bool {
    (1..=32).contains(&key.len())
        && key.bytes().enumerate().all(|(i, b)| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || (i > 0 && (b == b'_' || b == b'-'))
        })
}

/// 校验要开始的流水线：标题、目标、步数、键、要求的长度、依赖（没有环）。
pub fn check_project_pipeline(
    title: &str,
    goal: &str,
    steps: &[ProjectPipelineStep],
) -> Result<()> {
    let n = title.trim().chars().count();
    if n == 0 || n > MAX_PIPELINE_TITLE_CHARS {
        return Err(Error::Invalid(format!(
            "title must be 1-{MAX_PIPELINE_TITLE_CHARS} characters"
        )));
    }
    if goal.chars().count() > MAX_PIPELINE_GOAL_CHARS {
        return Err(Error::Invalid(format!(
            "goal must be at most {MAX_PIPELINE_GOAL_CHARS} characters"
        )));
    }
    if steps.is_empty() || steps.len() > MAX_PROJECT_PIPELINE_STEPS {
        return Err(Error::Invalid(format!(
            "a pipeline has 1-{MAX_PROJECT_PIPELINE_STEPS} steps"
        )));
    }
    for s in steps {
        if !valid_step_key(&s.key) {
            return Err(Error::Invalid(format!(
                "step key {:?} must be 1-32 of a-z 0-9 _ - (starting with a letter or digit)",
                s.key
            )));
        }
        let n = s.prompt.trim().chars().count();
        if n == 0 || n > MAX_STEP_PROMPT_CHARS {
            return Err(Error::Invalid(format!(
                "step {:?} needs a prompt of 1-{MAX_STEP_PROMPT_CHARS} characters",
                s.key
            )));
        }
    }
    let plan: Vec<PlanStep> = steps
        .iter()
        .map(|s| PlanStep {
            key: s.key.clone(),
            instance_id: s.instance_id,
            prompt: s.prompt.clone(),
            depends_on: s.depends_on.clone(),
        })
        .collect();
    order_steps(&plan).map_err(Error::Invalid)?;
    Ok(())
}

type PipelineRow = (Uuid, Uuid, String, serde_json::Value, Uuid);

fn record(row: PipelineRow) -> Result<ProjectPipelineRecord> {
    let (root, project, title, steps, created_by) = row;
    Ok(ProjectPipelineRecord {
        root: RunId(root),
        project_id: ProjectId(project),
        title,
        created_by: UserId(created_by),
        steps: from_json(steps, "pipeline steps")?,
    })
}

impl Tx<Worker> {
    /// 创建者开始一条项目流水线（8.17）：先校验（[`check_project_pipeline`]），每一步的 botin 要能接项目的活（专属、主人
    /// 能用、预算没用完：和派任务一样的拒绝）；根运行挂在创建者自己的专属 botin 上（排好序的步骤里第一个是创建者的那个，
    /// 没有就按位置第一个），没有的 Invalid。只有创建者；项目要开着；派单开关要开着。返回根运行（还在排队，驱动去推进）。
    pub async fn start_project_pipeline(
        &mut self,
        creator: UserId,
        p: ProjectId,
        title: &str,
        goal: &str,
        steps: &[ProjectPipelineStep],
        grant_ttl: Duration,
    ) -> Result<Run> {
        check_project_pipeline(title, goal, steps)?;
        if !self.project_dispatch_enabled().await? {
            return Err(Error::DispatchOff);
        }
        let mut owners = Vec::with_capacity(steps.len());
        for s in steps {
            match self.agent_owner(p, s.instance_id).await? {
                Some(o) => owners.push(o),
                None => {
                    // 不是成员的、项目不在的先按“不在项目里”报：下面的身份核对会把外人变成 NotFound。
                    owners.push(UserId(Uuid::nil()));
                }
            }
        }
        let also: Vec<UserId> = owners.iter().copied().filter(|o| !o.0.is_nil()).collect();
        let actor = self
            .project_actor(creator, p, &also, &[ProjectStatus::Active])
            .await?;
        actor.require_creator("start project pipelines")?;
        let mut stored = Vec::with_capacity(steps.len());
        for (s, owner) in steps.iter().zip(&owners) {
            if owner.0.is_nil() {
                return Err(Error::Invalid(format!(
                    "the agent for step {:?} is not in the project",
                    s.key
                )));
            }
            let Some(locked) = actor.locked(*owner) else {
                return Err(Error::Conflict(
                    "the project changed while starting the pipeline; try again".into(),
                ));
            };
            match self
                .project_target(p, s.instance_id, Some(locked.status), false, grant_ttl)
                .await?
            {
                Ok(_) => {}
                Err(refusal) => return Err(refusal.into_error()),
            }
            stored.push(ProjectStep {
                key: s.key.clone(),
                instance_id: s.instance_id,
                user_id: *owner,
                prompt: s.prompt.trim().to_owned(),
                depends_on: s.depends_on.clone(),
            });
        }
        // 根运行挂在创建者自己的专属 botin 上。
        let mine: Vec<Uuid> = sqlx::query_scalar(
            "SELECT a.instance_id FROM project_agents a \
               JOIN instances i ON i.id = a.instance_id AND i.workspace_project_id = a.project_id \
                AND i.state <> 'deleted' \
              WHERE a.project_id = $1 AND a.user_id = $2 AND a.left_at IS NULL \
              ORDER BY a.position, a.instance_id",
        )
        .bind(p.0)
        .bind(creator.0)
        .fetch_all(self.conn())
        .await?;
        let plan: Vec<PlanStep> = stored.iter().map(ProjectStep::plan_step).collect();
        let order = order_steps(&plan).map_err(Error::Invalid)?;
        let anchor = order
            .iter()
            .map(|s| s.instance_id.0)
            .find(|i| mine.contains(i))
            .or_else(|| mine.first().copied())
            .ok_or_else(|| {
                Error::Invalid(
                    "add one of your own dedicated botins to the project to run a pipeline".into(),
                )
            })?;
        let agent_version: String =
            sqlx::query_scalar("SELECT agent_version FROM instances WHERE id = $1")
                .bind(anchor)
                .fetch_one(self.conn())
                .await?;
        let goal = goal.trim();
        let prompt = if goal.is_empty() { title.trim() } else { goal };
        let mut new = NewRun::new(
            InstanceId(anchor),
            RunSource::Pipeline,
            prompt,
            agent_version,
        );
        new.kind = RunKind::Pipeline;
        new.run_grant_id = None;
        let root = self.insert_project_run(creator, p, &new).await?;
        sqlx::query(
            "INSERT INTO project_pipelines (root_run_id, project_id, title, steps, created_by) \
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(root.id.0)
        .bind(p.0)
        .bind(title.trim())
        .bind(to_json(&stored)?)
        .bind(creator.0)
        .execute(self.conn())
        .await?;
        Ok(root)
    }

    /// 要推进的项目流水线（排队中、等子运行中，到时间了，创建者的账号能用），不加锁：每个根运行由
    /// [`Tx::lock_project_pipeline`] 在自己的事务里加锁。
    pub async fn due_project_pipelines(&mut self, limit: i64) -> Result<Vec<(RunId, ProjectId)>> {
        let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
            "SELECT r.id, r.project_id FROM runs r \
              WHERE r.kind = 'pipeline' AND r.project_id IS NOT NULL \
                AND r.state IN ('queued', 'waiting_children') AND r.not_before <= now() \
                AND EXISTS (SELECT 1 FROM users u WHERE u.id = r.user_id AND u.status = 'active') \
              ORDER BY r.not_before, r.id LIMIT $1",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(r, p)| (RunId(r), ProjectId(p)))
            .collect())
    }

    /// 一条项目流水线（不加锁的读；执行器复制上游产出物时用）。
    pub async fn project_pipeline(&mut self, root: RunId) -> Result<Option<ProjectPipelineRecord>> {
        let row: Option<PipelineRow> = sqlx::query_as(
            "SELECT root_run_id, project_id, title, steps, created_by FROM project_pipelines WHERE root_run_id = $1",
        )
        .bind(root.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(record).transpose()
    }

    /// 推进一条项目流水线之前按 D4 加锁：创建者和每一步 botin 的主人的用户行（`FOR KEY SHARE`）→ 项目锁 → 根运行（`FOR
    /// UPDATE SKIP LOCKED`）。根运行已经不用推进了、别人锁着的返回 None（这一轮跳过）。
    pub async fn lock_project_pipeline(
        &mut self,
        root: RunId,
    ) -> Result<Option<(RunRecord, ProjectPipelineRecord)>> {
        let Some(pl) = self.project_pipeline(root).await? else {
            return Ok(None);
        };
        let mut users: Vec<UserId> = pl.steps.iter().map(|s| s.user_id).collect();
        users.push(pl.created_by);
        self.lock_users(&users).await?;
        self.lock_project(pl.project_id).await?;
        let locked: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM runs WHERE id = $1 AND kind = 'pipeline' AND project_id IS NOT NULL \
               AND state IN ('queued', 'waiting_children') AND not_before <= now() \
             FOR UPDATE SKIP LOCKED",
        )
        .bind(root.0)
        .fetch_optional(self.conn())
        .await?;
        if locked.is_none() {
            return Ok(None);
        }
        let rec = self.run_record(root).await?;
        Ok(Some((rec, pl)))
    }

    /// 开项目流水线的一步（调用方按 [`Tx::lock_project_pipeline`] 锁着）：这一步的 botin 要还能接项目的活，用它在项目里的
    /// 常设授权、它主人的预算；主人按了“全部停止”的先等确认。开不了的 [`ProjectStepStart::Refused`]（平台的说明）。
    pub async fn project_step_run(
        &mut self,
        root: &RunRecord,
        step: &ProjectStep,
        prompt: &str,
        grant_ttl: Duration,
    ) -> Result<ProjectStepStart> {
        let Some(p) = root.run.project_id else {
            return Err(Error::Invalid("not a project pipeline".into()));
        };
        let refused = || {
            ProjectStepStart::Refused(format!(
                "the agent for step {} cannot take project work now",
                step.key
            ))
        };
        let status: Option<String> = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
            .bind(step.user_id.0)
            .fetch_optional(self.conn())
            .await?;
        let status: Option<UserStatus> = status.map(|s| crate::parse(&s)).transpose()?;
        let target = match self
            .project_target(p, step.instance_id, status, false, grant_ttl)
            .await?
        {
            Ok(t) if t.owner == step.user_id => t,
            _ => return Ok(refused()),
        };
        let agent_version: String =
            sqlx::query_scalar("SELECT agent_version FROM instances WHERE id = $1")
                .bind(step.instance_id.0)
                .fetch_one(self.conn())
                .await?;
        let mut new = NewRun::new(step.instance_id, RunSource::Pipeline, prompt, agent_version);
        new.kind = RunKind::Agent;
        new.parent_run_id = Some(root.run.id);
        new.step_key = Some(step.key.clone());
        new.run_grant_id = Some(target.grant);
        new.budget = RunBudget {
            max_tokens: target.budget_left,
            ..RunBudget::default()
        };
        let mut run = self.insert_project_run(target.owner, p, &new).await?;
        if target.paused {
            run = self.hold_for_owner(run.id).await?;
        }
        Ok(ProjectStepStart::Started {
            run: Box::new(run),
            held: target.paused,
        })
    }
}

impl ProjectTx {
    /// 项目里的一条流水线（成员看）：标题、目标、各步（不带 botin 的主人）。不是这个项目的 NotFound。
    pub async fn project_pipeline(&mut self, p: ProjectId, root: RunId) -> Result<ProjectPipeline> {
        let run = self.project_run(p, root).await?;
        let row: (String, serde_json::Value) = sqlx::query_as(
            "SELECT title, steps FROM project_pipelines WHERE project_id = $1 AND root_run_id = $2",
        )
        .bind(p.0)
        .bind(root.0)
        .fetch_one(self.conn())
        .await?;
        let steps: Vec<ProjectStep> = from_json(row.1, "pipeline steps")?;
        Ok(ProjectPipeline {
            title: row.0,
            goal: run.prompt,
            steps: steps
                .into_iter()
                .map(|s| ProjectPipelineStep {
                    key: s.key,
                    instance_id: s.instance_id,
                    prompt: s.prompt,
                    depends_on: s.depends_on,
                })
                .collect(),
        })
    }
}
