//! 流水线（WBS 8.2、8.3、8.5）：计划带步骤时，到点生成一个流水线运行（运行树的根），
//! 这里按依赖顺序给每一步生成子运行，能并行的并行；有一步失败就停掉其余步骤，整棵树失败。
//!
//! 每一步的提示词后面附一份交接说明（整体目标、上游步骤的摘要、上游产出物清单），
//! 执行器开始这一步之前把上游产出物复制到工作区的 `handoff/` 目录（[`HandoffCopier`]）。
//! 流水线运行不占实例、不执行 agent，也没有租约：推进都在一个锁住根运行的事务里完成。
//!
//! 项目流水线（8.17）：创建者开始的、步骤可以在项目里任何一个专属 botin 上（不分主人）。每个根运行一个事务，按 D4 加锁
//! （[`store::Tx::lock_project_pipeline`]）；每一步用那个 botin 自己的授权和它主人的预算，交接说明按这一步主人的语言、
//! 上游的结果用边界标出来、注明是别的 botin 写的；一步没成功时根运行只记“第几步怎样了”，不抄对方的失败原因；不发通知
//! （8.19）。

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use notify::PushKind;
use proto::domain::{
    Locale, PlanStep, ProjectRunState, RunId, RunKind, RunSource, RunState, order_steps,
};
use serde_json::json;
use store::{
    Db, InstanceRuntime, NewRun, ProjectPipelineRecord, ProjectStepStart, RunChange, RunRecord, Tx,
    Worker,
};
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
        let mut started = Vec::new();
        for root in &roots {
            self.advance(&mut w, root, &mut report, &mut started)
                .await?;
        }
        // 计划的流水线开始了：远程开启实时活动（10.6）。按用户加锁，所以放到最后、按用户排好序再做：
        // 两个副本同时推进两批时加锁的顺序一样，不会互相等死。
        started.sort_by_key(|r: &RunRecord| r.user_id.0);
        for root in &started {
            crate::live::queue_starts(&mut w, root).await?;
        }
        // 处理过的排到队尾：一直等子运行的流水线不会每轮都占满这一批，别的流水线（别的用户的）也能轮到。
        let ids: Vec<_> = roots.iter().map(|r| r.run.id).collect();
        w.requeue_pipelines(&ids).await?;
        w.commit().await?;
        // 项目流水线（8.17）：每个根运行一个事务，一个出错不影响别的。
        let due = {
            let mut w = self.db.worker().await?;
            let due = w.due_project_pipelines(self.cfg.batch).await?;
            w.rollback().await?;
            due
        };
        for (root, _) in due {
            if let Err(e) = self.tick_project(root, &mut report).await {
                error!(run = %root, error = %e, "advancing a project pipeline failed");
            }
        }
        Ok(report)
    }

    /// 推进一条项目流水线：按 D4 加锁（别人锁着、已经不用推进的跳过），推进，排到队尾，提交。
    async fn tick_project(&self, root: RunId, report: &mut PipelineReport) -> store::Result<()> {
        let mut w = self.db.worker().await?;
        let Some((rec, pl)) = w.lock_project_pipeline(root).await? else {
            w.rollback().await?;
            return Ok(());
        };
        self.advance_project(&mut w, &rec, &pl, report).await?;
        w.requeue_pipelines(&[root]).await?;
        w.commit().await
    }

    /// 和 [`Self::advance`] 一样，按项目流水线自己存的步骤；失败的原因只写平台的话。
    async fn advance_project(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        pl: &ProjectPipelineRecord,
        report: &mut PipelineReport,
    ) -> store::Result<()> {
        let steps = pl.plan_steps();
        let order = match order_steps(&steps) {
            Ok(o) if !o.is_empty() => o,
            Ok(_) => {
                return self
                    .finish(w, root, Err("the pipeline has no steps".into()), report)
                    .await;
            }
            Err(e) => return self.finish(w, root, Err(e), report).await,
        };
        let moved;
        let root = if root.run.state == RunState::Queued {
            moved = w
                .set_unleased_state(
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
            &moved
        } else {
            root
        };
        let children: HashMap<String, RunRecord> = w
            .child_runs(root.run.id)
            .await?
            .into_iter()
            .filter_map(|c| c.run.step_key.clone().map(|k| (k, c)))
            .collect();
        // 一步没成功：只记粗略的结局（失败原因是这一步 botin 的主人的），停掉整棵树里别的（每个记一条 `run.state`；等主人
        // 确认的步骤，提醒在库里取消时一起标已读）。
        if let Some((key, bad)) = order.iter().find_map(|s| {
            children
                .get(&s.key)
                .filter(|c| matches!(c.run.state, RunState::Failed | RunState::Cancelled))
                .map(|c| (s.key.clone(), c))
        }) {
            let why = format!(
                "step {key} {}",
                ProjectRunState::coarse(bad.run.state).as_str()
            );
            let reason = format!("step {key} did not succeed");
            let cancelled = w
                .cancel_project_subtree(root.run.id, &reason, false, false)
                .await?;
            crate::project_tasks::log_cancelled(w, &cancelled, &reason).await?;
            return self.finish(w, root, Err(why), report).await;
        }
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
            let Some(stored) = pl.steps.iter().find(|s| s.key == step.key) else {
                continue;
            };
            match self
                .start_project_step(w, root, pl, step, stored, &deps)
                .await?
            {
                Ok(true) => report.steps_started += 1,
                // 这一步的 botin 排满了：先不开，下一轮再试。
                Ok(false) => {}
                Err(why) => {
                    let cancelled = w
                        .cancel_project_subtree(root.run.id, "pipeline stopped", false, false)
                        .await?;
                    crate::project_tasks::log_cancelled(w, &cancelled, "pipeline stopped").await?;
                    return self.finish(w, root, Err(why), report).await;
                }
            }
        }
        let all_done = order.iter().all(|s| {
            children
                .get(&s.key)
                .is_some_and(|c| c.run.state == RunState::Succeeded)
        });
        if all_done {
            let sep = crate::texts::pick(w.user_locale(root.user_id).await?, "：", ": ");
            let finals: Vec<String> = order
                .iter()
                .filter(|s| !steps.iter().any(|o| o.depends_on.contains(&s.key)))
                .filter_map(|s| {
                    children
                        .get(&s.key)
                        .and_then(|c| c.run.summary.as_ref())
                        .map(|sum| format!("{}{sep}{}", s.key, truncate(sum, 300)))
                })
                .collect();
            return self.finish(w, root, Ok(finals.join("\n")), report).await;
        }
        Ok(())
    }

    /// 开项目流水线的一步：开了 `Ok(true)`；这一步的 botin 排着的项目任务满了 `Ok(false)`（回到保存点，下一轮再试，流水线
    /// 不失败）。建运行放在保存点里：除了库连不上（`store::Error::Db`），被拒绝的一律只让这一条流水线失败（回到保存点，
    /// 平台的说明），别的根运行照常推进。替这一步 botin 的主人新签了常设授权的，给主人记一条 `grant.issue`。
    async fn start_project_step(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        pl: &ProjectPipelineRecord,
        step: &PlanStep,
        stored: &store::ProjectStep,
        deps: &[&RunRecord],
    ) -> store::Result<Result<bool, String>> {
        w.savepoint("project_step").await?;
        let started = async {
            let dep_ids: Vec<_> = deps.iter().map(|d| d.run.id).collect();
            let artifacts = w.run_artifacts(&dep_ids).await?;
            let locale = w.user_locale(stored.user_id).await?;
            let boundary = format!(
                "UPSTREAM-{}",
                &uuid::Uuid::now_v7().simple().to_string()[12..]
            );
            let prompt = project_handoff_prompt(
                locale,
                &pl.title,
                &root.run.prompt,
                step,
                deps,
                &artifacts,
                &boundary,
            );
            match w
                .project_step_run(root, stored, &prompt, crate::projects::PROJECT_GRANT_TTL)
                .await?
            {
                ProjectStepStart::Refused(why) => Ok::<_, store::Error>(Err(why)),
                ProjectStepStart::Deferred => Ok(Ok(false)),
                ProjectStepStart::Started {
                    run,
                    held,
                    grant_issued,
                } => {
                    if let Some(grant) = grant_issued {
                        crate::projects::audit_grant_issued(
                            w,
                            stored.user_id,
                            step.instance_id,
                            pl.project_id,
                            grant,
                            "project pipeline",
                        )
                        .await?;
                    }
                    w.append_event(
                        root.run.instance_id,
                        Some(root.run.id),
                        "pipeline.step_started",
                        &json!({ "step": step.key, "run_id": run.id, "instance_id": step.instance_id }),
                    )
                    .await?;
                    if held {
                        let project = w.project_name(pl.project_id).await?;
                        let botin = w.instance_name(step.instance_id).await?;
                        crate::projects::notify_held(
                            w,
                            stored.user_id,
                            pl.project_id,
                            &project,
                            run.id,
                            step.instance_id,
                            &botin,
                        )
                        .await?;
                    }
                    Ok(Ok(true))
                }
            }
        }
        .await;
        match started {
            Ok(Ok(true)) => {
                w.release_savepoint("project_step").await?;
                Ok(Ok(true))
            }
            Ok(Ok(false)) => {
                // 这一步没开：回到保存点，什么都不留。
                w.rollback_to_savepoint("project_step").await?;
                w.release_savepoint("project_step").await?;
                Ok(Ok(false))
            }
            Ok(Err(why)) => {
                w.rollback_to_savepoint("project_step").await?;
                Ok(Err(why))
            }
            Err(e @ store::Error::Db(_)) => Err(e),
            Err(e) => {
                tracing::warn!(run = %root.run.id, step = %step.key, error = %e, "a project pipeline step was refused");
                w.rollback_to_savepoint("project_step").await?;
                Ok(Err(format!(
                    "the agent for step {} cannot take project work now",
                    step.key
                )))
            }
        }
    }

    async fn advance(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        report: &mut PipelineReport,
        started: &mut Vec<RunRecord>,
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
        // 开始了就用开始后的记录（后面步骤起不来、要结束整个流水线时，是从“等子运行”结束，不是从“排队”）。
        let moved;
        let root = if root.run.state == RunState::Queued {
            moved = w
                .set_unleased_state(
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
            started.push(moved.clone());
            report.started += 1;
            &moved
        } else {
            root
        };
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
            let sep = crate::texts::pick(w.user_locale(root.user_id).await?, "：", ": ");
            let finals: Vec<String> = order
                .iter()
                .filter(|s| !steps.iter().any(|o| o.depends_on.contains(&s.key)))
                .filter_map(|s| {
                    children
                        .get(&s.key)
                        .and_then(|c| c.run.summary.as_ref())
                        .map(|sum| format!("{}{sep}{}", s.key, truncate(sum, 300)))
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
        // 建授权、建运行放在保存点里：被库里拒绝（这一步的 botin 在计划暂停时被标成了专属于项目，8.16；授权收窄不了）
        // 时只让这一条流水线失败，事务回到保存点接着推进这一批里别的流水线（别的用户的）。不先在这里查专属：库里的
        // 触发器是唯一的判断，测试走的就是这条路。
        w.savepoint("pipeline_step").await?;
        match self.create_step_run(w, root, title, step, deps, &rt).await {
            Ok(Ok(())) => {
                w.release_savepoint("pipeline_step").await?;
                Ok(Ok(()))
            }
            Ok(Err(why)) => {
                w.rollback_to_savepoint("pipeline_step").await?;
                Ok(Err(why))
            }
            Err(store::Error::InstanceDedicated) => {
                w.rollback_to_savepoint("pipeline_step").await?;
                Ok(Err(format!(
                    "the agent for step {} now works only for a project",
                    step.key
                )))
            }
            Err(e) => Err(e),
        }
    }

    async fn create_step_run(
        &self,
        w: &mut Tx<Worker>,
        root: &RunRecord,
        title: &str,
        step: &PlanStep,
        deps: &[&RunRecord],
        rt: &InstanceRuntime,
    ) -> store::Result<Result<(), String>> {
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
        let locale = w.user_locale(root.user_id).await?;
        let prompt = handoff_prompt(locale, title, &root.run.prompt, step, deps, &artifacts);
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
        // 项目流水线不发通知（8.19 再做给创建者的回执）。
        if root.run.project_id.is_some() {
            info!(run = %root.run.id, state = %to, "project pipeline finished");
            return Ok(());
        }
        let plan = match root.run.plan_id {
            Some(p) => w.plan(p).await.ok(),
            None => None,
        };
        // 计划设了成功时不通知（7.1，事件触发的计划常这么设）：失败照样通知。
        if to == RunState::Succeeded && plan.as_ref().is_some_and(|p| !p.policy.notify_success) {
            info!(run = %root.run.id, state = %to, "pipeline finished (quietly)");
            return Ok(());
        }
        let title = plan.map(|p| p.title).unwrap_or_default();
        let (kind, body) = push;
        let title = if title.is_empty() {
            crate::texts::APP_NAME.to_owned()
        } else {
            title
        };
        let locale = w.user_locale(root.user_id).await?;
        let body = match kind {
            PushKind::RunFailed => crate::texts::task_failed(locale, &body),
            _ if body.is_empty() => crate::texts::pipeline_finished(locale).to_owned(),
            _ => body,
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

/// 一步的提示词：步骤本身的要求，加上交接说明（8.5），按用户的语言（1.6）。
pub fn handoff_prompt(
    locale: Locale,
    title: &str,
    goal: &str,
    step: &PlanStep,
    deps: &[&RunRecord],
    artifacts: &[store::StoredArtifact],
) -> String {
    let words = crate::texts::HandoffWords::new(locale);
    let mut out = step.prompt.trim().to_owned();
    out.push_str(&words.heading(title, &step.key));
    out.push_str(&words.goal(&truncate(goal, 1000)));
    if !deps.is_empty() {
        out.push_str(words.upstream());
        for d in deps {
            let key = d.run.step_key.as_deref().unwrap_or("?");
            let summary = d.run.summary.as_deref().map(|s| truncate(s, 600));
            out.push_str(&words.upstream_step(key, summary.as_deref()));
        }
    }
    if !artifacts.is_empty() {
        out.push_str(words.artifacts());
        for a in artifacts {
            out.push_str(&words.artifact(&a.artifact.name, a.artifact.version, a.artifact.size));
        }
    }
    out
}

/// 项目流水线一步的提示词（8.17）：和 [`handoff_prompt`] 一样，按这一步 botin 主人的语言；上游步骤的结果和产出物是别的
/// botin 写的，用 `boundary` 前后标出来，注明是信息不是指令。
pub fn project_handoff_prompt(
    locale: Locale,
    title: &str,
    goal: &str,
    step: &PlanStep,
    deps: &[&RunRecord],
    artifacts: &[store::StoredArtifact],
    boundary: &str,
) -> String {
    let words = crate::texts::HandoffWords::new(locale);
    let mut out = step.prompt.trim().to_owned();
    out.push_str(&words.heading(&crate::texts::label(title), &step.key));
    out.push_str(&words.goal(&truncate(goal, 1000)));
    if deps.is_empty() && artifacts.is_empty() {
        return out;
    }
    out.push_str(&words.untrusted(boundary));
    out.push_str(&format!("\n<<<{boundary}"));
    if !deps.is_empty() {
        out.push_str(words.upstream());
        for d in deps {
            let key = d.run.step_key.as_deref().unwrap_or("?");
            let summary = d.run.summary.as_deref().map(|s| truncate(s, 600));
            out.push_str(&words.upstream_step(key, summary.as_deref()));
        }
    }
    if !artifacts.is_empty() {
        out.push_str(words.artifacts());
        for a in artifacts {
            out.push_str(&words.artifact(&a.artifact.name, a.artifact.version, a.artifact.size));
        }
    }
    out.push_str(&format!("\n{boundary}>>>"));
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
        let (Some(key), Some(parent)) = (&rec.run.step_key, rec.run.parent_run_id) else {
            return Ok(0);
        };
        // 计划的流水线按计划的步骤；项目流水线（8.17）按它自己存的步骤。
        if rec.run.plan_id.is_none() && rec.run.project_id.is_none() {
            return Ok(0);
        }
        let Some(sid) = rt.sandbox_id.clone() else {
            return Err("the sandbox is not running".into());
        };
        let artifacts = async {
            let mut w = self.db.worker().await?;
            let steps = match rec.run.plan_id {
                Some(plan) => w.plan_steps(plan).await?,
                None => w
                    .project_pipeline(parent)
                    .await?
                    .map(|pl| pl.plan_steps())
                    .unwrap_or_default(),
            };
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
