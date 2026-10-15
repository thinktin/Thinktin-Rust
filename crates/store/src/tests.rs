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
    Db, Error, NewCredential, NewInboxItem, NewInstance, NewOutboxItem, NewPlan, NewRun, RunChange,
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
        w.create_device(
            who,
            DevicePlatform::Ios,
            "张三的 iPhone",
            Some((PushChannelKind::Apns, "tok")),
        )
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
        tx.commit().await.unwrap();
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
