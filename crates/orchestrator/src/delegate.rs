//! 委派（WBS 8.7、8.8）：团队负责人 agent 用平台工具 `delegate` 把子任务交给团队里的其他 agent。
//!
//! - 子任务是父运行下的一个子运行，在成员自己的沙箱里执行、用它自己实例的模型 key；
//!   运行授权从父运行的授权收窄出来（范围不超过父运行，父授权吊销时一起失效），预算和整棵运行树共用（8.6）。
//! - 工具立刻返回，负责人可以接着干别的。它这一轮结束时还有子任务没做完，父运行转入“等待子任务”、
//!   放掉租约（沙箱照样会被空闲回收暂停）；子任务都结束后，平台把结果作为一条新消息交还给它，接着跑。
//! - 护栏（8.8）：委派最多 [`MAX_DEPTH`] 层；不能交给自己、也不能交给链上已经在等它的 agent
//!   （A 委派 B，B 又委派 A 会互相等死），也不能交给正（经别的 agent）在等它的（比如问了它一个问题、
//!   在等回答的成员，和问队友 8.11 共用“谁在等谁”）；一次运行最多委派 [`MAX_CHILDREN_PER_RUN`] 个子任务。
//! - agent 不可信：成员只能是负责人自己团队里的、同一用户的实例，库里再核对一次。
//! - 项目里（8.17）：只有项目的负责人能委派，可以交给项目里任何一个专属 botin，谁的都行。子运行记在 botin 的主人名下，
//!   子授权从负责人这次运行的授权收窄（和目标的常设授权取交集），预算按目标的主人设的算。库里存“标题\n\n任务”原文，
//!   平台的说明（谁委派的、是谁的 botin）在启动时加上。守着的规矩在库里、在项目锁里核对（见
//!   [`store::Tx::project_child_run`]）。

use std::time::Duration;

use async_trait::async_trait;
use proto::domain::{
    Instance, Locale, ProjectId, ProjectRunState, Run, RunKind, RunSource, RunState,
};
use proto::shim::PlatformTool;
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Db, NewRun, ProjectChild, ProjectChildResult};

use crate::shim::{PlatformTools, ToolContext, ToolOutput};
use crate::texts::{AnswerOutcome, ChildOutcome, children_results};

pub const DELEGATE_TOOLS: [&str; 2] = ["delegate_list", "delegate"];

/// 委派最多这么多层（负责人委派给成员算一层，成员再委派算第二层）。
pub const MAX_DEPTH: usize = 3;
/// 一次运行最多委派这么多个子任务。
pub const MAX_CHILDREN_PER_RUN: usize = 10;
/// 子任务的说明最长这么多字。
const MAX_TASK_CHARS: usize = 8000;
/// 子运行的授权最长有效期（不续期，跟着父授权走）。
const CHILD_GRANT_TTL: Duration = Duration::from_secs(7 * 24 * 3600);

pub struct DelegateTools {
    db: Db,
}

impl DelegateTools {
    pub fn new(db: Db) -> Self {
        Self { db }
    }

    async fn targets(&self, ctx: &ToolContext) -> Result<Vec<Instance>, String> {
        let mut t = self.db.tenant(ctx.user).await.map_err(internal)?;
        let targets = t.delegation_targets(ctx.instance).await.map_err(internal)?;
        t.rollback().await.map_err(internal)?;
        Ok(targets)
    }

    async fn list(&self, ctx: &ToolContext) -> Result<Value, String> {
        if ctx.project.is_some() {
            let p = crate::projects::live_project_call(&self.db, ctx).await?;
            return self.project_list(ctx, p).await;
        }
        let members: Vec<Value> = self
            .targets(ctx)
            .await?
            .into_iter()
            .map(|i| json!({ "name": i.name, "agent": i.agent_id, "instance_id": i.id }))
            .collect();
        let mut w = self.db.worker().await.map_err(internal)?;
        let children = w.delegated_runs(ctx.run).await.map_err(internal)?;
        w.rollback().await.map_err(internal)?;
        let subtasks: Vec<Value> = children
            .iter()
            .map(|r| {
                json!({
                    "run_id": r.id,
                    "instance_id": r.instance_id,
                    "state": r.state,
                    "summary": r.summary,
                })
            })
            .collect();
        Ok(json!({ "members": members, "subtasks": subtasks }))
    }

