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
                bot_tag: [1; 32],
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
    // 超过 3 个、或者新引用停用的 key：整体拒绝，原来的不变。
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
    let idle = a.create_credential(&credential("0004")).await.unwrap();
    a.set_credential_disabled(idle.id, true).await.unwrap();
    let err = a
        .set_model_routes(
            inst.id,
            &[ModelRoute {
                fallbacks: vec![fb(&idle, "m")],
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

/// key 的每日上限可以改、可以取消（11.9）；0、太大的不行；别人的、删了的找不到。
#[tokio::test]
async fn credential_daily_limit_can_be_changed_and_cleared() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let bob = user(db, "+8613800000002").await;
    let mut a = db.tenant(alice).await.unwrap();
    let id = a.create_credential(&credential("0001")).await.unwrap().id;
    assert_eq!(
        a.set_credential_daily_limit(id, Some(5)).await.unwrap(),
        Some(1_000_000)
    );
    assert_eq!(a.credential(id).await.unwrap().daily_token_limit, Some(5));
    assert_eq!(
        a.set_credential_daily_limit(id, None).await.unwrap(),
        Some(5)
    );
    assert_eq!(a.credential(id).await.unwrap().daily_token_limit, None);
    assert_eq!(
        a.set_credential_daily_limit(id, Some(7)).await.unwrap(),
        None
    );
    a.commit().await.unwrap();
    // 模型网关读到新的上限。
    let mut w = db.worker().await.unwrap();
    let sealed = w.sealed_credential(id).await.unwrap().unwrap();
    w.rollback().await.unwrap();
    assert_eq!(sealed.daily_token_limit, Some(7));
    for bad in [0, u64::MAX] {
        let mut a = db.tenant(alice).await.unwrap();
        assert!(matches!(
            a.set_credential_daily_limit(id, Some(bad)).await,
            Err(Error::Invalid(_))
        ));
        a.rollback().await.unwrap();
    }
    let mut b = db.tenant(bob).await.unwrap();
    assert!(matches!(
        b.set_credential_daily_limit(id, Some(1)).await,
        Err(Error::NotFound)
    ));
    b.rollback().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    a.delete_credential(id).await.unwrap();
    assert!(matches!(
        a.set_credential_daily_limit(id, Some(1)).await,
        Err(Error::NotFound)
    ));
    a.rollback().await.unwrap();
}

/// 停用的 key（11.9）：实例原来就用着的可以留在别名里（网关照样跳过它），所以从别名里去掉别的 key 能保存；
/// 新引用停用的 key（包括别的实例用着的）照样拒绝。
#[tokio::test]
async fn disabled_keys_can_stay_in_routes_but_not_be_added() {
    use proto::domain::RouteFallback;

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let (inst, other) = (instance(db, alice).await, instance(db, alice).await);
    let mut a = db.tenant(alice).await.unwrap();
    let mut k = Vec::new();
    for n in 1..=5 {
        k.push(
            a.create_credential(&credential(&format!("000{n}")))
                .await
                .unwrap()
                .id,
        );
    }
    let (ka, kb, kc, kd, ke) = (k[0], k[1], k[2], k[3], k[4]);
    let route = |alias: &str, main, fallbacks: &[proto::domain::CredentialId]| ModelRoute {
        alias: alias.into(),
        credential_id: main,
        upstream_model: "m".into(),
        fallbacks: fallbacks
            .iter()
            .map(|c| RouteFallback {
                credential_id: *c,
                upstream_model: "m".into(),
            })
            .collect(),
    };
    a.set_model_routes(inst.id, &[route("main", ka, &[kb]), route("fast", kc, &[])])
        .await
        .unwrap();
    a.set_model_routes(other.id, &[route("main", ke, &[])])
        .await
        .unwrap();
    a.set_credential_disabled(ka, true).await.unwrap();
    a.set_credential_disabled(ke, true).await.unwrap();
    a.commit().await.unwrap();

    // App 删 B 之前先把它从别名里去掉：A 停用着也照样保存，之后 B 能删。
    let mut a = db.tenant(alice).await.unwrap();
    let kept = [route("fast", kc, &[]), route("main", ka, &[])];
    a.set_model_routes(inst.id, &kept).await.unwrap();
    assert_eq!(a.model_routes(inst.id).await.unwrap(), kept);
    a.delete_credential(kb).await.unwrap();
    // 留着的 key 换位置也行（从主路由挪到降级链）。
    a.set_model_routes(inst.id, &[route("main", kc, &[ka])])
        .await
        .unwrap();
    a.commit().await.unwrap();
    // 网关读到的照样有它（跳过停用的 key 是网关的事）。
    let mut g = db.llmgw().await.unwrap();
    let gi = g.gateway_instance(inst.id).await.unwrap().unwrap();
    g.rollback().await.unwrap();
    assert_eq!(gi.routes[0].fallbacks, vec![(ka, "m".to_string())]);

    // 没在用的停用 key、别的实例用着的停用 key：不能新引用，原来的不变。
    let mut a = db.tenant(alice).await.unwrap();
    a.set_credential_disabled(kd, true).await.unwrap();
    a.commit().await.unwrap();
    for (main, fbs) in [(kd, vec![]), (kc, vec![kd]), (ke, vec![])] {
        let mut a = db.tenant(alice).await.unwrap();
        let err = a
            .set_model_routes(inst.id, &[route("main", main, &fbs)])
            .await
            .unwrap_err();
        assert!(matches!(err, Error::Invalid(_)), "{err:?}");
        a.rollback().await.unwrap();
    }
    // 去掉以后就不算原来用着的了：再加回来也拒绝。
    let mut a = db.tenant(alice).await.unwrap();
    a.set_model_routes(inst.id, &[route("main", kc, &[])])
        .await
        .unwrap();
    a.commit().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    assert!(matches!(
        a.set_model_routes(inst.id, &[route("main", kc, &[ka])])
            .await
            .unwrap_err(),
        Error::Invalid(_)
    ));
    a.rollback().await.unwrap();
    let mut a = db.tenant(alice).await.unwrap();
    assert_eq!(
        a.model_routes(inst.id).await.unwrap(),
        [route("main", kc, &[])]
    );
    a.rollback().await.unwrap();
}

/// 已删除的实例的别名不再占着 key（11.9）：删除实例时别名和降级链一起删；之前留下的删 key 时也不算。
#[tokio::test]
async fn deleted_instances_do_not_hold_keys() {
    use proto::domain::RouteFallback;

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let (gone, legacy, live) = (
        instance(db, alice).await,
        instance(db, alice).await,
        instance(db, alice).await,
    );
    let mut a = db.tenant(alice).await.unwrap();
    let mut keys = Vec::new();
    for n in 1..=5 {
        keys.push(
            a.create_credential(&credential(&format!("000{n}")))
                .await
                .unwrap(),
        );
    }
    let route = |main: usize, fallback: Option<usize>| ModelRoute {
        alias: "main".into(),
        credential_id: keys[main].id,
        upstream_model: "m".into(),
        fallbacks: fallback
            .map(|f| {
                vec![RouteFallback {
                    credential_id: keys[f].id,
                    upstream_model: "m".into(),
                }]
            })
            .unwrap_or_default(),
    };
    a.set_model_routes(gone.id, &[route(0, Some(1))])
        .await
        .unwrap();
    a.set_model_routes(legacy.id, &[route(2, Some(3))])
        .await
        .unwrap();
    a.set_model_routes(live.id, &[route(4, None)])
        .await
        .unwrap();
    a.commit().await.unwrap();

    let count = |table: &'static str, inst: proto::domain::InstanceId| async move {
        let sql = match table {
            "model_routes" => "SELECT count(*) FROM model_routes WHERE instance_id = $1",
            _ => "SELECT count(*) FROM model_route_fallbacks WHERE instance_id = $1",
        };
        sqlx::query_scalar::<_, i64>(sql)
            .bind(inst.0)
            .fetch_one(db.pool())
            .await
            .unwrap()
    };
    // 删除实例：别名和降级链一起删掉，它们指着的 key 可以删了。
    let mut a = db.tenant(alice).await.unwrap();
    a.delete_instance(gone.id).await.unwrap();
    a.commit().await.unwrap();
    assert_eq!(
        (
            count("model_routes", gone.id).await,
            count("model_route_fallbacks", gone.id).await
        ),
        (0, 0)
    );
    // 之前的版本删除实例时不删别名：留下的不算引用。
    sqlx::query("UPDATE instances SET state = 'deleted', deleted_at = now() WHERE id = $1")
        .bind(legacy.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert_eq!(count("model_routes", legacy.id).await, 1);
    let mut a = db.tenant(alice).await.unwrap();
    for k in &keys[..4] {
        a.delete_credential(k.id).await.unwrap();
    }
    // 还在用的实例的别名照样占着。
    assert!(
        a.delete_credential(keys[4].id)
            .await
            .unwrap_err()
            .is_conflict()
    );
    // 已删除的实例的别名看不到也改不了。
    assert!(matches!(
        a.model_routes(gone.id).await,
        Err(Error::NotFound)
    ));
    assert!(matches!(
        a.set_model_routes(legacy.id, &[]).await,
        Err(Error::NotFound)
    ));
    a.commit().await.unwrap();
}

/// 删除实例时一并处理它的计划（11.9）：它自己的计划标记删除、触发器停掉；别的实例的流水线有一步在它上面的暂停，
/// 改了步骤才能恢复；别的计划不动。
#[tokio::test]
async fn deleting_an_instance_retires_its_plans() {
    use proto::domain::{PlanId, PlanStep};

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000001").await;
    let (x, y) = (instance(db, alice).await, instance(db, alice).await);
    let mut a = db.tenant(alice).await.unwrap();
    let plan = |instance: &Instance, title: &str| NewPlan {
        instance_id: instance.id,
        title: title.into(),
        goal: "g".into(),
        policy: PlanPolicy::default(),
        catch_up: CatchUp::Once,
        created_by: PlanAuthor::User,
        run_grant_id: None,
    };
    let cron = ScheduleSpec::Cron {
        expr: "0 8 * * *".into(),
        tz: "Asia/Shanghai".into(),
    };
    let soon = Utc::now() - Days::minutes(1);
    let later = Utc::now() + Days::days(1);
    let px = a.create_plan(&plan(&x, "x 自己的")).await.unwrap();
    a.add_trigger(px.id, &cron, Some(soon)).await.unwrap();
    let px2 = a.create_plan(&plan(&x, "x 的第二个")).await.unwrap();
    let py = a.create_plan(&plan(&y, "y 上有一步在 x")).await.unwrap();
    a.set_plan_steps(
        py.id,
        &[PlanStep {
            key: "a".into(),
            instance_id: x.id,
            prompt: "p".into(),
            depends_on: vec![],
        }],
    )
    .await
    .unwrap();
    a.add_trigger(py.id, &cron, Some(soon)).await.unwrap();
    let pz = a.create_plan(&plan(&y, "y 自己的")).await.unwrap();
    a.add_trigger(pz.id, &cron, Some(later)).await.unwrap();
    a.commit().await.unwrap();

    let mut a = db.tenant(alice).await.unwrap();
    let retired = a.retire_instance_plans(x.id).await.unwrap();
    a.delete_instance(x.id).await.unwrap();
    a.commit().await.unwrap();
    let mut deleted = retired.deleted.clone();
    deleted.sort_by_key(|p| p.0);
    let mut want = vec![px.id, px2.id];
    want.sort_by_key(|p| p.0);
    assert_eq!((deleted, retired.paused), (want, vec![py.id]));

    let mut a = db.tenant(alice).await.unwrap();
    // 同一个事务里建的计划创建时间一样：按 id 比。
    let mut listed: Vec<(PlanId, bool)> = a
        .plans(None)
        .await
        .unwrap()
        .into_iter()
        .map(|p| (p.id, p.paused))
        .collect();
    listed.sort_by_key(|(id, _)| id.0);
    let mut want = vec![(py.id, true), (pz.id, false)];
    want.sort_by_key(|(id, _)| id.0);
    assert_eq!(listed, want);
    assert!(a.plans(Some(x.id)).await.unwrap().is_empty());
    assert!(matches!(a.plan(px.id).await, Err(Error::NotFound)));
    assert!(a.triggers(px.id).await.unwrap().iter().all(|t| !t.enabled));
    assert_eq!(a.deleted_step(py.id).await.unwrap().as_deref(), Some("a"));
    assert_eq!(a.deleted_step(pz.id).await.unwrap(), None);
    // 再来一次什么都不变。
    assert_eq!(
        a.retire_instance_plans(x.id).await.unwrap(),
        crate::RetiredPlans::default()
    );
    a.rollback().await.unwrap();
    // 只剩 y 自己的计划会触发。
    let mut w = db.worker().await.unwrap();
    let due: Vec<PlanId> = w
        .due_triggers(Utc::now() + Days::days(2), 100)
        .await
        .unwrap()
        .into_iter()
        .map(|d| d.plan.id)
        .collect();
    w.rollback().await.unwrap();
    assert_eq!(due, [pz.id]);
}

/// 接口删除实例的那几步（gateway routes/instances.rs）。
async fn delete_instance_like_the_api(
    db: Db,
    user: UserId,
    id: proto::domain::InstanceId,
) -> crate::Result<crate::RetiredPlans> {
    let mut t = db.tenant(user).await?;
    t.instance(id).await?;
    let retired = t.retire_instance_plans(id).await?;
    t.cancel_instance_runs(id, "instance deleted").await?;
    t.revoke_instance_grants(id, "instance deleted").await?;
    t.delete_instance(id).await?;
    t.commit().await?;
    Ok(retired)
}

fn plan_on(instance: &Instance) -> NewPlan {
    NewPlan {
        instance_id: instance.id,
        title: "t".into(),
        goal: "g".into(),
        policy: PlanPolicy::default(),
        catch_up: CatchUp::Once,
        created_by: PlanAuthor::User,
        run_grant_id: None,
    }
}

fn step_on(instance: &Instance) -> proto::domain::PlanStep {
    proto::domain::PlanStep {
        key: "a".into(),
        instance_id: instance.id,
        prompt: "p".into(),
        depends_on: vec![],
    }
}

/// 删除实例和删除、恢复计划同时发生，两个互相有一步在对方上的实例同时删除（11.9）：锁的顺序一样（计划 →
/// 触发器，计划按 id），不会死锁成 500。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deleting_instances_and_plans_together_does_not_deadlock() {
    let Some(t) = TestDb::new().await else { return };
    let db = t.db.clone();
    let alice = user(&db, "+8613800000001").await;
    let cron = ScheduleSpec::Cron {
        expr: "0 8 * * *".into(),
        tz: "Asia/Shanghai".into(),
    };
    let later = Utc::now() + Days::days(1);

    // 删除计划、恢复计划的请求先锁住计划，再动它的触发器；删除实例这时开始，等它提交。
    for resume in [false, true] {
        let x = instance(&db, alice).await;
        let mut a = db.tenant(alice).await.unwrap();
        let p = a.create_plan(&plan_on(&x)).await.unwrap();
        let trigger = a.add_trigger(p.id, &cron, Some(later)).await.unwrap();
        a.commit().await.unwrap();
        let mut r = db.tenant(alice).await.unwrap();
        r.set_plan_paused(p.id, !resume).await.unwrap();
        let d = tokio::spawn(delete_instance_like_the_api(db.clone(), alice, x.id));
        tokio::time::sleep(Duration::from_millis(200)).await;
        if resume {
            r.set_trigger_enabled(trigger.id, true, Some(later))
                .await
                .unwrap();
        } else {
            r.delete_plan(p.id).await.unwrap();
        }
        r.commit().await.unwrap();
        let retired = d.await.unwrap().unwrap();
        assert_eq!(retired.deleted.is_empty(), !resume, "{retired:?}");
        let mut a = db.tenant(alice).await.unwrap();
        assert!(matches!(a.plan(p.id).await, Err(Error::NotFound)));
        assert!(a.triggers(p.id).await.unwrap().iter().all(|t| !t.enabled));
        a.rollback().await.unwrap();
    }

    // x 的流水线有一步在 y 上，y 的有一步在 x 上，两个同时删除。
    for _ in 0..10 {
        let (x, y) = (instance(&db, alice).await, instance(&db, alice).await);
        let mut a = db.tenant(alice).await.unwrap();
        let px = a.create_plan(&plan_on(&x)).await.unwrap();
        a.set_plan_steps(px.id, &[step_on(&y)]).await.unwrap();
        let py = a.create_plan(&plan_on(&y)).await.unwrap();
        a.set_plan_steps(py.id, &[step_on(&x)]).await.unwrap();
        a.commit().await.unwrap();
        let (rx, ry) = tokio::join!(
            tokio::spawn(delete_instance_like_the_api(db.clone(), alice, x.id)),
            tokio::spawn(delete_instance_like_the_api(db.clone(), alice, y.id)),
        );
        rx.unwrap().unwrap();
        ry.unwrap().unwrap();
        let mut a = db.tenant(alice).await.unwrap();
        assert!(matches!(a.plan(px.id).await, Err(Error::NotFound)));
        assert!(matches!(a.plan(py.id).await, Err(Error::NotFound)));
        a.rollback().await.unwrap();
    }
}

async fn blocked<T>(h: &tokio::task::JoinHandle<T>) {
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!h.is_finished(), "should wait for the other transaction");
}

