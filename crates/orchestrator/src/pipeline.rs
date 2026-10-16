//! 流水线（WBS 8.2、8.3、8.5）：计划带步骤时，到点生成一个流水线运行（运行树的根），
//! 这里按依赖顺序给每一步生成子运行，能并行的并行；有一步失败就停掉其余步骤，整棵树失败。
//!
//! 每一步的提示词后面附一份交接说明（整体目标、上游步骤的摘要、上游产出物清单），
//! 执行器开始这一步之前把上游产出物复制到工作区的 `handoff/` 目录（[`HandoffCopier`]）。
//! 流水线运行不占实例、不执行 agent，也没有租约：推进都在一个锁住根运行的事务里完成。

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use notify::PushKind;
use proto::domain::{PlanStep, RunKind, RunSource, RunState, order_steps};
use serde_json::json;
use store::{Db, InstanceRuntime, NewRun, RunChange, RunRecord, Tx, Worker};
use tracing::{error, info};

use crate::artifacts::ArtifactStore;
use crate::outbox::{Notice, notify};

#[derive(Debug, Clone)]
pub struct PipelineConfig {
    pub tick: Duration,
    pub batch: i64,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            tick: Duration::from_secs(2),
            batch: 20,
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PipelineReport {
    pub started: usize,
    pub steps_started: usize,
    pub succeeded: usize,
    pub failed: usize,
}

pub struct PipelineDriver {
    db: Db,
    cfg: PipelineConfig,
}

fn truncate(s: &str, max: usize) -> String {
    let s = s.trim();
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_owned(),
    }
}

impl PipelineDriver {
    pub fn new(db: Db, cfg: PipelineConfig) -> Self {
        Self { db, cfg }
    }

    pub async fn tick(&self) -> store::Result<PipelineReport> {
        let mut report = PipelineReport::default();
        let mut w = self.db.worker().await?;
        let roots = w.due_pipelines(self.cfg.batch).await?;
        for root in &roots {
            self.advance(&mut w, root, &mut report).await?;
        }
        // 处理过的排到队尾：一直等子运行的流水线不会每轮都占满这一批，别的流水线（别的用户的）也能轮到。
        let ids: Vec<_> = roots.iter().map(|r| r.run.id).collect();
        w.requeue_pipelines(&ids).await?;
        w.commit().await?;
        Ok(report)
    }

    async fn advance(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        report: &mut PipelineReport,
    ) -> store::Result<()> {
        let Some(plan_id) = root.run.plan_id else {
            return self
                .finish(w, root, Err("a pipeline run needs a plan".into()), report)
                .await;
        };
        let steps = w.plan_steps(plan_id).await?;
        let order = match order_steps(&steps) {
            Ok(o) if !o.is_empty() => o,
            Ok(_) => {
                return self
                    .finish(w, root, Err("the plan has no steps".into()), report)
                    .await;
            }
            Err(e) => return self.finish(w, root, Err(e), report).await,
        };
        let title = w.plan(plan_id).await.map(|p| p.title).unwrap_or_default();
        if root.run.state == RunState::Queued {
            w.set_unleased_state(
                root.run.id,
                RunState::Queued,
                RunState::WaitingChildren,
                &RunChange {
                    reason: Some(format!("running {} steps", steps.len())),
                    ..Default::default()
                },
            )
            .await?;
            w.append_event(
                root.run.instance_id,
                Some(root.run.id),
                "run.state",
                &json!({ "state": RunState::WaitingChildren, "steps": steps.len() }),
            )
            .await?;
            report.started += 1;
        }
        let children: HashMap<String, RunRecord> = w
            .child_runs(root.run.id)
            .await?
            .into_iter()
            .filter_map(|c| c.run.step_key.clone().map(|k| (k, c)))
            .collect();

        // 失败传播：一步失败（或被单独停掉），其余步骤停下，整棵树失败。
        if let Some((key, bad)) = order.iter().find_map(|s| {
            children
                .get(&s.key)
                .filter(|c| matches!(c.run.state, RunState::Failed | RunState::Cancelled))
                .map(|c| (s.key.clone(), c))
        }) {
            let why = format!(
                "step {key} {}: {}",
                bad.run.state,
                bad.run
                    .error
                    .as_deref()
                    .or(bad.run.state_reason.as_deref())
                    .unwrap_or("no details")
            );
            w.cancel_children(root.run.id, &format!("step {key} did not succeed"))
                .await?;
            return self.finish(w, root, Err(why), report).await;
        }

        // 依赖都成功了、还没开始的步骤：开始。
        for step in &order {
            if children.contains_key(&step.key) {
                continue;
            }
            let deps: Option<Vec<&RunRecord>> = step
                .depends_on
                .iter()
                .map(|d| {
                    children
                        .get(d)
                        .filter(|c| c.run.state == RunState::Succeeded)
                })
                .collect();
            let Some(deps) = deps else { continue };
            if let Err(why) = self.start_step(w, root, &title, step, &deps).await? {
                w.cancel_children(root.run.id, "pipeline stopped").await?;
                return self.finish(w, root, Err(why), report).await;
            }
            report.steps_started += 1;
        }

        // 全部成功：根运行成功，摘要取最后几步（没有下游的步骤）的摘要。
        let all_done = order.iter().all(|s| {
            children
                .get(&s.key)
                .is_some_and(|c| c.run.state == RunState::Succeeded)
        });
        if all_done {
            let finals: Vec<String> = order
                .iter()
                .filter(|s| !steps.iter().any(|o| o.depends_on.contains(&s.key)))
                .filter_map(|s| {
                    children
                        .get(&s.key)
                        .and_then(|c| c.run.summary.as_ref())
                        .map(|sum| format!("{}：{}", s.key, truncate(sum, 300)))
                })
                .collect();
            return self.finish(w, root, Ok(finals.join("\n")), report).await;
        }
        Ok(())
    }

