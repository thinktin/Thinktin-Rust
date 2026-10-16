//! 实例生命周期：用本地沙箱后端 + 真实 Postgres（没有 DATABASE_URL 时跳过）。

use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use control::{BuiltinTemplates, Error, Lifecycle, LifecycleConfig, Templates};
use proto::domain::{
    CatchUp, InstanceId, InstanceState, PlanAuthor, PlanPolicy, PlanStep, RunSource, ScheduleSpec,
    UserId,
};
use sandbox::local::LocalProvider;
use sandbox::{SandboxId, SandboxProvider, SandboxState};
use store::testing::TestDb;
use store::{NewPlan, NewRun};

struct Env {
    t: TestDb,
    dir: tempfile::TempDir,
    provider: Arc<LocalProvider>,
    user: UserId,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let dir = tempfile::tempdir().unwrap();
    let provider = Arc::new(LocalProvider::new(dir.path()).unwrap());
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    Some(Env {
        t,
        dir,
        provider,
        user: user.id,
    })
}

fn lifecycle(e: &Env, cfg: LifecycleConfig) -> Lifecycle {
    Lifecycle::new(
        e.t.db.clone(),
        e.provider.clone(),
        Arc::new(BuiltinTemplates),
        cfg,
    )
}

async fn sandbox_state(p: &LocalProvider, id: &str) -> Option<SandboxState> {
    p.get(&SandboxId(id.into())).await.unwrap().map(|i| i.state)
}

#[tokio::test]
async fn adopt_wake_pause_archive_and_rebuild() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, LifecycleConfig::default());

    assert!(matches!(
        lc.adopt(e.user, "user:d", "no-such-agent", None, "x").await,
        Err(Error::UnknownAgent(_))
    ));
    assert!(matches!(
        lc.adopt(e.user, "user:d", "claude", Some("nope"), "x")
            .await,
        Err(Error::Invalid(_))
    ));
    let inst = lc
        .adopt(e.user, "user:d", "claude", Some("cli"), "My Claude")
        .await
        .unwrap();
    assert_eq!(inst.state, InstanceState::Provisioning);
    assert_eq!(inst.harness, "cli");
    assert_eq!(
        inst.agent_version,
        catalog::builtin("claude").unwrap().agent.version
    );

    // 第一次唤醒：从模板建沙箱，挂上工作区卷。
    let rt = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(rt.state, InstanceState::Running);
    let sid = rt.sandbox_id.clone().unwrap();
    assert_eq!(
        sandbox_state(&e.provider, &sid).await,
        Some(SandboxState::Running)
    );
    assert!(rt.sandbox_address.is_some());
    let again = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(
        again.sandbox_id.as_deref(),
        Some(sid.as_str()),
        "idempotent"
    );

    // 暂停 → 唤醒：同一个沙箱。
    assert!(lc.pause(inst.id).await.unwrap());
    assert_eq!(
        sandbox_state(&e.provider, &sid).await,
        Some(SandboxState::Paused)
    );
    assert!(!lc.pause(inst.id).await.unwrap(), "already paused");
    let woke = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(woke.sandbox_id.as_deref(), Some(sid.as_str()));
    assert_eq!(
        sandbox_state(&e.provider, &sid).await,
        Some(SandboxState::Running)
    );

    // 归档：沙箱销毁，工作区卷留着；再唤醒从模板重建。
    e.provider
        .write_file(&SandboxId(sid.clone()), "workspace/notes.txt", b"keep me")
        .await
        .unwrap();
    assert!(lc.archive(inst.id).await.unwrap());
    assert_eq!(sandbox_state(&e.provider, &sid).await, None);
    let mut w = e.t.db.worker().await.unwrap();
    let archived = w.instance_runtime(inst.id).await.unwrap();
    w.rollback().await.unwrap();
    assert_eq!(archived.state, InstanceState::Archived);
    assert_eq!(archived.sandbox_id, None);
    let rebuilt = lc.ensure_running(inst.id).await.unwrap();
    let new_sid = rebuilt.sandbox_id.clone().unwrap();
    assert_ne!(new_sid, sid);
    assert_eq!(
        e.provider
            .read_file(&SandboxId(new_sid.clone()), "workspace/notes.txt", u64::MAX)
            .await
            .unwrap(),
        b"keep me",
        "workspace volume survives archiving"
    );

    // 重建：指定不存在的版本被拒绝；同版本重建换新沙箱。
    assert!(matches!(
        lc.rebuild(inst.id, Some("0.0.0-nope")).await,
        Err(Error::UnknownVersion { .. })
    ));
    let r = lc.rebuild(inst.id, None).await.unwrap();
    assert_ne!(r.sandbox_id.as_deref(), Some(new_sid.as_str()));
    assert_eq!(sandbox_state(&e.provider, &new_sid).await, None);

    // 每次状态变化都有实例事件。
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    let states: Vec<String> = t
        .events_after(inst.id, 0, 100)
        .await
        .unwrap()
        .into_iter()
        .filter(|ev| ev.kind == "instance.state")
        .map(|ev| ev.payload["state"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        states,
        [
            "provisioning",
            "running",
            "paused",
            "running",
            "archived",
            "running",
            "running"
        ]
    );
}

