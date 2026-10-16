//! 委派（WBS 8.7、8.8）：团队负责人 agent 用平台工具 `delegate` 把子任务交给团队里的其他 agent。
//!
//! - 子任务是父运行下的一个子运行，在成员自己的沙箱里执行、用它自己实例的模型 key；
//!   运行授权从父运行的授权收窄出来（范围不超过父运行，父授权吊销时一起失效），预算和整棵运行树共用（8.6）。
//! - 工具立刻返回，负责人可以接着干别的。它这一轮结束时还有子任务没做完，父运行转入“等待子任务”、
//!   放掉租约（沙箱照样会被空闲回收暂停）；子任务都结束后，平台把结果作为一条新消息交还给它，接着跑。
//! - 护栏（8.8）：委派最多 [`MAX_DEPTH`] 层；不能交给自己、也不能交给链上已经在等它的 agent
//!   （A 委派 B，B 又委派 A 会互相等死）；一次运行最多委派 [`MAX_CHILDREN_PER_RUN`] 个子任务。
//! - agent 不可信：成员只能是负责人自己团队里的、同一用户的实例，库里再核对一次。

use std::time::Duration;

use async_trait::async_trait;
use proto::domain::{Instance, Run, RunKind, RunSource, RunState};
use proto::shim::PlatformTool;
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Db, NewRun};

use crate::shim::{PlatformTools, ToolContext, ToolOutput};

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
                e => internal(e),
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
        let prompt = format!(
            "（这是团队负责人（{lead}）委派给你的子任务「{title}」。做完后用几句话总结结果，\
             要交给负责人的文件用 artifact_publish 发布。）\n\n{task}"
        );
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
            .map_err(internal)?
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
}

#[derive(Deserialize)]
struct DelegateArgs {
    /// 成员的名字或实例 id。
    to: String,
    task: String,
    #[serde(default)]
    title: Option<String>,
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

/// 子任务的结果，作为新消息交还给负责人（8.7）。`children` 是这次要交还的、已经结束的子运行。
pub fn results_message(children: &[(Run, String)], original: &str) -> String {
    let mut out = String::from(
        "（你委派的子任务都结束了，结果如下。据此继续完成原来的任务；需要的话可以再委派。）\n",
    );
    for (i, (run, name)) in children.iter().enumerate() {
        // 子运行的提示词是“委派说明 + 空行 + 任务”，取任务的第一行。
        let task = run
            .prompt
            .split_once("\n\n")
            .map_or_else(|| first_line(&run.prompt, 40), |(_, t)| first_line(t, 40));
        let outcome = match run.state {
            RunState::Succeeded => {
                format!("完成。{}", run.summary.as_deref().unwrap_or("（没有总结）"))
            }
            RunState::Cancelled => "被取消了。".to_owned(),
            _ => format!(
                "失败：{}",
                first_line(run.error.as_deref().unwrap_or("原因不明"), 300)
            ),
        };
        out.push_str(&format!(
            "\n{}. 交给「{name}」的「{task}」：{outcome}",
            i + 1
        ));
    }
    out.push_str(&format!(
        "\n\n产出物用 artifact_list、artifact_read 查看。\n\n原来的任务（供参考）：\n{original}"
    ));
    out
}

#[async_trait]
impl PlatformTools for DelegateTools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![
            PlatformTool {
                name: "delegate_list".into(),
                description: "List the team members you can delegate to, and the subtasks you delegated in this run with their state.".into(),
                input_schema: json!({ "type": "object", "properties": {} }),
            },
            PlatformTool {
                name: "delegate".into(),
                description: "Hand a subtask to another agent in your team. It runs in that agent's own sandbox; exchange files through artifacts. Returns at once: carry on, and when you end your turn the platform waits for all your subtasks and sends you their results as a new message.".into(),
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
        };
        let msg = results_message(
            &[
                (
                    run(RunState::Succeeded, Some("做好了表格"), None),
                    "研究员".into(),
                ),
                (
                    run(RunState::Failed, None, Some("budget exceeded")),
                    "程序员".into(),
                ),
            ],
            "写一份竞品报告",
        );
        assert!(
            msg.contains("1. 交给「研究员」的「调研三家竞品」：完成。做好了表格"),
            "{msg}"
        );
        assert!(
            msg.contains("2. 交给「程序员」的「调研三家竞品」：失败：budget exceeded"),
            "{msg}"
        );
        assert!(msg.ends_with("写一份竞品报告"));
    }
}