    async fn delegate(&self, ctx: &ToolContext, args: DelegateArgs) -> Result<Value, String> {
        let task = args.task.trim();
        if task.is_empty() || task.chars().count() > MAX_TASK_CHARS {
            return Err(format!("task must be 1-{MAX_TASK_CHARS} characters"));
        }
        if ctx.project.is_some() {
            let p = crate::projects::live_project_call(&self.db, ctx).await?;
            return self.project_delegate(ctx, p, &args, task).await;
        }
        let to = args.to.trim();
        let targets = self.targets(ctx).await?;
        if targets.is_empty() {
            return Err(
                "only the lead of a team can delegate, and this agent leads no team".into(),
            );
        }
        let Some(target) = targets
            .iter()
            .find(|i| i.id.to_string() == to || i.name == to)
            .cloned()
        else {
            let names: Vec<&str> = targets.iter().map(|i| i.name.as_str()).collect();
            return Err(format!(
                "no team member called {to:?}; you can delegate to: {}",
                names.join(", ")
            ));
        };

        let mut w = self.db.worker().await.map_err(internal)?;
        // “谁在等谁”和问队友（8.11）共用：按用户加锁，检查和建子运行之间不会插进别的委派、提问。
        w.lock_run_waits(ctx.user).await.map_err(internal)?;
        // 护栏（8.8）：深度、循环。链上是这次运行和它的父运行们。
        let chain = w.run_chain(ctx.run).await.map_err(internal)?;
        let depth = chain
            .iter()
            .filter(|(_, _, source)| *source == RunSource::Delegate)
            .count();
        if depth >= MAX_DEPTH {
            return Err(format!(
                "delegation is limited to {MAX_DEPTH} levels; do this part yourself"
            ));
        }
        if chain.iter().any(|(_, instance, _)| *instance == target.id) {
            return Err(format!(
                "{} is already working on this task further up the chain; delegating to it would deadlock",
                target.name
            ));
        }
        // 跨运行树的循环：成员正在跑的运行（直接或经别的 agent）在等这次运行，比如它问了负责人一个问题。
        if w.instance_waits_for(target.id, ctx.run)
            .await
            .map_err(internal)?
        {
            return Err(format!(
                "{} is waiting (directly or through other agents) for you to finish; delegating to it \
                 would deadlock. Do this part yourself or delegate it to someone else",
                target.name
            ));
        }
        let children = w.delegated_runs(ctx.run).await.map_err(internal)?;
        if children.len() >= MAX_CHILDREN_PER_RUN {
            return Err(format!("at most {MAX_CHILDREN_PER_RUN} subtasks per run"));
        }
        let parent = w.run_record(ctx.run).await.map_err(internal)?;
        let (_, grant) = w.run_grant(ctx.grant).await.map_err(internal)?;
        // 权限不放大（8.6）：子授权从这次运行的授权收窄出来，范围相同、有效期不超过它。
        let child_grant = w
            .create_child_grant(ctx.grant, target.id, &grant.scope, CHILD_GRANT_TTL)
            .await
            .map_err(|e| match e {
                store::Error::Invalid(m) => m,
                e => refused(e),
            })?;
        let lead = w
            .instance_runtime(ctx.instance)
            .await
            .map(|rt| rt.agent_id)
            .unwrap_or_default();
        let title = args
            .title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map_or_else(|| first_line(task, 40), |t| first_line(t, 40));
        let locale = w.user_locale(ctx.user).await.map_err(internal)?;
        let prompt = crate::texts::delegated_task(locale, &lead, &title, task);
        let mut new = NewRun::new(
            target.id,
            RunSource::Delegate,
            prompt,
            target.agent_version.clone(),
        );
        new.kind = RunKind::Agent;
        new.plan_id = parent.run.plan_id;
        new.parent_run_id = Some(ctx.run);
        new.run_grant_id = Some(child_grant.id);
        // 预算整棵树共用（8.6）：子运行沿用根运行的上限，执行时按全树的用量核对。
        new.budget = parent.budget;
        let child = w
            .create_run(ctx.user, &new)
            .await
            .map_err(refused)?
            .ok_or_else(|| "could not create the subtask".to_owned())?;
        w.append_event(
            ctx.instance,
            Some(ctx.run),
            "delegate.started",
            &json!({ "child_run_id": child.id, "instance_id": target.id, "to": target.name, "title": title }),
        )
        .await
        .map_err(internal)?;
        w.commit().await.map_err(internal)?;
        Ok(json!({
            "run_id": child.id,
            "to": target.name,
            "status": "started",
            "next": "Keep working on other parts if you like. When you end your turn, the platform waits for your subtasks and sends you their results as a new message."
        }))
    }

