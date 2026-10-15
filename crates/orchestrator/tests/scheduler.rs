//! 调度循环：到点生成运行、补跑策略、重复扫描、坏规则。需要 DATABASE_URL（没有时跳过）。

use chrono::{DateTime, Duration, Utc};
use orchestrator::scheduler::{Scheduler, SchedulerConfig};
use proto::domain::{
    CatchUp, InstanceId, InstanceLimits, PlanAuthor, PlanId, PlanPolicy, RunSource, RunState,
    ScheduleSpec, TriggerId, UserId, UserStatus,
};
use store::testing::TestDb;
use store::{NewInstance, NewPlan};

fn at(s: &str) -> DateTime<Utc> {
    s.parse().unwrap()
}

struct Fixture {
    t: TestDb,
    user: UserId,
    instance: InstanceId,
}

async fn fixture() -> Option<Fixture> {
    let t = TestDb::new().await?;
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1.2.3".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "ws".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    tx.commit().await.unwrap();
    Some(Fixture {
        t,
        user: user.id,
        instance: inst.id,
    })
}

async fn plan_with_trigger(
    f: &Fixture,
    catch_up: CatchUp,
    spec: ScheduleSpec,
    next: DateTime<Utc>,
) -> (PlanId, TriggerId) {
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: f.instance,
            title: "news".into(),
            goal: "summarize the news".into(),
            policy: PlanPolicy::default(),
            catch_up,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    let trig = tx.add_trigger(plan.id, &spec, Some(next)).await.unwrap();
    tx.commit().await.unwrap();
    (plan.id, trig.id)
}

fn daily_8am_shanghai() -> ScheduleSpec {
    ScheduleSpec::Cron {
        expr: "0 8 * * *".into(),
        tz: "Asia/Shanghai".into(),
    }
}

fn scheduler(f: &Fixture) -> Scheduler {
    Scheduler::new(f.t.db.clone(), SchedulerConfig::default())
}

#[tokio::test]
async fn on_time_fire_creates_one_run_with_jitter() {
    let Some(f) = fixture().await else { return };
    // 北京时间 8 点 = UTC 0 点。
    let due = at("2026-10-14T00:00:00Z");
    let (plan, trig) = plan_with_trigger(&f, CatchUp::Once, daily_8am_shanghai(), due).await;
    let s = scheduler(&f);
    let report = s.tick(at("2026-10-13T23:59:59Z")).await.unwrap();
    assert_eq!(report.triggers, 0, "not due yet");

    let report = s.tick(at("2026-10-14T00:00:01Z")).await.unwrap();
    assert_eq!((report.triggers, report.runs_created), (1, 1));
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    let runs = tx.runs(f.instance, None, 10).await.unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].plan_id, Some(plan));
    assert_eq!(runs[0].source, RunSource::Plan);
    assert_eq!(runs[0].state, RunState::Queued);
    assert_eq!(runs[0].prompt, "summarize the news");
    let trig_now = &tx.triggers(plan).await.unwrap()[0];
    assert_eq!(trig_now.id, trig);
    assert_eq!(trig_now.last_fire_at, Some(due));
    assert_eq!(trig_now.next_fire_at, Some(at("2026-10-15T00:00:00Z")));
    tx.rollback().await.unwrap();
    let mut w = f.t.db.worker().await.unwrap();
    let rec = w.run_record(runs[0].id).await.unwrap();
    assert_eq!(rec.fire_time, Some(due));
    assert_eq!(rec.agent_version, "1.2.3");
    assert!(rec.not_before >= due && rec.not_before < due + Duration::seconds(30));
    w.rollback().await.unwrap();

    // 别的副本拿着旧的“下一次”又扫了一遍：唯一约束挡住，不会重复生成。
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    tx.set_trigger_enabled(trig, true, Some(due)).await.unwrap();
    tx.commit().await.unwrap();
    // （这次的运行还在排队，所以是并进去的；不在排队时由唯一约束挡住。）
    let report = s.tick(at("2026-10-14T00:00:02Z")).await.unwrap();
    assert_eq!(
        (report.runs_created, report.duplicates + report.coalesced),
        (0, 1)
    );
}

