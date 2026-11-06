//! 项目会话和工作区隔离（8.16）的库测试：专属实例、项目运行的隔离栅栏、归档键跟着空间走。需要真实 Postgres，没设置
//! DATABASE_URL 时跳过。

use std::time::Duration;

use proto::domain::{
    GrantScope, Instance, InstanceId, PlanAuthor, PlanStep, ProjectId, RunId, RunKind, RunSource,
    RunState, UserId,
};

use super::{instance, user};
use crate::instances::InstanceChange;
use crate::testing::TestDb;
use crate::{Db, Error, NewPlan, NewRun, RunChange, SoloAgent};

/// alice 的单人项目 P，里面两个 agent：b 专属于 P（整个沙箱只属于 P），c 是混用的；a 是项目外的私人实例。
struct Fixture {
    alice: UserId,
    p: ProjectId,
    a: Instance,
    b: Instance,
    c: Instance,
}

async fn fixture(db: &Db, phone: &str) -> Fixture {
    let alice = user(db, phone).await;
    let (a, b, c) = (
        instance(db, alice).await,
        instance(db, alice).await,
        instance(db, alice).await,
    );
    let mut t = db.tenant(alice).await.unwrap();
    let p = t
        .create_solo_project(
            "p",
            "",
            &[
                SoloAgent {
                    instance_id: b.id,
                    is_lead: true,
                    position: 0,
                },
                SoloAgent {
                    instance_id: c.id,
                    is_lead: false,
                    position: 1,
                },
            ],
        )
        .await
        .unwrap();
    t.commit().await.unwrap();
    dedicate(db, b.id, p).await;
    Fixture { alice, p, a, b, c }
}

/// 用 worker 的原始 SQL 把实例标成专属（8.16 的 `dedicate_project_agent` 在后面一步；这里只要库里的状态）。
async fn dedicate(db: &Db, instance: InstanceId, p: ProjectId) {
    let mut w = db.worker().await.unwrap();
    sqlx::query(
        "UPDATE instances SET workspace_project_id = $2, peer_access = false WHERE id = $1",
    )
    .bind(instance.0)
    .bind(p.0)
    .execute(w.conn())
    .await
    .unwrap();
    sqlx::query("UPDATE project_agents SET dedicated = dedicated WHERE instance_id = $1")
        .bind(instance.0)
        .execute(w.conn())
        .await
        .unwrap();
    w.commit().await.unwrap();
}

/// 项目里一个排队的运行（worker 写：8.16 里还没有派项目任务的接口）。按 `template`（a 上的私人运行）复制别的列；
/// 状态、租约、起止时间不抄，模板跑完了也是新排队的。
async fn project_run(db: &Db, template: RunId, p: ProjectId, instance: InstanceId) -> RunId {
    let cols: Vec<String> = sqlx::query_scalar(
        "SELECT column_name::text FROM information_schema.columns WHERE table_name = 'runs' \
           AND column_name NOT IN ('id', 'project_id', 'space_kind', 'space_id', 'instance_id', 'root_run_id', \
                                   'state', 'lease_owner', 'lease_expires_at', 'started_at', 'finished_at') \
         ORDER BY ordinal_position",
    )
    .fetch_all(db.pool())
    .await
    .unwrap();
    let list = cols.join(", ");
    let id = RunId::new();
    let mut w = db.worker().await.unwrap();
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO runs (id, project_id, instance_id, root_run_id, state, {list}) \
         SELECT $1, $2, $3, $1, 'queued', {list} FROM runs WHERE id = $4"
    )))
    .bind(id.0)
    .bind(p.0)
    .bind(instance.0)
    .bind(template.0)
    .execute(w.conn())
    .await
    .unwrap();
    w.commit().await.unwrap();
    id
}

async fn private_run(db: &Db, user: UserId, instance: &Instance) -> RunId {
    super::queue_run(db, user, instance, "private").await.id
}

const LEASE_SQL: &str = "UPDATE runs SET state = 'running', lease_owner = 'w1', \
     lease_expires_at = now() + interval '1 hour' WHERE id = $1";

