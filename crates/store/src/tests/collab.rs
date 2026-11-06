//! 项目内协作（8.17）的库测试：派单开关和写入时的栅栏、拿租约要项目协议、运行树跨主人。需要真实 Postgres，没设置
//! DATABASE_URL 时跳过。

use std::time::Duration;

use proto::domain::{InstanceId, ProjectId, RunId, UserId};

use super::isolation::{Fixture, fixture};
use super::{instance, project_grant, user};
use crate::testing::{TestDb, project_writer};
use crate::{Db, Error};

/// 谁来写一个项目运行（原始 SQL）。
#[derive(Clone, Copy, Debug)]
enum Writer {
    /// 用户自己（租户）。
    Tenant(UserId),
    /// 8.16 的程序：worker、声明了 1 级隔离，没有项目协议。
    Legacy,
    /// 这一版：worker、隔离级别、项目协议 2。
    Level(u8),
}

/// 项目运行的一行，默认是 `instance` 上用户发起、带 `grant` 的 agent 运行。
#[derive(Clone, Copy)]
struct Row {
    instance: InstanceId,
    grant: Option<uuid::Uuid>,
    parent: Option<RunId>,
    source: &'static str,
    urgent: bool,
    plan: Option<uuid::Uuid>,
}

impl Row {
    fn task(instance: InstanceId, grant: uuid::Uuid) -> Self {
        Self {
            instance,
            grant: Some(grant),
            parent: None,
            source: "user",
            urgent: false,
            plan: None,
        }
    }
}

async fn insert(db: &Db, p: ProjectId, who: Writer, row: Row) -> crate::Result<RunId> {
    insert_raw(db, p, who, row).await.map_err(Error::from)
}

async fn insert_raw(db: &Db, p: ProjectId, who: Writer, row: Row) -> sqlx::Result<RunId> {
    let id = RunId::new();
    let mut conn = db.pool().begin().await.unwrap();
    match who {
        Writer::Tenant(u) => {
            sqlx::query(
                "SELECT set_config('role', 'thinktin_app', true), set_config('app.user_id', $1, true)",
            )
            .bind(u.to_string())
            .execute(&mut *conn)
            .await
            .unwrap();
        }
        Writer::Legacy => {
            sqlx::query(
                "SELECT set_config('role', 'thinktin_worker', true), set_config('thinktin.isolation', '1', true)",
            )
            .execute(&mut *conn)
            .await
            .unwrap();
        }
        Writer::Level(n) => project_writer(&mut conn, n).await,
    }
    let root: Option<uuid::Uuid> = match row.parent {
        Some(parent) => {
            sqlx::query_scalar("SELECT root_run_id FROM runs WHERE id = $1")
                .bind(parent.0)
                .fetch_optional(&mut *conn)
                .await?
        }
        None => Some(id.0),
    };
    sqlx::query(
        "INSERT INTO runs (id, user_id, instance_id, project_id, root_run_id, parent_run_id, source, prompt, \
                           agent_version, run_grant_id, urgent, plan_id) \
         SELECT $1, user_id, id, $2, coalesce($3, $1), $4, $5, 'task', agent_version, $6, $7, $8 \
           FROM instances WHERE id = $9",
    )
    .bind(id.0)
    .bind(p.0)
    .bind(root)
    .bind(row.parent.map(|r| r.0))
    .bind(row.source)
    .bind(row.grant)
    .bind(row.urgent)
    .bind(row.plan)
    .bind(row.instance.0)
    .execute(&mut *conn)
    .await?;
    conn.commit().await?;
    Ok(id)
}

fn is_constraint(e: &Error, name: &str) -> bool {
    match e {
        Error::Invalid(m) | Error::Conflict(m) | Error::Forbidden(m) | Error::NotPermitted(m) => {
            m.contains(name)
        }
        _ => false,
    }
}

/// 被库里拒绝时的约束名。
async fn constraint_of(db: &Db, p: ProjectId, who: Writer, row: Row) -> String {
    let err = insert_raw(db, p, who, row).await.unwrap_err();
    err.as_database_error()
        .and_then(|d| d.constraint().map(String::from))
        .unwrap_or_else(|| err.to_string())
}