    /// 项目里能交给谁（项目里别的专属 botin），和这次运行委派出去的子任务（成员能看的粗略状态）。
    async fn project_list(&self, ctx: &ToolContext, p: ProjectId) -> Result<Value, String> {
        let (m, _, team) = crate::projects::project_team(&self.db, ctx, p).await?;
        let _ = m.finish().await;
        let members: Vec<Value> = team
            .iter()
            .map(|t| {
                json!({
                    "name": t.name,
                    "agent": t.agent,
                    "owner": t.owner,
                    "instance_id": t.instance,
                })
            })
            .collect();
        let mut w = self.db.worker().await.map_err(internal)?;
        let children = w.delegated_runs(ctx.run).await.map_err(internal)?;
        w.rollback().await.map_err(internal)?;
        let subtasks: Vec<Value> = children
            .iter()
            .map(|r| {
                let to = team
                    .iter()
                    .find(|t| t.instance == r.instance_id)
                    .map_or_else(
                        || "a botin that left the project".to_owned(),
                        |t| t.name.clone(),
                    );
                let mut v = json!({
                    "run_id": r.id,
                    "instance_id": r.instance_id,
                    "to": to,
                    "title": first_line(&r.prompt, 40),
                    "state": ProjectRunState::coarse(r.state),
                });
                if let Some(s) = r.summary.as_deref().filter(|s| !s.is_empty()) {
                    v["summary"] = json!(s);
                }
                v
            })
            .collect();
        Ok(json!({
            "members": members,
            "subtasks": subtasks,
            "note": crate::projects::PROJECT_UNTRUSTED,
        }))
    }

    /// 项目的负责人把子任务交给项目里别的专属 botin（8.17）。
    async fn project_delegate(
        &self,
        ctx: &ToolContext,
        p: ProjectId,
        args: &DelegateArgs,
        task: &str,
    ) -> Result<Value, String> {
        let to = args.to.trim();
        let (m, d, team) = crate::projects::project_team(&self.db, ctx, p).await?;
        let _ = m.finish().await;
        let Some(target) = crate::projects::find_teammate(&team, to)?.cloned() else {
            let names: Vec<&str> = team.iter().map(|t| t.name.as_str()).collect();
            return Err(format!(
                "no botin called {to:?} in this project; you can delegate to: {}",
                names.join(", ")
            ));
        };
        let title = args
            .title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map_or_else(|| first_line(task, 40), |t| first_line(t, 40));
        // 库里存原文：第一行是标题。平台的说明（谁委派的）启动时再加。
        let prompt = format!("{title}\n\n{task}");
        let mut w = self.db.worker().await.map_err(internal)?;
        let created = w
            .project_child_run(
                ctx.run,
                p,
                target.instance,
                &ProjectChild {
                    source: RunSource::Delegate,
                    prompt: &prompt,
                    max_depth: MAX_DEPTH,
                    max_siblings: MAX_CHILDREN_PER_RUN,
                    max_attempts: NewRun::new(target.instance, RunSource::Delegate, "", "")
                        .max_attempts,
                    answer_deadline: None,
                    dedupe: false,
                    grant_ttl: CHILD_GRANT_TTL,
                },
            )
            .await
            .map_err(crate::projects::project_write_error)?;
        let (child, held) = match created {
            ProjectChildResult::Created { run, held } => (run, held),
            ProjectChildResult::Existing(run) => (run, false),
            ProjectChildResult::Refused(why) => {
                let _ = w.rollback().await;
                return Err(crate::projects::child_refusal(why, &target.name, true));
            }
        };
        if held {
            crate::projects::notify_held(
                &mut w,
                target.owner_id,
                p,
                &d.summary.name,
                child.id,
                target.instance,
                &target.raw_name,
            )
            .await
            .map_err(internal)?;
        }
        w.append_event(
            ctx.instance,
            Some(ctx.run),
            "delegate.started",
            &json!({ "child_run_id": child.id, "instance_id": target.instance, "to": target.name, "title": title }),
        )
        .await
        .map_err(internal)?;
        w.commit().await.map_err(internal)?;
        let mut next = "Keep working on other parts if you like. When you end your turn, the platform waits for your subtasks and sends you their results as a new message.".to_owned();
        if held {
            next.insert_str(
                0,
                &format!(
                    "{}'s owner paused it, so the subtask starts once its owner confirms. ",
                    target.name
                ),
            );
        }
        Ok(json!({
            "run_id": child.id,
            "to": target.name,
            "owner": target.owner,
            "status": if held { "waiting_owner" } else { "started" },
            "next": next,
        }))
    }
}