/// 隔离栅栏（测试 3）：没声明隔离级别的连接拿不到任何项目运行的租约；1 级拿得到专属实例上的、拿不到混用实例上的；
/// 拿着租约的状态变更也查（transition_run 每次都写 lease_owner），续租、交还租约不查。
#[tokio::test]
async fn lease_fence_refuses_without_isolation() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016001").await;
    let template = private_run(db, f.alice, &f.a).await;
    let rb = project_run(db, template, f.p, f.b.id).await;
    let rc = project_run(db, template, f.p, f.c.id).await;
    // 没有设置：超级用户的连接也不行。
    for r in [rb, rc] {
        let err = sqlx::query(LEASE_SQL)
            .bind(r.0)
            .execute(db.pool())
            .await
            .map_err(Error::from)
            .unwrap_err();
        assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    }
    // 这一版的 worker（1 级）：专属的行，混用的不行。
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(LEASE_SQL)
        .bind(rc.0)
        .execute(w.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    sqlx::query(LEASE_SQL)
        .bind(rb.0)
        .execute(w.conn())
        .await
        .unwrap();
    w.commit().await.unwrap();
    // 拿着租约的状态变更：设成 0 级就不行。
    let mut w = db.worker().await.unwrap();
    sqlx::query("SELECT set_config('thinktin.isolation', '0', true)")
        .execute(w.conn())
        .await
        .unwrap();
    let err = w
        .transition_run(rb, "w1", RunState::WaitingApproval, &RunChange::default())
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    for to in [RunState::WaitingApproval, RunState::Running] {
        w.transition_run(rb, "w1", to, &RunChange::default())
            .await
            .unwrap();
    }
    w.commit().await.unwrap();
    // 续租不查。
    let mut conn = db.pool().begin().await.unwrap();
    sqlx::query("SELECT set_config('role', 'thinktin_worker', true)")
        .execute(&mut *conn)
        .await
        .unwrap();
    let renewed = sqlx::query(
        "UPDATE runs SET lease_expires_at = now() + interval '2 hours' WHERE id = $1 AND lease_owner = 'w1'",
    )
    .bind(rb.0)
    .execute(&mut *conn)
    .await
    .unwrap()
    .rows_affected();
    assert_eq!(renewed, 1);
    conn.commit().await.unwrap();
    // 交还租约（进退避）、结束：1 级都行。
    let mut w = db.worker().await.unwrap();
    w.transition_run(
        rb,
        "w1",
        RunState::Backoff,
        &RunChange {
            release_lease: true,
            ..RunChange::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let lease: Option<String> = sqlx::query_scalar("SELECT lease_owner FROM runs WHERE id = $1")
        .bind(rb.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(lease, None);
    // 私人运行不受影响（没有设置照样拿租约）。
    sqlx::query(LEASE_SQL)
        .bind(template.0)
        .execute(db.pool())
        .await
        .unwrap();
}

/// 专属实例不接私人的事（测试 4）：私人运行、紧急消息、运行授权、计划、计划的步骤、恢复暂停时还不是专属的计划、派进别的
/// 项目（建单人项目、整体替换单人项目的 agent）都被库里拒绝（`InstanceDedicated`）；不能再打开“让别的 agent 查我、问我”。
/// 同样的事放在私人、混用实例上照常。
#[tokio::test]
async fn dedicated_instances_refuse_private_work() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016011").await;
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .create_run(&NewRun::new(f.b.id, RunSource::User, "private", "1"))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    // 紧急消息（打断重来）也是私人运行。
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .queue_urgent_run(&NewRun::new(f.b.id, RunSource::User, "urgent", "1"))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .create_run_grant(
            f.b.id,
            None,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .create_plan(&NewPlan {
            instance_id: f.b.id,
            title: "daily".into(),
            goal: "g".into(),
            policy: Default::default(),
            catch_up: Default::default(),
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    // 计划的步骤（总是私人的）放不到专属实例上；放到混用的 c 上可以。
    let mut ta = db.tenant(f.alice).await.unwrap();
    let on_a = ta.create_plan(&super::plan_on(&f.a)).await.unwrap().id;
    ta.commit().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .set_plan_steps(on_a, &[super::step_on(&f.b)])
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    ta.set_plan_steps(on_a, &[super::step_on(&f.c)])
        .await
        .unwrap();
    ta.rollback().await.unwrap();
    // 暂停着的计划不挡标专属（计划自己的实例 x、步骤的实例 y 都是暂停以后才标的），恢复时被拒；私人实例上的照常恢复。
    let (x, y) = (instance(db, f.alice).await, instance(db, f.alice).await);
    let mut ta = db.tenant(f.alice).await.unwrap();
    let on_x = ta.create_plan(&super::plan_on(&x)).await.unwrap().id;
    let steps_on_y = ta.create_plan(&super::plan_on(&f.a)).await.unwrap().id;
    ta.set_plan_steps(steps_on_y, &[super::step_on(&y)])
        .await
        .unwrap();
    for plan in [on_a, on_x, steps_on_y] {
        ta.set_plan_paused(plan, true).await.unwrap();
    }
    ta.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.add_project_agents(f.alice, f.p, &super::mixed(&[x.id, y.id]), None, false, 0)
        .await
        .unwrap();
    for i in [x.id, y.id] {
        assert!(w.dedicate_project_agent(f.alice, f.p, i).await.unwrap());
    }
    w.commit().await.unwrap();
    for plan in [on_x, steps_on_y] {
        let mut ta = db.tenant(f.alice).await.unwrap();
        let err = ta.set_plan_paused(plan, false).await.unwrap_err();
        assert!(matches!(err, Error::InstanceDedicated), "{plan:?}: {err:?}");
        ta.rollback().await.unwrap();
    }
    let mut ta = db.tenant(f.alice).await.unwrap();
    ta.set_plan_paused(on_a, false).await.unwrap();
    ta.commit().await.unwrap();
    // 派进别的项目（建单人项目时）。
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .create_solo_project(
            "q",
            "",
            &[SoloAgent {
                instance_id: f.b.id,
                is_lead: true,
                position: 0,
            }],
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    // 整体替换单人项目 q 里的 agent 时放进专属于 P 的 b：不行；放进混用的 c 可以。
    let e = instance(db, f.alice).await;
    let solo = |instance_id, is_lead, position| SoloAgent {
        instance_id,
        is_lead,
        position,
    };
    let mut ta = db.tenant(f.alice).await.unwrap();
    let q = ta
        .create_solo_project("q", "", &[solo(e.id, true, 0)])
        .await
        .unwrap();
    ta.commit().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .replace_my_project_agents(q, &[solo(e.id, true, 0), solo(f.b.id, false, 1)])
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    ta.replace_my_project_agents(q, &[solo(e.id, true, 0), solo(f.c.id, false, 1)])
        .await
        .unwrap();
    ta.rollback().await.unwrap();
    // peer_access 打不开（CHECK instances_dedicated_no_peers）。
    let mut ta = db.tenant(f.alice).await.unwrap();
    let err = ta
        .update_instance(
            f.b.id,
            &InstanceChange {
                peer_access: Some(true),
                ..InstanceChange::default()
            },
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InstanceDedicated), "{err:?}");
    ta.rollback().await.unwrap();
    // 混用的 c、项目外的 a 照常。
    let mut ta = db.tenant(f.alice).await.unwrap();
    for i in [f.a.id, f.c.id] {
        ta.create_run(&NewRun::new(i, RunSource::User, "private", "1"))
            .await
            .unwrap();
    }
    ta.commit().await.unwrap();
    // 实例上还有没结束的事，标不成专属（instance_not_free）。
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(
        "UPDATE instances SET workspace_project_id = $2, peer_access = false WHERE id = $1",
    )
    .bind(f.c.id.0)
    .bind(f.p.0)
    .execute(w.conn())
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(
        matches!(&err, Error::Conflict(m) if m.starts_with("instance_not_free")),
        "{err:?}"
    );
    w.rollback().await.unwrap();
    // 读出来带着项目。
    let mut ta = db.tenant(f.alice).await.unwrap();
    assert_eq!(
        ta.instance(f.b.id).await.unwrap().dedicated_project_id,
        Some(f.p)
    );
    assert_eq!(
        ta.instance(f.c.id).await.unwrap().dedicated_project_id,
        None
    );
    ta.rollback().await.unwrap();
}

/// 删了的项目（测试 14）：worker 不再往它的运行上追加事件。
#[tokio::test]
async fn worker_cannot_append_to_deleted_projects() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016021").await;
    let template = private_run(db, f.alice, &f.a).await;
    let rb = project_run(db, template, f.p, f.b.id).await;
    let mut w = db.worker().await.unwrap();
    w.append_event(
        f.b.id,
        Some(rb),
        "agent.message",
        &serde_json::json!({ "text": "ok" }),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.delete_project(f.alice, f.p, false).await.unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = w
        .append_event(
            f.b.id,
            Some(rb),
            "agent.message",
            &serde_json::json!({ "text": "late" }),
        )
        .await
        .unwrap_err();
    assert!(
        matches!(&err, Error::Invalid(m) if m == "project_deleted"),
        "{err:?}"
    );
    w.rollback().await.unwrap();
}

/// 把连接串里的库名换成 `database`（查询参数留着）。
fn with_database(url: &str, database: &str) -> String {
    let (base, query) = match url.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (url, None),
    };
    let host = base.find("://").map_or(0, |i| i + 3);
    let base = match base[host..].find('/') {
        Some(i) => &base[..host + i],
        None => base,
    };
    match query {
        Some(query) => format!("{base}/{database}?{query}"),
        None => format!("{base}/{database}"),
    }
}

/// 连接带着隔离级别（测试 15）：生产的连接池（`Db::connect`，不是测试库自己的连接池）连上以后，库里看到的
/// application_name 是 `thinktin/i<级别>`。
#[tokio::test]
async fn application_name_is_versioned() {
    let Some(t) = TestDb::new().await else { return };
    let database: String = sqlx::query_scalar("SELECT current_database()::text")
        .fetch_one(t.db.pool())
        .await
        .unwrap();
    let url = with_database(&std::env::var("DATABASE_URL").unwrap(), &database);
    let db = Db::connect(&url, 1).await.unwrap();
    let (name, on): (String, String) = sqlx::query_as(
        "SELECT application_name::text, current_database()::text FROM pg_stat_activity \
          WHERE pid = pg_backend_pid()",
    )
    .fetch_one(db.pool())
    .await
    .unwrap();
    db.pool().close().await;
    assert_eq!(on, database);
    assert_eq!(name, crate::APPLICATION_NAME);
    assert_eq!(name, format!("thinktin/i{}", crate::ISOLATION_LEVEL));
}

/// 归档键跟着空间走（测试 17）：上一版的控制面给专属实例记 `workspaces/<用户>/…` 的键被拒；私人实例不能用
/// `projects/` 下的键；专属实例用自己项目前缀下的键可以。
#[tokio::test]
async fn archive_keys_follow_the_space() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016031").await;
    let user_key = format!("workspaces/{}/ws/1", f.alice.0.simple());
    let project_key = format!("projects/{}/workspaces/ws/1", f.p.0.simple());
    let stale = Duration::from_secs(3600);
    for (i, key) in [(f.b.id, &user_key), (f.a.id, &project_key)] {
        let mut w = db.worker().await.unwrap();
        let err = w.begin_workspace_archive(i, key, stale).await.unwrap_err();
        assert!(matches!(err, Error::Invalid(_)), "{key}: {err:?}");
        w.rollback().await.unwrap();
    }
    for (i, key) in [(f.b.id, &project_key), (f.a.id, &user_key)] {
        let mut w = db.worker().await.unwrap();
        assert!(
            w.begin_workspace_archive(i, key, stale).await.unwrap(),
            "{key}"
        );
        w.commit().await.unwrap();
    }
    // 别的项目的前缀也不行。
    let other = format!("projects/{}/workspaces/ws/1", ProjectId::new().0.simple());
    let mut w = db.worker().await.unwrap();
    sqlx::query("UPDATE instances SET workspace_archive_pending = NULL WHERE id = $1")
        .bind(f.b.id.0)
        .execute(w.conn())
        .await
        .unwrap();
    let err = w
        .begin_workspace_archive(f.b.id, &other, stale)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
}

/// 私人那边的查询不看项目（8.16 测试 16）：别的 agent 查不到专属实例；占着实例的、最近结束的只算私人运行；捎带给 agent 的
/// 排队消息只取同一个空间的。
#[tokio::test]
async fn private_queries_ignore_project_rows() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016041").await;
    let mut ta = db.tenant(f.alice).await.unwrap();
    let peers: Vec<InstanceId> = ta
        .peers(f.a.id)
        .await
        .unwrap()
        .into_iter()
        .map(|p| p.instance.id)
        .collect();
    assert!(peers.contains(&f.c.id), "{peers:?}");
    assert!(
        !peers.contains(&f.b.id),
        "dedicated instances are not peers"
    );
    ta.rollback().await.unwrap();
    // c 上一个跑着的项目运行：不算占着（私人那边看不到它）。
    let template = private_run(db, f.alice, &f.a).await;
    let rc = project_run(db, template, f.p, f.c.id).await;
    let mut conn = db.pool().begin().await.unwrap();
    sqlx::query("SELECT set_config('thinktin.isolation', '2', true)")
        .execute(&mut *conn)
        .await
        .unwrap();
    sqlx::query(LEASE_SQL)
        .bind(rc.0)
        .execute(&mut *conn)
        .await
        .unwrap();
    conn.commit().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    assert!(ta.instance_holder(f.c.id).await.unwrap().is_none());
    ta.rollback().await.unwrap();
    // 排队的用户消息（不紧急、没捎带过）：私人的和项目里的各一条，按空间取。
    let queued_private = private_run(db, f.alice, &f.c).await;
    let queued_project = project_run(db, template, f.p, f.c.id).await;
    let mut w = db.worker().await.unwrap();
    for (space, want) in [(None, queued_private), (Some(f.p), queued_project)] {
        let got: Vec<RunId> = w
            .unannounced_messages(f.c.id, space, 10)
            .await
            .unwrap()
            .into_iter()
            .map(|r| r.id)
            .collect();
        assert_eq!(got, vec![want], "{space:?}");
    }
    w.rollback().await.unwrap();
}

async fn instance_row(db: &Db, i: InstanceId) -> (Option<uuid::Uuid>, String, String, bool, i64) {
    sqlx::query_as(
        "SELECT workspace_project_id, workspace_id, state, peer_access, token_epoch FROM instances WHERE id = $1",
    )
    .bind(i.0)
    .fetch_one(db.pool())
    .await
    .unwrap()
}

/// 标成专属（8.16 测试 6）：工作区换成全新的（旧的沙箱和卷记下来等销毁、旧的归档排进清理），准备中、令牌代数加一、
/// 不让别的 agent 查；私人授权吊销；等着用户处理的出网请求删掉、保险箱请求过期，提醒标已读。实例上还有事的不行；
/// 不在项目里的 NotFound；已经是专属的什么也不做。释放：还在项目里不行，撤下以后换回全新的私人工作区。
#[tokio::test]
async fn dedicating_retires_the_workspace() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016051").await;
    let c = f.c.id;
    let archive = format!("workspaces/{}/vol-1/1", f.alice.0.simple());
    let (egress, vault) = (uuid::Uuid::now_v7(), uuid::Uuid::now_v7());
    let mut ta = db.tenant(f.alice).await.unwrap();
    let grant = ta
        .create_run_grant(c, None, &GrantScope::default(), Duration::from_secs(3600))
        .await
        .unwrap();
    ta.commit().await.unwrap();
    for sql in [
        "INSERT INTO egress_requests (id, user_id, instance_id, host) VALUES ($1, $3, $4, 'example.com')",
        "INSERT INTO vault_requests (id, user_id, instance_id, name, expires_at) \
         VALUES ($2, $3, $4, 'github', now() + interval '1 hour')",
        "INSERT INTO inbox_items (id, user_id, kind, title, body, egress_request_id) \
         VALUES (gen_random_uuid(), $3, 'egress_request', 't', '', $1)",
        "INSERT INTO inbox_items (id, user_id, kind, title, body, vault_request_id) \
         VALUES (gen_random_uuid(), $3, 'vault_request', 't', '', $2)",
    ] {
        sqlx::query(sqlx::AssertSqlSafe(sql.to_string()))
            .bind(egress)
            .bind(vault)
            .bind(f.alice.0)
            .bind(c.0)
            .execute(db.pool())
            .await
            .unwrap();
    }
    sqlx::query("UPDATE instances SET workspace_archive_key = $2 WHERE id = $1")
        .bind(c.0)
        .bind(&archive)
        .execute(db.pool())
        .await
        .unwrap();
    let before = instance_row(db, c).await;
    let mut w = db.worker().await.unwrap();
    assert!(w.dedicate_project_agent(f.alice, f.p, c).await.unwrap());
    w.commit().await.unwrap();
    let after = instance_row(db, c).await;
    assert_eq!(after.0, Some(f.p.0));
    assert_ne!(after.1, before.1, "a fresh workspace");
    assert_eq!(after.2, "provisioning");
    assert!(!after.3, "no peer access");
    assert_eq!(after.4, before.4 + 1);
    let retired: (String, String) = sqlx::query_as(
        "SELECT workspace_id, reason FROM retired_workspaces WHERE instance_id = $1",
    )
    .bind(c.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!(retired, (before.1.clone(), "dedicate".to_string()));
    for (sql, id, want) in [
        (
            "SELECT count(*) FROM blob_purge WHERE blob_key = $1::text",
            None,
            1,
        ),
        (
            "SELECT count(*) FROM egress_requests WHERE id = $2",
            Some(egress),
            0,
        ),
        (
            "SELECT count(*) FROM vault_requests WHERE id = $2 AND status = 'expired'",
            Some(vault),
            1,
        ),
        (
            "SELECT count(*) FROM inbox_items WHERE (egress_request_id = $2 OR vault_request_id = $2) \
          AND read_at IS NULL",
            Some(egress),
            0,
        ),
        (
            "SELECT count(*) FROM inbox_items WHERE vault_request_id = $2 AND read_at IS NULL",
            Some(vault),
            0,
        ),
        (
            "SELECT count(*) FROM run_grants WHERE id = $2 AND revoked_at IS NOT NULL",
            Some(grant.id.0),
            1,
        ),
        (
            "SELECT count(*) FROM project_agents WHERE instance_id = $2 AND dedicated",
            Some(c.0),
            1,
        ),
    ] {
        let n: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(sql.to_string()))
            .bind(&archive)
            .bind(id)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(n, want, "{sql}");
    }
    // 再来一次：已经是专属的。
    let mut w = db.worker().await.unwrap();
    assert!(!w.dedicate_project_agent(f.alice, f.p, c).await.unwrap());
    // 项目外的实例：NotFound。
    let err = w
        .dedicate_project_agent(f.alice, f.p, f.a.id)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    w.rollback().await.unwrap();
    // 还有没结束的运行、还在别的项目里：不行。
    let (e, g) = (instance(db, f.alice).await, instance(db, f.alice).await);
    let mut ta = db.tenant(f.alice).await.unwrap();
    let solo = |id| SoloAgent {
        instance_id: id,
        is_lead: false,
        position: 0,
    };
    let q = ta
        .create_solo_project("q", "", &[solo(e.id), solo(g.id)])
        .await
        .unwrap();
    ta.create_solo_project("r", "", &[solo(g.id)])
        .await
        .unwrap();
    ta.commit().await.unwrap();
    private_run(db, f.alice, &e).await;
    for i in [e.id, g.id] {
        let mut w = db.worker().await.unwrap();
        let err = w.dedicate_project_agent(f.alice, q, i).await.unwrap_err();
        assert!(
            matches!(&err, Error::Conflict(m) if m.starts_with("instance_not_free")),
            "{err:?}"
        );
        w.rollback().await.unwrap();
    }
    // 释放：还在项目里不行；撤下以后换回私人的。
    let mut w = db.worker().await.unwrap();
    let err = w.release_instance(f.alice, c).await.unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    w.rollback().await.unwrap();
    sqlx::query("UPDATE project_agents SET left_at = now() WHERE instance_id = $1")
        .bind(c.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    let released = w.release_instance(f.alice, c).await.unwrap();
    w.commit().await.unwrap();
    assert_eq!(released.dedicated_project_id, None);
    assert!(released.peer_access);
    let row = instance_row(db, c).await;
    assert_eq!((row.0, row.2.as_str()), (None, "provisioning"));
    assert_ne!(row.1, after.1);
    // 不是专属的：Invalid。
    let mut w = db.worker().await.unwrap();
    let err = w.release_instance(f.alice, c).await.unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
}

/// 删项目（8.16 测试 11 的实例这一半）：专属于它的实例在同一个事务里换回全新的私人工作区；别人锁着的跳过、后台清理时换；
/// 实例已经删了、还等着清理的，后台清理把项目和归档键清掉（归档对象排进清理）。
#[tokio::test]
async fn deleting_retires_dedicated_workspaces() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016061").await;
    let mut w = db.worker().await.unwrap();
    w.delete_project(f.alice, f.p, false).await.unwrap();
    w.commit().await.unwrap();
    let row = instance_row(db, f.b.id).await;
    assert_eq!((row.0, row.2.as_str(), row.3), (None, "provisioning", true));
    let reason: String =
        sqlx::query_scalar("SELECT reason FROM retired_workspaces WHERE instance_id = $1")
            .bind(f.b.id.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(reason, "project_deleted");
    // 锁着的：删的时候跳过，清理时换。
    let g = fixture(db, "+8613800016062").await;
    let mut holder = db.worker().await.unwrap();
    holder.lock_instance(g.b.id).await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.delete_project(g.alice, g.p, false).await.unwrap();
    w.commit().await.unwrap();
    holder.rollback().await.unwrap();
    assert_eq!(instance_row(db, g.b.id).await.0, Some(g.p.0));
    // 删了、等着清理的实例（带着项目下的归档）。
    let h = fixture(db, "+8613800016063").await;
    let key = format!("projects/{}/workspaces/ws/1", h.p.0.simple());
    sqlx::query(
        "UPDATE instances SET workspace_archive_key = $2, state = 'deleted', deleted_at = now() WHERE id = $1",
    )
    .bind(h.b.id.0)
    .bind(&key)
    .execute(db.pool())
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    w.delete_project(h.alice, h.p, false).await.unwrap();
    w.commit().await.unwrap();
    loop {
        let mut w = db.worker().await.unwrap();
        let n = w.purge_deleted_projects(50, Duration::ZERO).await.unwrap();
        w.commit().await.unwrap();
        if n == 0 {
            break;
        }
    }
    assert_eq!(instance_row(db, g.b.id).await.0, None);
    assert_eq!(instance_row(db, h.b.id).await.0, None);
    let queued: i64 = sqlx::query_scalar("SELECT count(*) FROM blob_purge WHERE blob_key = $1")
        .bind(&key)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(queued, 1);
    for p in [f.p, g.p, h.p] {
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM projects WHERE id = $1")
            .bind(p.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(n, 0, "purged");
    }
}

/// 标专属和删实例同时进行（8.16 测试 18）：不会互相等死；删了的实例不会被改回“准备中”。
#[tokio::test]
async fn dedicate_races_instance_delete() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016071").await;
    for round in 0..10 {
        let x = instance(db, f.alice).await;
        let mut w = db.worker().await.unwrap();
        w.add_project_agents(f.alice, f.p, &super::mixed(&[x.id]), None, true, 0)
            .await
            .unwrap();
        w.commit().await.unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (db1, db2, b1, b2) = (db.clone(), db.clone(), barrier.clone(), barrier);
        let (alice, p, id) = (f.alice, f.p, x.id);
        let dedicate = tokio::spawn(async move {
            b1.wait().await;
            let mut w = db1.worker().await.unwrap();
            match w.dedicate_project_agent(alice, p, id).await {
                Ok(_) => w.commit().await,
                Err(e) => Err(e),
            }
        });
        let delete = tokio::spawn(async move {
            b2.wait().await;
            let mut t = db2.tenant(alice).await.unwrap();
            match t.delete_instance(id).await {
                Ok(_) => t.commit().await,
                Err(e) => Err(e),
            }
        });
        let (d, del) = (dedicate.await.unwrap(), delete.await.unwrap());
        for r in [&d, &del] {
            if let Err(e) = r {
                let s = format!("{e:?}");
                assert!(!s.contains("40P01"), "round {round}: deadlock {s}");
                assert!(matches!(e, Error::NotFound), "round {round}: {e:?}");
            }
        }
        assert!(
            del.is_ok(),
            "round {round}: the delete always wins or follows"
        );
        let (state, space): (String, Option<uuid::Uuid>) =
            sqlx::query_as("SELECT state, workspace_project_id FROM instances WHERE id = $1")
                .bind(id.0)
                .fetch_one(db.pool())
                .await
                .unwrap();
        assert_eq!(state, "deleted", "round {round}: {space:?}");
    }
}

/// 标专属和私人消息同时来（8.16 测试 5，每轮一个新的混用实例，普通消息和紧急消息轮流）：只有一边成功（消息先到的，标专属
/// 回 `instance_not_free`；标专属先到的，消息回 `InstanceDedicated`），不会死锁；专属实例上从来没有没结束的私人运行。
#[tokio::test]
async fn dedicate_races_private_message() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016141").await;
    let unfinished_private = |i: InstanceId| async move {
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM runs WHERE instance_id = $1 AND project_id IS NULL \
               AND state NOT IN ('succeeded', 'failed', 'cancelled')",
        )
        .bind(i.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
        n
    };
    for round in 0..20 {
        let urgent = round % 2 == 1;
        let x = instance(db, f.alice).await;
        let mut w = db.worker().await.unwrap();
        w.add_project_agents(f.alice, f.p, &super::mixed(&[x.id]), None, false, 0)
            .await
            .unwrap();
        w.commit().await.unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (db1, db2, b1, b2) = (db.clone(), db.clone(), barrier.clone(), barrier);
        let (alice, p, id) = (f.alice, f.p, x.id);
        let dedicate = tokio::spawn(async move {
            b1.wait().await;
            let mut w = db1.worker().await.unwrap();
            match w.dedicate_project_agent(alice, p, id).await {
                Ok(_) => w.commit().await,
                Err(e) => Err(e),
            }
        });
        let message = tokio::spawn(async move {
            b2.wait().await;
            let mut t = db2.tenant(alice).await.unwrap();
            let new = NewRun::new(id, RunSource::User, "hi", "1");
            let r = if urgent {
                t.queue_urgent_run(&new).await.map(|_| ())
            } else {
                t.create_run(&new).await.map(|_| ())
            };
            match r {
                Ok(()) => t.commit().await,
                Err(e) => Err(e),
            }
        });
        let (d, m) = (dedicate.await.unwrap(), message.await.unwrap());
        for r in [&d, &m] {
            if let Err(e) = r {
                let s = format!("{e:?}");
                assert!(!s.contains("40P01"), "round {round}: deadlock {s}");
            }
        }
        assert!(
            d.is_ok() != m.is_ok(),
            "round {round}: exactly one wins: {d:?} {m:?}"
        );
        if let Err(e) = &d {
            assert!(
                matches!(e, Error::Conflict(s) if s.starts_with("instance_not_free")),
                "round {round}: {e:?}"
            );
        }
        if let Err(e) = &m {
            assert!(
                matches!(e, Error::InstanceDedicated),
                "round {round}: {e:?}"
            );
        }
        let space = instance_row(db, id).await.0;
        assert_eq!(space, d.is_ok().then_some(f.p.0), "round {round}");
        assert_eq!(
            unfinished_private(id).await,
            i64::from(m.is_ok()),
            "round {round}"
        );
    }
    let mixed_up: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM runs r JOIN instances i ON i.id = r.instance_id \
          WHERE i.workspace_project_id IS NOT NULL AND r.project_id IS NULL \
            AND r.state NOT IN ('succeeded', 'failed', 'cancelled')",
    )
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!(mixed_up, 0, "no private run on a dedicated instance");
}