    /// 给一步建子运行：从计划的授权收窄出这一步实例的授权，提示词附上交接说明。
    async fn start_step(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        title: &str,
        step: &PlanStep,
        deps: &[&RunRecord],
    ) -> store::Result<Result<(), String>> {
        let rt: InstanceRuntime = match w.instance_runtime(step.instance_id).await {
            Ok(rt) if rt.state != proto::domain::InstanceState::Deleted => rt,
            Ok(_) | Err(store::Error::NotFound) => {
                return Ok(Err(format!(
                    "the instance for step {} was deleted",
                    step.key
                )));
            }
            Err(e) => return Err(e),
        };
        let grant = match root.run_grant_id {
            Some(parent) => {
                let (_, p) = w.run_grant(parent).await?;
                match w
                    .create_child_grant(
                        parent,
                        step.instance_id,
                        &p.scope,
                        Duration::from_secs(7 * 24 * 3600),
                    )
                    .await
                {
                    Ok(g) => Some(g.id),
                    Err(store::Error::Invalid(m)) => return Ok(Err(m)),
                    Err(e) => return Err(e),
                }
            }
            None => None,
        };
        let dep_ids: Vec<_> = deps.iter().map(|d| d.run.id).collect();
        let artifacts = w.run_artifacts(&dep_ids).await?;
        let prompt = handoff_prompt(title, &root.run.prompt, step, deps, &artifacts);
        let mut new = NewRun::new(
            step.instance_id,
            RunSource::Pipeline,
            prompt,
            rt.agent_version.clone(),
        );
        new.kind = RunKind::Agent;
        new.plan_id = root.run.plan_id;
        new.parent_run_id = Some(root.run.id);
        new.step_key = Some(step.key.clone());
        new.run_grant_id = grant;
        new.budget = root.budget;
        let child = w.create_run(root.user_id, &new).await?;
        if let Some(child) = child {
            w.append_event(
                root.run.instance_id,
                Some(root.run.id),
                "pipeline.step_started",
                &json!({ "step": step.key, "run_id": child.id, "instance_id": step.instance_id }),
            )
            .await?;
        }
        Ok(Ok(()))
    }

    async fn finish(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        result: Result<String, String>,
        report: &mut PipelineReport,
    ) -> store::Result<()> {
        let (to, change, push) = match &result {
            Ok(summary) => {
                report.succeeded += 1;
                (
                    RunState::Succeeded,
                    RunChange {
                        summary: Some(summary.clone()).filter(|s| !s.is_empty()),
                        ..Default::default()
                    },
                    (PushKind::RunFinished, truncate(summary, 100)),
                )
            }
            Err(why) => {
                report.failed += 1;
                (
                    RunState::Failed,
                    RunChange {
                        reason: Some(truncate(why, 200)),
                        error: Some(why.clone()),
                        ..Default::default()
                    },
                    (PushKind::RunFailed, truncate(why, 100)),
                )
            }
        };
        let from = root.run.state;
        // 还在排队就失败（没有步骤）：先进入等待再结束，状态机里排队不能直接失败。
        let from = if from == RunState::Queued && to == RunState::Failed {
            w.set_unleased_state(
                root.run.id,
                RunState::Queued,
                RunState::WaitingChildren,
                &RunChange::default(),
            )
            .await?;
            RunState::WaitingChildren
        } else {
            from
        };
        let done = w.set_unleased_state(root.run.id, from, to, &change).await?;
        w.append_event(
            root.run.instance_id,
            Some(root.run.id),
            "run.state",
            &json!({ "state": to, "reason": done.run.state_reason }),
        )
        .await?;
        let title = match root.run.plan_id {
            Some(p) => w.plan(p).await.map(|p| p.title).unwrap_or_default(),
            None => String::new(),
        };
        let (kind, body) = push;
        let title = if title.is_empty() {
            crate::texts::APP_NAME.to_owned()
        } else {
            title
        };
        let body = if body.is_empty() {
            let locale = w.user_locale(root.user_id).await?;
            crate::texts::pipeline_finished(locale).to_owned()
        } else {
            body
        };
        let notice = Notice {
            instance: Some(root.run.instance_id),
            run: Some(root.run.id),
            plan: root.run.plan_id,
            thread_id: Some(root.run.id.to_string()),
            dedupe_key: Some(format!("run:{}:{to}", root.run.id)),
            ai_generated: kind == PushKind::RunFinished,
            ..Notice::new(kind, title, body)
        };
        notify(w, root.user_id, &notice).await?;
        info!(run = %root.run.id, state = %to, "pipeline finished");
        Ok(())
    }

