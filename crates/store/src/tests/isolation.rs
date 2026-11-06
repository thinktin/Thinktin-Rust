//! 项目会话和工作区隔离（8.16）的库测试：专属实例、项目运行的隔离栅栏、归档键跟着空间走。需要真实 Postgres，没设置
//! DATABASE_URL 时跳过。

use std::time::Duration;

use proto::domain::{
    GrantScope, Instance, InstanceId, PlanAuthor, ProjectId, RunId, RunSource, RunState, UserId,
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

/// 项目里一个排队的运行（worker 写：8.16 里还没有派项目任务的接口）。按 `template`（a 上的私人运行）复制别的列。
async fn project_run(db: &Db, template: RunId, p: ProjectId, instance: InstanceId) -> RunId {
    let cols: Vec<String> = sqlx::query_scalar(
        "SELECT column_name::text FROM information_schema.columns WHERE table_name = 'runs' \
           AND column_name NOT IN ('id', 'project_id', 'space_kind', 'space_id', 'instance_id', 'root_run_id') \
         ORDER BY ordinal_position",
    )
    .fetch_all(db.pool())
    .await
    .unwrap();
    let list = cols.join(", ");
    let id = RunId::new();
    let mut w = db.worker().await.unwrap();
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO runs (id, project_id, instance_id, root_run_id, {list}) \
         SELECT $1, $2, $3, $1, {list} FROM runs WHERE id = $4"
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

/// 专属实例不接私人的事（测试 4）：私人运行、运行授权、计划、派进别的项目都被库里拒绝（`InstanceDedicated`）；
/// 不能再打开“让别的 agent 查我、问我”。
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
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
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

/// 连接带着隔离级别（测试 15）。
#[tokio::test]
async fn application_name_is_versioned() {
    let Some(t) = TestDb::new().await else { return };
    let name: String = sqlx::query_scalar(
        "SELECT application_name::text FROM pg_stat_activity WHERE pid = pg_backend_pid()",
    )
    .fetch_one(t.db.pool())
    .await
    .unwrap();
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