/// 暂停着的计划还有没结束的流水线（8.16 评审）：根运行在 x 上等子运行，后面还有一步在 y 上；计划暂停不挡流水线往下走，
/// 所以 y 标不成专属（`instance_not_free`，库里的触发器也拦）。流水线结束以后可以。
#[tokio::test]
async fn dedicating_waits_for_running_pipelines() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016131").await;
    let (x, y) = (instance(db, f.alice).await, instance(db, f.alice).await);
    let mut w = db.worker().await.unwrap();
    w.add_project_agents(f.alice, f.p, &super::mixed(&[y.id]), None, false, 0)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    let plan = ta.create_plan(&super::plan_on(&x)).await.unwrap().id;
    ta.set_plan_steps(
        plan,
        &[
            super::step_on(&x),
            PlanStep {
                key: "b".into(),
                instance_id: y.id,
                prompt: "p".into(),
                depends_on: vec!["a".into()],
            },
        ],
    )
    .await
    .unwrap();
    ta.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let root = w
        .create_run(
            f.alice,
            &NewRun {
                kind: RunKind::Pipeline,
                plan_id: Some(plan),
                ..NewRun::new(x.id, RunSource::Plan, "root", "1")
            },
        )
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    sqlx::query("UPDATE runs SET state = 'waiting_children' WHERE id = $1")
        .bind(root.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut ta = db.tenant(f.alice).await.unwrap();
    ta.set_plan_paused(plan, true).await.unwrap();
    ta.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = w
        .dedicate_project_agent(f.alice, f.p, y.id)
        .await
        .unwrap_err();
    assert!(
        matches!(&err, Error::Conflict(m) if m.starts_with("instance_not_free") && m.contains("pipeline")),
        "{err:?}"
    );
    w.rollback().await.unwrap();
    // 库里的触发器兜底（0059）。
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(
        "UPDATE instances SET workspace_project_id = $2, peer_access = false WHERE id = $1",
    )
    .bind(y.id.0)
    .bind(f.p.0)
    .execute(w.conn())
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(
        matches!(&err, Error::Conflict(m) if m.starts_with("instance_not_free")),
        "{err:?}"
    );
    w.rollback().await.unwrap();
    assert_eq!(instance_row(db, y.id).await.0, None);
    // 流水线结束了：可以标（暂停的计划还留着这一步）。
    finish(db, root.id).await;
    let mut w = db.worker().await.unwrap();
    assert!(w.dedicate_project_agent(f.alice, f.p, y.id).await.unwrap());
    w.commit().await.unwrap();
    assert_eq!(instance_row(db, y.id).await.0, Some(f.p.0));
}