    pub async fn run(&self, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let mut tick = tokio::time::interval(self.cfg.tick);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        info!("pipeline driver started");
        loop {
            tokio::select! {
                () = &mut stop => break,
                _ = tick.tick() => {
                    if let Err(e) = self.tick().await {
                        error!(error = %e, "pipeline tick failed");
                    }
                }
            }
        }
        info!("pipeline driver stopped");
    }
}

/// 一步的提示词：步骤本身的要求，加上交接说明（8.5）。
pub fn handoff_prompt(
    title: &str,
    goal: &str,
    step: &PlanStep,
    deps: &[&RunRecord],
    artifacts: &[store::StoredArtifact],
) -> String {
    let mut out = step.prompt.trim().to_owned();
    out.push_str("\n\n---\n【交接说明】");
    if title.is_empty() {
        out.push_str(&format!("这是一条流水线中的一步（{}）。", step.key));
    } else {
        out.push_str(&format!("这是流水线「{title}」中的一步（{}）。", step.key));
    }
    out.push_str(&format!("\n整体目标：{}", truncate(goal, 1000)));
    if !deps.is_empty() {
        out.push_str("\n上游步骤的结果：");
        for d in deps {
            let key = d.run.step_key.as_deref().unwrap_or("?");
            let summary = d.run.summary.as_deref().map(|s| truncate(s, 600));
            out.push_str(&format!(
                "\n- {key}：{}",
                summary.as_deref().unwrap_or("（没有摘要）")
            ));
        }
    }
    if !artifacts.is_empty() {
        out.push_str("\n上游产出物（开始前已复制到工作区的 handoff/ 目录；也可以用 artifact_list、artifact_read 查看）：");
        for a in artifacts {
            out.push_str(&format!(
                "\n- handoff/{} （v{}，{} 字节）",
                a.artifact.name, a.artifact.version, a.artifact.size
            ));
        }
    }
    out
}

/// 执行器开始一个流水线步骤之前，把上游步骤的产出物复制到这一步的工作区（8.5）。
pub struct HandoffCopier {
    db: Db,
    store: Arc<ArtifactStore>,
    provider: Arc<dyn sandbox::SandboxProvider>,
    workdir: String,
}

impl HandoffCopier {
    pub fn new(
        db: Db,
        store: Arc<ArtifactStore>,
        provider: Arc<dyn sandbox::SandboxProvider>,
        workdir: impl Into<String>,
    ) -> Self {
        Self {
            db,
            store,
            provider,
            workdir: workdir.into(),
        }
    }

    /// 返回复制了几个文件。不是流水线步骤的运行什么都不做。
    pub async fn copy(&self, rec: &RunRecord, rt: &InstanceRuntime) -> Result<usize, String> {
        let (Some(key), Some(parent), Some(plan)) =
            (&rec.run.step_key, rec.run.parent_run_id, rec.run.plan_id)
        else {
            return Ok(0);
        };
        let Some(sid) = rt.sandbox_id.clone() else {
            return Err("the sandbox is not running".into());
        };
        let artifacts = async {
            let mut w = self.db.worker().await?;
            let steps = w.plan_steps(plan).await?;
            let deps = steps
                .iter()
                .find(|s| &s.key == key)
                .map(|s| s.depends_on.clone())
                .unwrap_or_default();
            let siblings = w.child_runs(parent).await?;
            let dep_runs: Vec<_> = siblings
                .iter()
                .filter(|c| c.run.step_key.as_ref().is_some_and(|k| deps.contains(k)))
                .map(|c| c.run.id)
                .collect();
            let a = w.run_artifacts(&dep_runs).await?;
            w.rollback().await?;
            Ok::<_, store::Error>(a)
        }
        .await
        .map_err(|e| e.to_string())?;
        for a in &artifacts {
            let bytes = self.store.read(a).await.map_err(|e| e.to_string())?;
            let path = format!("{}/handoff/{}", self.workdir, a.artifact.name);
            self.provider
                .write_file(&sandbox::SandboxId(sid.clone()), &path, &bytes)
                .await
                .map_err(|e| format!("copying {}: {e}", a.artifact.name))?;
        }
        if !artifacts.is_empty() {
            info!(run = %rec.run.id, files = artifacts.len(), "copied upstream artifacts into the workspace");
        }
        Ok(artifacts.len())
    }
}