#[tokio::test]
async fn catch_up_policies() {
    let Some(f) = fixture().await else { return };
    // 停机三天：错过 11、12、13、14 号四次。
    let due = at("2026-10-11T00:00:00Z");
    let now = at("2026-10-14T03:00:00Z");
    let (once, _) = plan_with_trigger(&f, CatchUp::Once, daily_8am_shanghai(), due).await;
    let (all, _) = plan_with_trigger(&f, CatchUp::All, daily_8am_shanghai(), due).await;
    let (skip, _) = plan_with_trigger(&f, CatchUp::Skip, daily_8am_shanghai(), due).await;
    let report = scheduler(&f).tick(now).await.unwrap();
    assert_eq!((report.triggers, report.runs_created), (3, 1 + 4));

    let mut w = f.t.db.worker().await.unwrap();
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    let runs = tx.runs(f.instance, None, 100).await.unwrap();
    let fires = |plan| {
        let mut v: Vec<_> = runs
            .iter()
            .filter(|r| r.plan_id == Some(plan))
            .map(|r| r.id)
            .collect();
        v.sort();
        v
    };
    let once_runs = fires(once);
    assert_eq!(once_runs.len(), 1);
    assert_eq!(
        w.run_record(once_runs[0]).await.unwrap().fire_time,
        Some(at("2026-10-14T00:00:00Z")),
        "only the latest missed fire"
    );
    assert_eq!(fires(all).len(), 4);
    assert!(fires(skip).is_empty());
    for plan in [once, all, skip] {
        let t = &tx.triggers(plan).await.unwrap()[0];
        assert_eq!(t.next_fire_at, Some(at("2026-10-15T00:00:00Z")));
    }
    let skipped = &tx.triggers(skip).await.unwrap()[0];
    assert_eq!(skipped.last_fire_at, None, "nothing ran");
}

#[tokio::test]
async fn one_shot_and_broken_triggers() {
    let Some(f) = fixture().await else { return };
    let when = at("2026-10-14T09:30:00Z");
    let (once, _) =
        plan_with_trigger(&f, CatchUp::Once, ScheduleSpec::Once { at: when }, when).await;
    let (broken, _) = plan_with_trigger(
        &f,
        CatchUp::Once,
        ScheduleSpec::Cron {
            expr: "0 8 * * *".into(),
            tz: "Mars/Olympus_Mons".into(),
        },
        when,
    )
    .await;
    let s = scheduler(&f);
    let report = s.tick(when + Duration::seconds(1)).await.unwrap();
    assert_eq!((report.runs_created, report.invalid), (1, 1));
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    assert_eq!(tx.triggers(once).await.unwrap()[0].next_fire_at, None);
    assert_eq!(tx.triggers(broken).await.unwrap()[0].next_fire_at, None);
    tx.rollback().await.unwrap();
    // 之后不再触发。
    let report = s.tick(when + Duration::days(2)).await.unwrap();
    assert_eq!(report.triggers, 0);
    // 暂停的计划不生成运行。
    let (paused, _) = plan_with_trigger(&f, CatchUp::Once, daily_8am_shanghai(), when).await;
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    tx.set_plan_paused(paused, true).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(s.tick(when + Duration::days(3)).await.unwrap().triggers, 0);
}

/// 长期运行的 RRULE：调度时把 DTSTART 挪到最近一次触发，之后每次计算都快，触发时间不变。
#[tokio::test]
async fn long_running_rrules_get_their_start_moved_forward() {
    let Some(f) = fixture().await else { return };
    let due = at("2026-10-14T00:00:00Z"); // 上海早上 8 点
    let spec = ScheduleSpec::Rrule {
        rule: "DTSTART;TZID=Asia/Shanghai:20260901T080000\nRRULE:FREQ=DAILY".into(),
    };
    let (plan, _) = plan_with_trigger(&f, CatchUp::Once, spec, due).await;
    let report = scheduler(&f)
        .tick(at("2026-10-14T00:00:01Z"))
        .await
        .unwrap();
    assert_eq!(report.runs_created, 1);
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    let trig = &tx.triggers(plan).await.unwrap()[0];
    let ScheduleSpec::Rrule { rule } = &trig.spec else {
        panic!("still an rrule")
    };
    assert!(
        rule.starts_with("DTSTART;TZID=Asia/Shanghai:20261014T080000"),
        "{rule}"
    );
    assert_eq!(trig.next_fire_at, Some(at("2026-10-15T00:00:00Z")));
    tx.rollback().await.unwrap();
}