async fn claim_all(db: &Db) -> Vec<RunId> {
    let mut got = Vec::new();
    loop {
        let mut w = db.worker().await.unwrap();
        let r = w
            .claim_next_run("w1", Duration::from_secs(60))
            .await
            .unwrap();
        w.commit().await.unwrap();
        match r {
            Some(r) => got.push(r.run.id),
            None => return got,
        }
    }
}

async fn finish(db: &Db, r: RunId) {
    sqlx::query(
        "UPDATE runs SET state = 'succeeded', lease_owner = NULL, lease_expires_at = NULL, finished_at = now() \
          WHERE id = $1",
    )
    .bind(r.0)
    .execute(db.pool())
    .await
    .unwrap();
}

/// 领取（8.16 测试 1）：私人实例上的私人运行、专属实例上的项目运行领得到，混用实例上的项目运行哪一版都不领；agent 撤下、
/// 项目归档、删了以后专属实例上排队的也不领；混用实例上紧急的项目运行不挡同一个实例上的私人运行。
#[tokio::test]
async fn claim_takes_dedicated_project_runs_only() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016081").await;
    let ra = private_run(db, f.alice, &f.a).await;
    let rb = project_run(db, ra, f.p, f.b.id).await;
    let rc = project_run(db, ra, f.p, f.c.id).await;
    let mut got = claim_all(db).await;
    got.sort_by_key(|r| r.0);
    let mut want = vec![ra, rb];
    want.sort_by_key(|r| r.0);
    assert_eq!(got, want);
    let state: String = sqlx::query_scalar("SELECT state FROM runs WHERE id = $1")
        .bind(rc.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(state, "queued", "mixed project runs stay queued");
    for r in [ra, rb] {
        finish(db, r).await;
    }
    // agent 撤下、项目归档、删除以后：专属实例上新排队的不领。
    for (undo, redo) in [
        (
            "UPDATE project_agents SET left_at = now(), is_lead = false WHERE instance_id = $1",
            "UPDATE project_agents SET left_at = NULL, is_lead = true WHERE instance_id = $1",
        ),
        (
            "UPDATE projects SET status = 'archived', archived_at = now() WHERE id = (SELECT workspace_project_id FROM instances WHERE id = $1)",
            "UPDATE projects SET status = 'active', archived_at = NULL WHERE id = (SELECT workspace_project_id FROM instances WHERE id = $1)",
        ),
    ] {
        let queued = project_run(db, ra, f.p, f.b.id).await;
        sqlx::query(undo)
            .bind(f.b.id.0)
            .execute(db.pool())
            .await
            .unwrap();
        assert!(!claim_all(db).await.contains(&queued), "{undo}");
        sqlx::query(redo)
            .bind(f.b.id.0)
            .execute(db.pool())
            .await
            .unwrap();
        assert_eq!(claim_all(db).await, vec![queued], "{redo}");
        finish(db, queued).await;
    }
    // 混用实例 c：紧急的项目运行不挡私人运行（各算各的空间）。
    let urgent = project_run(db, ra, f.p, f.c.id).await;
    sqlx::query("UPDATE runs SET urgent = true WHERE id = $1")
        .bind(urgent.0)
        .execute(db.pool())
        .await
        .unwrap();
    let rc_private = private_run(db, f.alice, &f.c).await;
    assert_eq!(claim_all(db).await, vec![rc_private]);
}

