//! 需要真实 Postgres 的测试：没设置 DATABASE_URL 时跳过（见 testing.rs）。

use std::time::Duration;

use chrono::{Datelike, Duration as Days, NaiveDate, Utc};
use proto::domain::{
    CatchUp, Instance, InstanceLimits, ModelRoute, PlanAuthor, PlanPolicy, RunSource, RunState,
    ScheduleSpec, UserId, UserStatus,
};
use serde_json::json;

use crate::testing::TestDb;
use crate::{
    Db, Error, NewCredential, NewInboxItem, NewInstance, NewOutboxItem, NewPlan, NewRun, NewUsage,
    RunChange,
};

const LEASE: Duration = Duration::from_secs(60);

async fn user(db: &Db, phone: &str) -> UserId {
    let mut w = db.worker().await.unwrap();
    let (u, created) = w.upsert_user_by_phone(phone).await.unwrap();
    assert!(created);
    w.commit().await.unwrap();
    u.id
}

async fn instance(db: &Db, user: UserId) -> Instance {
    let mut t = db.tenant(user).await.unwrap();
    let i = t
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "vol-1".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    t.commit().await.unwrap();
    i
}

fn credential(last4: &str) -> NewCredential {
    NewCredential {
        id: proto::domain::CredentialId::new(),
        vendor: "anthropic".into(),
        label: "work".into(),
        anthropic_base: None,
        openai_base: None,
        responses_base: None,
        sealed: vec![1, 2, 3, 4],
        last4: last4.into(),
        daily_token_limit: Some(1_000_000),
    }
}

async fn queue_run(db: &Db, user: UserId, instance: &Instance, prompt: &str) -> proto::domain::Run {
    let mut t = db.tenant(user).await.unwrap();
    let r = t
        .create_run(&NewRun::new(instance.id, RunSource::User, prompt, "1"))
        .await
        .unwrap();
    t.commit().await.unwrap();
    r
}

#[test]
fn sql_terminal_states_match_domain() {
    // runs.rs 的 SQL 里直接写了结束状态。
    let terminal: Vec<_> = RunState::ALL
        .iter()
        .filter(|s| s.is_terminal())
        .map(|s| s.as_str())
        .collect();
    assert_eq!(terminal, ["succeeded", "failed", "cancelled"]);
    let src = include_str!("runs.rs");
    assert!(src.contains("('succeeded', 'failed', 'cancelled')"));
    let holding: Vec<_> = RunState::ALL
        .iter()
        .filter(|s| s.holds_instance())
        .map(|s| format!("'{}'", s.as_str()))
        .collect();
    let migration = include_str!("../migrations/0001_init.sql");
    for s in &holding {
        assert!(src.contains(s.as_str()), "claim query lists {s}");
        assert!(migration.contains(s.as_str()), "unique index lists {s}");
    }
}

#[tokio::test]
async fn tenants_are_isolated() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let inst = instance(db, alice).await;

    let mut a = db.tenant(alice).await.unwrap();
    let cred = a.create_credential(&credential("abcd")).await.unwrap();
    a.set_model_routes(
        inst.id,
        &[ModelRoute {
            alias: "main".into(),
            credential_id: cred.id,
            upstream_model: "claude-sonnet".into(),
            fallbacks: vec![],
        }],
    )
    .await
    .unwrap();
    assert_eq!(a.me().await.unwrap().id, alice);
    a.commit().await.unwrap();

    let mut b = db.tenant(bob).await.unwrap();
    assert!(matches!(b.instance(inst.id).await, Err(Error::NotFound)));
    assert!(b.instances().await.unwrap().is_empty());
    assert!(b.credentials().await.unwrap().is_empty());
    assert!(matches!(
        b.model_routes(inst.id).await,
        Err(Error::NotFound)
    ));
    assert!(matches!(
        b.create_run(&NewRun::new(inst.id, RunSource::User, "hi", "1"))
            .await,
        Err(Error::NotFound)
    ));
    // 改不到别人的行：RLS 下这些行不存在。
    assert!(matches!(
        b.rename_instance(inst.id, "mine").await,
        Err(Error::NotFound)
    ));
    assert!(matches!(
        b.append_event(inst.id, None, "x", &json!({})).await,
        Err(Error::NotFound)
    ));
    b.rollback().await.unwrap();

    // 自己的实例也不能指向别人的 key：仓储先查（RLS 下看不到），绕过仓储直接写还有复合外键挡住
    // （外键检查不受 RLS 约束，单列外键会放过）。
    let bob_inst = instance(db, bob).await;
    let mut b = db.tenant(bob).await.unwrap();
    let err = b
        .set_model_routes(
            bob_inst.id,
            &[ModelRoute {
                alias: "main".into(),
                credential_id: cred.id,
                upstream_model: "x".into(),
                fallbacks: vec![],
            }],
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    b.rollback().await.unwrap();
    let mut b = db.tenant(bob).await.unwrap();
    let err: Error = sqlx::query(
        "INSERT INTO model_routes (instance_id, alias, user_id, credential_id, upstream_model) \
         VALUES ($1, 'main', $2, $3, 'x')",
    )
    .bind(bob_inst.id.0)
    .bind(bob.0)
    .bind(cred.id.0)
    .execute(b.conn())
    .await
    .unwrap_err()
    .into();
    assert!(
        matches!(&err, Error::Invalid(m) if m.contains("model_routes_credential_id_user_id_fkey")),
        "{err:?}"
    );
    b.rollback().await.unwrap();

    // 绕过仓储直接写 SQL 也一样：冒充别人写入被策略拒绝，登录验证码表读不到。
    let mut b = db.tenant(bob).await.unwrap();
    let err: Error = sqlx::query(
        "INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id) \
         VALUES (gen_random_uuid(), $1, 'a', '1', 'acp', 'x', 'v')",
    )
    .bind(alice.0)
    .execute(b.conn())
    .await
    .unwrap_err()
    .into();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    b.rollback().await.unwrap();
    let mut b = db.tenant(bob).await.unwrap();
    let err: Error = sqlx::query("SELECT * FROM login_codes")
        .execute(b.conn())
        .await
        .unwrap_err()
        .into();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    b.rollback().await.unwrap();
    let mut b = db.tenant(bob).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(b.conn())
        .await
        .unwrap();
    assert_eq!(n, 1, "only sees itself");
    b.rollback().await.unwrap();

    // 后台角色看得到全部。
    let mut w = db.worker().await.unwrap();
    let rt = w.instance_runtime(inst.id).await.unwrap();
    assert_eq!(rt.user_id, alice);
    w.rollback().await.unwrap();
}