/// 恢复、确认前查步骤，改步骤时查实例，都和删除实例互斥（11.9）：先查的那边提交以后删除才处理计划（暂停刚恢复的、
/// 刚加了它上面的步骤的流水线）；删除先开始的，查的那边等它提交，看到实例已经删了。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn plan_step_checks_and_instance_deletion_take_turns() {
    let Some(t) = TestDb::new().await else { return };
    let db = t.db.clone();
    let alice = user(&db, "+8613800000001").await;
    let y = instance(&db, alice).await;
    let paused_pipeline = |x: Instance| {
        let db = db.clone();
        let y = y.clone();
        async move {
            let mut a = db.tenant(alice).await.unwrap();
            let p = a.create_plan(&plan_on(&y)).await.unwrap();
            a.set_plan_steps(p.id, &[step_on(&x)]).await.unwrap();
            a.set_plan_paused(p.id, true).await.unwrap();
            a.commit().await.unwrap();
            p.id
        }
    };

    // 恢复先查过步骤：删除等它提交，再把它暂停。
    let x = instance(&db, alice).await;
    let p = paused_pipeline(x.clone()).await;
    let mut r = db.tenant(alice).await.unwrap();
    assert_eq!(r.deleted_step(p).await.unwrap(), None);
    let d = tokio::spawn(delete_instance_like_the_api(db.clone(), alice, x.id));
    blocked(&d).await;
    r.set_plan_paused(p, false).await.unwrap();
    r.commit().await.unwrap();
    assert_eq!(d.await.unwrap().unwrap().paused, [p]);
    let mut a = db.tenant(alice).await.unwrap();
    assert!(a.plan(p).await.unwrap().paused);
    a.rollback().await.unwrap();

    // 删除先开始：恢复等它提交，看到那一步的实例删了。
    let x = instance(&db, alice).await;
    let p = paused_pipeline(x.clone()).await;
    let mut d = db.tenant(alice).await.unwrap();
    assert_eq!(d.retire_instance_plans(x.id).await.unwrap().paused, []);
    d.delete_instance(x.id).await.unwrap();
    let r = tokio::spawn({
        let db = db.clone();
        async move {
            let mut r = db.tenant(alice).await.unwrap();
            r.deleted_step(p).await
        }
    });
    blocked(&r).await;
    d.commit().await.unwrap();
    assert_eq!(r.await.unwrap().unwrap().as_deref(), Some("a"));

    // 改步骤先查过实例：删除等它提交，再暂停这个在跑的流水线。
    let x = instance(&db, alice).await;
    let mut a = db.tenant(alice).await.unwrap();
    let p = a.create_plan(&plan_on(&y)).await.unwrap().id;
    a.commit().await.unwrap();
    let mut s = db.tenant(alice).await.unwrap();
    s.set_plan_steps(p, &[step_on(&x)]).await.unwrap();
    let d = tokio::spawn(delete_instance_like_the_api(db.clone(), alice, x.id));
    blocked(&d).await;
    s.commit().await.unwrap();
    assert_eq!(d.await.unwrap().unwrap().paused, [p]);

    // 删除先开始：改步骤等它提交，实例已经删了。
    let x = instance(&db, alice).await;
    let mut d = db.tenant(alice).await.unwrap();
    d.retire_instance_plans(x.id).await.unwrap();
    d.delete_instance(x.id).await.unwrap();
    let s = tokio::spawn({
        let db = db.clone();
        let x = x.clone();
        async move {
            let mut s = db.tenant(alice).await.unwrap();
            s.set_plan_steps(p, &[step_on(&x)]).await
        }
    });
    blocked(&s).await;
    d.commit().await.unwrap();
    assert!(matches!(s.await.unwrap(), Err(Error::NotFound)));
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
    // 请求的提醒（10.7）：处理完算已读；子类型的格式不对的写不进去。
    let notice = |vault_request_id, subtype: Option<&str>| NewInboxItem {
        kind: "vault_request".into(),
        title: "填一下".into(),
        vault_request_id,
        subtype: subtype.map(Into::into),
        ..Default::default()
    };
    let user = a.user();
    a.insert_inbox(user, &notice(Some(r1.id), None))
        .await
        .unwrap();
    assert!(matches!(
        a.insert_inbox(user, &notice(None, Some("Bad-Kind"))).await,
        Err(Error::Invalid(_))
    ));
    let done = a
        .resolve_vault_request(r1.id, Some(github.id))
        .await
        .unwrap();
    assert_eq!(
        (done.status, done.item_id),
        (VaultRequestStatus::Fulfilled, Some(github.id))
    );
    let inbox = a.inbox(None, 10, false).await.unwrap();
    assert_eq!(
        (inbox.len(), inbox[0].vault_request_id, inbox[0].read),
        (1, Some(r1.id), true)
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
                wait_code: Some("invalid"),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(waiting.lease_owner, None);
    assert_eq!(waiting.run.wait_code.as_deref(), Some("invalid"));
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
    // 领起来就清掉（不只是读的时候看不到）。
    assert_eq!(resumed.run.wait_code, None);
    let stored: Option<String> = sqlx::query_scalar("SELECT wait_code FROM runs WHERE id = $1")
        .bind(run.id.0)
        .fetch_one(w.conn())
        .await
        .unwrap();
    assert_eq!(stored, None);

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
    use crate::{ImChannelChange, ImSlot, ImWebhook, NewImChannel, NewOutboxItem};
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
                bot_tag: [2; 32],
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

    // 同一个人不能把同一个群机器人绑两次；别人绑了同一个机器人可以，发送节奏合在一起算（见下）。
    let same_bot = |id| NewImChannel {
        id,
        vendor: ImVendor::Dingtalk,
        label: String::new(),
        sealed: vec![8; 40],
        hint: "…beef".into(),
        has_secret: false,
        bot_tag: [2; 32],
        events: vec![ImEvent::RunFailed],
    };
    let mut tx = db.tenant(alice).await.unwrap();
    assert!(matches!(
        tx.create_im_channel(&same_bot(ImChannelId::new()), 20)
            .await,
        Err(Error::Conflict(_))
    ));
    tx.rollback().await.unwrap();
    let bobs = ImChannelId::new();
    let mut tx = db.tenant(bob).await.unwrap();
    tx.create_im_channel(&same_bot(bobs), 20).await.unwrap();
    tx.commit().await.unwrap();

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
    assert!(
        matches!(w.take_im_slot(bobs, gap).await.unwrap(), ImSlot::Wait(a) if a == at),
        "the same bot bound by someone else shares the pace"
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
    sqlx::query("DELETE FROM im_bot_slots")
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
                webhook: Some(ImWebhook {
                    vendor: ImVendor::Dingtalk,
                    sealed: vec![7; 40],
                    hint: "…cafe".into(),
                    has_secret: false,
                    bot_tag: [3; 32],
                }),
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
        webhook: Some(ImWebhook {
            vendor: ImVendor::Wecom,
            sealed: vec![1],
            hint: "…0000".into(),
            has_secret: false,
            bot_tag: [4; 32],
        }),
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
                webhook: Some(ImWebhook {
                    vendor: ImVendor::Dingtalk,
                    sealed: vec![5; 40],
                    hint: "…f00d".into(),
                    has_secret: true,
                    bot_tag: [5; 32],
                }),
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
        webhook: Some(ImWebhook {
            vendor: ImVendor::Dingtalk,
            sealed: vec![5; 40],
            hint: "…f00d".into(),
            has_secret: true,
            bot_tag: [5; 32],
        }),
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
    for i in 0..12u8 {
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
                        bot_tag: [100 + i; 32],
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

async fn claim_live(db: &Db, owner: &str, step_gap: Duration) -> Vec<crate::LiveActivity> {
    let mut w = db.worker().await.unwrap();
    let got = w
        .claim_live_activities(owner, LEASE, 10, 10, Duration::ZERO, step_gap)
        .await
        .unwrap();
    w.commit().await.unwrap();
    got
}

async fn settle_live(db: &Db, a: &crate::LiveActivity, owner: &str, s: crate::LiveSettle) {
    let mut w = db.worker().await.unwrap();
    w.settle_live_activity(a.device_id, a.run_id, owner, a.push_token.as_deref(), &s)
        .await
        .unwrap();
    w.commit().await.unwrap();
}

#[tokio::test]
async fn live_activities_follow_their_runs_per_device() {
    use crate::LiveSettle;
    use proto::domain::{DevicePlatform, RunState, SessionId};
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000051").await;
    let bob = user(db, "+8613800000052").await;
    let hour = Duration::from_secs(3600);
    let minute = Duration::from_secs(60);
    let mut w = db.worker().await.unwrap();
    let phone = w
        .create_device(alice, DevicePlatform::Ios, "iPhone", None)
        .await
        .unwrap();
    w.create_session(SessionId::new(), alice, phone, b"r1", hour)
        .await
        .unwrap();
    let mac = w
        .create_device(alice, DevicePlatform::Macos, "Mac", None)
        .await
        .unwrap();
    w.create_session(SessionId::new(), alice, mac, b"r2", hour)
        .await
        .unwrap();
    let bobs = w
        .create_device(bob, DevicePlatform::Ios, "iPhone", None)
        .await
        .unwrap();
    w.create_session(SessionId::new(), bob, bobs, b"r3", hour)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "整理邮件").await;
    let set_run = |state: &'static str, steps: i32| {
        let pool = db.pool().clone();
        async move {
            sqlx::query("UPDATE runs SET state = $2, steps = $3 WHERE id = $1")
                .bind(run.id.0)
                .bind(state)
                .bind(steps)
                .execute(&pool)
                .await
                .unwrap();
        }
    };

    // App 开的：登记令牌。只有 iPhone、iPad 有；别人的运行登记不了。
    let mut tx = db.tenant(alice).await.unwrap();
    tx.register_live_activity(phone, run.id, "aa11", 5)
        .await
        .unwrap();
    assert!(matches!(
        tx.register_live_activity(mac, run.id, "bb22", 5).await,
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        tx.set_activity_start_token(mac, Some("cc33")).await,
        Err(Error::Invalid(_))
    ));
    tx.commit().await.unwrap();
    let mut tx = db.tenant(bob).await.unwrap();
    assert!(matches!(
        tx.register_live_activity(bobs, run.id, "dd44", 5).await,
        Err(Error::NotFound)
    ));
    tx.rollback().await.unwrap();

    // 还没发过：领得到，带着运行现在的样子；锁着的别人领不到。
    let got = claim_live(db, "n1", minute).await;
    assert_eq!(got.len(), 1);
    let a = got[0].clone();
    assert_eq!(
        (a.device_id, a.run_id, a.user_id, a.pushed),
        (phone, run.id, alice, false)
    );
    assert_eq!(
        (a.state, a.steps, a.push_token.as_deref(), a.sent_state),
        (RunState::Queued, 0, Some("aa11"), None)
    );
    assert_eq!((a.instance_id, a.instance_name.as_str()), (inst.id, "main"));
    assert!(claim_live(db, "n2", minute).await.is_empty());
    let mut w = db.worker().await.unwrap();
    assert!(matches!(
        w.settle_live_activity(
            phone,
            run.id,
            "n2",
            Some("aa11"),
            &LiveSettle::End { error: None }
        )
        .await,
        Err(Error::LeaseLost { .. })
    ));
    w.rollback().await.unwrap();
    let sent = |state, steps, ended| LiveSettle::Sent {
        state,
        steps,
        started: false,
        ended,
        wait_code: None,
    };
    settle_live(db, &a, "n1", sent(RunState::Queued, 0, false)).await;
    assert!(
        claim_live(db, "n1", minute).await.is_empty(),
        "nothing changed"
    );

    // 只是步数变了：离上次不到间隔不发；状态变了马上发。
    set_run("queued", 3).await;
    assert!(claim_live(db, "n1", minute).await.is_empty());
    let got = claim_live(db, "n1", Duration::ZERO).await;
    assert_eq!(got[0].steps, 3);
    // 暂时失败：到时间再领，记着次数。
    settle_live(
        db,
        &got[0],
        "n1",
        LiveSettle::Retry {
            error: "TooManyRequests".into(),
            at: Utc::now() + chrono::Duration::minutes(5),
        },
    )
    .await;
    assert!(claim_live(db, "n1", Duration::ZERO).await.is_empty());
    sqlx::query("UPDATE live_activities SET retry_at = now() - interval '1 second'")
        .execute(db.pool())
        .await
        .unwrap();
    set_run("running", 4).await;
    let got = claim_live(db, "n1", minute).await;
    assert_eq!((got[0].state, got[0].attempts), (RunState::Running, 1));
    settle_live(db, &got[0], "n1", sent(RunState::Running, 4, false)).await;

    // 结束：发过 end 就不再发；App 换了令牌（重新开了一个）：现在的状态再发一次。
    set_run("succeeded", 6).await;
    let got = claim_live(db, "n1", minute).await;
    assert_eq!((got[0].state, got[0].attempts), (RunState::Succeeded, 0));
    settle_live(db, &got[0], "n1", sent(RunState::Succeeded, 6, true)).await;
    assert!(claim_live(db, "n1", Duration::ZERO).await.is_empty());
    let mut tx = db.tenant(alice).await.unwrap();
    tx.register_live_activity(phone, run.id, "aa12", 5)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let got = claim_live(db, "n1", minute).await;
    assert_eq!(got[0].push_token.as_deref(), Some("aa12"));
    // App 在发送期间换了令牌：锁还在（别人领不到，不会同时发两次），旧的结果记不上，放开锁后新令牌接着发。
    let mut tx = db.tenant(alice).await.unwrap();
    tx.register_live_activity(phone, run.id, "aa13", 5)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert!(
        claim_live(db, "n2", minute).await.is_empty(),
        "still locked"
    );
    settle_live(db, &got[0], "n1", sent(RunState::Succeeded, 6, true)).await;
    let got = claim_live(db, "n1", minute).await;
    assert_eq!(
        (got[0].push_token.as_deref(), got[0].sent_state),
        (Some("aa13"), None)
    );
    settle_live(db, &got[0], "n1", sent(RunState::Succeeded, 6, true)).await;
    // 同一个令牌再报一次：什么都不变（不会每报一次就发一次）。
    let mut tx = db.tenant(alice).await.unwrap();
    tx.register_live_activity(phone, run.id, "aa13", 5)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert!(claim_live(db, "n1", Duration::ZERO).await.is_empty());

    // 远程开启：登录着、登记了推送开启令牌的 iPhone 各一个，最多 max_open 个开着。
    let mut tx = db.tenant(alice).await.unwrap();
    tx.set_activity_start_token(phone, Some("ee55"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let planned = queue_run(db, alice, &inst, "每日新闻").await;
    let other = queue_run(db, alice, &inst, "周报").await;
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.queue_live_starts(alice, planned.id, 1).await.unwrap(), 1);
    assert_eq!(w.queue_live_starts(alice, planned.id, 1).await.unwrap(), 0);
    assert_eq!(
        w.queue_live_starts(alice, other.id, 1).await.unwrap(),
        0,
        "one pushed activity open at a time"
    );
    w.commit().await.unwrap();
    let got = claim_live(db, "n1", minute).await;
    assert_eq!(got.len(), 1);
    let p = got[0].clone();
    assert_eq!(
        (p.run_id, p.pushed, p.push_token.as_deref()),
        (planned.id, true, None)
    );
    assert_eq!(
        (p.start_token.as_deref(), p.start_sent),
        (Some("ee55"), false)
    );
    settle_live(
        db,
        &p,
        "n1",
        LiveSettle::Sent {
            state: RunState::Queued,
            steps: 0,
            started: true,
            ended: false,
            wait_code: None,
        },
    )
    .await;
    // 开启了、App 还没报上令牌：没法发；报上来了接着发。
    assert!(claim_live(db, "n1", Duration::ZERO).await.is_empty());
    let mut tx = db.tenant(alice).await.unwrap();
    tx.register_live_activity(phone, planned.id, "ff66", 5)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let got = claim_live(db, "n1", minute).await;
    assert_eq!(
        (got[0].run_id, got[0].pushed, got[0].push_token.as_deref()),
        (planned.id, true, Some("ff66"))
    );
    // App 关掉了：不再发。
    let mut tx = db.tenant(alice).await.unwrap();
    tx.end_live_activity(phone, planned.id).await.unwrap();
    tx.commit().await.unwrap();
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(planned.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert!(claim_live(db, "n1", Duration::ZERO).await.is_empty());

    // 开启了却一直没拿到令牌、运行已经结束：领出来了结掉。
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.queue_live_starts(alice, other.id, 1).await.unwrap(), 1);
    w.commit().await.unwrap();
    let got = claim_live(db, "n1", minute).await;
    settle_live(
        db,
        &got[0],
        "n1",
        LiveSettle::Sent {
            state: RunState::Queued,
            steps: 0,
            started: true,
            ended: false,
            wait_code: None,
        },
    )
    .await;
    sqlx::query("UPDATE runs SET state = 'cancelled' WHERE id = $1")
        .bind(other.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let got = claim_live(db, "n1", minute).await;
    assert_eq!(
        (got[0].run_id, got[0].state),
        (other.id, RunState::Cancelled)
    );
    settle_live(db, &got[0], "n1", LiveSettle::End { error: None }).await;
    assert!(claim_live(db, "n1", Duration::ZERO).await.is_empty());

    // 推送开启令牌只属于一台设备：bob 在同一台手机上登记了，alice 的清掉；下线的设备也清掉。
    let mut tx = db.tenant(bob).await.unwrap();
    tx.set_activity_start_token(bobs, Some("ee55"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.release_activity_start_token(bobs, "ee55").await.unwrap(),
        1
    );
    let third = queue_run(db, alice, &inst, "再来一次").await;
    assert_eq!(w.queue_live_starts(alice, third.id, 5).await.unwrap(), 0);
    w.commit().await.unwrap();
    let mut tx = db.tenant(bob).await.unwrap();
    tx.revoke_device(bobs, "test").await.unwrap();
    tx.commit().await.unwrap();
    let token: Option<String> =
        sqlx::query_scalar("SELECT activity_start_token FROM devices WHERE id = $1")
            .bind(bobs.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(token, None);
}

#[tokio::test]
async fn live_activities_resist_floods_and_races() {
    use crate::LiveSettle;
    use proto::domain::{DevicePlatform, SessionId};
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let hour = Duration::from_secs(3600);
    let mut phones = Vec::new();
    for n in 0..2 {
        let u = user(db, &format!("+86138000000{}", 61 + n)).await;
        let mut w = db.worker().await.unwrap();
        let d = w
            .create_device(u, DevicePlatform::Ios, "iPhone", None)
            .await
            .unwrap();
        w.create_session(SessionId::new(), u, d, format!("r{n}").as_bytes(), hour)
            .await
            .unwrap();
        w.commit().await.unwrap();
        phones.push((u, d));
    }
    let [(mallory, mphone), (victim, vphone)] = phones[..] else {
        unreachable!()
    };
    let minst = instance(db, mallory).await;
    let vinst = instance(db, victim).await;
    let register = |u, d, run, token: &'static str| async move {
        let mut tx = db.tenant(u).await.unwrap();
        let r = tx.register_live_activity(d, run, token, 10).await;
        tx.commit().await.unwrap();
        r
    };
    let claim = |per_user| async move {
        let mut w = db.worker().await.unwrap();
        let got = w
            .claim_live_activities("n1", LEASE, 3, per_user, Duration::ZERO, Duration::ZERO)
            .await
            .unwrap();
        w.commit().await.unwrap();
        got
    };

    // 几个开了好几个钟头的、不停地换令牌：每轮只领得到每个用户的几个，等得最久的先领；后来的用户照样领得到。
    let mut runs = Vec::new();
    for n in 0..4 {
        let r = queue_run(db, mallory, &minst, &format!("m{n}")).await;
        register(mallory, mphone, r.id, "aa01").await.unwrap();
        runs.push(r.id);
    }
    sqlx::query("UPDATE live_activities SET created_at = now() - interval '1 hour'")
        .execute(db.pool())
        .await
        .unwrap();
    let vrun = queue_run(db, victim, &vinst, "v").await;
    register(victim, vphone, vrun.id, "bb01").await.unwrap();
    for round in 0..3 {
        let got = claim(2).await;
        let theirs = got.iter().filter(|a| a.user_id == mallory).count();
        assert!(theirs <= 2, "round {round}: {theirs} of one user");
        if round == 0 {
            assert!(got.iter().any(|a| a.user_id == victim), "victim waits");
        }
        for a in &got {
            settle_live(
                db,
                a,
                "n1",
                LiveSettle::End {
                    error: Some("BadDeviceToken".into()),
                },
            )
            .await;
        }
        for r in &runs {
            register(
                mallory,
                mphone,
                *r,
                if round % 2 == 0 { "aa02" } else { "aa03" },
            )
            .await
            .unwrap();
        }
    }
    // 发过一次、之后不停地换假令牌（每次都 BadDeviceToken）：刚换过令牌的排到后面，先轮每个用户的第一个，
    // 后来的用户第一批就排得上。
    sqlx::query(
        "UPDATE live_activities SET sent_at = now() - interval '1 hour' WHERE user_id = $1",
    )
    .bind(mallory.0)
    .execute(db.pool())
    .await
    .unwrap();
    for (n, r) in runs.iter().enumerate() {
        register(mallory, mphone, *r, ["ab01", "ab02", "ab03", "ab04"][n])
            .await
            .unwrap();
    }
    let late = queue_run(db, victim, &vinst, "v2").await;
    register(victim, vphone, late.id, "bc01").await.unwrap();
    sqlx::query(
        "UPDATE live_activities SET sent_at = now() - interval '10 seconds' WHERE run_id = $1",
    )
    .bind(late.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let got = claim(4).await;
    assert!(
        got.iter().any(|a| a.run_id == late.id),
        "{:?}",
        got.iter().map(|a| a.user_id).collect::<Vec<_>>()
    );
    for a in &got {
        settle_live(db, a, "n1", LiveSettle::End { error: None }).await;
    }

    // 令牌失效后再报同一个：不会重新打开（不会每报一次就发一次）。
    let mut w = db.worker().await.unwrap();
    let ended: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM live_activities WHERE run_id = $1 AND ended_at IS NOT NULL",
    )
    .bind(vrun.id.0)
    .fetch_one(w.conn())
    .await
    .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(ended, 1);
    register(victim, vphone, vrun.id, "bb01").await.unwrap();
    assert!(!claim(10).await.iter().any(|a| a.user_id == victim));

    // 放弃了的：同一个令牌再报一次从头来；App 关掉了的不行。
    sqlx::query("UPDATE live_activities SET ended_at = NULL WHERE run_id = $1")
        .bind(vrun.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let got = claim(10).await;
    let a = got.iter().find(|a| a.user_id == victim).unwrap();
    settle_live(
        db,
        a,
        "n1",
        LiveSettle::GiveUp {
            error: "gave up".into(),
        },
    )
    .await;
    assert!(!claim(10).await.iter().any(|a| a.user_id == victim));
    register(victim, vphone, vrun.id, "bb01").await.unwrap();
    let got = claim(10).await;
    let a = got.iter().find(|a| a.user_id == victim).unwrap();
    assert_eq!((a.attempts, a.sent_state), (0, None));
    settle_live(db, a, "n1", LiveSettle::GiveUp { error: "x".into() }).await;
    let mut tx = db.tenant(victim).await.unwrap();
    tx.end_live_activity(vphone, vrun.id).await.unwrap();
    tx.commit().await.unwrap();
    register(victim, vphone, vrun.id, "bb01").await.unwrap();
    assert!(!claim(10).await.iter().any(|a| a.user_id == victim));

    // 运行早就结束了：不能登记。
    sqlx::query(
        "UPDATE runs SET state = 'succeeded', finished_at = now() - interval '1 hour' WHERE id = $1",
    )
    .bind(runs[0].0)
    .execute(db.pool())
    .await
    .unwrap();
    assert!(matches!(
        register(mallory, mphone, runs[0], "aa09").await,
        Err(Error::Invalid(_))
    ));

    // 并发的登记一起也超不过一台设备的上限。
    let mut fresh = Vec::new();
    for n in 0..4 {
        fresh.push(queue_run(db, victim, &vinst, &format!("f{n}")).await.id);
    }
    let joins: Vec<_> = fresh
        .iter()
        .map(|r| {
            let db = db.clone();
            let r = *r;
            tokio::spawn(async move {
                let mut tx = db.tenant(victim).await.unwrap();
                let ok = tx
                    .register_live_activity(vphone, r, "cc01", 2)
                    .await
                    .is_ok();
                tokio::time::sleep(Duration::from_millis(50)).await;
                tx.commit().await.unwrap();
                ok
            })
        })
        .collect();
    let mut ok = 0;
    for j in joins {
        ok += usize::from(j.await.unwrap());
    }
    assert_eq!(ok, 2);

    // 两个副本同时领到同一个用户的两个计划运行：远程开启的也超不过上限。
    let mut tx = db.tenant(mallory).await.unwrap();
    tx.set_activity_start_token(mphone, Some("dd01"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut planned = Vec::new();
    for n in 0..3 {
        planned.push(queue_run(db, mallory, &minst, &format!("p{n}")).await.id);
    }
    let joins: Vec<_> = planned
        .iter()
        .map(|r| {
            let db = db.clone();
            let r = *r;
            tokio::spawn(async move {
                let mut w = db.worker().await.unwrap();
                let n = w.queue_live_starts(mallory, r, 1).await.unwrap();
                tokio::time::sleep(Duration::from_millis(50)).await;
                w.commit().await.unwrap();
                n
            })
        })
        .collect();
    let mut queued = 0;
    for j in joins {
        queued += j.await.unwrap();
    }
    assert_eq!(queued, 1);
}

#[tokio::test]
async fn live_activities_follow_the_phone() {
    use proto::domain::{DevicePlatform, PushChannelKind, SessionId};
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let hour = Duration::from_secs(3600);
    let alice = user(db, "+8613800000071").await;
    let bob = user(db, "+8613800000072").await;
    let apns = Some((PushChannelKind::Apns, "0a0b"));
    let mut w = db.worker().await.unwrap();
    let phone = w
        .create_device(alice, DevicePlatform::Ios, "iPhone", apns)
        .await
        .unwrap();
    w.create_session(SessionId::new(), alice, phone, b"r1", hour)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "长任务").await;
    let child = queue_run(db, alice, &inst, "子任务").await;
    sqlx::query("UPDATE runs SET parent_run_id = $2, steps = 4 WHERE id = $1")
        .bind(child.id.0)
        .bind(run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut tx = db.tenant(alice).await.unwrap();
    tx.set_activity_start_token(phone, Some("ee01"))
        .await
        .unwrap();
    tx.register_live_activity(phone, run.id, "aa01", 5)
        .await
        .unwrap();
    tx.commit().await.unwrap();

    // 步数连同直接子运行的一起算（流水线的步骤、委派的子任务）。
    let got = claim_live(db, "n1", Duration::ZERO).await;
    assert_eq!(got[0].steps, 4);
    // 前面的发得慢、锁过期了：续不上，不发。
    sqlx::query("UPDATE live_activities SET locked_until = now() - interval '1 second'")
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(
        !w.extend_live_lock(phone, run.id, "n1", LEASE, None)
            .await
            .unwrap()
    );
    w.rollback().await.unwrap();
    let got = claim_live(db, "n1", Duration::ZERO).await;
    let mut w = db.worker().await.unwrap();
    assert!(
        w.extend_live_lock(phone, run.id, "n1", LEASE, None)
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    settle_live(
        db,
        &got[0],
        "n1",
        crate::LiveSettle::Sent {
            state: got[0].state,
            steps: 4,
            started: false,
            ended: false,
            wait_code: None,
        },
    )
    .await;

    // 换了令牌（新的实时活动）：8 小时从现在算。
    sqlx::query("UPDATE live_activities SET created_at = now() - interval '7 hours'")
        .execute(db.pool())
        .await
        .unwrap();
    let mut tx = db.tenant(alice).await.unwrap();
    tx.register_live_activity(phone, run.id, "aa02", 5)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let fresh: bool = sqlx::query_scalar(
        "SELECT created_at > now() - interval '1 minute' FROM live_activities WHERE run_id = $1",
    )
    .bind(run.id.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert!(fresh);

    // 远程开启领了、还没发：用户关掉了远程开启（或者换了令牌）就不发了。
    let planned0 = queue_run(db, alice, &inst, "早报").await;
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.queue_live_starts(alice, planned0.id, 2).await.unwrap(), 1);
    w.commit().await.unwrap();
    let got = claim_live(db, "n1", Duration::ZERO).await;
    let p = got
        .iter()
        .find(|a| a.run_id == planned0.id)
        .unwrap()
        .clone();
    let mut w = db.worker().await.unwrap();
    assert!(
        w.extend_live_lock(phone, planned0.id, "n1", LEASE, Some("ee01"))
            .await
            .unwrap()
    );
    assert!(
        !w.extend_live_lock(phone, planned0.id, "n1", LEASE, Some("ee99"))
            .await
            .unwrap()
    );
    w.commit().await.unwrap();

    // 同一台手机换成 bob 登录（推送令牌跟着手机走）：alice 那台不再远程开启，开着的不再更新；已经领了的也不发。
    let mut w = db.worker().await.unwrap();
    w.create_device(bob, DevicePlatform::Ios, "iPhone", apns)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(
        !w.extend_live_lock(phone, p.run_id, "n1", LEASE, Some("ee01"))
            .await
            .unwrap()
    );
    w.rollback().await.unwrap();
    let (start, ended): (Option<String>, bool) = sqlx::query_as(
        "SELECT d.activity_start_token, x.ended_at IS NOT NULL FROM devices d \
         JOIN live_activities x ON x.device_id = d.id WHERE d.id = $1",
    )
    .bind(phone.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!((start, ended), (None, true));
    let planned = queue_run(db, alice, &inst, "每日新闻").await;
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.queue_live_starts(alice, planned.id, 2).await.unwrap(), 0);
    w.rollback().await.unwrap();
}

/// 只有等 key、等电脑时才有等待原因：别的状态下库里留着旧值也看不到（上一版的副本不清它）。
#[tokio::test]
async fn wait_codes_only_show_while_waiting() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000081").await;
    let inst = instance(db, alice).await;
    let run = queue_run(db, alice, &inst, "work").await;
    for (state, shown) in [
        ("running", None),
        ("waiting_quota", Some("invalid")),
        ("waiting_device", Some("invalid")),
    ] {
        sqlx::query("UPDATE runs SET state = $2, wait_code = 'invalid' WHERE id = $1")
            .bind(run.id.0)
            .bind(state)
            .execute(db.pool())
            .await
            .unwrap();
        let mut w = db.worker().await.unwrap();
        let got = w.run_record(run.id).await.unwrap().run.wait_code;
        w.rollback().await.unwrap();
        assert_eq!(got.as_deref(), shown, "{state}");
    }
    assert!(
        sqlx::query("UPDATE runs SET wait_code = 'Bad Code' WHERE id = $1")
            .bind(run.id.0)
            .execute(db.pool())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn runs_across_instances_by_plan_and_state() {
    use crate::RunFilter;
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800000091").await;
    let bob = user(db, "+8613800000092").await;
    let a = instance(db, alice).await;
    let b = instance(db, alice).await;
    let done = queue_run(db, alice, &a, "done").await;
    sqlx::query("UPDATE runs SET state = 'succeeded', finished_at = now() WHERE id = $1")
        .bind(done.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let queued = queue_run(db, alice, &a, "queued").await;
    let other = queue_run(db, alice, &b, "on b").await;
    let mut tx = db.tenant(alice).await.unwrap();
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: b.id,
            title: "日报".into(),
            goal: "summarize".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let root = w
        .create_run(
            alice,
            &NewRun {
                plan_id: Some(plan.id),
                ..NewRun::new(a.id, RunSource::Plan, "root", "1")
            },
        )
        .await
        .unwrap()
        .unwrap();
    let step = w
        .create_run(
            alice,
            &NewRun {
                plan_id: Some(plan.id),
                parent_run_id: Some(root.id),
                step_key: Some("s1".into()),
                ..NewRun::new(b.id, RunSource::Pipeline, "step", "1")
            },
        )
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    let bobs = instance(db, bob).await;
    queue_run(db, bob, &bobs, "bob's").await;

    let list = |u, f: RunFilter, before, limit| async move {
        let mut tx = db.tenant(u).await.unwrap();
        let runs = tx.list_runs(f, before, limit).await.unwrap();
        tx.rollback().await.unwrap();
        runs.iter().map(|r| r.id).collect::<Vec<_>>()
    };
    let all = list(alice, RunFilter::default(), None, 50).await;
    assert_eq!(all, [step.id, root.id, other.id, queued.id, done.id]);
    let active = list(
        alice,
        RunFilter {
            active: true,
            ..Default::default()
        },
        None,
        50,
    )
    .await;
    assert!(!active.contains(&done.id) && active.len() == 4);
    let of_plan = RunFilter {
        plan: Some(plan.id),
        ..Default::default()
    };
    assert_eq!(list(alice, of_plan, None, 50).await, [step.id, root.id]);
    assert_eq!(
        list(
            alice,
            RunFilter {
                roots: true,
                ..of_plan
            },
            None,
            50
        )
        .await,
        [root.id]
    );
    // 往下翻：两页不重叠，合起来是全部。
    let first = list(alice, RunFilter::default(), None, 2).await;
    let rest = list(alice, RunFilter::default(), Some(first[1]), 50).await;
    assert_eq!([first, rest].concat(), all);
    // 别人的计划：什么都没有。
    assert!(list(bob, of_plan, None, 50).await.is_empty());
}

/// 工作区归档（没有卷的后端）：实例上只记最新的一份；换掉的、没用上的上传、回收或删掉实例时，
/// 对象都排进 blob_purge。后台角色能做全部这些。
#[tokio::test]
async fn workspace_archives_queue_replaced_objects() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let u = user(db, "+8613800000771").await;
    let inst = instance(db, u).await;
    let queued = || async {
        let mut w = db.worker().await.unwrap();
        let mut keys = w.blob_purge_batch(100).await.unwrap();
        w.forget_blob_purge(&keys).await.unwrap();
        w.commit().await.unwrap();
        keys.sort();
        keys
    };
    let archive = || async {
        let mut w = db.worker().await.unwrap();
        w.instance_runtime(inst.id).await.unwrap().archive
    };
    let k = |name: &str| format!("workspaces/{}/ws-1/{name}", u.0.simple());
    let id1 = uuid::Uuid::now_v7();
    let sha = [7u8; 32];

    // 别处的上传在这么久之内刷新过就不另起一份。
    let fresh = Duration::from_secs(600);
    let begin = |id: proto::domain::InstanceId, key: String| async move {
        let mut w = db.worker().await.unwrap();
        let began = w.begin_workspace_archive(id, &key, fresh).await.unwrap();
        w.commit().await.unwrap();
        began
    };
    let age_pending = |id: proto::domain::InstanceId| async move {
        sqlx::query(
            "UPDATE instances SET workspace_archive_pending_since = now() - interval '1 hour' WHERE id = $1",
        )
        .bind(id.0)
        .execute(db.pool())
        .await
        .unwrap();
    };

    assert!(begin(inst.id, k("a1")).await);
    assert!(archive().await.is_none(), "pending is not an archive yet");
    let mut w = db.worker().await.unwrap();
    assert!(
        w.finish_workspace_archive(inst.id, &k("a1"), id1, 1234, &sha)
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    let a = archive().await.unwrap();
    assert_eq!((a.key, a.id, a.bytes, a.sha256), (k("a1"), id1, 1234, sha));
    assert!(queued().await.is_empty(), "the finished upload is kept");

    // 一个实例同时只存一份：刷新着的上传挡住别处；太久没刷新的（进程中途被杀）被换掉，旧的排进队列，
    // 它的完成、刷新、放弃都不再生效。
    assert!(begin(inst.id, k("stale")).await);
    assert!(
        !begin(inst.id, k("other")).await,
        "another upload is in progress"
    );
    let mut w = db.worker().await.unwrap();
    assert!(
        w.refresh_workspace_archive(inst.id, &k("stale"))
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    assert!(!begin(inst.id, k("other")).await);
    age_pending(inst.id).await;
    assert!(
        begin(inst.id, k("a2")).await,
        "an abandoned upload is replaced"
    );
    let mut w = db.worker().await.unwrap();
    assert!(
        !w.finish_workspace_archive(inst.id, &k("stale"), id1, 1, &sha)
            .await
            .unwrap()
    );
    assert!(
        !w.refresh_workspace_archive(inst.id, &k("stale"))
            .await
            .unwrap()
    );
    assert!(
        !w.abort_workspace_archive(inst.id, &k("stale"))
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    assert_eq!(queued().await, [k("stale")]);
    assert_eq!(archive().await.unwrap().key, k("a1"));

    // 新的归档换掉旧的：旧对象排进队列。
    let mut w = db.worker().await.unwrap();
    let id2 = uuid::Uuid::now_v7();
    assert!(
        w.finish_workspace_archive(inst.id, &k("a2"), id2, 99, &sha)
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    assert_eq!(archive().await.unwrap().id, id2);
    assert_eq!(queued().await, [k("a1")]);

    // 放弃上传：对象排进队列，现有的归档不动；之后马上能再开始一份。
    assert!(begin(inst.id, k("a3")).await);
    let mut w = db.worker().await.unwrap();
    assert!(w.abort_workspace_archive(inst.id, &k("a3")).await.unwrap());
    w.commit().await.unwrap();
    assert_eq!(queued().await, [k("a3")]);
    assert_eq!(archive().await.unwrap().key, k("a2"));

    // 回收实例：归档和待定的上传都排进队列；之后上传完成的不算数（调用方自己删掉对象）。
    assert!(begin(inst.id, k("a4")).await);
    let mut w = db.worker().await.unwrap();
    w.mark_instance_purged(inst.id).await.unwrap();
    assert!(!w.abort_workspace_archive(inst.id, &k("a4")).await.unwrap());
    w.commit().await.unwrap();
    assert_eq!(queued().await, [k("a2"), k("a4")]);
    assert!(archive().await.is_none());

    // 整行删掉（运维清理）：同样排进队列。
    let other = instance(db, u).await;
    assert!(begin(other.id, k("b1")).await);
    let mut w = db.worker().await.unwrap();
    assert!(
        w.finish_workspace_archive(other.id, &k("b1"), id1, 1, &sha)
            .await
            .unwrap()
    );
    w.commit().await.unwrap();
    assert!(begin(other.id, k("b2")).await);
    sqlx::query("DELETE FROM instances WHERE id = $1")
        .bind(other.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert_eq!(queued().await, [k("b1"), k("b2")]);

    // 只排这个用户自己前缀下的键：拿别的键（别人的产出物、归档）来不会被删。
    let third = instance(db, u).await;
    assert!(begin(third.id, "artifacts/someone-else".into()).await);
    let mut w = db.worker().await.unwrap();
    w.abort_workspace_archive(third.id, "artifacts/someone-else")
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert!(queued().await.is_empty());

    // 失败的原因里带着控制字符（沙箱里打印的）也记得下。
    let mut w = db.worker().await.unwrap();
    w.record_workspace_archive_failure(third.id, "tar: bad\0name\u{1b}[31m")
        .await
        .unwrap();
    let error: String =
        sqlx::query_scalar("SELECT workspace_archive_error FROM instances WHERE id = $1")
            .bind(third.id.0)
            .fetch_one(w.conn())
            .await
            .unwrap();
    assert_eq!(error, "tar: bad name [31m");
    w.commit().await.unwrap();

    // 放回：记下的时间是当下的；刷新着的不算没人管，太久没刷新的算。
    let mut w = db.worker().await.unwrap();
    w.begin_restore(third.id, "sbx-1").await.unwrap();
    assert!(!w.restore_is_stale(third.id, fresh).await.unwrap());
    assert!(w.refresh_restore(third.id, "sbx-1").await.unwrap());
    assert!(!w.refresh_restore(third.id, "sbx-2").await.unwrap());
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(w.stale_restores(fresh, 10).await.unwrap().is_empty());
    sqlx::query("UPDATE instances SET restoring_since = now() - interval '1 hour' WHERE id = $1")
        .bind(third.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert!(w.restore_is_stale(third.id, fresh).await.unwrap());
    assert_eq!(w.stale_restores(fresh, 10).await.unwrap(), [third.id]);
    assert!(w.end_restore(third.id, "sbx-1").await.unwrap());
    assert!(!w.restore_is_stale(third.id, fresh).await.unwrap());
    w.commit().await.unwrap();

    // 业务角色改不了归档、沙箱这些列（只有后台角色能写）。
    let mut t = db.tenant(u).await.unwrap();
    let denied = sqlx::query("UPDATE instances SET workspace_archive_pending = 'x' WHERE id = $1")
        .bind(third.id.0)
        .execute(t.conn())
        .await;
    assert!(
        denied.is_err(),
        "the tenant role cannot write archive columns"
    );
    t.rollback().await.unwrap();
    // 新建实例时也写不了（不然能让巡检去删一个它指定的沙箱）。
    for column in [
        "sandbox_id",
        "restoring_sandbox_id",
        "workspace_archive_pending",
    ] {
        let mut t = db.tenant(u).await.unwrap();
        let denied = sqlx::query(sqlx::AssertSqlSafe(format!(
            "INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id, {column}) \
             VALUES (gen_random_uuid(), $1, 'a', '1', 'acp', 'x', 'w', 'victim')"
        )))
        .bind(u.0)
        .execute(t.conn())
        .await;
        assert!(denied.is_err(), "the tenant role cannot insert {column}");
        t.rollback().await.unwrap();
    }
    let mut t = db.tenant(u).await.unwrap();
    sqlx::query(
        "INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id) \
         VALUES (gen_random_uuid(), $1, 'a', '1', 'acp', 'x', 'w')",
    )
    .bind(u.0)
    .execute(t.conn())
    .await
    .expect("the columns create_instance writes are still allowed");
    t.rollback().await.unwrap();
}