/// 派单开关和写入时的栅栏（8.17 测试 1）：迁移完是关着的；租户写不进；8.16 的程序（没有项目协议）、混用实例只有 1 级
/// 的写不进；撤下的 agent、删了的实例写不进；来自计划、紧急的、没带授权的、父运行不在或者结束了的写不进；开关关着的
/// 写不进。都对的写得进。
#[tokio::test]
async fn dispatch_switch_gates_project_writes() {
    let Some(fresh) = TestDb::up_to(60).await else {
        return;
    };
    let mut w = fresh.db.worker().await.unwrap();
    assert!(
        !w.project_dispatch_enabled().await.unwrap(),
        "off by default"
    );
    w.rollback().await.unwrap();
    drop(fresh);

    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let Fixture { alice, p, b, c, .. } = fixture(db, "+8613800017011").await;
    let gb = project_grant(db, p.0, b.id.0).await;
    let gc = project_grant(db, p.0, c.id.0).await;
    // 都对的：专属的 b 1 级就行，混用的 c 要 2 级。
    let ok = insert(db, p, Writer::Level(1), Row::task(b.id, gb))
        .await
        .unwrap();
    insert(db, p, Writer::Level(2), Row::task(c.id, gc))
        .await
        .unwrap();
    let tenant = insert(db, p, Writer::Tenant(alice), Row::task(b.id, gb))
        .await
        .unwrap_err();
    assert!(matches!(tenant, Error::Forbidden(_)), "{tenant:?}");
    for (who, row, want) in [
        (Writer::Legacy, Row::task(b.id, gb), "runs_isolation"),
        (Writer::Level(1), Row::task(c.id, gc), "runs_isolation"),
        (
            Writer::Level(1),
            Row {
                urgent: true,
                ..Row::task(b.id, gb)
            },
            "project_run_shape",
        ),
        (
            Writer::Level(1),
            Row {
                grant: None,
                ..Row::task(b.id, gb)
            },
            "project_run_shape",
        ),
        (
            Writer::Level(1),
            Row {
                parent: Some(RunId::new()),
                source: "ask",
                ..Row::task(b.id, gb)
            },
            "project_run_shape",
        ),
    ] {
        let got = constraint_of(db, p, who, row).await;
        assert_eq!(got, want, "{who:?}");
    }
    // 来自计划的：计划不能在专属实例上生效，这里只看栅栏（随便一个 id，触发器先于外键拒绝）。
    let got = constraint_of(
        db,
        p,
        Writer::Level(1),
        Row {
            plan: Some(uuid::Uuid::now_v7()),
            ..Row::task(b.id, gb)
        },
    )
    .await;
    assert_eq!(got, "project_run_shape");
    // 父运行结束了：不再收子运行。
    sqlx::query("UPDATE runs SET state = 'cancelled', finished_at = now() WHERE id = $1")
        .bind(ok.0)
        .execute(db.pool())
        .await
        .unwrap();
    let got = constraint_of(
        db,
        p,
        Writer::Level(1),
        Row {
            parent: Some(ok),
            source: "ask",
            ..Row::task(b.id, gb)
        },
    )
    .await;
    assert_eq!(got, "project_run_shape");
    // c 撤下了：写不进（授权也写不进）。
    sqlx::query(
        "UPDATE project_agents SET left_at = now(), is_lead = false WHERE instance_id = $1",
    )
    .bind(c.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let err = insert(db, p, Writer::Level(2), Row::task(c.id, gc))
        .await
        .unwrap_err();
    assert!(is_constraint(&err, "project_agent_gone"), "{err:?}");
    // b 的实例删了（租户删了、worker 还没撤下的那一会儿）：也写不进。
    sqlx::query("UPDATE instances SET state = 'deleted', deleted_at = now() WHERE id = $1")
        .bind(b.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let err = insert(db, p, Writer::Level(1), Row::task(b.id, gb))
        .await
        .unwrap_err();
    assert!(is_constraint(&err, "project_agent_gone"), "{err:?}");
    sqlx::query("UPDATE instances SET state = 'provisioning', deleted_at = NULL WHERE id = $1")
        .bind(b.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    // 开关关了：派单写不进（项目授权也一样）。
    let mut w = db.worker().await.unwrap();
    w.set_project_dispatch(false, "test", Some("closing"))
        .await
        .unwrap();
    w.commit().await.unwrap();
    let err = insert(db, p, Writer::Level(1), Row::task(b.id, gb))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::DispatchOff), "{err:?}");
    let mut conn = db.pool().begin().await.unwrap();
    project_writer(&mut conn, 1).await;
    let err = sqlx::query(
        "INSERT INTO run_grants (id, user_id, instance_id, scope, expires_at, project_id) \
         SELECT $1, user_id, id, '{}', now() + interval '1 day', $2 FROM instances WHERE id = $3",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(p.0)
    .bind(b.id.0)
    .execute(&mut *conn)
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(matches!(err, Error::DispatchOff), "{err:?}");
}

/// 拿项目运行的租约要项目协议（8.17 测试 2）：只声明了隔离级别的事务（8.16 的领取、接管、改状态）拿不到，声明了协议的
/// 拿得到。
#[tokio::test]
async fn lease_fence_needs_project_protocol() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let Fixture { p, b, .. } = fixture(db, "+8613800017021").await;
    let gb = project_grant(db, p.0, b.id.0).await;
    let run = insert(db, p, Writer::Level(1), Row::task(b.id, gb))
        .await
        .unwrap();
    let lease = "UPDATE runs SET state = 'running', lease_owner = 'w1', \
                 lease_expires_at = now() + interval '1 hour' WHERE id = $1";
    let mut conn = db.pool().begin().await.unwrap();
    sqlx::query("SELECT set_config('thinktin.isolation', '1', true)")
        .execute(&mut *conn)
        .await
        .unwrap();
    let err = sqlx::query(lease)
        .bind(run.0)
        .execute(&mut *conn)
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    conn.rollback().await.unwrap();
    let mut conn = db.pool().begin().await.unwrap();
    project_writer(&mut conn, 1).await;
    sqlx::query(lease)
        .bind(run.0)
        .execute(&mut *conn)
        .await
        .unwrap();
    conn.commit().await.unwrap();
    // 这一版的领取也领得到（Db::worker 声明了两个）。
    let other = insert(db, p, Writer::Level(1), Row::task(b.id, gb))
        .await
        .unwrap();
    sqlx::query("UPDATE runs SET state = 'succeeded', lease_owner = NULL, finished_at = now() WHERE id = $1")
        .bind(run.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    let claimed = w
        .claim_next_run("w1", Duration::from_secs(60))
        .await
        .unwrap()
        .expect("the project run");
    assert_eq!(claimed.run.id, other);
}

/// 私人的运行树还是同一个主人（8.17 测试 7）：别人的私人运行下面建不了子运行（runs_parent_space）；同主人的父子外键删了
/// 以后这一条还在挡。
#[tokio::test]
async fn private_trees_stay_same_owner() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800017031").await;
    let bob = user(db, "+8613800017032").await;
    let (a, b) = (instance(db, alice).await, instance(db, bob).await);
    let parent = super::queue_run(db, alice, &a, "private parent").await;
    let mut w = db.worker().await.unwrap();
    let mut child = crate::NewRun::new(b.id, proto::domain::RunSource::Delegate, "x", "1");
    child.parent_run_id = Some(parent.id);
    let err = w.create_run(bob, &child).await.unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let mut own = crate::NewRun::new(a.id, proto::domain::RunSource::Delegate, "x", "1");
    own.parent_run_id = Some(parent.id);
    w.create_run(alice, &own).await.unwrap().unwrap();
    w.commit().await.unwrap();
}

/// 0060 删掉同一主人的父子外键（8.17 测试 18）：迁移前建好的私人运行树迁移后照样在，两个外键没了。
#[tokio::test]
async fn migration_0060_drops_same_owner_parent_keys() {
    let Some(t) = TestDb::up_to(59).await else {
        return;
    };
    let db = &t.db;
    let alice = user(db, "+8613800017041").await;
    let a = super::old_instance(db, alice).await;
    let parent = super::old_run(db, alice, &a).await;
    let child = uuid::Uuid::now_v7();
    sqlx::query(
        "INSERT INTO runs (id, user_id, instance_id, root_run_id, parent_run_id, source, prompt, agent_version) \
         VALUES ($1, $2, $3, $4, $4, 'delegate', 'child', '1')",
    )
    .bind(child)
    .bind(alice.0)
    .bind(a.id.0)
    .bind(parent.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    t.migrate_rest().await;
    let left: Vec<String> = sqlx::query_scalar(
        "SELECT conname::text FROM pg_constraint WHERE conname IN \
           ('runs_parent_run_id_user_id_fkey', 'run_grants_parent_id_user_id_fkey')",
    )
    .fetch_all(db.pool())
    .await
    .unwrap();
    assert!(left.is_empty(), "{left:?}");
    let parent_of: Option<uuid::Uuid> =
        sqlx::query_scalar("SELECT parent_run_id FROM runs WHERE id = $1")
            .bind(child)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(parent_of, Some(parent.id.0));
}

/// 连着的老副本（8.17 测试 14）：同一个登录账号、同一个库里连接名不是这一版的连接按名字列出来，这一版的、自己这个
/// 连接不算；在开着的 worker 事务旁边查也一样。
#[tokio::test]
async fn legacy_sessions_as_login() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let url = std::env::var("DATABASE_URL").unwrap();
    let database: String = sqlx::query_scalar("SELECT current_database()::text")
        .fetch_one(db.pool())
        .await
        .unwrap();
    let base: sqlx::postgres::PgConnectOptions = url.parse().unwrap();
    let base = base.database(&database);
    let old = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect_with(base.clone().application_name("thinktin/i1"))
        .await
        .unwrap();
    let unnamed = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect_with(base.clone())
        .await
        .unwrap();
    sqlx::query("SELECT 1").execute(&old).await.unwrap();
    sqlx::query("SELECT 1").execute(&unnamed).await.unwrap();
    let w = db.worker().await.unwrap();
    let got = db.legacy_sessions().await.unwrap();
    w.rollback().await.unwrap();
    assert!(
        got.iter().any(|(name, n)| name == "thinktin/i1" && *n == 1),
        "{got:?}"
    );
    assert!(
        got.iter()
            .any(|(name, _)| name.is_empty() || name != "thinktin/i1"),
        "{got:?}"
    );
    assert!(
        !got.iter().any(|(name, _)| name == crate::APPLICATION_NAME),
        "{got:?}"
    );
    old.close().await;
    unnamed.close().await;
}

/// 关开关等着在途的派单（8.17 测试 21）：派单写进去、还没提交时关开关要等它；两边都提交以后找得到这个没结束的运行，
/// 逐个取消。
#[tokio::test]
async fn off_waits_for_in_flight_dispatch() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let Fixture { p, b, .. } = fixture(db, "+8613800017051").await;
    let gb = project_grant(db, p.0, b.id.0).await;
    let mut dispatch = db.pool().begin().await.unwrap();
    project_writer(&mut dispatch, 1).await;
    let run = uuid::Uuid::now_v7();
    sqlx::query(
        "INSERT INTO runs (id, user_id, instance_id, project_id, root_run_id, source, prompt, agent_version, \
                           run_grant_id) \
         SELECT $1, user_id, id, $2, $1, 'user', 'task', agent_version, $3 FROM instances WHERE id = $4",
    )
    .bind(run)
    .bind(p.0)
    .bind(gb)
    .bind(b.id.0)
    .execute(&mut *dispatch)
    .await
    .unwrap();
    // 关开关的事务在锁超时之前拿不到这一行。
    let mut w = db.worker().await.unwrap();
    sqlx::query("SET LOCAL lock_timeout = '300ms'")
        .execute(w.conn())
        .await
        .unwrap();
    let err = w
        .set_project_dispatch(false, "test", None)
        .await
        .unwrap_err();
    assert!(format!("{err:?}").contains("55P03"), "{err:?}");
    w.rollback().await.unwrap();
    dispatch.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.set_project_dispatch(false, "test", None).await.unwrap();
    assert_eq!(w.projects_with_unfinished_runs(10).await.unwrap(), vec![p]);
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.lock_project(p).await.unwrap();
    w.cancel_project_runs(p, "project dispatch was switched off")
        .await
        .unwrap();
    assert!(
        w.projects_with_unfinished_runs(10)
            .await
            .unwrap()
            .is_empty()
    );
    w.commit().await.unwrap();
}
