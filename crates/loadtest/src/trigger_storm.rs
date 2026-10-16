//! 整点触发洪峰：`triggers` 个计划在同一个整点到点，`replicas` 个调度器副本同时扫描。
//!
//! 核对：每个触发正好生成一个运行（多副本靠 SKIP LOCKED 分头处理，唯一约束兜底），扫完后没有剩下到点的触发器，
//! 运行的最早开始时间都落在 [触发时间, 触发时间 + 抖动上限) 里。报告每秒能处理多少个触发，以及抖动之后
//! 每秒最多有多少个运行可以开始（执行器要扛住的峰值）。

use std::time::{Duration, Instant};

use anyhow::{Context, ensure};
use chrono::{DateTime, Timelike, Utc};
use futures_util::{StreamExt, TryStreamExt};
use orchestrator::scheduler::{Scheduler, SchedulerConfig};
use proto::domain::{CatchUp, InstanceLimits, PlanAuthor, PlanPolicy, ScheduleSpec, UserId};
use serde::Serialize;
use store::{Db, NewInstance, NewPlan};

use crate::stats::rate;

#[derive(Debug, Clone)]
pub struct Config {
    /// 同一时刻到点的触发器数（每个触发器一个计划、一个实例）。
    pub triggers: usize,
    /// 这些实例分给多少个用户。
    pub users: usize,
    /// 同时扫描的调度器副本数。
    pub replicas: usize,
    /// 每个事务处理多少个触发器。
    pub batch: i64,
    /// 削峰抖动上限。
    pub max_jitter: Duration,
    /// 造数据时的并发事务数。
    pub seed_concurrency: usize,
}