#[tokio::test]
async fn users_and_credentials() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let mut w = db.worker().await.unwrap();
    let (again, created) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    assert!(!created);
    assert_eq!(again.id, alice);
    w.set_user_status(alice, UserStatus::Deleted).await.unwrap();
    // 注销后同一个手机号可以重新注册，是新账号。
    let (fresh, created) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    assert!(created);
    assert_ne!(fresh.id, alice);
    w.commit().await.unwrap();

    let user = fresh.id;
    let inst = instance(db, user).await;
    let mut a = db.tenant(user).await.unwrap();
    let cred = a.create_credential(&credential("wxyz")).await.unwrap();
    assert_eq!(cred.last4, "wxyz");
    let route = ModelRoute {
        alias: "main".into(),
        credential_id: cred.id,
        upstream_model: "m".into(),
        fallbacks: vec![],
    };
    a.set_model_routes(inst.id, std::slice::from_ref(&route))
        .await
        .unwrap();
    assert_eq!(a.model_routes(inst.id).await.unwrap(), vec![route]);
    // 还有路由指向它时不能删。
    assert!(
        a.delete_credential(cred.id)
            .await
            .unwrap_err()
            .is_conflict()
    );
    a.set_model_routes(inst.id, &[]).await.unwrap();
    a.delete_credential(cred.id).await.unwrap();
    assert!(a.credentials().await.unwrap().is_empty());
    let sealed: Vec<u8> = sqlx::query_scalar("SELECT sealed FROM credentials WHERE id = $1")
        .bind(cred.id.0)
        .fetch_one(a.conn())
        .await
        .unwrap();
    assert!(sealed.is_empty(), "ciphertext is wiped on delete");
    // 删了、停用的 key 不能再被路由引用；非法别名被检查约束挡住。
    let err = a
        .set_model_routes(
            inst.id,
            &[ModelRoute {
                alias: "main".into(),
                credential_id: cred.id,
                upstream_model: "m".into(),
                fallbacks: vec![],
            }],
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)));
    a.rollback().await.unwrap();
    let mut a = db.tenant(user).await.unwrap();
    let live = a.create_credential(&credential("1234")).await.unwrap();
    let err = a
        .set_model_routes(
            inst.id,
            &[ModelRoute {
                alias: "Bad Alias".into(),
                credential_id: live.id,
                upstream_model: "m".into(),
                fallbacks: vec![],
            }],
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn plan_fires_create_one_run() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let inst = instance(db, alice).await;
    let mut a = db.tenant(alice).await.unwrap();
    let plan = a
        .create_plan(&NewPlan {
            instance_id: inst.id,
            title: "daily news".into(),
            goal: "summarize".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    let spec = ScheduleSpec::Cron {
        expr: "0 8 * * *".into(),
        tz: "Asia/Shanghai".into(),
    };
    let due_at = Utc::now() - Days::minutes(1);
    let trig = a.add_trigger(plan.id, &spec, Some(due_at)).await.unwrap();
    a.commit().await.unwrap();

    // 两个副本同时扫描：各自锁不同的触发器行（这里只有一个，另一个拿不到）。
    let mut w1 = db.worker().await.unwrap();
    let due = w1.due_triggers(Utc::now(), 10).await.unwrap();
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].trigger.id, trig.id);
    assert_eq!(due[0].user_id, alice);
    assert_eq!(due[0].plan.id, plan.id);
    let mut w2 = db.worker().await.unwrap();
    assert!(w2.due_triggers(Utc::now(), 10).await.unwrap().is_empty());
    w2.rollback().await.unwrap();

    // 即使两个事务都试图为同一个名义时间建运行，也只有一个成功。
    let fire = due[0].trigger.next_fire_at.unwrap();
    let mut new = NewRun::new(inst.id, RunSource::Plan, &plan.goal, "1");
    new.plan_id = Some(plan.id);
    new.trigger_id = Some(trig.id);
    new.fire_time = Some(fire);
    let first = w1.create_run(alice, &new).await.unwrap();
    assert!(first.is_some());
    let next = fire + Days::days(1);
    w1.advance_trigger(trig.id, Some(fire), Some(next))
        .await
        .unwrap();
    let racing = {
        let db = db.clone();
        let new = new.clone();
        tokio::spawn(async move {
            let mut w = db.worker().await.unwrap();
            let r = w.create_run(alice, &new).await.unwrap();
            w.commit().await.unwrap();
            r
        })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    w1.commit().await.unwrap();
    assert!(racing.await.unwrap().is_none(), "duplicate fire is ignored");

    let mut a = db.tenant(alice).await.unwrap();
    let triggers = a.triggers(plan.id).await.unwrap();
    assert_eq!(triggers[0].next_fire_at, Some(next));
    assert_eq!(triggers[0].last_fire_at, Some(fire));
    // 暂停的计划不再到点。
    a.set_trigger_enabled(trig.id, true, Some(due_at))
        .await
        .unwrap();
    a.set_plan_paused(plan.id, true).await.unwrap();
    a.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(w.due_triggers(Utc::now(), 10).await.unwrap().is_empty());
    w.rollback().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn claims_respect_one_run_per_instance() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let x = instance(db, alice).await;
    let y = instance(db, alice).await;
    let r1 = queue_run(db, alice, &x, "one").await;
    let r2 = queue_run(db, alice, &x, "two").await;
    let r3 = queue_run(db, alice, &y, "three").await;

    let mut w1 = db.worker().await.unwrap();
    let c1 = w1.claim_next_run("a", LEASE).await.unwrap().unwrap();
    assert_eq!(c1.run.id, r1.id);
    assert_eq!(c1.run.state, RunState::Starting);
    assert_eq!(c1.run.attempt, 1);
    assert_eq!(c1.lease_owner.as_deref(), Some("a"));
    // 另一个副本同时领取：跳过锁着的 r1；r2 和 r1 同一个实例，撞上唯一索引后退回，改领 r3。
    let other = {
        let db = db.clone();
        tokio::spawn(async move {
            let mut w = db.worker().await.unwrap();
            let c = w.claim_next_run("b", LEASE).await.unwrap();
            w.commit().await.unwrap();
            c
        })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    w1.commit().await.unwrap();
    let c2 = other.await.unwrap().unwrap();
    assert_eq!(c2.run.id, r3.id);
    let mut w = db.worker().await.unwrap();
    assert!(
        w.claim_next_run("c", LEASE).await.unwrap().is_none(),
        "r2 waits until x is free"
    );

    // r1 跑完，r2 才能领。
    w.transition_run(r1.id, "a", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    let done = w
        .transition_run(
            r1.id,
            "a",
            RunState::Succeeded,
            &RunChange {
                summary: Some("ok".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert!(done.run.started_at.is_some() && done.run.finished_at.is_some());
    assert_eq!(done.lease_owner, None);
    let c3 = w.claim_next_run("c", LEASE).await.unwrap().unwrap();
    assert_eq!(c3.run.id, r2.id);
    w.commit().await.unwrap();
}

#[tokio::test]
async fn run_lifecycle_and_leases() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "work").await;
    assert_eq!(run.root_run_id, run.id);

    let mut w = db.worker().await.unwrap();
    w.claim_next_run("a", LEASE).await.unwrap().unwrap();
    // 不合法的迁移、别人的租约都被拒绝。
    assert!(matches!(
        w.transition_run(run.id, "a", RunState::Succeeded, &RunChange::default())
            .await,
        Err(Error::InvalidTransition { .. })
    ));
    assert!(matches!(
        w.transition_run(run.id, "b", RunState::Running, &RunChange::default())
            .await,
        Err(Error::LeaseLost { .. })
    ));
    w.transition_run(run.id, "a", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    // 等审批：放掉租约；审批回来后别的副本拿租约继续。
    let waiting = w
        .transition_run(
            run.id,
            "a",
            RunState::WaitingApproval,
            &RunChange {
                reason: Some("approval req-1".into()),
                release_lease: true,
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(waiting.lease_owner, None);
    assert!(!w.renew_lease(run.id, "a", LEASE).await.unwrap());
    assert!(w.acquire_lease(run.id, "b", LEASE).await.unwrap().is_some());
    assert!(
        w.acquire_lease(run.id, "c", LEASE).await.unwrap().is_none(),
        "held by b"
    );
    w.transition_run(run.id, "b", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    let used = w.add_run_usage(run.id, 1500, 3).await.unwrap();
    assert_eq!((used.run.tokens_used, used.steps), (1500, 3));
    w.commit().await.unwrap();

    // 子运行挂在同一棵树上。
    let mut a = db.tenant(alice).await.unwrap();
    let other = instance_in(&mut a).await;
    let mut child = NewRun::new(other.id, RunSource::Delegate, "sub", "1");
    child.parent_run_id = Some(run.id);
    let child = a.create_run(&child).await.unwrap();
    assert_eq!(child.root_run_id, run.id);
    assert_eq!(a.run_tree(run.id).await.unwrap().len(), 2);
    a.cancel_run(child.id, None).await.unwrap();
    // 用户取消：执行中的副本续租失败。
    let cancelled = a.cancel_run(run.id, None).await.unwrap();
    assert_eq!(cancelled.state, RunState::Cancelled);
    assert!(matches!(
        a.cancel_run(run.id, None).await,
        Err(Error::InvalidTransition { .. })
    ));
    a.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(!w.renew_lease(run.id, "b", LEASE).await.unwrap());
    w.commit().await.unwrap();

    // 崩溃接管：租约过期的运行被别的副本接走；退避后的运行到点重新领取，算第二次尝试。
    let crashed = queue_run(db, alice, &inst, "again").await;
    let mut w = db.worker().await.unwrap();
    w.claim_next_run("a", Duration::ZERO)
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let taken = w.take_over_expired("b", LEASE, 10).await.unwrap();
    assert_eq!(taken.len(), 1);
    assert_eq!(taken[0].run.id, crashed.id);
    assert_eq!(taken[0].lease_owner.as_deref(), Some("b"));
    w.transition_run(
        crashed.id,
        "b",
        RunState::Backoff,
        &RunChange {
            error: Some("sandbox crashed".into()),
            not_before: Some(Utc::now() - Days::seconds(1)),
            release_lease: true,
            ..Default::default()
        },
    )
    .await
    .unwrap();
    let retried = w.claim_next_run("c", LEASE).await.unwrap().unwrap();
    assert_eq!(retried.run.id, crashed.id);
    assert_eq!(retried.run.attempt, 2);
    assert_eq!(retried.run.error.as_deref(), Some("sandbox crashed"));
    w.commit().await.unwrap();

    // 冻结的账号不领新运行。
    let mut w = db.worker().await.unwrap();
    w.transition_run(crashed.id, "c", RunState::Failed, &RunChange::default())
        .await
        .unwrap();
    w.set_user_status(alice, UserStatus::Frozen).await.unwrap();
    w.commit().await.unwrap();
    queue_run(db, alice, &inst, "frozen").await;
    let mut w = db.worker().await.unwrap();
    assert!(w.claim_next_run("a", LEASE).await.unwrap().is_none());
}

async fn instance_in(t: &mut crate::Tx<crate::Tenant>) -> Instance {
    t.create_instance(&NewInstance {
        agent_id: "codex".into(),
        agent_version: "1".into(),
        harness: "acp".into(),
        name: "helper".into(),
        workspace_id: "vol-2".into(),
        limits: InstanceLimits::default(),
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn events_are_sequenced_per_instance() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let x = instance(db, alice).await;
    let y = instance(db, alice).await;
    let mut a = db.tenant(alice).await.unwrap();
    for i in 0..3 {
        let e = a
            .append_event(x.id, None, "message", &json!({ "i": i }))
            .await
            .unwrap();
        assert_eq!(e.seq, i + 1);
    }
    assert_eq!(
        a.append_event(y.id, None, "message", &json!({}))
            .await
            .unwrap()
            .seq,
        1
    );
    let tail = a.events_after(x.id, 1, 100).await.unwrap();
    assert_eq!(tail.iter().map(|e| e.seq).collect::<Vec<_>>(), [2, 3]);
    assert_eq!(tail[1].payload, json!({ "i": 2 }));
    assert_eq!(a.event_range(x.id).await.unwrap(), (1, 3));
    a.commit().await.unwrap();

    // 分区维护：提前建好的分区可以重复建；过了保留期的整月分区被删掉。
    let mut w = db.worker().await.unwrap();
    let today = Utc::now().date_naive();
    let this_month = NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap();
    w.ensure_event_partitions(this_month, 3).await.unwrap();
    assert_eq!(w.drop_event_partitions_before(this_month).await.unwrap(), 1);
    assert_eq!(w.drop_event_partitions_before(this_month).await.unwrap(), 0);
    w.commit().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    assert_eq!(a.events_after(x.id, 0, 100).await.unwrap().len(), 3);
}

#[tokio::test]
async fn outbox_delivers_once_and_retries() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let item = NewOutboxItem {
        kind: "push".into(),
        payload: json!({ "title": "done" }),
        dedupe_key: Some("run_finished:1".into()),
        available_at: None,
    };
    let mut a = db.tenant(alice).await.unwrap();
    assert!(a.enqueue_outbox(&item).await.unwrap());
    assert!(!a.enqueue_outbox(&item).await.unwrap(), "deduplicated");
    a.audit(
        "user:dev-1",
        "credential.create",
        Some("cred-1"),
        &json!({}),
    )
    .await
    .unwrap();
    a.commit().await.unwrap();
    // 业务角色只能看到自己的去重键，读不到出箱内容。
    let bob = user(db, "+8613800000002").await;
    let mut b = db.tenant(bob).await.unwrap();
    assert!(b.enqueue_outbox(&item).await.unwrap(), "keys are per user");
    let keys: Vec<String> = sqlx::query_scalar("SELECT dedupe_key FROM outbox")
        .fetch_all(b.conn())
        .await
        .unwrap();
    assert_eq!(keys, ["run_finished:1"]);
    let err: Error = sqlx::query("SELECT payload FROM outbox")
        .execute(b.conn())
        .await
        .unwrap_err()
        .into();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    b.rollback().await.unwrap();
    // 回滚的事务里入箱的通知不会发出去。
    let mut a = db.tenant(alice).await.unwrap();
    assert!(
        a.enqueue_outbox(&NewOutboxItem {
            dedupe_key: Some("rolled-back".into()),
            ..item.clone()
        })
        .await
        .unwrap()
    );
    a.rollback().await.unwrap();

    let mut w = db.worker().await.unwrap();
    let got = w.claim_outbox("d1", LEASE, 10).await.unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!((got[0].user_id, got[0].attempts), (alice, 1));
    w.commit().await.unwrap();
    // 锁着的条目别的投递器领不到；失败后按时间重试。
    let mut w = db.worker().await.unwrap();
    assert!(w.claim_outbox("d2", LEASE, 10).await.unwrap().is_empty());
    assert!(matches!(
        w.finish_outbox(got[0].id, "d2", None).await,
        Err(Error::LeaseLost { .. })
    ));
    w.retry_outbox(got[0].id, "d1", "apns 503", Utc::now() - Days::seconds(1))
        .await
        .unwrap();
    let again = w.claim_outbox("d2", LEASE, 10).await.unwrap();
    assert_eq!(again[0].attempts, 2);
    w.finish_outbox(again[0].id, "d2", None).await.unwrap();
    assert!(w.claim_outbox("d3", LEASE, 10).await.unwrap().is_empty());
    let audits: i64 = sqlx::query_scalar("SELECT count(*) FROM audit_log WHERE user_id = $1")
        .bind(alice.0)
        .fetch_one(w.conn())
        .await
        .unwrap();
    assert_eq!(audits, 1);
}

#[tokio::test]
async fn inbox_keeps_every_notice_with_read_state() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "hi").await;
    let item = |n: u32| NewInboxItem {
        kind: "run_finished".into(),
        title: format!("t{n}"),
        body: "done".into(),
        instance_id: Some(inst.id),
        run_id: Some(run.id),
        dedupe_key: Some(format!("k{n}")),
        ..NewInboxItem::default()
    };
    let mut w = db.worker().await.unwrap();
    let mut ids = Vec::new();
    for n in 0..5 {
        ids.push(w.insert_inbox(alice, &item(n)).await.unwrap().unwrap());
    }
    assert_eq!(
        w.insert_inbox(alice, &item(0)).await.unwrap(),
        None,
        "deduplicated"
    );
    w.commit().await.unwrap();

    // 别人看不到，也写不进别人的收件箱。
    let mut b = db.tenant(bob).await.unwrap();
    assert!(b.inbox(None, 50, false).await.unwrap().is_empty());
    assert!(matches!(b.inbox_item(ids[0]).await, Err(Error::NotFound)));
    assert!(b.insert_inbox(alice, &item(9)).await.is_err());
    b.rollback().await.unwrap();
    let mut b = db.tenant(bob).await.unwrap();
    assert_eq!(b.mark_inbox_read(Some(&ids), None).await.unwrap(), 0);
    assert!(matches!(
        b.delete_inbox_item(ids[0]).await,
        Err(Error::NotFound)
    ));
    b.commit().await.unwrap();

    let mut a = db.tenant(alice).await.unwrap();
    let page = a.inbox(None, 3, false).await.unwrap();
    assert_eq!(
        page.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(),
        ["t4", "t3", "t2"],
        "newest first"
    );
    let rest = a.inbox(Some(page[2].id), 3, false).await.unwrap();
    assert_eq!(rest.len(), 2);
    assert_eq!(a.inbox_unread().await.unwrap(), 5);
    assert_eq!(a.mark_inbox_read(Some(&ids[..1]), None).await.unwrap(), 1);
    // “全部已读”只标到客户端看到的那一条为止。
    assert_eq!(a.mark_inbox_read(None, Some(ids[3])).await.unwrap(), 3);
    assert_eq!(a.inbox_unread().await.unwrap(), 1);
    let unread = a.inbox(None, 50, true).await.unwrap();
    assert_eq!(unread.len(), 1);
    assert_eq!(unread[0].id, ids[4]);
    a.mark_inbox_unread(ids[0]).await.unwrap();
    assert_eq!(a.inbox_unread().await.unwrap(), 2);
    a.delete_inbox_item(ids[0]).await.unwrap();
    assert_eq!(a.inbox(None, 50, false).await.unwrap().len(), 4);
    // 自己的事务里也能写（平台工具代表用户操作时）。
    assert!(a.insert_inbox(alice, &item(7)).await.unwrap().is_some());
    a.commit().await.unwrap();

    // 运行删除后条目还在，只是不再指向它。
    let mut w = db.worker().await.unwrap();
    sqlx::query("DELETE FROM runs WHERE id = $1")
        .bind(run.id.0)
        .execute(w.conn())
        .await
        .unwrap();
    w.commit().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    let all = a.inbox(None, 50, false).await.unwrap();
    assert_eq!(all.len(), 5);
    assert!(all.iter().all(|i| i.run_id.is_none()));
}

/// 租户隔离的兜底（15.2）：业务角色碰得到的、带 user_id 的表都必须开 RLS 并有策略；
/// 新加表忘了开会在这里失败。
#[tokio::test]
async fn every_tenant_table_the_app_can_touch_has_rls() {
    let Some(t) = TestDb::new().await else { return };
    let rows: Vec<(String, bool, i64, bool)> = sqlx::query_as(
        "SELECT c.relname::text, c.relrowsecurity, \
           (SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = c.relname), \
           has_table_privilege('thinktin_app', c.oid, 'SELECT, INSERT, UPDATE, DELETE') \
             OR has_any_column_privilege('thinktin_app', c.oid, 'SELECT, INSERT, UPDATE') \
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
         WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') \
           AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'user_id' AND NOT a.attisdropped) \
         ORDER BY 1",
    )
    .fetch_all(t.db.pool())
    .await
    .unwrap();
    assert!(rows.len() > 10, "{rows:?}");
    let mut bad = Vec::new();
    for (table, rls, policies, app_can_touch) in &rows {
        if *app_can_touch && (!rls || *policies == 0) {
            bad.push(table.clone());
        }
    }
    assert!(
        bad.is_empty(),
        "tables reachable by thinktin_app without RLS: {bad:?}"
    );
    // 业务角色不能绕过 RLS。
    let bypass: bool =
        sqlx::query_scalar("SELECT rolbypassrls FROM pg_roles WHERE rolname = 'thinktin_app'")
            .fetch_one(t.db.pool())
            .await
            .unwrap();
    assert!(!bypass);
    // 用户表按 id 隔离。
    let users_rls: bool =
        sqlx::query_scalar("SELECT relrowsecurity FROM pg_class WHERE relname = 'users'")
            .fetch_one(t.db.pool())
            .await
            .unwrap();
    assert!(users_rls);
    let touched: Vec<&str> = rows.iter().filter(|r| r.3).map(|r| r.0.as_str()).collect();
    for must in [
        "instances",
        "runs",
        "plans",
        "credentials",
        "inbox_items",
        "artifacts",
        "teams",
    ] {
        assert!(touched.contains(&must), "{must} missing from {touched:?}");
    }
}

/// 注销（16.4）：用户的内容全部删掉，手机号、设备去标识化；别人的数据不受影响。
#[tokio::test]
async fn erasing_an_account_deletes_its_content() {
    use proto::domain::{
        ArtifactId, DevicePlatform, PlanStep, PushChannelKind, TeamMember, TeamRole,
        TeamTemplateSpec, TemplateMember,
    };

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    for who in [alice, bob] {
        let inst = instance(db, who).await;
        let run = queue_run(db, who, &inst, "写一份关于我体检报告的总结").await;
        let mut w = db.worker().await.unwrap();
        w.insert_user_key(who, "local", &[1, 2, 3]).await.unwrap();
        let phone = w
            .create_device(
                who,
                DevicePlatform::Ios,
                "张三的 iPhone",
                Some((PushChannelKind::Apns, "tok")),
            )
            .await
            .unwrap();
        let mac = w
            .create_device(who, DevicePlatform::Macos, "张三的 MacBook", None)
            .await
            .unwrap();
        w.create_device_call(&crate::NewDeviceCall {
            user: who,
            device: mac,
            run: Some(run.id),
            tool: "fs_read".into(),
            arguments: json!({ "path": "/Users/zhangsan/体检报告.pdf" }),
            timeout: Duration::from_secs(60),
        })
        .await
        .unwrap();
        w.create_approval(&crate::NewApproval {
            user: who,
            instance: inst.id,
            run: run.id,
            request_id: "r1",
            title: Some("删除病历.pdf"),
            options: &json!([]),
            tool_call: &json!({}),
            expires_in: Duration::from_secs(60),
        })
        .await
        .unwrap();
        w.insert_artifact(&crate::NewArtifact {
            id: ArtifactId::new(),
            user: who,
            instance: inst.id,
            run: run.id,
            root: run.id,
            name: "体检总结.md",
            content_type: "text/markdown",
            size: 3,
            sha256: &[0; 32],
            blob_key: "k",
        })
        .await
        .unwrap();
        w.insert_inbox(
            who,
            &NewInboxItem {
                kind: "run_finished".into(),
                title: "体检".into(),
                body: "血压偏高".into(),
                ..NewInboxItem::default()
            },
        )
        .await
        .unwrap();
        w.enqueue_outbox(
            who,
            &NewOutboxItem {
                kind: "push".into(),
                payload: json!({ "body": "血压偏高" }),
                dedupe_key: None,
                available_at: None,
            },
        )
        .await
        .unwrap();
        w.commit().await.unwrap();
        let mut tx = db.tenant(who).await.unwrap();
        tx.append_event(
            inst.id,
            Some(run.id),
            "agent.message",
            &json!({ "text": "血压偏高" }),
        )
        .await
        .unwrap();
        tx.append_event(inst.id, None, "instance.state", &json!({}))
            .await
            .unwrap();
        let plan = tx
            .create_plan(&NewPlan {
                instance_id: inst.id,
                title: "每周体检提醒".into(),
                goal: "看看我的体检数据".into(),
                policy: PlanPolicy::default(),
                catch_up: CatchUp::Once,
                created_by: PlanAuthor::User,
                run_grant_id: None,
            })
            .await
            .unwrap();
        tx.add_trigger(
            plan.id,
            &ScheduleSpec::Cron {
                expr: "0 8 * * 1".into(),
                tz: "Asia/Shanghai".into(),
            },
            None,
        )
        .await
        .unwrap();
        tx.set_plan_steps(
            plan.id,
            &[PlanStep {
                key: "a".into(),
                instance_id: inst.id,
                prompt: "读体检报告".into(),
                depends_on: vec![],
            }],
        )
        .await
        .unwrap();
        tx.create_team(
            "家庭医生",
            &[TeamMember {
                instance_id: inst.id,
                role: TeamRole::Lead,
                position: 0,
            }],
        )
        .await
        .unwrap();
        tx.create_team_template(
            "家庭医生",
            &TeamTemplateSpec {
                members: vec![TemplateMember {
                    agent_id: "claude".into(),
                    harness: None,
                    name: "医生".into(),
                    role: TeamRole::Lead,
                }],
            },
        )
        .await
        .unwrap();
        tx.create_vault_item(&crate::NewVaultItem {
            id: proto::domain::VaultItemId::new(),
            name: "hospital".into(),
            purpose: "医院网站".into(),
            sealed: vec![1, 2, 3],
            has_username: true,
            instance_ids: vec![inst.id],
        })
        .await
        .unwrap();
        tx.create_im_channel(
            &crate::NewImChannel {
                id: proto::domain::ImChannelId::new(),
                vendor: proto::domain::ImVendor::Feishu,
                label: "家庭群".into(),
                sealed: vec![4, 5, 6],
                hint: "…abcd".into(),
                has_secret: true,
                events: vec![proto::domain::ImEvent::RunFinished],
            },
            20,
        )
        .await
        .unwrap();
        tx.create_vault_request(&crate::NewVaultRequest {
            instance_id: inst.id,
            run_id: Some(run.id),
            name: "insurance".into(),
            purpose: "保险公司网站".into(),
            fields: vec!["username".into(), "password".into()],
            expires_in: Duration::from_secs(3600),
        })
        .await
        .unwrap();
        tx.send_device_message(
            phone,
            mac,
            proto::domain::DeviceMessageKind::Capability,
            &json!({ "dirs": ["/Users/zhangsan/体检"] }),
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();
        let mut r = db.relay().await.unwrap();
        r.link_device(&crate::NewLink {
            device: mac,
            user: who,
            node: "relay-1".into(),
            connection: uuid::Uuid::now_v7(),
        })
        .await
        .unwrap();
        r.commit().await.unwrap();
    }

    // 送达过的推送记录也有正文，注销时一起删。
    sqlx::query("UPDATE outbox SET delivered_at = now()")
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    w.erase_account(alice).await.unwrap();
    w.commit().await.unwrap();
    // 产出物的密文排进清理队列。
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.blob_purge_batch(10).await.unwrap(), ["k"]);
    w.rollback().await.unwrap();

    let count = |table: &'static str, user: UserId| async move {
        let n: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT count(*) FROM {table} WHERE user_id = $1"
        )))
        .bind(user.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
        n
    };
    for table in [
        "user_keys",
        "model_routes",
        "model_route_fallbacks",
        "runs",
        "events",
        "approvals",
        "artifacts",
        "plans",
        "triggers",
        "plan_steps",
        "inbox_items",
        "outbox",
        "teams",
        "team_members",
        "team_templates",
        "vault_items",
        "vault_requests",
        "im_channels",
        "device_calls",
        "device_messages",
        "device_links",
    ] {
        assert_eq!(
            count(table, alice).await,
            0,
            "{table} still has alice's rows"
        );
        assert!(
            count(table, bob).await > 0 || table.starts_with("model_route"),
            "{table}: bob untouched"
        );
    }
    let (phone, name): (String, Option<String>) =
        sqlx::query_as("SELECT phone, display_name FROM users WHERE id = $1")
            .bind(alice.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!((phone.as_str(), name), ("deleted", None));
    let devices: Vec<(String, Option<String>)> =
        sqlx::query_as("SELECT name, push_token FROM devices WHERE user_id = $1")
            .bind(alice.0)
            .fetch_all(db.pool())
            .await
            .unwrap();
    assert!(devices.iter().all(|(n, tok)| n.is_empty() && tok.is_none()));
    let states: Vec<(String, String)> =
        sqlx::query_as("SELECT state, name FROM instances WHERE user_id = $1")
            .bind(alice.0)
            .fetch_all(db.pool())
            .await
            .unwrap();
    assert!(states.iter().all(|(s, n)| s == "deleted" && n.is_empty()));
    // 同一个手机号可以重新注册成新账号。
    let mut w = db.worker().await.unwrap();
    let (again, created) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    assert!(created && again.id != alice);
}

/// 降级链（9.9）：跟着主路由存取、最多 3 个、key 要可用、被引用的 key 不能删、网关按顺序读到。
#[tokio::test]
async fn route_fallbacks_round_trip_and_guard_their_keys() {
    use proto::domain::RouteFallback;

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let inst = instance(db, alice).await;
    let mut a = db.tenant(alice).await.unwrap();
    let primary = a.create_credential(&credential("0001")).await.unwrap();
    let backup = a.create_credential(&credential("0002")).await.unwrap();
    let spare = a.create_credential(&credential("0003")).await.unwrap();
    let fb = |c: &proto::domain::Credential, m: &str| RouteFallback {
        credential_id: c.id,
        upstream_model: m.into(),
    };
    let route = ModelRoute {
        alias: "main".into(),
        credential_id: primary.id,
        upstream_model: "m-primary".into(),
        fallbacks: vec![fb(&backup, "m-backup"), fb(&spare, "m-spare")],
    };
    let plain = ModelRoute {
        alias: "fast".into(),
        credential_id: spare.id,
        upstream_model: "m-fast".into(),
        fallbacks: vec![],
    };
    a.set_model_routes(inst.id, &[route.clone(), plain.clone()])
        .await
        .unwrap();
    assert_eq!(
        a.model_routes(inst.id).await.unwrap(),
        vec![plain.clone(), route.clone()]
    );
    // 只被降级链引用的 key 也不能删。
    assert!(
        a.delete_credential(backup.id)
            .await
            .unwrap_err()
            .is_conflict()
    );
    a.commit().await.unwrap();

    // 模型网关按顺序读到降级链。
    let mut g = db.llmgw().await.unwrap();
    let gi = g.gateway_instance(inst.id).await.unwrap().unwrap();
    g.rollback().await.unwrap();
    let main = gi.routes.iter().find(|r| r.alias == "main").unwrap();
    assert_eq!(
        main.fallbacks,
        vec![
            (backup.id, "m-backup".to_string()),
            (spare.id, "m-spare".to_string())
        ]
    );
    assert!(
        gi.routes
            .iter()
            .find(|r| r.alias == "fast")
            .unwrap()
            .fallbacks
            .is_empty()
    );

    // 别人看不到这些行。
    let mut b = db.tenant(bob).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM model_route_fallbacks")
        .fetch_one(b.conn())
        .await
        .unwrap();
    assert_eq!(n, 0);
    b.rollback().await.unwrap();

    let mut a = db.tenant(alice).await.unwrap();
    // 超过 3 个、或者引用停用的 key：整体拒绝，原来的不变。
    let too_many = ModelRoute {
        fallbacks: vec![
            fb(&backup, "a"),
            fb(&spare, "b"),
            fb(&backup, "c"),
            fb(&spare, "d"),
        ],
        ..route.clone()
    };
    assert!(matches!(
        a.set_model_routes(inst.id, &[too_many]).await.unwrap_err(),
        Error::Invalid(_)
    ));
    a.rollback().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    a.set_credential_disabled(spare.id, true).await.unwrap();
    let err = a
        .set_model_routes(
            inst.id,
            &[ModelRoute {
                fallbacks: vec![fb(&spare, "m")],
                ..route.clone()
            }],
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    a.rollback().await.unwrap();

    // 替换别名时降级链一起替换；去掉降级链后 key 可以删。
    let mut a = db.tenant(alice).await.unwrap();
    let bare = ModelRoute {
        fallbacks: vec![],
        ..route.clone()
    };
    a.set_model_routes(inst.id, std::slice::from_ref(&bare))
        .await
        .unwrap();
    assert_eq!(a.model_routes(inst.id).await.unwrap(), vec![bare]);
    a.delete_credential(backup.id).await.unwrap();
    a.commit().await.unwrap();
}

/// 删除实例：从它的授权收窄给别的实例的子授权一起吊销；根在它上面的运行树里、在别的实例上跑的步骤一起取消。
/// 父授权失效后，子授权也换不到沙箱令牌、模型网关也不认。
#[tokio::test]
async fn deleting_an_instance_stops_its_whole_run_tree_and_grant_tree() {
    use proto::domain::GrantScope;

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let x = instance(db, alice).await;
    let y = instance(db, alice).await;
    let mut a = db.tenant(alice).await.unwrap();
    let g = a
        .create_run_grant(
            x.id,
            None,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let mut root = NewRun::new(x.id, RunSource::User, "pipeline", "1");
    root.run_grant_id = Some(g.id);
    let root = a.create_run(&root).await.unwrap();
    a.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let gy = w
        .create_child_grant(
            g.id,
            y.id,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let mut step = NewRun::new(y.id, RunSource::User, "step on y", "1");
    step.parent_run_id = Some(root.id);
    step.run_grant_id = Some(gy.id);
    let step = w.create_run(alice, &step).await.unwrap().unwrap();
    w.commit().await.unwrap();

    // 只让父授权失效：子授权跟着不能用（换沙箱令牌、模型网关都不认），恢复以后又能用。
    let ttl = Duration::from_secs(3600);
    let set_parent_revoked = |revoked: bool| async move {
        sqlx::query("UPDATE run_grants SET revoked_at = CASE WHEN $2 THEN now() END WHERE id = $1")
            .bind(g.id.0)
            .bind(revoked)
            .execute(db.pool())
            .await
            .unwrap();
    };
    let usable = || async {
        let mut w = db.worker().await.unwrap();
        let touched = w.touch_run_grant(gy.id, ttl, ttl).await.unwrap().is_some();
        w.rollback().await.unwrap();
        let mut gw = db.llmgw().await.unwrap();
        let aliases = gw.usable_grant_aliases(gy.id).await.unwrap().is_some();
        gw.rollback().await.unwrap();
        (touched, aliases)
    };
    assert_eq!(usable().await, (true, true));
    set_parent_revoked(true).await;
    assert_eq!(usable().await, (false, false));
    set_parent_revoked(false).await;
    assert_eq!(usable().await, (true, true));

    // 删除实例 x 的流程：取消运行、吊销授权。
    let mut a = db.tenant(alice).await.unwrap();
    assert_eq!(
        a.cancel_instance_runs(x.id, "instance deleted")
            .await
            .unwrap(),
        2
    );
    a.revoke_instance_grants(x.id, "instance deleted")
        .await
        .unwrap();
    a.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.run_record(step.id).await.unwrap().run.state,
        RunState::Cancelled
    );
    let (_, child) = w.run_grant(gy.id).await.unwrap();
    assert!(
        child.revoked_at.is_some(),
        "child grant on another instance is revoked"
    );
    assert!(w.touch_run_grant(gy.id, ttl, ttl).await.unwrap().is_none());
    w.rollback().await.unwrap();
    let mut gw = db.llmgw().await.unwrap();
    assert!(gw.usable_grant_aliases(gy.id).await.unwrap().is_none());
}

/// 流水线驱动器按轮转处理：处理过的排到队尾，一直等子运行的流水线不会每轮都占满这一批。
#[tokio::test]
async fn pipeline_roots_are_served_round_robin() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let inst = instance(db, alice).await;
    let mut a = db.tenant(alice).await.unwrap();
    let mut ids = Vec::new();
    for i in 0..5 {
        let mut new = NewRun::new(inst.id, RunSource::User, format!("p{i}"), "1");
        new.kind = proto::domain::RunKind::Pipeline;
        ids.push(a.create_run(&new).await.unwrap().id);
    }
    a.commit().await.unwrap();
    let mut seen = Vec::new();
    for _ in 0..3 {
        let mut w = db.worker().await.unwrap();
        let batch: Vec<_> = w
            .due_pipelines(2)
            .await
            .unwrap()
            .into_iter()
            .map(|r| r.run.id)
            .collect();
        w.requeue_pipelines(&batch).await.unwrap();
        w.commit().await.unwrap();
        seen.extend(batch);
    }
    // 三轮、每轮两个：五个都轮到了，第六个又回到第一个。
    let distinct: std::collections::HashSet<_> = seen.iter().collect();
    assert_eq!(distinct.len(), 5, "{seen:?}");
}

/// 推送只发给还登录着的设备；同一台设备换了账号登录，之前的账号不再收到推送。
#[tokio::test]
async fn pushes_only_reach_signed_in_devices_and_their_current_user() {
    use proto::domain::{DevicePlatform, PushChannelKind, SessionId};
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let hour = Duration::from_secs(3600);
    let mut w = db.worker().await.unwrap();
    let shared = Some((PushChannelKind::Apns, "shared-token"));
    let a_dev = w
        .create_device(alice, DevicePlatform::Ios, "iPad", shared)
        .await
        .unwrap();
    let a_session = SessionId::new();
    w.create_session(a_session, alice, a_dev, b"r1", hour)
        .await
        .unwrap();
    assert_eq!(w.push_targets(alice).await.unwrap().len(), 1);
    // 会话被吊销（没走退出接口，设备记录还在）：这台设备收不到了。
    w.revoke_session(a_session, "test").await.unwrap();
    assert!(w.push_targets(alice).await.unwrap().is_empty());
    w.create_session(SessionId::new(), alice, a_dev, b"r2", hour)
        .await
        .unwrap();
    assert_eq!(w.push_targets(alice).await.unwrap().len(), 1);
    // bob 在同一台设备上登录：令牌归 bob。
    let b_dev = w
        .create_device(bob, DevicePlatform::Ios, "iPad", shared)
        .await
        .unwrap();
    w.create_session(SessionId::new(), bob, b_dev, b"r3", hour)
        .await
        .unwrap();
    assert!(w.push_targets(alice).await.unwrap().is_empty());
    assert_eq!(w.push_targets(bob).await.unwrap().len(), 1);
    w.rollback().await.unwrap();
}

/// 冻结、“全部停止”（4.6）：只动这个用户的东西，占着实例的运行让令牌代数加一。
#[tokio::test]
async fn stopping_everything_for_a_user() {
    use proto::domain::GrantScope;

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let x = instance(db, alice).await;
    let y = instance(db, alice).await;
    let z = instance(db, bob).await;
    let mut a = db.tenant(alice).await.unwrap();
    for i in [&x, &y] {
        a.create_run_grant(
            i.id,
            None,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    }
    let mut plans = Vec::new();
    for title in ["daily", "weekly", "monthly"] {
        let p = a
            .create_plan(&NewPlan {
                instance_id: x.id,
                title: title.into(),
                goal: "summarize".into(),
                policy: PlanPolicy::default(),
                catch_up: CatchUp::Once,
                created_by: PlanAuthor::User,
                run_grant_id: None,
            })
            .await
            .unwrap();
        plans.push(p.id);
    }
    a.set_plan_paused(plans[2], true).await.unwrap();
    a.commit().await.unwrap();
    let mut b = db.tenant(bob).await.unwrap();
    b.create_run_grant(
        z.id,
        None,
        &GrantScope::default(),
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    b.commit().await.unwrap();

    // x 上的运行开始执行（占着实例），y 上的还在排队；bob 的不受影响。
    let rx = queue_run(db, alice, &x, "one").await;
    let mut w = db.worker().await.unwrap();
    let claimed = w.claim_next_run("node", LEASE).await.unwrap().unwrap();
    assert_eq!(claimed.run.id, rx.id);
    w.commit().await.unwrap();
    let ry = queue_run(db, alice, &y, "two").await;
    let rz = queue_run(db, bob, &z, "theirs").await;

    async fn epoch(w: &mut crate::Tx<crate::Worker>, id: proto::domain::InstanceId) -> u64 {
        w.instance_runtime(id).await.unwrap().token_epoch
    }
    let mut w = db.worker().await.unwrap();
    let (ex, ey, ez) = (
        epoch(&mut w, x.id).await,
        epoch(&mut w, y.id).await,
        epoch(&mut w, z.id).await,
    );
    let summary = w.account_summary(alice).await.unwrap();
    assert_eq!(
        (
            summary.instances,
            summary.active_runs,
            summary.active_plans,
            summary.active_grants
        ),
        (2, 2, 2, 2)
    );
    assert_eq!(summary.user.status, UserStatus::Active);

    assert_eq!(
        w.cancel_user_runs(alice, "account frozen").await.unwrap(),
        2
    );
    assert_eq!(w.revoke_user_grants(alice, "stop_all").await.unwrap(), 2);
    assert_eq!(w.pause_user_plans(alice).await.unwrap(), 2);
    assert_eq!(w.pause_user_plans(alice).await.unwrap(), 0);
    assert_eq!(epoch(&mut w, x.id).await, ex + 1);
    assert_eq!(
        epoch(&mut w, y.id).await,
        ey,
        "a queued run holds no tokens"
    );
    assert_eq!(epoch(&mut w, z.id).await, ez);
    for (id, state) in [
        (rx.id, RunState::Cancelled),
        (ry.id, RunState::Cancelled),
        (rz.id, RunState::Queued),
    ] {
        assert_eq!(w.run_record(id).await.unwrap().run.state, state);
    }
    let rec = w.run_record(rx.id).await.unwrap();
    assert_eq!(rec.run.state_reason.as_deref(), Some("account frozen"));
    let summary = w.account_summary(alice).await.unwrap();
    assert_eq!(
        (
            summary.active_runs,
            summary.active_plans,
            summary.active_grants
        ),
        (0, 0, 0)
    );
    let theirs = w.account_summary(bob).await.unwrap();
    assert_eq!((theirs.active_runs, theirs.active_grants), (1, 1));
    w.commit().await.unwrap();
}

/// 密码保险箱（9.11）：同名冲突、实例限制、按实例取密文、请求复用和处理、互相看不到。
#[tokio::test]
async fn vault_items_and_requests() {
    use proto::domain::{InstanceId, VaultItemId, VaultRequestStatus};

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let x = instance(db, alice).await;
    let y = instance(db, alice).await;
    let z = instance(db, bob).await;
    let item = |name: &str, instance_ids: Vec<InstanceId>| crate::NewVaultItem {
        id: VaultItemId::new(),
        name: name.into(),
        purpose: format!("{name} account"),
        sealed: vec![9; 40],
        has_username: false,
        instance_ids,
    };

    let mut a = db.tenant(alice).await.unwrap();
    let github = a.create_vault_item(&item("github", vec![])).await.unwrap();
    let bank = a
        .create_vault_item(&item("bank", vec![x.id]))
        .await
        .unwrap();
    assert_eq!(bank.instance_ids, vec![x.id]);
    a.commit().await.unwrap();
    // 同名冲突；别人的实例当作不存在；名字不合规则被数据库挡住。
    for (new, conflict) in [
        (item("github", vec![]), true),
        (item("evil", vec![z.id]), false),
        (item("Bad.Name", vec![]), false),
    ] {
        let mut a = db.tenant(alice).await.unwrap();
        let err = a.create_vault_item(&new).await.unwrap_err();
        assert_eq!(err.is_conflict(), conflict, "{err}");
        a.rollback().await.unwrap();
    }
    // bob 看不到 alice 的条目。
    let mut b = db.tenant(bob).await.unwrap();
    assert!(b.vault_items().await.unwrap().is_empty());
    assert!(matches!(
        b.sealed_vault_item(github.id).await,
        Err(Error::NotFound)
    ));
    b.rollback().await.unwrap();

    // 改用途、实例和密文。
    let mut a = db.tenant(alice).await.unwrap();
    let changed = a
        .update_vault_item(
            bank.id,
            &crate::VaultItemChange {
                purpose: Some("网银".into()),
                instance_ids: Some(vec![y.id]),
                sealed: Some((vec![7; 40], true)),
            },
        )
        .await
        .unwrap();
    assert_eq!(
        (changed.purpose.as_str(), changed.has_username),
        ("网银", true)
    );
    assert_eq!(changed.instance_ids, vec![y.id]);
    assert_eq!(
        a.sealed_vault_item(bank.id).await.unwrap().sealed,
        vec![7; 40]
    );
    assert_eq!(
        a.sealed_vault_item_named("github").await.unwrap().item.id,
        github.id
    );
    assert_eq!(a.vault_item_count().await.unwrap(), 2);
    let names: Vec<String> = a
        .vault_items()
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.name)
        .collect();
    assert_eq!(names, ["bank", "github"]);
    a.commit().await.unwrap();

    // 运行只拿得到这个实例能用的条目。
    let mut w = db.worker().await.unwrap();
    let want = vec!["github".to_string(), "bank".to_string(), "nope".to_string()];
    for (inst, expect) in [(x.id, vec!["github"]), (y.id, vec!["bank", "github"])] {
        let got: Vec<String> = w
            .vault_items_for_instance(alice, inst, &want)
            .await
            .unwrap()
            .into_iter()
            .map(|i| i.item.name)
            .collect();
        assert_eq!(got, expect);
    }
    assert!(
        w.vault_items_for_instance(bob, z.id, &want)
            .await
            .unwrap()
            .is_empty()
    );
    assert_eq!(w.user_vault_items(alice).await.unwrap().len(), 2);
    w.touch_vault_items(&[github.id]).await.unwrap();
    w.commit().await.unwrap();

    // 请求：同名的还在等就复用；处理过的不能再处理；过期的读出来是 expired，同名新请求时关掉。
    let req = |name: &str, secs: u64| crate::NewVaultRequest {
        instance_id: x.id,
        run_id: None,
        name: name.into(),
        purpose: "mail".into(),
        fields: vec!["password".into()],
        expires_in: Duration::from_secs(secs),
    };
    let mut a = db.tenant(alice).await.unwrap();
    let (r1, created) = a.create_vault_request(&req("mail", 3600)).await.unwrap();
    assert!(created);
    assert_eq!(r1.status, VaultRequestStatus::Pending);
    let (again, created) = a.create_vault_request(&req("mail", 3600)).await.unwrap();
    assert!(!created);
    assert_eq!(again.id, r1.id);
    let (old, _) = a.create_vault_request(&req("old", 0)).await.unwrap();
    assert_eq!(old.status, VaultRequestStatus::Expired);
    let pending: Vec<String> = a
        .vault_requests(true)
        .await
        .unwrap()
        .into_iter()
        .map(|r| r.name)
        .collect();
    assert_eq!(pending, ["mail"]);
    assert_eq!(a.vault_requests(false).await.unwrap().len(), 2);
    let (old2, created) = a.create_vault_request(&req("old", 3600)).await.unwrap();
    assert!(created && old2.id != old.id);
    assert_eq!(
        a.vault_request(old.id).await.unwrap().status,
        VaultRequestStatus::Expired
    );
    let done = a
        .resolve_vault_request(r1.id, Some(github.id))
        .await
        .unwrap();
    assert_eq!(
        (done.status, done.item_id),
        (VaultRequestStatus::Fulfilled, Some(github.id))
    );
    assert!(matches!(
        a.resolve_vault_request(r1.id, None).await,
        Err(Error::Conflict(_))
    ));
    let declined = a.resolve_vault_request(old2.id, None).await.unwrap();
    assert_eq!(declined.status, VaultRequestStatus::Declined);
    a.commit().await.unwrap();
    let mut b = db.tenant(bob).await.unwrap();
    assert!(b.vault_requests(false).await.unwrap().is_empty());
    b.rollback().await.unwrap();

    // 删除条目：请求里的引用置空。
    let mut a = db.tenant(alice).await.unwrap();
    a.delete_vault_item(github.id).await.unwrap();
    assert!(matches!(
        a.delete_vault_item(github.id).await,
        Err(Error::NotFound)
    ));
    assert_eq!(a.vault_request(r1.id).await.unwrap().item_id, None);
    a.commit().await.unwrap();
}

/// 等 key、等电脑（7.11）：放掉租约等着；唤醒后接着跑不占重试次数；过了最晚的时间交给超时处理。
#[tokio::test]
async fn runs_wait_for_a_key_then_resume_or_time_out() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000021").await;
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "work").await;

    let mut w = db.worker().await.unwrap();
    let claimed = w.claim_next_run("a", LEASE).await.unwrap().unwrap();
    assert_eq!((claimed.run.attempt, claimed.max_attempts), (1, 3));
    w.transition_run(run.id, "a", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    let deadline = Utc::now() + Days::hours(1);
    let waiting = w
        .transition_run(
            run.id,
            "a",
            RunState::WaitingQuota,
            &RunChange {
                reason: Some("key invalid".into()),
                not_before: Some(deadline),
                release_lease: true,
                wait_deadline: Some(deadline),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(waiting.lease_owner, None);
    w.commit().await.unwrap();

    // 等用户换 key：领不到，也没超时。
    let mut w = db.worker().await.unwrap();
    assert!(w.claim_next_run("b", LEASE).await.unwrap().is_none());
    assert!(
        w.claim_expired_waits("b", LEASE, 10)
            .await
            .unwrap()
            .is_empty()
    );
    w.commit().await.unwrap();

    // 换了 key：马上能领（只唤醒等 key 的），接着跑不占重试次数。
    let mut tx = db.tenant(alice).await.unwrap();
    assert_eq!(
        tx.wake_waiting_runs(RunState::WaitingDevice).await.unwrap(),
        0
    );
    assert_eq!(
        tx.wake_waiting_runs(RunState::WaitingQuota).await.unwrap(),
        1
    );
    tx.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let resumed = w.claim_next_run("b", LEASE).await.unwrap().unwrap();
    assert_eq!(
        (
            resumed.run.id,
            resumed.run.state,
            resumed.run.attempt,
            resumed.max_attempts
        ),
        (run.id, RunState::Starting, 2, 4)
    );

    // 又卡住了，而且已经过了最晚的时间：不再领起来，交给超时处理（拿到租约）。
    w.transition_run(run.id, "b", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    let past = Utc::now() - Days::seconds(1);
    w.transition_run(
        run.id,
        "b",
        RunState::WaitingQuota,
        &RunChange {
            not_before: Some(past),
            release_lease: true,
            wait_deadline: Some(past),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(w.claim_next_run("c", LEASE).await.unwrap().is_none());
    let expired = w.claim_expired_waits("c", LEASE, 10).await.unwrap();
    assert_eq!(expired.len(), 1);
    assert_eq!(expired[0].lease_owner.as_deref(), Some("c"));
    w.transition_run(run.id, "c", RunState::Failed, &RunChange::default())
        .await
        .unwrap();
    w.commit().await.unwrap();

    // 模型网关记下的调用结果，新的在前。
    for status in [401u16, 402] {
        let mut w = db.worker().await.unwrap();
        w.insert_usage(&NewUsage {
            user: alice,
            instance: inst.id,
            alias: "main".into(),
            vendor: "anthropic".into(),
            upstream_model: "m".into(),
            endpoint: "messages".into(),
            status,
            outcome: "upstream_status".into(),
            ..NewUsage::default()
        })
        .await
        .unwrap();
        w.commit().await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut w = db.worker().await.unwrap();
    let since = w.db_now().await.unwrap() - Days::minutes(1);
    let calls = w.recent_model_calls(inst.id, since, 10).await.unwrap();
    assert_eq!(
        calls.iter().map(|c| c.status).collect::<Vec<_>>(),
        [402, 401]
    );
    assert!(calls.iter().all(|c| c.outcome == "upstream_status"));
    let later = w.db_now().await.unwrap() + Days::minutes(1);
    assert!(
        w.recent_model_calls(inst.id, later, 10)
            .await
            .unwrap()
            .is_empty()
    );
    w.rollback().await.unwrap();
}

/// 设备中继（14.1）：在线状态、调用的领取和回填、连接被顶掉、断线判失败、消息的方向和投递、
/// 电脑上线唤醒等电脑的运行、中继角色的权限、数据维护。
#[tokio::test]
async fn the_device_relay_routes_calls_and_messages() {
    use proto::domain::{DeviceCallState, DeviceMessageKind, DevicePlatform};

    use crate::{NewDeviceCall, NewLink};

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613900000001").await;
    let bob = user(db, "+8613900000002").await;
    let mut w = db.worker().await.unwrap();
    let mac = w
        .create_device(alice, DevicePlatform::Macos, "MacBook", None)
        .await
        .unwrap();
    let phone = w
        .create_device(alice, DevicePlatform::Ios, "iPhone", None)
        .await
        .unwrap();
    let bob_phone = w
        .create_device(bob, DevicePlatform::Android, "Pixel", None)
        .await
        .unwrap();
    // 有电脑，但还没连上中继。
    assert!(w.has_computer(alice).await.unwrap());
    assert!(!w.has_computer(bob).await.unwrap());
    assert_eq!(w.online_computer(alice).await.unwrap(), None);
    w.commit().await.unwrap();
    let call = |tool: &str| NewDeviceCall {
        user: alice,
        device: mac,
        run: None,
        tool: tool.into(),
        arguments: json!({ "path": "/tmp/a" }),
        timeout: Duration::from_secs(60),
    };

    // 一个运行在等电脑上线（7.11）。
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "整理桌面").await;
    let mut w = db.worker().await.unwrap();
    w.claim_next_run("a", LEASE).await.unwrap().unwrap();
    w.transition_run(run.id, "a", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    let deadline = Utc::now() + Days::hours(1);
    w.transition_run(
        run.id,
        "a",
        RunState::WaitingDevice,
        &RunChange {
            not_before: Some(deadline),
            release_lease: true,
            wait_deadline: Some(deadline),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();

    // 电脑连上中继：在线，等电脑的运行被唤醒。
    let conn1 = uuid::Uuid::now_v7();
    let mut r = db.relay().await.unwrap();
    assert_eq!(
        r.device_platform(mac).await.unwrap(),
        Some((alice, DevicePlatform::Macos, false))
    );
    r.link_device(&NewLink {
        device: mac,
        user: alice,
        node: "relay-1".into(),
        connection: conn1,
    })
    .await
    .unwrap();
    assert!(
        r.set_link_info(mac, conn1, &["fs_read".to_owned()], "1.0.0")
            .await
            .unwrap()
    );
    assert_eq!(r.wake_device_waiters(alice).await.unwrap(), 1);
    assert_eq!(r.wake_device_waiters(bob).await.unwrap(), 0);
    r.commit().await.unwrap();

    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.claim_next_run("b", LEASE)
            .await
            .unwrap()
            .map(|c| c.run.id),
        Some(run.id)
    );
    assert_eq!(
        w.online_computer(alice).await.unwrap(),
        Some((mac, vec!["fs_read".to_owned()]))
    );
    assert_eq!(w.online_computer(bob).await.unwrap(), None);
    let read = w.create_device_call(&call("fs_read")).await.unwrap();
    w.commit().await.unwrap();

    // 中继领走调用、电脑回结果。
    let mut r = db.relay().await.unwrap();
    let claimed = r.claim_device_calls(mac, conn1, 10).await.unwrap();
    assert_eq!(claimed.len(), 1);
    assert_eq!(
        (
            claimed[0].id,
            claimed[0].tool.as_str(),
            &claimed[0].arguments
        ),
        (read, "fs_read", &json!({ "path": "/tmp/a" }))
    );
    assert!(
        r.claim_device_calls(mac, conn1, 10)
            .await
            .unwrap()
            .is_empty()
    );
    let answer = json!({ "content": [{ "type": "text", "text": "hello" }], "is_error": false });
    // 别的连接回不了；结果只收一次。
    assert!(
        !r.finish_device_call(read, mac, uuid::Uuid::now_v7(), &answer)
            .await
            .unwrap()
    );
    assert!(
        r.finish_device_call(read, mac, conn1, &answer)
            .await
            .unwrap()
    );
    assert!(
        !r.finish_device_call(read, mac, conn1, &answer)
            .await
            .unwrap()
    );
    r.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let rec = w.device_call(read).await.unwrap();
    assert_eq!(
        (rec.state, rec.result),
        (DeviceCallState::Done, Some(answer))
    );
    assert!(!w.expire_device_call(read).await.unwrap());
    let lost = w.create_device_call(&call("screenshot")).await.unwrap();
    w.commit().await.unwrap();

    // 调用转出去以后，同一台电脑又连了一次：旧连接被顶掉（心跳刷不上），
    // 旧连接断开时在线状态留给新连接，转给旧连接、没回的调用判失败。
    let mut r = db.relay().await.unwrap();
    assert_eq!(r.claim_device_calls(mac, conn1, 10).await.unwrap().len(), 1);
    let conn2 = uuid::Uuid::now_v7();
    r.link_device(&NewLink {
        device: mac,
        user: alice,
        node: "relay-2".into(),
        connection: conn2,
    })
    .await
    .unwrap();
    assert!(!r.touch_link(mac, conn1).await.unwrap());
    assert!(r.touch_link(mac, conn2).await.unwrap());
    assert_eq!(r.unlink_device(mac, conn1).await.unwrap(), vec![lost]);
    r.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let rec = w.device_call(lost).await.unwrap();
    assert_eq!(rec.state, DeviceCallState::Failed);
    assert!(rec.error.is_some());
    assert_eq!(
        w.online_computer(alice).await.unwrap().map(|c| c.0),
        Some(mac)
    );
    // 平台不等了的调用不再转出。
    let late = w.create_device_call(&call("fs_list")).await.unwrap();
    assert!(w.expire_device_call(late).await.unwrap());
    w.commit().await.unwrap();
    let mut r = db.relay().await.unwrap();
    assert!(
        r.claim_device_calls(mac, conn2, 10)
            .await
            .unwrap()
            .is_empty()
    );
    r.commit().await.unwrap();

    // 手机发给电脑：能力令牌。方向不对、发给自己、发给别人的设备都不行。
    let mut a = db.tenant(alice).await.unwrap();
    let grant = a
        .send_device_message(
            phone,
            mac,
            DeviceMessageKind::Capability,
            &json!({ "g": 1 }),
        )
        .await
        .unwrap();
    assert!(matches!(
        a.send_device_message(phone, mac, DeviceMessageKind::ApprovalRequest, &json!({}))
            .await,
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        a.send_device_message(phone, phone, DeviceMessageKind::Capability, &json!({}))
            .await,
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        a.send_device_message(phone, bob_phone, DeviceMessageKind::Capability, &json!({}))
            .await,
        Err(Error::NotFound)
    ));
    a.commit().await.unwrap();
    // 电脑收到、确认后不再投递；电脑发审批请求给手机，不能发能力令牌。
    let mut r = db.relay().await.unwrap();
    assert_eq!(
        r.pending_device_messages(alice, mac, 10).await.unwrap(),
        vec![grant.clone()]
    );
    assert_eq!(
        r.ack_device_messages(alice, mac, &[grant.id])
            .await
            .unwrap(),
        1
    );
    assert!(
        r.pending_device_messages(alice, mac, 10)
            .await
            .unwrap()
            .is_empty()
    );
    let ask = r
        .send_device_message(
            alice,
            mac,
            phone,
            DeviceMessageKind::ApprovalRequest,
            &json!({ "tool": "rm" }),
        )
        .await
        .unwrap();
    assert!(matches!(
        r.send_device_message(alice, mac, phone, DeviceMessageKind::Capability, &json!({}))
            .await,
        Err(Error::Invalid(_))
    ));
    r.commit().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    assert_eq!(
        a.pending_device_messages(phone, 10).await.unwrap(),
        vec![ask.clone()]
    );
    assert_eq!(a.online_devices().await.unwrap(), vec![mac]);
    assert_eq!(a.ack_device_messages(phone, &[ask.id]).await.unwrap(), 1);
    a.commit().await.unwrap();
    // 别人看不到。
    let mut b = db.tenant(bob).await.unwrap();
    assert!(b.online_devices().await.unwrap().is_empty());
    assert!(b.pending_device_messages(mac, 10).await.unwrap().is_empty());
    b.rollback().await.unwrap();

    // 中继的角色碰不到别的数据。
    for sql in [
        "SELECT count(*) FROM credentials",
        "SELECT refresh_hash FROM sessions",
        "SELECT prompt FROM runs",
        "SELECT phone FROM users",
    ] {
        let mut r = db.relay().await.unwrap();
        let denied = sqlx::query(sql).execute(r.conn()).await;
        assert!(denied.is_err(), "relay can run {sql}");
        r.rollback().await.unwrap();
    }

    // 数据维护：调用、消息、不新鲜的在线状态都清掉。
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.purge_device_traffic(Duration::ZERO).await.unwrap(), 6);
    w.commit().await.unwrap();
}

/// 发布（2.9）：迁移过的库和程序对得上；回滚到上一版（库里有程序不认识的迁移）时照常启动、
/// `migrate` 不报错；少了迁移、改过迁移都拒绝启动。服务角色读得到迁移记录。
#[tokio::test]
async fn builds_check_the_database_migrations() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    assert_eq!(
        db.migration_status().await.unwrap(),
        crate::MigrationStatus::default()
    );

    // 下一版加的迁移，这一版不认识。
    sqlx::query(
        "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) \
         VALUES (99999, 'next release', true, '\\x00', 1)",
    )
    .execute(db.pool())
    .await
    .unwrap();
    db.migrate().await.unwrap();
    let status = db.migration_status().await.unwrap();
    assert_eq!(status.newer, [99999]);
    assert_eq!(status.problem(), None);

    // 服务的登录账号经角色继承读迁移记录。
    for role in ["thinktin_worker", "thinktin_llmgw", "thinktin_relay"] {
        let mut tx = db.pool().begin().await.unwrap();
        sqlx::query(sqlx::AssertSqlSafe(format!("SET LOCAL ROLE {role}")))
            .execute(&mut *tx)
            .await
            .unwrap();
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM _sqlx_migrations")
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        assert!(n > 0, "{role}");
        tx.rollback().await.unwrap();
    }

    // 发布过的迁移被改了、这一版要的迁移还没执行：拒绝启动。
    sqlx::query("UPDATE _sqlx_migrations SET checksum = '\\x01' WHERE version = 1")
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM _sqlx_migrations WHERE version = 16")
        .execute(db.pool())
        .await
        .unwrap();
    let status = db.migration_status().await.unwrap();
    assert_eq!(status.modified, [1]);
    assert_eq!(status.pending, [16]);
    let problem = status.problem().unwrap();
    assert!(problem.contains("missing migrations 16"), "{problem}");
}

#[tokio::test]
async fn im_channels_are_per_user_rate_limited_and_settle_without_spending_attempts() {
    use crate::{ImChannelChange, ImSlot, NewImChannel, NewOutboxItem};
    use proto::domain::{ImChannelId, ImEvent, ImVendor};

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000011").await;
    let bob = user(db, "+8613800000012").await;
    let id = ImChannelId::new();
    let mut tx = db.tenant(alice).await.unwrap();
    let ch = tx
        .create_im_channel(
            &NewImChannel {
                id,
                vendor: ImVendor::Dingtalk,
                label: "运维群".into(),
                sealed: vec![9; 40],
                hint: "…beef".into(),
                has_secret: true,
                events: vec![ImEvent::RunFailed, ImEvent::Approval, ImEvent::RunFailed],
            },
            20,
        )
        .await
        .unwrap();
    assert_eq!(ch.events, vec![ImEvent::Approval, ImEvent::RunFailed]);
    assert!(ch.enabled && ch.last_error.is_none());
    tx.commit().await.unwrap();

    // 别人看不见、改不了、删不掉。
    let mut tx = db.tenant(bob).await.unwrap();
    assert!(tx.im_channels().await.unwrap().is_empty());
    assert!(matches!(tx.im_channel(id).await, Err(Error::NotFound)));
    let change = ImChannelChange {
        label: Some("x".into()),
        ..Default::default()
    };
    assert!(matches!(
        tx.update_im_channel(id, &change).await,
        Err(Error::NotFound)
    ));
    assert!(matches!(
        tx.delete_im_channel(id).await,
        Err(Error::NotFound)
    ));
    assert!(
        tx.im_channels_for(alice, ImEvent::RunFailed)
            .await
            .unwrap()
            .is_empty()
    );
    tx.rollback().await.unwrap();

    // 订了哪些事件就只发哪些；停用的不发。
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.im_channels_for(alice, ImEvent::RunFailed).await.unwrap(),
        vec![id]
    );
    assert!(
        w.im_channels_for(alice, ImEvent::RunFinished)
            .await
            .unwrap()
            .is_empty()
    );
    // 发送节奏：两条之间隔 30 秒，可以连着发两条，第 3 条等到 30 秒后。
    let gap = Duration::from_secs(30);
    assert_eq!(w.take_im_slot(id, gap).await.unwrap(), ImSlot::Go);
    assert_eq!(w.take_im_slot(id, gap).await.unwrap(), ImSlot::Go);
    let ImSlot::Wait(at) = w.take_im_slot(id, gap).await.unwrap() else {
        panic!("not this channel's turn yet")
    };
    let wait = at - Utc::now();
    assert!(
        wait > chrono::Duration::seconds(25) && wait <= chrono::Duration::seconds(30),
        "{wait}"
    );
    // 厂商说限流了：往后推，不会往前挪。
    w.throttle_im_channel(id, Utc::now() + chrono::Duration::minutes(10))
        .await
        .unwrap();
    let ImSlot::Wait(at) = w.take_im_slot(id, gap).await.unwrap() else {
        panic!("throttled")
    };
    assert!(at > Utc::now() + chrono::Duration::minutes(9));
    w.throttle_im_channel(id, Utc::now()).await.unwrap();
    assert!(
        matches!(w.take_im_slot(id, gap).await.unwrap(), ImSlot::Wait(a) if a > Utc::now() + chrono::Duration::minutes(9))
    );
    sqlx::query("UPDATE im_channels SET next_slot_at = NULL WHERE id = $1")
        .bind(id.0)
        .execute(w.conn())
        .await
        .unwrap();
    // 失败：记下原因；机器人没了：停用。只改读的那一刻的行。
    let seen = w.sealed_im_channel(id).await.unwrap().unwrap();
    assert_eq!(seen.user_id, alice);
    assert_eq!((seen.sealed.clone(), seen.webhook_rev), (vec![9; 40], 0));
    assert!(
        !w.record_im_result(id, seen.webhook_rev, Some("sign not match"), false)
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    let mut tx = db.tenant(alice).await.unwrap();
    let got = tx.im_channel(id).await.unwrap();
    assert_eq!(got.last_error.as_deref(), Some("sign not match"));
    assert!(got.enabled);
    // 换了地址：错误清掉；换成别家的地址不行。
    let rotated = tx
        .update_im_channel(
            id,
            &ImChannelChange {
                webhook: Some((ImVendor::Dingtalk, vec![7; 40], "…cafe".into(), false)),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(
        (
            rotated.hint.as_str(),
            rotated.has_secret,
            rotated.last_error
        ),
        ("…cafe", false, None)
    );
    let other_vendor = ImChannelChange {
        webhook: Some((ImVendor::Wecom, vec![1], "…0000".into(), false)),
        ..Default::default()
    };
    assert!(matches!(
        tx.update_im_channel(id, &other_vendor).await,
        Err(Error::Invalid(_))
    ));
    tx.commit().await.unwrap();
    // 用户换地址之前读到的旧行，结果不能停掉新地址；改名字、改事件不影响记结果。
    let mut tx = db.tenant(alice).await.unwrap();
    tx.update_im_channel(
        id,
        &ImChannelChange {
            label: Some("值班群".into()),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(
        !w.record_im_result(id, seen.webhook_rev, Some("token is not exist"), true)
            .await
            .unwrap()
    );
    let now = w.sealed_im_channel(id).await.unwrap().unwrap();
    assert!(now.channel.enabled && now.channel.last_error.is_none());
    assert_eq!(now.webhook_rev, 1);
    assert!(
        !w.record_im_result(id, now.webhook_rev, None, false)
            .await
            .unwrap()
    );
    assert!(
        w.record_im_result(id, now.webhook_rev, Some("token is not exist"), true)
            .await
            .unwrap(),
        "turned off"
    );
    assert!(
        !w.record_im_result(id, now.webhook_rev, Some("token is not exist"), true)
            .await
            .unwrap(),
        "already off"
    );
    let off = w.sealed_im_channel(id).await.unwrap().unwrap();
    assert!(!off.channel.enabled && off.channel.last_sent_at.is_some());
    assert_eq!(w.take_im_slot(id, gap).await.unwrap(), ImSlot::Gone);
    assert!(
        w.im_channels_for(alice, ImEvent::RunFailed)
            .await
            .unwrap()
            .is_empty()
    );

    // 出箱：只领会处理的种类；自己的限流推后不算一次尝试。
    for kind in ["im", "future-kind"] {
        w.enqueue_outbox(
            alice,
            &NewOutboxItem {
                kind: kind.into(),
                payload: json!({}),
                dedupe_key: None,
                available_at: None,
            },
        )
        .await
        .unwrap();
    }
    let got = w
        .claim_outbox_of("n1", Duration::from_secs(60), 10, Some(&["push", "im"]))
        .await
        .unwrap();
    assert_eq!(
        got.iter().map(|i| i.kind.as_str()).collect::<Vec<_>>(),
        vec!["im"]
    );
    assert_eq!(got[0].attempts, 1);
    w.defer_outbox(
        got[0].id,
        "n1",
        "rate limited",
        Utc::now() - chrono::Duration::seconds(1),
    )
    .await
    .unwrap();
    let again = w
        .claim_outbox_of("n1", Duration::from_secs(60), 10, Some(&["im"]))
        .await
        .unwrap();
    assert_eq!((again.len(), again[0].attempts), (1, 1));
    assert!(matches!(
        w.defer_outbox(again[0].id, "someone-else", "x", Utc::now())
            .await,
        Err(Error::LeaseLost { .. })
    ));
    w.commit().await.unwrap();

    // 停用后换上新地址：重新打开，错误清掉。
    let mut tx = db.tenant(alice).await.unwrap();
    let back = tx
        .update_im_channel(
            id,
            &ImChannelChange {
                webhook: Some((ImVendor::Dingtalk, vec![5; 40], "…f00d".into(), true)),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert!(back.enabled && back.last_error.is_none());
    // 用户自己关掉的：换了地址还是关着，自己打开才发。
    let off = ImChannelChange {
        enabled: Some(false),
        ..Default::default()
    };
    assert!(!tx.update_im_channel(id, &off).await.unwrap().enabled);
    let rotate = ImChannelChange {
        webhook: Some((ImVendor::Dingtalk, vec![5; 40], "…f00d".into(), true)),
        ..Default::default()
    };
    assert!(!tx.update_im_channel(id, &rotate).await.unwrap().enabled);
    let on = ImChannelChange {
        enabled: Some(true),
        ..Default::default()
    };
    assert!(tx.update_im_channel(id, &on).await.unwrap().enabled);
    tx.commit().await.unwrap();

    // IM 条目按渠道排队：每个渠道只领最早的一条；推后的那条挡着后面的；渠道删了一起放弃。
    let other = ImChannelId::new();
    let mut w = db.worker().await.unwrap();
    for (ch, n) in [(id, 3), (other, 1)] {
        for _ in 0..n {
            w.enqueue_outbox(
                alice,
                &NewOutboxItem {
                    kind: "im".into(),
                    payload: json!({ "channel": ch, "message": {} }),
                    dedupe_key: None,
                    available_at: None,
                },
            )
            .await
            .unwrap();
        }
    }
    let heads = w
        .claim_im_outbox("n1", Duration::from_secs(60), 10)
        .await
        .unwrap();
    let chans: Vec<String> = heads
        .iter()
        .map(|i| i.payload["channel"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        chans,
        vec![id.to_string(), other.to_string()],
        "one head per channel"
    );
    assert!(
        w.claim_im_outbox("n1", Duration::from_secs(60), 10)
            .await
            .unwrap()
            .is_empty(),
        "heads in flight block the rest"
    );
    w.defer_outbox(
        heads[0].id,
        "n1",
        "not yet",
        Utc::now() + chrono::Duration::minutes(5),
    )
    .await
    .unwrap();
    assert!(
        w.claim_im_outbox("n1", Duration::from_secs(60), 10)
            .await
            .unwrap()
            .is_empty(),
        "a deferred head blocks the rest"
    );
    assert_eq!(
        w.drop_im_backlog(id, "im channel deleted").await.unwrap(),
        3
    );
    assert_eq!(
        w.drop_im_backlog(other, "x").await.unwrap(),
        0,
        "rows in flight are left to their holder"
    );
    // 失败重试中的排在新条目后面领：出故障的那一家占不满发送的名额。
    w.retry_outbox(
        heads[1].id,
        "n1",
        "timed out",
        Utc::now() - chrono::Duration::minutes(1),
    )
    .await
    .unwrap();
    let third = ImChannelId::new();
    w.enqueue_outbox(
        alice,
        &NewOutboxItem {
            kind: "im".into(),
            payload: json!({ "channel": third, "message": {} }),
            dedupe_key: None,
            available_at: None,
        },
    )
    .await
    .unwrap();
    let first = w
        .claim_im_outbox("n1", Duration::from_secs(60), 1)
        .await
        .unwrap();
    assert_eq!(first[0].payload["channel"], json!(third));
    let next = w
        .claim_im_outbox("n1", Duration::from_secs(60), 1)
        .await
        .unwrap();
    assert_eq!((next[0].id, next[0].attempts), (heads[1].id, 2));
    w.commit().await.unwrap();

    let mut tx = db.tenant(alice).await.unwrap();
    tx.delete_im_channel(id).await.unwrap();
    assert!(matches!(
        tx.delete_im_channel(id).await,
        Err(Error::NotFound)
    ));
    assert_eq!(tx.im_channel_count().await.unwrap(), 0);
    tx.commit().await.unwrap();

    // 上限：并发的新建请求一起也不能超过。
    let mut joins = Vec::new();
    for i in 0..12 {
        let db = db.clone();
        joins.push(tokio::spawn(async move {
            let mut tx = db.tenant(alice).await.unwrap();
            let r = tx
                .create_im_channel(
                    &NewImChannel {
                        id: ImChannelId::new(),
                        vendor: ImVendor::Wecom,
                        label: format!("群 {i}"),
                        sealed: vec![1; 40],
                        hint: "…0001".into(),
                        has_secret: false,
                        events: vec![ImEvent::RunFinished],
                    },
                    5,
                )
                .await;
            if r.is_ok() {
                tx.commit().await.unwrap();
            }
            r.is_ok()
        }));
    }
    let mut created = 0;
    for j in joins {
        created += usize::from(j.await.unwrap());
    }
    assert_eq!(created, 5);
    let mut tx = db.tenant(alice).await.unwrap();
    assert_eq!(tx.im_channel_count().await.unwrap(), 5);
}