#[tokio::test]
async fn busy_instances_are_left_alone_and_lost_sandboxes_are_rebuilt() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, LifecycleConfig::default());
    let inst = lc
        .adopt(e.user, "user:d", "codex", None, "Codex")
        .await
        .unwrap();
    let rt = lc.ensure_running(inst.id).await.unwrap();

    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.create_run(&NewRun::new(
        inst.id,
        RunSource::User,
        "work",
        &inst.agent_version,
    ))
    .await
    .unwrap();
    t.commit().await.unwrap();
    let mut w = e.t.db.worker().await.unwrap();
    let run = w
        .claim_next_run("node-a", Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    assert!(!lc.pause(inst.id).await.unwrap());
    assert!(!lc.archive(inst.id).await.unwrap());
    assert!(matches!(lc.rebuild(inst.id, None).await, Err(Error::Busy)));
    let mut w = e.t.db.worker().await.unwrap();
    w.transition_run(
        run.run.id,
        "node-a",
        proto::domain::RunState::Failed,
        &Default::default(),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();

    // 沙箱在背后没了（宿主机故障）：唤醒时重建，不报错。
    let sid = rt.sandbox_id.unwrap();
    e.provider.destroy(&SandboxId(sid.clone())).await.unwrap();
    let healed = lc.ensure_running(inst.id).await.unwrap();
    assert_ne!(healed.sandbox_id.as_deref(), Some(sid.as_str()));
    // 本地后端重启（内存里的登记全丢）：同样重建。
    let restarted = Arc::new(LocalProvider::new(e.dir.path()).unwrap());
    let lc2 = Lifecycle::new(
        e.t.db.clone(),
        restarted.clone(),
        Arc::new(BuiltinTemplates),
        LifecycleConfig::default(),
    );
    let healed2 = lc2.ensure_running(inst.id).await.unwrap();
    assert_ne!(healed2.sandbox_id, healed.sandbox_id);
    // 暂停时发现沙箱没了：当作归档。
    let lc3 = Lifecycle::new(
        e.t.db.clone(),
        Arc::new(LocalProvider::new(e.dir.path()).unwrap()),
        Arc::new(BuiltinTemplates),
        LifecycleConfig::default(),
    );
    assert!(lc3.pause(inst.id).await.unwrap());
    let mut w = e.t.db.worker().await.unwrap();
    assert_eq!(
        w.instance_runtime(inst.id).await.unwrap().state,
        InstanceState::Archived
    );
}

#[tokio::test]
async fn sweep_pauses_archives_and_purges() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            idle_pause: Duration::ZERO,
            archive_after: Duration::ZERO,
            ..LifecycleConfig::default()
        },
    );
    let idle = lc
        .adopt(e.user, "user:d", "claude", None, "idle")
        .await
        .unwrap();
    let scheduled = lc
        .adopt(e.user, "user:d", "claude", None, "scheduled")
        .await
        .unwrap();
    lc.ensure_running(idle.id).await.unwrap();
    lc.ensure_running(scheduled.id).await.unwrap();
    // 一小时后有计划要触发的实例不归档（到点还得重建，太慢）。
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    let plan = t
        .create_plan(&NewPlan {
            instance_id: scheduled.id,
            title: "hourly".into(),
            goal: "check".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    t.add_trigger(
        plan.id,
        &ScheduleSpec::Cron {
            expr: "0 * * * *".into(),
            tz: "UTC".into(),
        },
        Some(Utc::now() + chrono::Duration::hours(1)),
    )
    .await
    .unwrap();
    t.commit().await.unwrap();

    let report = lc.sweep().await.unwrap();
    assert_eq!((report.paused, report.archived, report.failed), (2, 1, 0));
    let mut w = e.t.db.worker().await.unwrap();
    assert_eq!(
        w.instance_runtime(idle.id).await.unwrap().state,
        InstanceState::Archived
    );
    assert_eq!(
        w.instance_runtime(scheduled.id).await.unwrap().state,
        InstanceState::Paused
    );
    w.rollback().await.unwrap();

    // 删除后回收沙箱和工作区卷，只回收一次。
    let rt = lc.ensure_running(scheduled.id).await.unwrap();
    let volume = e.dir.path().join("volumes").join(&rt.workspace_id);
    assert!(volume.exists());
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.delete_instance(scheduled.id).await.unwrap();
    t.commit().await.unwrap();
    assert!(matches!(
        lc.ensure_running(scheduled.id).await,
        Err(Error::Deleted)
    ));
    let report = lc.sweep().await.unwrap();
    assert_eq!(report.purged, 1);
    assert!(!volume.exists());
    assert_eq!(
        sandbox_state(&e.provider, rt.sandbox_id.as_deref().unwrap()).await,
        None
    );
    assert_eq!(lc.sweep().await.unwrap().purged, 0);
}

/// 升级、回滚（6.7）：换了版本的实例下次唤醒时按新版本重建沙箱，工作区保留。
#[tokio::test]
async fn version_changes_rebuild_on_the_next_wake() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, LifecycleConfig::default());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let rt = lc.ensure_running(inst.id).await.unwrap();
    let old = rt.sandbox_id.clone().unwrap();
    e.provider
        .write_file(&SandboxId(old.clone()), "workspace/notes.md", b"keep me")
        .await
        .unwrap();
    // 没换版本时唤醒不重建。
    assert_eq!(
        lc.ensure_running(inst.id).await.unwrap().sandbox_id,
        Some(old.clone())
    );

    // 不存在的版本：拒绝重建，旧沙箱不动。
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.request_instance_version(inst.id, "0.0.0-missing")
        .await
        .unwrap();
    t.commit().await.unwrap();
    assert!(matches!(
        lc.ensure_running(inst.id).await,
        Err(Error::UnknownVersion { .. })
    ));
    assert_eq!(
        sandbox_state(&e.provider, &old).await,
        Some(SandboxState::Running)
    );

    let current = catalog::builtin("pi").unwrap().agent.version;
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    let i = t.request_instance_version(inst.id, &current).await.unwrap();
    assert_eq!(i.agent_version, current);
    t.commit().await.unwrap();
    let rt = lc.ensure_running(inst.id).await.unwrap();
    let new = rt.sandbox_id.clone().unwrap();
    assert_ne!(new, old, "a fresh sandbox from the template");
    assert!(!rt.rebuild_pending);
    assert_eq!(
        sandbox_state(&e.provider, &old).await,
        None,
        "old one destroyed"
    );
    let kept = e
        .provider
        .read_file(&SandboxId(new.clone()), "workspace/notes.md", u64::MAX)
        .await
        .unwrap();
    assert_eq!(kept, b"keep me", "the workspace volume survives");
    // 之后照常唤醒，不再重建。
    assert_eq!(
        lc.ensure_running(inst.id).await.unwrap().sandbox_id,
        Some(new)
    );
}

