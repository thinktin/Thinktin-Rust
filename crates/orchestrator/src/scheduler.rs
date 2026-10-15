//! 调度循环（WBS 7.2、7.6）：扫描到点的触发器，按补跑策略生成计划运行，推进下一次触发时间。
//!
//! - 多副本同时扫描：到点的触发器行用 SKIP LOCKED 锁住，各拿各的；即使重复，
//!   运行表上 (plan_id, fire_time) 的唯一约束也保证同一次触发只生成一个运行。
//! - 削峰：运行的最早开始时间 = 名义触发时间 + 确定性抖动（同一次触发在哪个副本算都一样）。
//! - 触发规则坏了（时区改名、规则不合法）：停掉这个触发器并记审计，不影响其他触发器。
//! - 积压：实例忙（一次只跑一个运行）时，计划已经有排队没开始的运行，新的触发并进去，不再建运行；
//!   补跑策略是“全部补”的最多攒 [`MAX_QUEUED_FIRES`] 个。账号冻结期间不调度，解冻后错过的触发按补跑策略处理。

use std::future::Future;
use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{CatchUp, RunSource, ScheduleSpec};
use serde_json::json;
use store::{Db, DueTrigger, NewRun, Tx, Worker};
use tracing::{debug, error, info, warn};

use crate::schedule::{Schedule, enforce_min_gap, jitter, plan_due};

/// 补跑策略是“全部补”的计划最多攒多少个排队的运行，再多的触发并进已有的运行。
pub const MAX_QUEUED_FIRES: u32 = 10;

#[derive(Debug, Clone)]
pub struct SchedulerConfig {
    /// 扫描间隔。
    pub tick: Duration,
    /// 每个事务处理多少个触发器。
    pub batch: i64,
    /// 削峰抖动上限。
    pub max_jitter: Duration,
    /// 计划运行的最多尝试次数。
    pub max_attempts: u32,
    /// 同一个触发器两次触发的最小间隔（兜底，和新建计划时的检查一致）。
    pub min_interval: Duration,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            tick: Duration::from_secs(5),
            batch: 100,
            max_jitter: Duration::from_secs(30),
            max_attempts: 3,
            min_interval: Duration::from_secs(5 * 60),
        }
    }
}

/// 一次扫描的结果。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TickReport {
    pub triggers: usize,
    pub runs_created: usize,
    /// 已经有运行的触发（别的副本先建了）。
    pub duplicates: usize,
    /// 计划已经有排队没开始的运行，并进去了的触发。
    pub coalesced: usize,
    /// 规则失效、被停掉的触发器。
    pub invalid: usize,
}

pub struct Scheduler {
    db: Db,
    cfg: SchedulerConfig,
}

impl Scheduler {
    pub fn new(db: Db, cfg: SchedulerConfig) -> Self {
        Self { db, cfg }
    }

    /// 处理所有名义触发时间不晚于 `now` 的触发器。
    pub async fn tick(&self, now: DateTime<Utc>) -> store::Result<TickReport> {
        let mut report = TickReport::default();
        loop {
            let mut w = self.db.worker().await?;
            let due = w.due_triggers(now, self.cfg.batch).await?;
            let n = due.len();
            for d in &due {
                self.fire(&mut w, d, now, &mut report).await?;
            }
            w.commit().await?;
            report.triggers += n;
            if (n as i64) < self.cfg.batch {
                return Ok(report);
            }
        }
    }