#[derive(Deserialize)]
struct DelegateArgs {
    /// 成员的名字或实例 id。
    to: String,
    task: String,
    #[serde(default)]
    title: Option<String>,
}

/// 目标实例专属于一个项目（8.16：库里拒绝了私人任务）。
fn refused(e: store::Error) -> String {
    match e {
        store::Error::InstanceDedicated => {
            "that agent works only for a project and cannot take private tasks".to_owned()
        }
        e => internal(e),
    }
}

fn internal(e: impl std::fmt::Display) -> String {
    tracing::warn!(error = %e, "delegate tool failed");
    "internal error, try again later".into()
}

/// 第一行，最多 `max` 个字。
fn first_line(s: &str, max: usize) -> String {
    let line = s.lines().next().unwrap_or_default().trim();
    let mut out: String = line.chars().take(max).collect();
    if line.chars().count() > max {
        out.push('…');
    }
    out
}

/// 子任务的结果、问队友的回答，作为新消息交还给 agent（8.7、8.11），按用户的语言（1.6）。
/// `children` 是这次要交还的、已经结束的子运行和成员名（委派的和提问的都在里面）。
///
/// 项目里（`project`，8.17）子运行是别的用户的：库里存的是原文（取第一行），不给失败原因（是对方主人私人的，可能带着
/// 密钥），名字由调用方过了 [`crate::texts::label`]。
pub fn results_message(
    locale: Locale,
    children: &[(Run, String)],
    original: &str,
    project: bool,
) -> String {
    // 私人的子运行的提示词是“说明 + 空行 + 任务（问题）”，取任务的第一行。
    let rows: Vec<(String, Option<String>)> = children
        .iter()
        .map(|(run, _)| {
            let max = if run.source == RunSource::Ask { 60 } else { 40 };
            if project {
                return (first_line(&run.prompt, max), None);
            }
            let task = run
                .prompt
                .split_once("\n\n")
                .map_or_else(|| first_line(&run.prompt, max), |(_, t)| first_line(t, max));
            let error = run.error.as_deref().map(|e| first_line(e, 300));
            (task, error)
        })
        .collect();
    let mut delegated: Vec<(&str, &str, ChildOutcome<'_>)> = Vec::new();
    let mut asked: Vec<(&str, &str, AnswerOutcome<'_>)> = Vec::new();
    for ((run, name), (task, error)) in children.iter().zip(&rows) {
        if run.source == RunSource::Ask {
            let outcome = match run.state {
                RunState::Succeeded => AnswerOutcome::Answered(run.summary.as_deref()),
                RunState::Cancelled
                    if run.state_reason.as_deref() == Some(store::ANSWER_TIMEOUT_REASON) =>
                {
                    AnswerOutcome::TimedOut(crate::ask::ANSWER_TIMEOUT.as_secs() / 60)
                }
                RunState::Cancelled => AnswerOutcome::Cancelled,
                _ => AnswerOutcome::Failed(error.as_deref()),
            };
            asked.push((name.as_str(), task.as_str(), outcome));
        } else {
            let outcome = match run.state {
                RunState::Succeeded => ChildOutcome::Done(run.summary.as_deref()),
                RunState::Cancelled => ChildOutcome::Cancelled,
                _ => ChildOutcome::Failed(error.as_deref()),
            };
            delegated.push((name.as_str(), task.as_str(), outcome));
        }
    }
    children_results(locale, &delegated, &asked, original, project)
}

#[async_trait]
impl PlatformTools for DelegateTools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![
            PlatformTool {
                read_only: false,
                name: "delegate_list".into(),
                description: "List the agents you can delegate to (your team, or in project work the project's botins), and the subtasks you delegated in this run with their state.".into(),
                input_schema: json!({ "type": "object", "properties": {} }),
            },
            PlatformTool {
                read_only: false,
                name: "delegate".into(),
                description: "Hand a subtask to another agent in your team (in project work: another botin in the project, whoever owns it). It runs in that agent's own sandbox; exchange files through artifacts. Returns at once: carry on, and when you end your turn the platform waits for all your subtasks and sends you their results as a new message.".into(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "to": { "type": "string", "description": "Member name or instance_id from delegate_list" },
                        "task": { "type": "string", "description": "What the member should do, with everything it needs to know" },
                        "title": { "type": "string", "description": "Short name for the subtask" }
                    },
                    "required": ["to", "task"]
                }),
            },
        ]
    }

    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput {
        let result = match name {
            "delegate_list" => self.list(ctx).await,
            "delegate" => match serde_json::from_value::<DelegateArgs>(arguments.clone()) {
                Ok(a) => self.delegate(ctx, a).await,
                Err(e) => Err(format!("bad arguments: {e}")),
            },
            other => Err(format!("unknown platform tool {other}")),
        };
        match result {
            Ok(v) => ToolOutput::text(v.to_string()),
            Err(m) => ToolOutput::error(m),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::domain::{InstanceId, RunId};

    #[test]
    fn titles_are_short_single_lines() {
        assert_eq!(first_line("写周报\n第二行", 40), "写周报");
        assert_eq!(first_line(&"长".repeat(50), 4), "长长长长…");
        assert_eq!(first_line("", 4), "");
    }

    #[test]
    fn results_list_each_subtask() {
        let run = |state, summary: Option<&str>, error: Option<&str>| Run {
            id: RunId::new(),
            kind: RunKind::Agent,
            instance_id: InstanceId::new(),
            plan_id: None,
            parent_run_id: None,
            root_run_id: RunId::new(),
            step_key: None,
            source: RunSource::Delegate,
            prompt: "（委派说明）\n\n调研三家竞品\n要表格".into(),
            state,
            state_reason: None,
            attempt: 1,
            tokens_used: 0,
            summary: summary.map(str::to_owned),
            error: error.map(str::to_owned),
            created_at: chrono::Utc::now(),
            started_at: None,
            finished_at: None,
            wait_code: None,
            project_id: None,
        };
        let children = [
            (
                run(RunState::Succeeded, Some("做好了表格"), None),
                "研究员".into(),
            ),
            (
                run(RunState::Failed, None, Some("budget exceeded")),
                "程序员".into(),
            ),
            (run(RunState::Cancelled, None, None), "测试员".into()),
        ];
        let msg = results_message(Locale::ZhCn, &children, "写一份竞品报告", false);
        assert!(
            msg.contains("1. 交给「研究员」的「调研三家竞品」：完成。做好了表格"),
            "{msg}"
        );
        assert!(
            msg.contains("2. 交给「程序员」的「调研三家竞品」：失败：budget exceeded"),
            "{msg}"
        );
        assert!(
            msg.contains("3. 交给「测试员」的「调研三家竞品」：被取消了。"),
            "{msg}"
        );
        assert!(msg.ends_with("写一份竞品报告"));
        // 英文用户（1.6）。
        let msg = results_message(Locale::En, &children, "Write a report", false);
        assert!(
            msg.contains("2. “调研三家竞品” for 程序员: Failed: budget exceeded"),
            "{msg}"
        );
        assert!(msg.ends_with("Write a report"));

        // 问队友的（8.11）：回答、超时、取消分开说。
        let ask = |state, summary: Option<&str>, reason: Option<&str>| Run {
            source: RunSource::Ask,
            prompt: "（提问说明）\n\n上周的数据放在哪？".into(),
            state_reason: reason.map(str::to_owned),
            ..run(state, summary, None)
        };
        let mixed = [
            children[0].clone(),
            (
                ask(RunState::Succeeded, Some("在 data/ 下"), None),
                "研究员".into(),
            ),
            (
                ask(
                    RunState::Cancelled,
                    None,
                    Some(store::ANSWER_TIMEOUT_REASON),
                ),
                "写手".into(),
            ),
            (ask(RunState::Cancelled, None, None), "测试员".into()),
        ];
        let msg = results_message(Locale::ZhCn, &mixed, "写一份竞品报告", false);
        assert!(
            msg.starts_with("（你委派的子任务都结束了，问队友的问题也有结果了"),
            "{msg}"
        );
        assert!(
            msg.contains("\n1. 交给「研究员」的「调研三家竞品」：完成。"),
            "{msg}"
        );
        assert!(
            msg.contains("\n问1. 问「研究员」的「上周的数据放在哪？」：回答：在 data/ 下"),
            "{msg}"
        );
        assert!(
            msg.contains("问2. 问「写手」的「上周的数据放在哪？」：对方没有在 30 分钟内回答。"),
            "{msg}"
        );
        assert!(
            msg.contains("问3. 问「测试员」的「上周的数据放在哪？」：没问成：被取消了。"),
            "{msg}"
        );
    }
}