/// 上一版程序的领取语句（8.16 测试 2，照 8.15 的原样）：专属实例上的项目运行一个都选不出来；库里的栅栏也不让它们拿租约
/// （见 `lease_fence_refuses_without_isolation`）。
#[tokio::test]
async fn old_claim_sql_never_returns_project_runs() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016091").await;
    let template = private_run(db, f.alice, &f.a).await;
    finish(db, template).await;
    let rb = project_run(db, template, f.p, f.b.id).await;
    let old_claim = "SELECT r.id FROM runs r JOIN users u ON u.id = r.user_id AND u.status = 'active' \
         WHERE r.kind = 'agent' AND r.project_id IS NULL AND r.not_before <= now() \
           AND r.state IN ('queued', 'backoff', 'waiting_quota', 'waiting_device', 'waiting_children')";
    let old_takeover = "SELECT id FROM runs WHERE lease_owner IS NOT NULL AND lease_expires_at < now() \
         AND state NOT IN ('succeeded', 'failed', 'cancelled') AND project_id IS NULL";
    let old_waits = "SELECT id FROM runs WHERE state IN ('waiting_quota', 'waiting_device') \
         AND wait_deadline <= now() AND (lease_owner IS NULL OR lease_expires_at < now()) AND project_id IS NULL";
    let old_pipelines = "SELECT id FROM runs WHERE kind = 'pipeline' AND state IN ('queued', 'waiting_children') \
         AND not_before <= now() AND project_id IS NULL";
    // 三种状态：排队、租约过期、等待超时。
    for setup in [
        None,
        Some(
            "UPDATE runs SET state = 'running', lease_owner = 'gone', lease_expires_at = now() - interval '1 minute' WHERE id = $1",
        ),
        Some(
            "UPDATE runs SET state = 'waiting_quota', lease_owner = NULL, lease_expires_at = NULL, wait_deadline = now() - interval '1 minute' WHERE id = $1",
        ),
    ] {
        if let Some(sql) = setup {
            let mut conn = db.pool().begin().await.unwrap();
            sqlx::query("SELECT set_config('thinktin.isolation', '1', true)")
                .execute(&mut *conn)
                .await
                .unwrap();
            sqlx::query(sql)
                .bind(rb.0)
                .execute(&mut *conn)
                .await
                .unwrap();
            conn.commit().await.unwrap();
        }
        for old in [old_claim, old_takeover, old_waits, old_pipelines] {
            let ids: Vec<uuid::Uuid> = sqlx::query_scalar(old).fetch_all(db.pool()).await.unwrap();
            assert!(!ids.contains(&rb.0), "{old}");
        }
    }
    // 这一版的接管、等待超时照样按空间领得到它。
    let mut w = db.worker().await.unwrap();
    let waits = w
        .claim_expired_waits("w1", Duration::from_secs(60), 10)
        .await
        .unwrap();
    assert_eq!(waits.iter().map(|r| r.run.id).collect::<Vec<_>>(), vec![rb]);
    w.rollback().await.unwrap();
}