impl Default for Config {
    fn default() -> Self {
        let sched = SchedulerConfig::default();
        Self {
            triggers: 10_000,
            users: 1_000,
            replicas: 4,
            batch: sched.batch,
            max_jitter: sched.max_jitter,
            seed_concurrency: 16,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Replica {
    pub triggers: usize,
    pub runs_created: usize,
    pub duplicates: usize,
    pub coalesced: usize,
    pub invalid: usize,
    pub elapsed_ms: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub triggers: usize,
    pub users: usize,
    pub replicas: usize,
    pub batch: i64,
    pub seed_secs: f64,
    /// 从所有副本开始扫描到最后一个副本扫完。
    pub fire_ms: f64,
    pub triggers_per_sec: f64,
    pub per_replica: Vec<Replica>,
    /// 库里这次触发的运行数，以及其中不同计划的个数（两者都应等于 `triggers`）。
    pub runs: i64,
    pub distinct_plans: i64,
    /// 各副本合计。
    pub duplicates: usize,
    pub coalesced: usize,
    /// 扫完后再扫一遍还到点的触发器（应为 0）。
    pub leftover: usize,
    /// 运行的最早开始时间相对触发时间的偏移（毫秒）。
    pub jitter_min_ms: f64,
    pub jitter_max_ms: f64,
    /// 抖动后每秒可以开始的运行数：平均和最忙的那一秒。
    pub start_mean_per_sec: f64,
    pub start_peak_per_sec: i64,
}

/// 名义触发时间：当前这个整点。
fn top_of_hour(now: DateTime<Utc>) -> DateTime<Utc> {
    now.with_nanosecond(0)
        .and_then(|t| t.with_second(0))
        .and_then(|t| t.with_minute(0))
        .unwrap_or(now)
}

async fn seed_one(db: &Db, user: UserId, i: usize, due: DateTime<Utc>) -> anyhow::Result<()> {
    let spec = ScheduleSpec::Cron {
        expr: "0 * * * *".into(),
        tz: "UTC".into(),
    };
    let mut tx = db.tenant(user).await?;
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "loadtest".into(),
            harness: "acp".into(),
            name: format!("storm-{i}"),
            workspace_id: format!("ws-storm-{i}"),
            limits: InstanceLimits::default(),
        })
        .await?;
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: inst.id,
            title: format!("hourly {i}"),
            goal: "hourly report".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await?;
    tx.add_trigger(plan.id, &spec, Some(due)).await?;
    tx.commit().await?;
    Ok(())
}

/// 造数据：用户、实例、计划、到点的触发器。返回名义触发时间。
pub async fn seed(db: &Db, cfg: &Config) -> anyhow::Result<DateTime<Utc>> {
    ensure!(
        cfg.triggers > 0 && cfg.users > 0,
        "need at least one trigger and one user"
    );
    let due = top_of_hour(Utc::now());
    let mut users = Vec::with_capacity(cfg.users);
    let mut w = db.worker().await?;
    for u in 0..cfg.users {
        let (user, _) = w.upsert_user_by_phone(&format!("+86139{u:08}")).await?;
        users.push(user.id);
    }
    w.commit().await?;
    futures_util::stream::iter(0..cfg.triggers)
        .map(|i| seed_one(db, users[i % users.len()], i, due))
        .buffer_unordered(cfg.seed_concurrency.max(1))
        .try_collect::<Vec<()>>()
        .await
        .context("seed triggers")?;
    Ok(due)
}

pub async fn run(db: &Db, cfg: &Config) -> anyhow::Result<Report> {
    let seed_start = Instant::now();
    let due = seed(db, cfg).await?;
    let seed_secs = seed_start.elapsed().as_secs_f64();

    let sched_cfg = SchedulerConfig {
        batch: cfg.batch.max(1),
        max_jitter: cfg.max_jitter,
        ..SchedulerConfig::default()
    };
    // 各副本拿同一个“现在”：整点过一秒。
    let now = due + chrono::Duration::seconds(1);
    let start = Instant::now();
    let mut tasks = Vec::with_capacity(cfg.replicas.max(1));
    for _ in 0..cfg.replicas.max(1) {
        let s = Scheduler::new(db.clone(), sched_cfg.clone());
        tasks.push(tokio::spawn(async move {
            let t = Instant::now();
            let r = s.tick(now).await;
            (r, t.elapsed())
        }));
    }
    let mut per_replica = Vec::with_capacity(tasks.len());
    for task in tasks {
        let (r, elapsed) = task.await.context("scheduler replica panicked")?;
        let r = r.context("scheduler tick")?;
        per_replica.push(Replica {
            triggers: r.triggers,
            runs_created: r.runs_created,
            duplicates: r.duplicates,
            coalesced: r.coalesced,
            invalid: r.invalid,
            elapsed_ms: elapsed.as_secs_f64() * 1000.0,
        });
    }
    let fire = start.elapsed();
    let leftover = Scheduler::new(db.clone(), sched_cfg)
        .tick(now)
        .await?
        .triggers;

    let (runs, distinct_plans, jitter_min_ms, jitter_max_ms): (i64, i64, Option<f64>, Option<f64>) =
        sqlx::query_as(
            "SELECT count(*), count(DISTINCT plan_id), \
               min(EXTRACT(EPOCH FROM (not_before - fire_time)) * 1000)::float8, \
               max(EXTRACT(EPOCH FROM (not_before - fire_time)) * 1000)::float8 \
             FROM runs WHERE fire_time = $1",
        )
        .bind(due)
        .fetch_one(db.pool())
        .await?;
    let per_sec: Vec<(i64, i64)> = sqlx::query_as(
        "SELECT floor(EXTRACT(EPOCH FROM (not_before - fire_time)))::int8 AS s, count(*) \
         FROM runs WHERE fire_time = $1 GROUP BY 1 ORDER BY 1",
    )
    .bind(due)
    .fetch_all(db.pool())
    .await?;
    let start_peak_per_sec = per_sec.iter().map(|(_, n)| *n).max().unwrap_or(0);
    let jitter_secs = cfg.max_jitter.as_secs_f64().max(1.0);

    Ok(Report {
        triggers: cfg.triggers,
        users: cfg.users,
        replicas: per_replica.len(),
        batch: cfg.batch,
        seed_secs,
        fire_ms: fire.as_secs_f64() * 1000.0,
        triggers_per_sec: rate(cfg.triggers, fire),
        duplicates: per_replica.iter().map(|r| r.duplicates).sum(),
        coalesced: per_replica.iter().map(|r| r.coalesced).sum(),
        per_replica,
        runs,
        distinct_plans,
        leftover,
        jitter_min_ms: jitter_min_ms.unwrap_or(0.0),
        jitter_max_ms: jitter_max_ms.unwrap_or(0.0),
        start_mean_per_sec: runs as f64 / jitter_secs,
        start_peak_per_sec,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn top_of_hour_truncates() {
        let t: DateTime<Utc> = "2026-10-16T14:41:28.123Z".parse().unwrap();
        assert_eq!(
            top_of_hour(t),
            "2026-10-16T14:00:00Z".parse::<DateTime<Utc>>().unwrap()
        );
    }
}