/// 预热（6.5）：计划快到点时，它要用的、暂停着的实例提前唤醒；还早的不动。
#[tokio::test]
async fn instances_wake_up_shortly_before_their_plans_fire() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            prewarm_lead: Duration::from_secs(120),
            ..LifecycleConfig::default()
        },
    );
    let mut ids = Vec::new();
    for name in ["soon", "step", "later"] {
        let i = lc
            .adopt(e.user, "user:d", "claude", None, name)
            .await
            .unwrap();
        lc.ensure_running(i.id).await.unwrap();
        assert!(lc.pause(i.id).await.unwrap());
        ids.push(i.id);
    }
    let (soon, step, later) = (ids[0], ids[1], ids[2]);
    let plan = |instance: InstanceId| NewPlan {
        instance_id: instance,
        title: "p".into(),
        goal: "g".into(),
        policy: PlanPolicy::default(),
        catch_up: CatchUp::Once,
        created_by: PlanAuthor::User,
        run_grant_id: None,
    };
    let hourly = ScheduleSpec::Cron {
        expr: "0 * * * *".into(),
        tz: "UTC".into(),
    };
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    // 一分钟后触发的流水线：计划自己的实例和第一步的实例都要预热。
    let p1 = t.create_plan(&plan(soon)).await.unwrap();
    t.add_trigger(
        p1.id,
        &hourly,
        Some(Utc::now() + chrono::Duration::seconds(60)),
    )
    .await
    .unwrap();
    t.set_plan_steps(
        p1.id,
        &[PlanStep {
            key: "first".into(),
            instance_id: step,
            prompt: "collect".into(),
            depends_on: Vec::new(),
        }],
    )
    .await
    .unwrap();
    // 一小时后才触发的不动。
    let p2 = t.create_plan(&plan(later)).await.unwrap();
    t.add_trigger(
        p2.id,
        &hourly,
        Some(Utc::now() + chrono::Duration::hours(1)),
    )
    .await
    .unwrap();
    t.commit().await.unwrap();

    let report = lc.sweep().await.unwrap();
    assert_eq!((report.prewarmed, report.paused, report.failed), (2, 0, 0));
    let mut w = e.t.db.worker().await.unwrap();
    for (id, want) in [
        (soon, InstanceState::Running),
        (step, InstanceState::Running),
        (later, InstanceState::Paused),
    ] {
        assert_eq!(w.instance_runtime(id).await.unwrap().state, want);
    }
    w.rollback().await.unwrap();
    // 已经醒着的不重复唤醒。
    assert_eq!(lc.sweep().await.unwrap().prewarmed, 0);
}