/// 网关删实例用的就是 `remove_instance`（先锁项目、再锁出网请求，之后才动实例行）。
async fn delete_like_gateway(db: Db, user: UserId, id: InstanceId) -> crate::Result<()> {
    let mut t = db.tenant(user).await?;
    t.remove_instance(id).await?;
    t.commit().await
}

async fn pending_egress(db: &Db, user: UserId, instance: InstanceId, host: &str) -> uuid::Uuid {
    let id = uuid::Uuid::now_v7();
    sqlx::query(
        "INSERT INTO egress_requests (id, user_id, instance_id, host) VALUES ($1, $2, $3, $4)",
    )
    .bind(id)
    .bind(user.0)
    .bind(instance.0)
    .bind(host)
    .execute(db.pool())
    .await
    .unwrap();
    id
}

/// 放回私人、加入时标专属和删实例同时来（8.16 评审）：实例有在等的出网请求时，两边都是先请求后实例，不会死锁。
#[tokio::test]
async fn release_and_dedicate_race_instance_delete_with_egress() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016111").await;
    for round in 0..12 {
        let release = round % 2 == 0;
        let x = instance(db, f.alice).await;
        if release {
            let mut w = db.worker().await.unwrap();
            w.add_project_agents(
                f.alice,
                f.p,
                &[crate::JoinAgent::Existing {
                    id: x.id,
                    dedicate: true,
                    ack_shared_memory: false,
                }],
                None,
                false,
                0,
            )
            .await
            .unwrap();
            w.withdraw_project_agent(f.alice, f.p, x.id).await.unwrap();
            w.commit().await.unwrap();
        }
        pending_egress(db, f.alice, x.id, "example.com").await;
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (db1, db2, b1, b2) = (db.clone(), db.clone(), barrier.clone(), barrier);
        let (alice, p, id) = (f.alice, f.p, x.id);
        let change = tokio::spawn(async move {
            b1.wait().await;
            let mut w = db1.worker().await.unwrap();
            let r = if release {
                w.release_instance(alice, id).await.map(|_| ())
            } else {
                w.add_project_agents(
                    alice,
                    p,
                    &[crate::JoinAgent::Existing {
                        id,
                        dedicate: true,
                        ack_shared_memory: false,
                    }],
                    None,
                    false,
                    0,
                )
                .await
                .map(|_| ())
            };
            match r {
                Ok(()) => w.commit().await,
                Err(e) => Err(e),
            }
        });
        let delete = tokio::spawn(async move {
            b2.wait().await;
            delete_like_gateway(db2, alice, id).await
        });
        let (c, del) = (change.await.unwrap(), delete.await.unwrap());
        for r in [&c, &del] {
            if let Err(e) = r {
                let s = format!("{e:?}");
                assert!(!s.contains("40P01"), "round {round}: deadlock {s}");
            }
        }
        assert!(del.is_ok(), "round {round}: {del:?}");
    }
}