fn queued_runs(runs: &[proto::domain::Run], plan: PlanId) -> Vec<proto::domain::Run> {
    runs.iter()
        .filter(|r| r.plan_id == Some(plan) && r.state == RunState::Queued)
        .cloned()
        .collect()
}

/// 实例一直忙、计划的运行没被领走：新的触发并进排队的运行，不会攒出一长串
/// （“全部补”的最多攒 MAX_QUEUED_FIRES 个）。
#[tokio::test]
async fn fires_merge_into_a_queued_run_while_the_instance_is_busy() {
    let Some(f) = fixture().await else { return };
    let every_5 = ScheduleSpec::Cron {
        expr: "*/5 * * * *".into(),
        tz: "UTC".into(),
    };
    let t0 = at("2026-10-14T00:00:00Z");
    let (once, _) = plan_with_trigger(&f, CatchUp::Once, every_5.clone(), t0).await;
    let (all, _) = plan_with_trigger(&f, CatchUp::All, every_5, t0).await;
    let s = scheduler(&f);
    let mut coalesced = 0;
    for i in 0..24 {
        let report = s
            .tick(t0 + Duration::minutes(5 * i) + Duration::seconds(1))
            .await
            .unwrap();
        assert_eq!(report.triggers, 2);
        coalesced += report.coalesced;
    }
    let max = orchestrator::scheduler::MAX_QUEUED_FIRES as usize;
    assert_eq!(coalesced, 23 + (24 - max));
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    let runs = tx.runs(f.instance, None, 100).await.unwrap();
    let pending = queued_runs(&runs, once);
    assert_eq!(pending.len(), 1);
    assert_eq!(queued_runs(&runs, all).len(), max);
    // 排队的运行处理掉之后，下一次触发照常建运行。
    tx.cancel_run(pending[0].id, None).await.unwrap();
    tx.commit().await.unwrap();
    let report = s
        .tick(t0 + Duration::minutes(5 * 24) + Duration::seconds(1))
        .await
        .unwrap();
    assert_eq!((report.runs_created, report.coalesced), (1, 1));
}

/// 冻结的账号不调度；解冻后错过的触发按补跑策略处理。
#[tokio::test]
async fn frozen_accounts_are_not_scheduled_and_catch_up_when_unfrozen() {
    let Some(f) = fixture().await else { return };
    let due = at("2026-10-11T00:00:00Z");
    let (plan, _) = plan_with_trigger(&f, CatchUp::Once, daily_8am_shanghai(), due).await;
    let mut w = f.t.db.worker().await.unwrap();
    w.set_user_status(f.user, UserStatus::Frozen).await.unwrap();
    w.commit().await.unwrap();
    let s = scheduler(&f);
    assert_eq!(s.tick(due + Duration::hours(1)).await.unwrap().triggers, 0);
    assert_eq!(
        s.tick(at("2026-10-14T03:00:00Z")).await.unwrap().triggers,
        0
    );

    let mut w = f.t.db.worker().await.unwrap();
    w.set_user_status(f.user, UserStatus::Active).await.unwrap();
    w.commit().await.unwrap();
    let report = s.tick(at("2026-10-14T03:00:00Z")).await.unwrap();
    assert_eq!(report.runs_created, 1);
    let mut tx = f.t.db.tenant(f.user).await.unwrap();
    let runs = tx.runs(f.instance, None, 100).await.unwrap();
    let pending = queued_runs(&runs, plan);
    assert_eq!(pending.len(), 1);
    tx.rollback().await.unwrap();
    let mut w = f.t.db.worker().await.unwrap();
    assert_eq!(
        w.run_record(pending[0].id).await.unwrap().fire_time,
        Some(at("2026-10-14T00:00:00Z")),
        "only the latest missed fire"
    );
}