    async fn fire(
        &self,
        w: &mut Tx<Worker>,
        d: &DueTrigger,
        now: DateTime<Utc>,
        report: &mut TickReport,
    ) -> store::Result<()> {
        let t = &d.trigger;
        let Some(due) = t.next_fire_at else {
            return Ok(());
        };
        let schedule = match Schedule::parse(&t.spec) {
            Ok(s) => s,
            Err(e) => {
                warn!(trigger = %t.id, error = %e, "trigger spec is invalid, disabling it");
                w.advance_trigger(t.id, None, None).await?;
                w.audit(
                    Some(d.user_id),
                    "system",
                    "trigger.disabled",
                    Some(&t.id.to_string()),
                    &json!({ "reason": e.to_string() }),
                )
                .await?;
                report.invalid += 1;
                return Ok(());
            }
        };
        let mut plan = plan_due(&schedule, due, now, d.plan.catch_up);
        let throttled =
            enforce_min_gap(&mut plan, &schedule, t.last_fire_at, self.cfg.min_interval);
        if throttled > 0 {
            warn!(trigger = %t.id, throttled, "fires closer than the minimum interval were skipped");
        }
        // 带步骤的计划生成流水线运行（8.3），由流水线驱动给每一步建子运行。
        let pipeline = !w.plan_steps(d.plan.id).await?.is_empty();
        if plan.dropped > 0 {
            warn!(trigger = %t.id, dropped = plan.dropped, "too many missed fires, some were dropped");
        }
        let max_queued = match d.plan.catch_up {
            CatchUp::All => MAX_QUEUED_FIRES,
            CatchUp::Once | CatchUp::Skip => 1,
        };
        let mut queued = w.queued_plan_runs(d.plan.id).await?;
        for fire in &plan.fires {
            if queued >= max_queued {
                debug!(trigger = %t.id, plan = %d.plan.id, %fire, "plan already has a queued run, merging this fire into it");
                report.coalesced += 1;
                metrics::counter!("thinktin_scheduled_fires_coalesced_total").increment(1);
                continue;
            }
            let mut run = NewRun::new(
                d.plan.instance_id,
                RunSource::Plan,
                d.plan.goal.clone(),
                d.agent_version.clone(),
            );
            if pipeline {
                run.kind = proto::domain::RunKind::Pipeline;
            }
            run.plan_id = Some(d.plan.id);
            run.trigger_id = Some(t.id);
            run.fire_time = Some(*fire);
            run.run_grant_id = d.run_grant_id;
            run.budget = d.plan.policy.budget;
            run.max_attempts = self.cfg.max_attempts;
            let delay = jitter(t.id.0.as_bytes(), *fire, self.cfg.max_jitter);
            run.not_before = Some(*fire + chrono::Duration::from_std(delay).unwrap_or_default());
            match w.create_run(d.user_id, &run).await? {
                Some(r) => {
                    debug!(run = %r.id, plan = %d.plan.id, %fire, "plan run created");
                    queued += 1;
                    report.runs_created += 1;
                    metrics::counter!("thinktin_scheduled_runs_total").increment(1);
                }
                None => report.duplicates += 1,
            }
        }
        // 跳过补跑时没有生成运行，最后一次触发时间保持原样。
        w.advance_trigger(t.id, plan.fires.last().copied(), plan.next)
            .await?;
        // 长期运行的 RRULE：DTSTART 挪到最近一次触发，之后每次计算不用从很早以前数起。
        if let ScheduleSpec::Rrule { rule } = &t.spec
            && let Some(last) = plan.fires.last().copied().or(t.last_fire_at)
            && schedule.needs_rebase(last)
            && let Some(rule) = Schedule::rebased_rrule(rule, last)
        {
            debug!(trigger = %t.id, "moved the rule's DTSTART forward");
            w.set_trigger_spec(t.id, &ScheduleSpec::Rrule { rule })
                .await?;
        }
        Ok(())
    }

    /// 一直扫描，直到 `stop` 完成。单次扫描失败只记日志，下一轮再来。
    pub async fn run(&self, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let mut tick = tokio::time::interval(self.cfg.tick);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        info!("scheduler started");
        loop {
            tokio::select! {
                () = &mut stop => break,
                _ = tick.tick() => {
                    match self.tick(Utc::now()).await {
                        Ok(r) if r.runs_created > 0 || r.invalid > 0 => {
                            info!(runs = r.runs_created, invalid = r.invalid, "scheduler tick");
                        }
                        Ok(_) => {}
                        Err(e) => error!(error = %e, "scheduler tick failed"),
                    }
                }
            }
        }
        info!("scheduler stopped");
    }
}