/// 换工作区和“一直允许”同时进行（8.16 测试 19）：用户已经锁着请求时，换工作区删不掉它；之后再答“一直允许”也不能把网站
/// 加进新的工作区（请求记着是在哪个工作区里问的）。新工作区里再问的照常。
#[tokio::test]
async fn retire_races_egress_always() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016121").await;
    let x = instance(db, f.alice).await;
    let old = pending_egress(db, f.alice, x.id, "old.example.com").await;
    let mut ta = db.tenant(f.alice).await.unwrap();
    sqlx::query("SELECT id FROM egress_requests WHERE id = $1 FOR UPDATE")
        .bind(old)
        .execute(ta.conn())
        .await
        .unwrap();
    // 项目删了换掉这个工作区：等不了用户锁着的请求，跳过它。
    let mut w = db.worker().await.unwrap();
    sqlx::query("SELECT id FROM instances WHERE id = $1 FOR UPDATE")
        .bind(x.id.0)
        .execute(w.conn())
        .await
        .unwrap();
    w.retire_workspace(x.id, None, "project_deleted")
        .await
        .unwrap();
    w.commit().await.unwrap();
    let err = ta
        .decide_egress_request(
            proto::domain::EgressRequestId(old),
            proto::domain::EgressDecision::Always,
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    ta.commit().await.unwrap();
    assert!(instance_hosts(db, x.id).await.is_empty());
    let decide = |id: uuid::Uuid| async move {
        let mut ta = db.tenant(f.alice).await.unwrap();
        let r = ta
            .decide_egress_request(
                proto::domain::EgressRequestId(id),
                proto::domain::EgressDecision::Always,
            )
            .await;
        ta.commit().await.unwrap();
        r
    };
    // 别的更新（后台标提醒过）不改它记着的工作区：照样不能答。
    sqlx::query("UPDATE egress_requests SET notified_at = now() WHERE id = $1")
        .bind(old)
        .execute(db.pool())
        .await
        .unwrap();
    assert!(matches!(decide(old).await, Err(Error::NotFound)));
    // 新工作区里的 agent 再问同一个网站（出口代理改 asked_at）：记成新的工作区，能答了。
    sqlx::query("UPDATE egress_requests SET asked_at = now() WHERE id = $1")
        .bind(old)
        .execute(db.pool())
        .await
        .unwrap();
    decide(old).await.unwrap();
    assert_eq!(instance_hosts(db, x.id).await, vec!["old.example.com"]);
    // 新工作区里问的：照常加进去。
    let fresh = pending_egress(db, f.alice, x.id, "new.example.com").await;
    let mut ta = db.tenant(f.alice).await.unwrap();
    ta.decide_egress_request(
        proto::domain::EgressRequestId(fresh),
        proto::domain::EgressDecision::Always,
    )
    .await
    .unwrap();
    ta.commit().await.unwrap();
    assert_eq!(
        instance_hosts(db, x.id).await,
        vec!["old.example.com", "new.example.com"]
    );
}