/// 内置清单，再加上一份下架名单（15.5）。
struct Withdrawing(Vec<(&'static str, String)>);

impl Templates for Withdrawing {
    fn current(&self, agent_id: &str) -> Option<catalog::Manifest> {
        BuiltinTemplates.current(agent_id)
    }
    fn manifest(&self, agent_id: &str, version: &str) -> Option<catalog::Manifest> {
        if self.withdrawn(agent_id, version).is_some() {
            return None;
        }
        BuiltinTemplates.manifest(agent_id, version)
    }
    fn withdrawn(&self, agent_id: &str, version: &str) -> Option<String> {
        self.0
            .iter()
            .any(|(a, v)| *a == agent_id && v == version)
            .then(|| "TT-2026-001".to_string())
    }
}

#[tokio::test]
async fn instances_on_a_withdrawn_version_move_to_the_current_one() {
    let Some(e) = env().await else { return };
    let pi = catalog::builtin("pi").unwrap();
    let current = pi.agent.version.clone();
    let lc = Lifecycle::new(
        e.t.db.clone(),
        e.provider.clone(),
        Arc::new(Withdrawing(vec![("pi", "0.0.1-old".into())])),
        LifecycleConfig::default(),
    );
    // 一个锁在有漏洞的旧版本上的实例。
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    let inst = t
        .create_instance(&store::NewInstance {
            agent_id: "pi".into(),
            agent_version: "0.0.1-old".into(),
            harness: pi.default_harness().id.clone(),
            name: "Pi".into(),
            workspace_id: "ws-old-pi".into(),
            limits: Default::default(),
        })
        .await
        .unwrap();
    t.commit().await.unwrap();

    // 唤醒时换到当前版本、按它建沙箱，并记审计。
    let rt = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(rt.agent_version, current);
    assert!(!rt.rebuild_pending);
    assert!(rt.sandbox_id.is_some());
    let mut w = e.t.db.worker().await.unwrap();
    assert_eq!(
        w.instance_runtime(inst.id).await.unwrap().agent_version,
        current
    );
    w.rollback().await.unwrap();
    let detail: serde_json::Value = sqlx::query_scalar(
        "SELECT detail FROM audit_log WHERE action = 'instance.version.withdrawn' AND target = $1",
    )
    .bind(inst.id.to_string())
    .fetch_one(e.t.db.pool())
    .await
    .unwrap();
    assert_eq!(detail["from"], "0.0.1-old");
    assert_eq!(detail["to"], current.as_str());
    assert_eq!(detail["advisory"], "TT-2026-001");

    // 当前版本也下架了：不能领养，已有的实例不再启动，沙箱不动。
    let lc = Lifecycle::new(
        e.t.db.clone(),
        e.provider.clone(),
        Arc::new(Withdrawing(vec![("pi", current.clone())])),
        LifecycleConfig::default(),
    );
    assert!(matches!(
        lc.adopt(e.user, "user:d", "pi", None, "Pi 2").await,
        Err(Error::Withdrawn { .. })
    ));
    assert!(matches!(
        lc.ensure_running(inst.id).await,
        Err(Error::Withdrawn { .. })
    ));
    let sid = rt.sandbox_id.unwrap();
    assert_eq!(
        sandbox_state(&e.provider, &sid).await,
        Some(SandboxState::Running)
    );
}