/// 删实例的加锁顺序（8.16 评审）：别人先锁着它的出网请求（放回私人、标专属、回答出网请求的第一步）时，删实例停在锁出网
/// 请求那一步、还没碰实例行，所以不会和对方的下一步（锁实例）互相等。
#[tokio::test]
async fn instance_delete_locks_egress_before_the_instance() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let f = fixture(db, "+8613800016131").await;
    let x = instance(db, f.alice).await;
    pending_egress(db, f.alice, x.id, "example.com").await;
    let mut w = db.worker().await.unwrap();
    w.prelock_egress(x.id).await.unwrap();
    let (db2, alice, id) = (db.clone(), f.alice, x.id);
    let delete = tokio::spawn(async move { delete_like_gateway(db2, alice, id).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !delete.is_finished(),
        "the delete waits for the egress requests"
    );
    let mut probe = db.pool().begin().await.unwrap();
    sqlx::query("SELECT id FROM instances WHERE id = $1 FOR UPDATE NOWAIT")
        .bind(x.id.0)
        .execute(&mut *probe)
        .await
        .expect("the delete has not locked the instance yet");
    probe.rollback().await.unwrap();
    w.commit().await.unwrap();
    delete.await.unwrap().unwrap();
    assert_eq!(instance_row(db, x.id).await.2, "deleted");
}

async fn instance_hosts(db: &Db, id: InstanceId) -> Vec<String> {
    sqlx::query_scalar("SELECT egress_hosts FROM instances WHERE id = $1")
        .bind(id.0)
        .fetch_one(db.pool())
        .await
        .unwrap()
}
