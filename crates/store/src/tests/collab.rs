//! 项目内协作（8.17）的库测试：派单开关和写入时的栅栏、拿租约要项目协议、运行树跨主人。需要真实 Postgres，没设置
//! DATABASE_URL 时跳过。

use std::time::Duration;

use proto::domain::{
    Instance, InstanceId, ProjectBudget, ProjectId, RunId, RunSource, RunState, UserId,
};

use super::isolation::{Fixture, dedicate, fixture};
use super::{instance, project_grant, user};
use crate::testing::{TestDb, project_writer};
use crate::{
    AgentLimits, BoardFilter, BoardWriter, ChildRefusal, Db, Error, NewProjectBoardPost,
    ProjectChild, ProjectChildResult, SoloAgent,
};

/// 谁来写一个项目运行（原始 SQL）。
#[derive(Clone, Copy, Debug)]
enum Writer {
    /// 用户自己（租户）。
    Tenant(UserId),
    /// 8.16 的程序：worker、声明了 1 级隔离，没有项目协议。
    Legacy,
    /// 这一版：worker、隔离级别、项目协议 2。
    Level(u8),
    /// 租户自己把隔离级别、项目协议都设上了（只有“只有 worker 写”那一条挡得住）。
    TenantSpoofing(UserId),
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
        Writer::TenantSpoofing(u) => {
            sqlx::query(
                "SELECT set_config('role', 'thinktin_app', true), set_config('app.user_id', $1, true), \
                        set_config('thinktin.isolation', '2', true), set_config('thinktin.project_protocol', '2', true)",
            )
            .bind(u.to_string())
            .execute(&mut *conn)
            .await
            .unwrap();
        }
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
    // 租户把隔离级别、项目协议都设上：运行、授权照样写不进（只有 worker 写）。
    let got = constraint_of(db, p, Writer::TenantSpoofing(alice), Row::task(b.id, gb)).await;
    assert!(got.contains("written by the server only"), "{got}");
    let mut conn = db.pool().begin().await.unwrap();
    sqlx::query(
        "SELECT set_config('role', 'thinktin_app', true), set_config('app.user_id', $1, true), \
                set_config('thinktin.isolation', '2', true), set_config('thinktin.project_protocol', '2', true)",
    )
    .bind(alice.to_string())
    .execute(&mut *conn)
    .await
    .unwrap();
    let err = sqlx::query(
        "INSERT INTO run_grants (id, user_id, instance_id, scope, expires_at, project_id) \
         VALUES ($1, $2, $3, '{}', now() + interval '1 day', $4)",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(alice.0)
    .bind(b.id.0)
    .bind(p.0)
    .execute(&mut *conn)
    .await
    .unwrap_err();
    assert!(
        err.to_string().contains("written by the server only"),
        "{err}"
    );
    conn.rollback().await.unwrap();
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

const TTL: Duration = Duration::from_secs(90 * 24 * 3600);

/// 两个人的共享项目 p：alice 建的，负责人是她专属于 p 的 a；bob 加入，派了专属于 p 的 b；alice 还有一个混用的 m 在 p 里；
/// carol 是外人。
struct Shared {
    alice: UserId,
    bob: UserId,
    carol: UserId,
    p: ProjectId,
    a: Instance,
    b: Instance,
    m: Instance,
}

async fn shared(db: &Db, phone: u64) -> Shared {
    let alice = user(db, &format!("+86{phone}")).await;
    let bob = user(db, &format!("+86{}", phone + 1)).await;
    let carol = user(db, &format!("+86{}", phone + 2)).await;
    let (a, m, b) = (
        instance(db, alice).await,
        instance(db, alice).await,
        instance(db, bob).await,
    );
    let mut t = db.tenant(alice).await.unwrap();
    let p = t
        .create_solo_project(
            "p",
            "",
            &[
                SoloAgent {
                    instance_id: a.id,
                    is_lead: true,
                    position: 0,
                },
                SoloAgent {
                    instance_id: m.id,
                    is_lead: false,
                    position: 1,
                },
            ],
        )
        .await
        .unwrap();
    t.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role, consented_at, daily_token_limit, \
                                      total_token_limit) VALUES ($1, $2, 'member', now(), 1000000, 5000000)",
    )
    .bind(p.0)
    .bind(bob.0)
    .execute(w.conn())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO project_agents (project_id, instance_id, user_id, position) VALUES ($1, $2, $3, 2)",
    )
    .bind(p.0)
    .bind(b.id.0)
    .bind(bob.0)
    .execute(w.conn())
    .await
    .unwrap();
    sqlx::query("UPDATE projects SET shared_at = now() WHERE id = $1")
        .bind(p.0)
        .execute(w.conn())
        .await
        .unwrap();
    w.commit().await.unwrap();
    dedicate(db, a.id, p).await;
    dedicate(db, b.id, p).await;
    Shared {
        alice,
        bob,
        carol,
        p,
        a,
        b,
        m,
    }
}

/// 运行的两个 token 上限：树共用的（`max_tokens`，成员预算）和它自己的（`own_max_tokens`，botin 限额）。
async fn caps(db: &Db, run: RunId) -> (Option<u64>, Option<u64>) {
    let v: serde_json::Value = sqlx::query_scalar("SELECT budget FROM runs WHERE id = $1")
        .bind(run.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    (v["max_tokens"].as_u64(), v["own_max_tokens"].as_u64())
}

async fn task(
    db: &Db,
    by: UserId,
    p: ProjectId,
    to: Option<InstanceId>,
) -> crate::Result<crate::Dispatched> {
    let mut w = db.worker().await.unwrap();
    let r = w
        .create_project_task(by, p, to, "write the brief", TTL)
        .await;
    match r {
        Ok(d) => {
            w.commit().await.unwrap();
            Ok(d)
        }
        Err(e) => Err(e),
    }
}

async fn run_row(db: &Db, run: RunId) -> (String, Option<String>, Option<uuid::Uuid>, uuid::Uuid) {
    sqlx::query_as("SELECT state, wait_code, run_grant_id, user_id FROM runs WHERE id = $1")
        .bind(run.0)
        .fetch_one(db.pool())
        .await
        .unwrap()
}

async fn grant_scope(db: &Db, grant: uuid::Uuid) -> proto::domain::GrantScope {
    let v: serde_json::Value = sqlx::query_scalar("SELECT scope FROM run_grants WHERE id = $1")
        .bind(grant)
        .fetch_one(db.pool())
        .await
        .unwrap();
    serde_json::from_value(v).unwrap()
}

/// 创建者派任务（8.17 测试 3）：记在 botin 主人名下、用主人在项目里的常设授权（工具就是项目那一组），第二次用同一个授权；
/// 私人那边找不到这个授权。成员、外人、归档、开关关着的不行；混用的、撤下的、没负责人又没指定的、主人冻结的、排满的
/// 不行。
#[tokio::test]
async fn creator_task_rules() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017101).await;
    let d = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert_eq!(d.owner, s.bob);
    assert!(!d.needs_confirmation);
    let issued = d.grant_issued.expect("a new standing grant");
    let (state, wait, grant, owner) = run_row(db, d.run.id).await;
    assert_eq!((state.as_str(), wait, owner), ("queued", None, s.bob.0));
    assert_eq!(grant, Some(issued.0));
    assert_eq!(d.run.project_id, Some(s.p));
    let scope = grant_scope(db, issued.0).await;
    assert_eq!(scope.platform_tools, proto::domain::PROJECT_PLATFORM_TOOLS);
    assert!(scope.aliases.is_empty() && scope.max_tokens.is_none());
    // bob 在项目里的预算：每天一百万、总共五百万，没用过，任务的上限就是一百万。
    let budget: serde_json::Value = sqlx::query_scalar("SELECT budget FROM runs WHERE id = $1")
        .bind(d.run.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(budget["max_tokens"], 1_000_000);
    let again = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert_eq!(again.grant_issued, None);
    assert_eq!(run_row(db, again.run.id).await.2, Some(issued.0));
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.active_grant_for_instance(s.b.id).await.unwrap(), None);
    w.rollback().await.unwrap();
    // 不指定的派给负责人 a（alice 自己的）。
    let lead = task(db, s.alice, s.p, None).await.unwrap();
    assert_eq!((lead.owner, lead.run.instance_id), (s.alice, s.a.id));
    // 成员、外人。
    let err = task(db, s.bob, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    let err = task(db, s.carol, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // 混用的 m。
    let err = task(db, s.alice, s.p, Some(s.m.id)).await.unwrap_err();
    assert!(matches!(err, Error::AgentNotIsolated), "{err:?}");
    // bob 冻结了：他的 botin 接不了活。
    sqlx::query("UPDATE users SET status = 'frozen' WHERE id = $1")
        .bind(s.bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    let err = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::AgentUnavailable), "{err:?}");
    sqlx::query("UPDATE users SET status = 'active' WHERE id = $1")
        .bind(s.bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    // b 排满了（已经排了 2 个，再派 8 个到 10 个）。
    for _ in 0..8 {
        task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    }
    let err = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::AgentBusy), "{err:?}");
    // 开关关着。
    let mut w = db.worker().await.unwrap();
    w.set_project_dispatch(false, "test", None).await.unwrap();
    w.commit().await.unwrap();
    let err = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap_err();
    assert!(matches!(err, Error::DispatchOff), "{err:?}");
    let mut w = db.worker().await.unwrap();
    w.set_project_dispatch(true, "test", None).await.unwrap();
    w.commit().await.unwrap();
    // 没有负责人、也没指定：不行。
    let mut w = db.worker().await.unwrap();
    w.set_project_lead(s.alice, s.p, None).await.unwrap();
    w.commit().await.unwrap();
    let err = task(db, s.alice, s.p, None).await.unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    // a 撤下了：不行。
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.alice, s.p, s.a.id)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let err = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    // 项目归档了：找不到。
    let mut w = db.worker().await.unwrap();
    w.archive_project(s.alice, s.p).await.unwrap();
    w.commit().await.unwrap();
    let err = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
}

/// 预算（8.17 测试 3 的预算一半，用户 2026-11-07 定的 botin 限额）：任务的上限是成员预算和主人给这个 botin 设的限额里
/// 最紧的一个，用完了不派。限额只有主人能设，每天的不能大于总的。别人的 botin 用完了创建者只看到 AgentUnavailable，
/// 自己的才是 BudgetReached（派任务、开始流水线都是）。
#[tokio::test]
async fn budget_and_agent_limits() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017111).await;
    let set = |who: UserId, daily: Option<u64>, total: Option<u64>| async move {
        let mut w = db.worker().await.unwrap();
        let r = w
            .set_project_agent_limits(
                who,
                s.p,
                s.b.id,
                AgentLimits {
                    daily_token_limit: daily,
                    total_token_limit: total,
                },
            )
            .await;
        if r.is_ok() {
            w.commit().await.unwrap();
        }
        r
    };
    assert!(matches!(
        set(s.alice, Some(10), None).await,
        Err(Error::NotPermitted(_))
    ));
    assert!(matches!(
        set(s.bob, Some(10), Some(5)).await,
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        set(s.bob, Some(0), None).await,
        Err(Error::Invalid(_))
    ));
    set(s.bob, Some(3000), Some(4000)).await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.project_agent_limits(s.bob, s.p, s.b.id).await.unwrap(),
        AgentLimits {
            daily_token_limit: Some(3000),
            total_token_limit: Some(4000)
        }
    );
    assert!(matches!(
        w.project_agent_limits(s.alice, s.p, s.b.id).await,
        Err(Error::NotPermitted(_))
    ));
    assert!(matches!(
        w.project_agent_limits(s.carol, s.p, s.b.id).await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();
    // （树共用的上限 = 成员预算还剩的，任务自己的上限 = botin 限额还剩的。）
    let max_tokens = |d: crate::Dispatched| async move { caps(db, d.run.id).await };
    let first = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert_eq!(
        max_tokens(first.clone()).await,
        (Some(1_000_000), Some(3000))
    );
    // b 用掉 2500：今天还剩 500（总的剩 1500），任务自己的上限 500。
    sqlx::query("UPDATE runs SET tokens_used = 2500, state = 'succeeded', finished_at = now() WHERE id = $1")
        .bind(first.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let second = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert_eq!(
        max_tokens(second.clone()).await,
        (Some(1_000_000 - 2500), Some(500))
    );
    // 再用掉 500：今天的用完了。
    sqlx::query(
        "UPDATE runs SET tokens_used = 500, state = 'succeeded', finished_at = now() WHERE id = $1",
    )
    .bind(second.run.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    // 别人的 botin：和主人的账号不能用了是同一个错误（别人的预算、限额不告诉创建者），开始流水线也一样。
    let err = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::AgentUnavailable), "{err:?}");
    let err = start_pipeline(db, s.alice, s.p, &[step("x", s.b.id, "x", &[])])
        .await
        .unwrap_err();
    assert!(matches!(err, Error::AgentUnavailable), "{err:?}");
    // 去掉 botin 的限额：成员预算（每天一百万）里还剩不少。
    set(s.bob, None, None).await.unwrap();
    let third = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert_eq!(max_tokens(third).await, (Some(1_000_000 - 3000), None));
    // 成员预算改小到用掉的那么多：也用完了。
    let mut w = db.worker().await.unwrap();
    w.set_project_budget(
        s.bob,
        s.p,
        &ProjectBudget {
            daily_token_limit: Some(3000),
            total_token_limit: Some(3000),
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let err = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap_err();
    assert!(matches!(err, Error::AgentUnavailable), "{err:?}");
    // 创建者自己的 botin a 限额用完了：照旧说是预算用完了。
    let mut w = db.worker().await.unwrap();
    w.set_project_agent_limits(
        s.alice,
        s.p,
        s.a.id,
        AgentLimits {
            daily_token_limit: Some(100),
            total_token_limit: None,
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let own = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap();
    sqlx::query("UPDATE runs SET tokens_used = 100 WHERE id = $1")
        .bind(own.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let err = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap_err();
    assert!(matches!(err, Error::BudgetReached), "{err:?}");
    let err = start_pipeline(db, s.alice, s.p, &[step("x", s.a.id, "x", &[])])
        .await
        .unwrap_err();
    assert!(matches!(err, Error::BudgetReached), "{err:?}");
}

/// “全部停止”以后（8.17 测试 19，用户 2026-11-07 定）：别人照样能派，任务先等主人确认、不会被领走；主人拒绝的取消、
/// 暂停还在；主人确认一个，这个 botin 等确认的都换上新授权排队，之后派来的不再问。别人不能替主人确认；过期没确认的
/// 兜底取消。
#[tokio::test]
async fn stop_all_needs_one_confirmation() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017121).await;
    let first = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    let mut w = db.worker().await.unwrap();
    sqlx::query("UPDATE runs SET state = 'cancelled', finished_at = now() WHERE id = $1")
        .bind(first.run.id.0)
        .execute(w.conn())
        .await
        .unwrap();
    w.revoke_user_grants(s.bob, crate::STOP_ALL_REASON)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let (x, y, z) = (
        task(db, s.alice, s.p, Some(s.b.id)).await.unwrap(),
        task(db, s.alice, s.p, Some(s.b.id)).await.unwrap(),
        task(db, s.alice, s.p, Some(s.b.id)).await.unwrap(),
    );
    for d in [&x, &y, &z] {
        assert!(d.needs_confirmation);
        let (state, wait, ..) = run_row(db, d.run.id).await;
        assert_eq!(
            (state.as_str(), wait.as_deref()),
            ("queued", Some(crate::OWNER_CONFIRM_WAIT))
        );
    }
    let mut w = db.worker().await.unwrap();
    assert!(
        w.claim_next_run("w1", Duration::from_secs(60))
            .await
            .unwrap()
            .is_none()
    );
    // 也不会被捎带进 b 上跑着的项目运行里。
    assert!(
        w.unannounced_messages(s.b.id, Some(s.p), 10)
            .await
            .unwrap()
            .is_empty()
    );
    w.rollback().await.unwrap();
    let confirm = |who: UserId, run: RunId, yes: bool| async move {
        let mut w = db.worker().await.unwrap();
        let r = w.confirm_project_task(who, s.p, run, yes, TTL).await;
        if r.is_ok() {
            w.commit().await.unwrap();
        }
        r
    };
    assert!(matches!(
        confirm(s.alice, x.run.id, true).await,
        Err(Error::NotPermitted(_))
    ));
    let (declined, grant) = confirm(s.bob, x.run.id, false).await.unwrap();
    assert_eq!((declined, grant), (vec![x.run.id], None));
    assert_eq!(run_row(db, x.run.id).await.0, "cancelled");
    assert!(matches!(
        confirm(s.bob, x.run.id, true).await,
        Err(Error::Conflict(_))
    ));
    assert_eq!(
        run_row(db, y.run.id).await.1.as_deref(),
        Some(crate::OWNER_CONFIRM_WAIT)
    );
    // z 过了期限：兜底取消。
    sqlx::query("UPDATE runs SET wait_deadline = now() - interval '1 minute' WHERE id = $1")
        .bind(z.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.cancel_unconfirmed_project_tasks(10).await.unwrap(),
        vec![(z.run.id, s.b.id)]
    );
    w.commit().await.unwrap();
    let (resumed, grant) = confirm(s.bob, y.run.id, true).await.unwrap();
    assert_eq!(resumed, vec![y.run.id]);
    let grant = grant.expect("a new standing grant");
    let (state, wait, run_grant, _) = run_row(db, y.run.id).await;
    assert_eq!(
        (state.as_str(), wait, run_grant),
        ("queued", None, Some(grant.0))
    );
    let after = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert!(!after.needs_confirmation);
    assert_eq!(run_row(db, after.run.id).await.2, Some(grant.0));
    let mut w = db.worker().await.unwrap();
    let claimed = w
        .claim_next_run("w1", Duration::from_secs(60))
        .await
        .unwrap()
        .expect("the confirmed task");
    assert_eq!(claimed.run.id, y.run.id);
    assert_eq!(claimed.run.state, RunState::Starting);
}

/// 按“全部停止”的时候 botin 还没有常设授权（还没派过活）：之后派来的照样先等主人确认，确认一次就恢复正常；全部停止
/// 以后才加进项目的 botin 不用确认（迁移 0063）。
#[tokio::test]
async fn stop_all_before_any_grant_still_asks() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017191).await;
    let mut w = db.worker().await.unwrap();
    w.mark_stopped_all(s.bob).await.unwrap();
    w.commit().await.unwrap();
    let (x, y) = (
        task(db, s.alice, s.p, Some(s.b.id)).await.unwrap(),
        task(db, s.alice, s.p, Some(s.b.id)).await.unwrap(),
    );
    assert!(x.needs_confirmation && y.needs_confirmation);
    let grants: Vec<(uuid::Uuid, Option<String>)> = sqlx::query_as(
        "SELECT id, revoke_reason FROM run_grants WHERE instance_id = $1 AND project_id = $2 \
          ORDER BY created_at, id",
    )
    .bind(s.b.id.0)
    .bind(s.p.0)
    .fetch_all(db.pool())
    .await
    .unwrap();
    assert_eq!(
        grants.iter().map(|(_, r)| r.as_deref()).collect::<Vec<_>>(),
        vec![Some(crate::STOP_ALL_REASON)],
        "one paused marker, reused by the second task"
    );
    for d in [&x, &y] {
        let (state, wait, grant, _) = run_row(db, d.run.id).await;
        assert_eq!(
            (state.as_str(), wait.as_deref(), grant),
            ("queued", Some(crate::OWNER_CONFIRM_WAIT), Some(grants[0].0))
        );
    }
    let mut w = db.worker().await.unwrap();
    let (resumed, grant) = w
        .confirm_project_task(s.bob, s.p, x.run.id, true, TTL)
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(resumed.len(), 2);
    let after = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert!(!after.needs_confirmation);
    assert_eq!(run_row(db, after.run.id).await.2, grant.map(|g| g.0));
    // alice 的 a 在 alice 按全部停止之后才在项目里派活：a 是全部停止之前加进项目的，要确认。
    let mut w = db.worker().await.unwrap();
    w.mark_stopped_all(s.alice).await.unwrap();
    w.commit().await.unwrap();
    assert!(
        task(db, s.alice, s.p, Some(s.a.id))
            .await
            .unwrap()
            .needs_confirmation
    );
    // 全部停止以后才加进项目的不用（加入本身就是主人刚做的决定）。
    sqlx::query("UPDATE users SET stopped_all_at = now() - interval '1 hour' WHERE id = $1")
        .bind(s.bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query(
        "UPDATE run_grants SET revoked_at = now(), revoke_reason = 'test' WHERE instance_id = $1",
    )
    .bind(s.b.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    assert!(
        !task(db, s.alice, s.p, Some(s.b.id))
            .await
            .unwrap()
            .needs_confirmation
    );
}

/// “全部停止”和派单互相等（C6 评审）：一个派单正在给 b 签常设授权、还没提交，bob 这时按“全部停止”：等派单提交以后才
/// 吊销，新签的那个也吊销了；之后再派的先等确认。
#[tokio::test]
async fn stop_all_waits_for_an_in_flight_dispatch() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017201).await;
    let mut w1 = db.worker().await.unwrap();
    let d = w1
        .create_project_task(s.alice, s.p, Some(s.b.id), "write it", TTL)
        .await
        .unwrap();
    let issued = d.grant_issued.expect("a new standing grant");
    let stop = {
        let db = db.clone();
        let bob = s.bob;
        tokio::spawn(async move {
            let mut w = db.worker().await.unwrap();
            w.mark_stopped_all(bob).await.unwrap();
            let n = w
                .revoke_user_grants(bob, crate::STOP_ALL_REASON)
                .await
                .unwrap();
            w.commit().await.unwrap();
            n
        })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!stop.is_finished(), "stop all must wait for the dispatch");
    w1.commit().await.unwrap();
    assert!(stop.await.unwrap() >= 1);
    let reason: Option<String> =
        sqlx::query_scalar("SELECT revoke_reason FROM run_grants WHERE id = $1")
            .bind(issued.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(reason.as_deref(), Some(crate::STOP_ALL_REASON));
    assert!(
        task(db, s.alice, s.p, Some(s.b.id))
            .await
            .unwrap()
            .needs_confirmation
    );
}

/// 确认等着的任务（C6 评审）：委派来的子任务留着它从负责人的授权收窄出来的子授权，创建者派的换上新的常设授权。
#[tokio::test]
async fn confirming_keeps_a_delegate_child_grant() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017211).await;
    let lead = lead_run(db, &s).await;
    task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.mark_stopped_all(s.bob).await.unwrap();
    w.revoke_user_grants(s.bob, crate::STOP_ALL_REASON)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let held = match child(db, lead, s.p, s.b.id, &delegate("check numbers")).await {
        ProjectChildResult::Created {
            run, held: true, ..
        } => run,
        other => panic!("{other:?}"),
    };
    let child_grant = run_row(db, held.id).await.2.unwrap();
    let parent: Option<uuid::Uuid> =
        sqlx::query_scalar("SELECT parent_id FROM run_grants WHERE id = $1")
            .bind(child_grant)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert!(parent.is_some(), "a narrowed child grant");
    let creator = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert!(creator.needs_confirmation);
    let mut w = db.worker().await.unwrap();
    let (resumed, grant) = w
        .confirm_project_task(s.bob, s.p, creator.run.id, true, TTL)
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(resumed.len(), 2);
    assert_eq!(run_row(db, held.id).await.2, Some(child_grant));
    assert_eq!(run_row(db, creator.run.id).await.2, grant.map(|g| g.0));
}

/// 设负责人（8.17 测试 11）：只有创建者；共享项目里混用的不行、专属的行；只有自己的项目里混用的也行；旧的负责人清掉；
/// 撤下负责人以后项目没有负责人。
#[tokio::test]
async fn set_project_lead_rules() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017131).await;
    let lead = |who: UserId, p: ProjectId, i: Option<InstanceId>| async move {
        let mut w = db.worker().await.unwrap();
        let r = w.set_project_lead(who, p, i).await;
        if r.is_ok() {
            w.commit().await.unwrap();
        }
        r
    };
    assert!(matches!(
        lead(s.bob, s.p, Some(s.b.id)).await,
        Err(Error::NotPermitted(_))
    ));
    assert!(matches!(
        lead(s.alice, s.p, Some(s.m.id)).await,
        Err(Error::AgentNotIsolated)
    ));
    let change = lead(s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert_eq!(change.old, Some((s.a.id, s.alice)));
    assert_eq!(change.new, Some((s.b.id, s.bob)));
    let mut w = db.worker().await.unwrap();
    assert!(w.is_project_lead(s.p, s.b.id).await.unwrap());
    assert!(!w.is_project_lead(s.p, s.a.id).await.unwrap());
    w.rollback().await.unwrap();
    assert!(matches!(
        lead(s.alice, s.p, Some(InstanceId::new())).await,
        Err(Error::Invalid(_))
    ));
    // 只有自己的项目：混用的也能当负责人。
    let Fixture { alice, p, c, .. } = fixture(db, "+8613800017135").await;
    let change = lead(alice, p, Some(c.id)).await.unwrap();
    assert_eq!(change.new, Some((c.id, alice)));
    // bob 撤下负责人 b：项目没有负责人了。
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.bob, s.p, s.b.id).await.unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.project_lead(s.p).await.unwrap(), None);
    w.rollback().await.unwrap();
}

fn delegate(prompt: &str) -> ProjectChild<'_> {
    ProjectChild {
        source: RunSource::Delegate,
        prompt,
        max_depth: 3,
        max_siblings: 10,
        max_attempts: 3,
        answer_deadline: None,
        dedupe: false,
        grant_ttl: Duration::from_secs(7 * 24 * 3600),
    }
}

fn ask(prompt: &str) -> ProjectChild<'_> {
    ProjectChild {
        source: RunSource::Ask,
        max_siblings: 5,
        max_attempts: 2,
        answer_deadline: Some(chrono::Utc::now() + chrono::Duration::minutes(30)),
        dedupe: true,
        ..delegate(prompt)
    }
}

async fn child(
    db: &Db,
    caller: RunId,
    p: ProjectId,
    to: InstanceId,
    c: &ProjectChild<'_>,
) -> ProjectChildResult {
    let mut w = db.worker().await.unwrap();
    let r = w.project_child_run(caller, p, to, c).await.unwrap();
    w.commit().await.unwrap();
    r
}

fn created(r: ProjectChildResult) -> proto::domain::Run {
    match r {
        ProjectChildResult::Created { run, held, .. } => {
            assert!(!held);
            run
        }
        other => panic!("{other:?}"),
    }
}

fn refused(r: ProjectChildResult) -> ChildRefusal {
    match r {
        ProjectChildResult::Refused(why) => why,
        other => panic!("{other:?}"),
    }
}

/// 负责人 a 上的一个跑着的任务（创建者派的）。
async fn lead_run(db: &Db, s: &Shared) -> RunId {
    let d = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap();
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(d.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    d.run.id
}

async fn grant_row(db: &Db, g: uuid::Uuid) -> (uuid::Uuid, Option<uuid::Uuid>, Option<uuid::Uuid>) {
    sqlx::query_as("SELECT user_id, parent_id, project_id FROM run_grants WHERE id = $1")
        .bind(g)
        .fetch_one(db.pool())
        .await
        .unwrap()
}

/// alice 给负责人 a 设每天 9000、bob 给 b 设每天 7000（跨主人的子运行要带目标 botin 的，不带调用方的）。
async fn cross_owner_limits(db: &Db, s: &Shared) {
    let mut w = db.worker().await.unwrap();
    for (owner, instance, daily) in [(s.alice, s.a.id, 9000), (s.bob, s.b.id, 7000)] {
        w.set_project_agent_limits(
            owner,
            s.p,
            instance,
            AgentLimits {
                daily_token_limit: Some(daily),
                total_token_limit: None,
            },
        )
        .await
        .unwrap();
    }
    w.commit().await.unwrap();
}

/// 负责人跨主人委派（8.17 测试 4）：a（alice 的负责人）委派给 bob 的 b：子运行记在 bob 名下，子授权的父授权是 a 这次的
/// 授权、主人是 bob、在项目里，工具是两边都有的、别名用 bob 自己的；预算按 bob 还剩的。不是负责人的不能委派（库里的
/// 栅栏也挡着）；给自己、链上已有的、个数超了的不行。
#[tokio::test]
async fn lead_delegates_across_owners() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017141).await;
    cross_owner_limits(db, &s).await;
    let r = lead_run(db, &s).await;
    let c = created(child(db, r, s.p, s.b.id, &delegate("brief\n\nwrite it")).await);
    let (state, _, grant, owner) = run_row(db, c.id).await;
    assert_eq!((state.as_str(), owner), ("queued", s.bob.0));
    assert_eq!(c.parent_run_id, Some(r));
    assert_eq!(c.prompt, "brief\n\nwrite it");
    let lead_grant = run_row(db, r).await.2.unwrap();
    let grant = grant.unwrap();
    assert_eq!(
        grant_row(db, grant).await,
        (s.bob.0, Some(lead_grant), Some(s.p.0))
    );
    let scope = grant_scope(db, grant).await;
    assert_eq!(scope.platform_tools, proto::domain::PROJECT_PLATFORM_TOOLS);
    let budget: serde_json::Value = sqlx::query_scalar("SELECT budget FROM runs WHERE id = $1")
        .bind(c.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(budget["max_tokens"], 1_000_000);
    // 子运行自己的上限是 bob 给 b 设的 7000，不是 alice 给负责人 a 设的 9000。
    assert_eq!(caps(db, r).await.1, Some(9000));
    assert_eq!(caps(db, c.id).await, (Some(1_000_000), Some(7000)));
    // 给自己：不行。
    assert_eq!(
        refused(child(db, r, s.p, s.a.id, &delegate("x")).await),
        ChildRefusal::SelfTarget
    );
    // 一个运行最多开一个（测试里设成 1）：第二个不行。
    let one = ProjectChild {
        max_siblings: 1,
        ..delegate("again")
    };
    assert_eq!(
        refused(child(db, r, s.p, s.b.id, &one).await),
        ChildRefusal::TooMany
    );
    // b 上的子运行不是负责人：不能委派；问链上的 a 也不行（会互相等）。
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(c.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert_eq!(
        refused(child(db, c.id, s.p, s.a.id, &delegate("back")).await),
        ChildRefusal::NotLead
    );
    assert_eq!(
        refused(child(db, c.id, s.p, s.a.id, &ask("why?")).await),
        ChildRefusal::OnChain
    );
    // 库里也挡着：不是负责人的运行下面写不进委派。
    let bob_grant = run_row(db, c.id).await.2.unwrap();
    let got = constraint_of(
        db,
        s.p,
        Writer::Level(1),
        Row {
            instance: s.a.id,
            grant: Some(run_row(db, r).await.2.unwrap()),
            parent: Some(c.id),
            source: "delegate",
            urgent: false,
            plan: None,
        },
    )
    .await;
    assert_eq!(got, "project_delegate_not_lead", "{bob_grant}");
    // 混用的 m：不行。
    assert_eq!(
        refused(child(db, r, s.p, s.m.id, &delegate("x")).await),
        ChildRefusal::TargetNotIsolated
    );
}

/// 跨主人提问（8.17 测试 5）：子运行用 bob 自己的常设授权、存的是问题原文；同一个问题还没交还时就是那一个；太深的不行。
#[tokio::test]
async fn ask_across_owners() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017151).await;
    cross_owner_limits(db, &s).await;
    let r = lead_run(db, &s).await;
    let q = created(child(db, r, s.p, s.b.id, &ask("what is the deadline?")).await);
    assert_eq!(q.prompt, "what is the deadline?");
    assert_eq!(caps(db, q.id).await, (Some(1_000_000), Some(7000)));
    let (_, _, grant, owner) = run_row(db, q.id).await;
    assert_eq!(owner, s.bob.0);
    assert_eq!(
        grant_row(db, grant.unwrap()).await,
        (s.bob.0, None, Some(s.p.0))
    );
    match child(db, r, s.p, s.b.id, &ask("what is the deadline?")).await {
        ProjectChildResult::Existing(run) => assert_eq!(run.id, q.id),
        other => panic!("{other:?}"),
    }
    let shallow = ProjectChild {
        max_depth: 0,
        ..ask("another")
    };
    assert_eq!(
        refused(child(db, r, s.p, s.b.id, &shallow).await),
        ChildRefusal::TooDeep
    );
}

/// 同一个主人的 botin 之间委派、提问（终审 #3）：子运行树共用的上限沿用父运行的（不超过成员预算还剩的），自己的上限是
/// 目标 botin 还剩的限额（主人给它设的）。bob 的负责人 b 接了 alice 派的任务，委派、问 bob 的 b2（每天限 1000）。
#[tokio::test]
async fn same_owner_children_keep_the_target_limit() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017251).await;
    let b2 = instance(db, s.bob).await;
    sqlx::query(
        "INSERT INTO project_agents (project_id, instance_id, user_id, position) VALUES ($1, $2, $3, 3)",
    )
    .bind(s.p.0)
    .bind(b2.id.0)
    .bind(s.bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    dedicate(db, b2.id, s.p).await;
    let mut w = db.worker().await.unwrap();
    w.set_project_lead(s.alice, s.p, Some(s.b.id))
        .await
        .unwrap();
    w.set_project_agent_limits(
        s.bob,
        s.p,
        b2.id,
        AgentLimits {
            daily_token_limit: Some(1000),
            total_token_limit: None,
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    // bob 的成员预算每天 30,000（树共用的上限按它算），b2 自己每天 1000。
    sqlx::query("UPDATE project_members SET daily_token_limit = 30000 WHERE project_id = $1 AND user_id = $2")
        .bind(s.p.0)
        .bind(s.bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    let d = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(d.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert_eq!(caps(db, d.run.id).await, (Some(30_000), None));
    let c = created(child(db, d.run.id, s.p, b2.id, &delegate("brief\n\nwrite it")).await);
    assert_eq!(run_row(db, c.id).await.3, s.bob.0);
    assert_eq!(caps(db, c.id).await, (Some(30_000), Some(1000)));
    let q = created(child(db, d.run.id, s.p, b2.id, &ask("what is the deadline?")).await);
    assert_eq!(caps(db, q.id).await, (Some(30_000), Some(1000)));
    // 负责人已经花了 25,000，b2 花了 400（终审修复的复查 N1、B1）：执行器把树里 bob 用掉的都算进树共用的上限，所以它是
    // 成员预算还剩的 4600 加上树里的 25,400（只给 4600 的话子运行一开始就超）；b2 自己的上限只算 b2 用的，还剩 600。
    sqlx::query("UPDATE runs SET tokens_used = 25000 WHERE id = $1")
        .bind(d.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query(
        "UPDATE runs SET tokens_used = 400, state = 'succeeded', finished_at = now() WHERE id = $1",
    )
    .bind(c.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let c2 = created(child(db, d.run.id, s.p, b2.id, &delegate("brief\n\ncheck it")).await);
    assert_eq!(caps(db, c2.id).await, (Some(30_000), Some(600)));
    let q2 = created(child(db, d.run.id, s.p, b2.id, &ask("who reviews it?")).await);
    assert_eq!(caps(db, q2.id).await, (Some(30_000), Some(600)));
    // 树共用的上限取父运行的和成员预算的里紧的：父运行的更紧就用父运行的，父运行不限就用成员预算的。
    sqlx::query(
        "UPDATE runs SET budget = jsonb_set(budget, '{max_tokens}', '27000'::jsonb) WHERE id = $1",
    )
    .bind(d.run.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let c3 = created(child(db, d.run.id, s.p, b2.id, &delegate("brief\n\nlist it")).await);
    assert_eq!(caps(db, c3.id).await, (Some(27_000), Some(600)));
    sqlx::query(
        "UPDATE runs SET budget = jsonb_set(budget, '{max_tokens}', 'null'::jsonb) WHERE id = $1",
    )
    .bind(d.run.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let c4 = created(child(db, d.run.id, s.p, b2.id, &delegate("brief\n\nsort it")).await);
    assert_eq!(caps(db, c4.id).await, (Some(30_000), Some(600)));
}

/// 创建者自己的 botin 之间（终审修复的复查 R3、B1）：alice 没有成员预算，树共用的上限不限；m 每天 1000 时子运行自己的
/// 上限是 1000；a 的限额只管 a 自己的运行，不管它交给 m 的。
#[tokio::test]
async fn creator_children_use_their_own_botin_limit() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017261).await;
    dedicate(db, s.m.id, s.p).await;
    let limits = |daily: Option<u64>| AgentLimits {
        daily_token_limit: daily,
        total_token_limit: None,
    };
    let mut w = db.worker().await.unwrap();
    w.set_project_agent_limits(s.alice, s.p, s.m.id, limits(Some(1000)))
        .await
        .unwrap();
    w.commit().await.unwrap();
    let running = |run: RunId, tokens: i64| async move {
        sqlx::query("UPDATE runs SET state = 'running', tokens_used = $2 WHERE id = $1")
            .bind(run.0)
            .bind(tokens)
            .execute(db.pool())
            .await
            .unwrap();
    };
    let d = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap();
    assert_eq!(caps(db, d.run.id).await, (None, None));
    running(d.run.id, 300).await;
    let c = created(child(db, d.run.id, s.p, s.m.id, &delegate("brief\n\nwrite it")).await);
    assert_eq!(caps(db, c.id).await, (None, Some(1000)));
    let q = created(child(db, d.run.id, s.p, s.m.id, &ask("what is the deadline?")).await);
    assert_eq!(caps(db, q.id).await, (None, Some(1000)));
    // a 每天 5000（已经用了 300），m 不限：a 的任务自己的上限 4700，交给 m 的不限。
    let mut w = db.worker().await.unwrap();
    w.set_project_agent_limits(s.alice, s.p, s.a.id, limits(Some(5000)))
        .await
        .unwrap();
    w.set_project_agent_limits(s.alice, s.p, s.m.id, limits(None))
        .await
        .unwrap();
    w.commit().await.unwrap();
    sqlx::query("UPDATE runs SET state = 'succeeded', finished_at = now() WHERE id = $1")
        .bind(d.run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let d2 = task(db, s.alice, s.p, Some(s.a.id)).await.unwrap();
    assert_eq!(caps(db, d2.run.id).await, (None, Some(4700)));
    running(d2.run.id, 0).await;
    let c2 = created(child(db, d2.run.id, s.p, s.m.id, &delegate("brief\n\ncheck it")).await);
    assert_eq!(caps(db, c2.id).await, (None, None));
}

/// 任何一边撤下都停（8.17 测试 6、22）：负责人 a 撤下，a 的运行和 bob 那边的子运行一起取消，子授权不能用了；只撤 b，
/// b 的子运行取消、子授权吊销，a 的运行还在；bob 退出，他的子运行取消，alice 的运行还在。
#[tokio::test]
async fn revocation_either_side() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017161).await;
    let r = lead_run(db, &s).await;
    let c = created(child(db, r, s.p, s.b.id, &delegate("part 1")).await);
    let c_grant = proto::domain::GrantId(run_row(db, c.id).await.2.unwrap());
    // 撤 b：b 的子运行取消、子授权吊销；a 的还在跑。
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.bob, s.p, s.b.id).await.unwrap();
    w.commit().await.unwrap();
    assert_eq!(run_row(db, c.id).await.0, "cancelled");
    assert_eq!(run_row(db, r).await.0, "running");
    let mut w = db.worker().await.unwrap();
    assert!(
        w.touch_run_grant(c_grant, Duration::from_secs(60), TTL)
            .await
            .unwrap()
            .is_none()
    );
    w.rollback().await.unwrap();
    // b 回来（专属的还在），再委派一个；a 撤下：a 的运行和 b 上的子运行一起取消，子授权沿父授权链不能用了。
    let mut w = db.worker().await.unwrap();
    sqlx::query(
        "UPDATE project_agents SET left_at = NULL, added_at = now() WHERE instance_id = $1",
    )
    .bind(s.b.id.0)
    .execute(w.conn())
    .await
    .unwrap();
    w.commit().await.unwrap();
    let c2 = created(child(db, r, s.p, s.b.id, &delegate("part 2")).await);
    let c2_grant = proto::domain::GrantId(run_row(db, c2.id).await.2.unwrap());
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.alice, s.p, s.a.id)
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(run_row(db, r).await.0, "cancelled");
    assert_eq!(run_row(db, c2.id).await.0, "cancelled");
    let mut w = db.worker().await.unwrap();
    assert!(
        w.touch_run_grant(c2_grant, Duration::from_secs(60), TTL)
            .await
            .unwrap()
            .is_none()
    );
    w.rollback().await.unwrap();
}

/// bob 退出（8.17 测试 6 的另一半）：他的子运行取消，alice 负责人的运行还在。
#[tokio::test]
async fn leaving_cancels_only_the_leavers_part() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017171).await;
    let r = lead_run(db, &s).await;
    let c = created(child(db, r, s.p, s.b.id, &delegate("part")).await);
    let mut w = db.worker().await.unwrap();
    w.leave_project(s.bob, s.p).await.unwrap();
    w.commit().await.unwrap();
    assert_eq!(run_row(db, c.id).await.0, "cancelled");
    assert_eq!(run_row(db, r).await.0, "running");
}

/// 撤下一个 botin（8.17，D16）：它的运行连同整棵子树（包括它问出去、落在别人的 botin 上的）一起取消；别的不动。
#[tokio::test]
async fn withdrawing_cancels_the_botins_subtree() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017321).await;
    let lead = lead_run(db, &s).await;
    let on_b = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap().run.id;
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(on_b.0)
        .execute(db.pool())
        .await
        .unwrap();
    let asked = created(child(db, on_b, s.p, s.a.id, &ask("where is the data?")).await);
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.bob, s.p, s.b.id).await.unwrap();
    w.commit().await.unwrap();
    assert_eq!(run_row(db, on_b).await.0, "cancelled");
    assert_eq!(
        run_row(db, asked.id).await.0,
        "cancelled",
        "the question it asked alice's botin goes too"
    );
    assert_eq!(run_row(db, lead).await.0, "running");
}

/// 在项目里取消（8.17 测试 8）：创建者取消整棵树（连 bob 的子运行）；主人取消自己的；别的成员不行；结束了的不行。
#[tokio::test]
async fn project_cancel_rules() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017181).await;
    let r = lead_run(db, &s).await;
    let c = created(child(db, r, s.p, s.b.id, &delegate("part")).await);
    let cancel = |who: UserId, run: RunId| async move {
        let mut w = db.worker().await.unwrap();
        let out = w.cancel_project_run(who, s.p, run).await;
        if out.is_ok() {
            w.commit().await.unwrap();
        }
        out
    };
    assert!(matches!(
        cancel(s.bob, r).await,
        Err(Error::NotPermitted(_))
    ));
    assert!(matches!(cancel(s.carol, r).await, Err(Error::NotFound)));
    let (role, gone) = cancel(s.alice, r).await.unwrap();
    assert_eq!(role, proto::domain::ProjectRole::Creator);
    let mut gone: Vec<RunId> = gone.into_iter().map(|(r, _)| r).collect();
    gone.sort();
    let mut want = vec![r, c.id];
    want.sort();
    assert_eq!(gone, want);
    assert!(matches!(
        cancel(s.alice, r).await,
        Err(Error::InvalidTransition { .. })
    ));
    // bob 取消自己 botin 的任务。
    let own = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    let (role, gone) = cancel(s.bob, own.run.id).await.unwrap();
    assert_eq!(role, proto::domain::ProjectRole::Member);
    assert_eq!(gone, vec![(own.run.id, s.b.id)]);
}

/// 兜底取消没人管的子运行（8.17 测试 9）：负责人的运行从私人那条路被取消了（不知道 bob 那边的子运行），兜底把 bob 的
/// 子运行取消；别人锁着的这一轮跳过，下一轮再取消。
#[tokio::test]
async fn orphaned_children_swept() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017191).await;
    let r = lead_run(db, &s).await;
    let c = created(child(db, r, s.p, s.b.id, &delegate("part")).await);
    sqlx::query("UPDATE runs SET state = 'cancelled', finished_at = now() WHERE id = $1")
        .bind(r.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut holder = db.pool().begin().await.unwrap();
    sqlx::query("SELECT id FROM runs WHERE id = $1 FOR UPDATE")
        .bind(c.id.0)
        .execute(&mut *holder)
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(
        w.cancel_orphaned_project_children(10)
            .await
            .unwrap()
            .is_empty()
    );
    w.commit().await.unwrap();
    holder.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.cancel_orphaned_project_children(10).await.unwrap(),
        vec![(c.id, s.b.id)]
    );
    w.commit().await.unwrap();
    assert_eq!(run_row(db, c.id).await.0, "cancelled");
}

/// 项目里的运行树按主人算用量（8.17 测试 10）。
#[tokio::test]
async fn tree_tokens_per_owner() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017201).await;
    let r = lead_run(db, &s).await;
    let c = created(child(db, r, s.p, s.b.id, &delegate("part")).await);
    for (id, n) in [(r, 100), (c.id, 50)] {
        sqlx::query("UPDATE runs SET tokens_used = $2 WHERE id = $1")
            .bind(id.0)
            .bind(n)
            .execute(db.pool())
            .await
            .unwrap();
    }
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.tree_tokens_except(r, c.id, Some(s.bob)).await.unwrap(), 0);
    assert_eq!(
        w.tree_tokens_except(r, c.id, Some(s.alice)).await.unwrap(),
        100
    );
    assert_eq!(w.tree_tokens_except(r, r, Some(s.bob)).await.unwrap(), 50);
    assert_eq!(w.tree_tokens_except(r, c.id, None).await.unwrap(), 100);
    w.rollback().await.unwrap();
}

/// 取消别人的子运行时结掉审批、请求（8.17 测试 20）：bob 的子运行上等着的审批作废、出网请求过期。整棵树取消和
/// “父运行失败了取消子孙”两条路都这样。
#[tokio::test]
async fn cancels_settle_approvals() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017211).await;
    for path in ["subtree", "descendants"] {
        let r = lead_run(db, &s).await;
        let c = created(child(db, r, s.p, s.b.id, &delegate(path)).await);
        let mut w = db.worker().await.unwrap();
        let approval = w
            .create_approval(&crate::NewApproval {
                user: s.bob,
                instance: s.b.id,
                run: c.id,
                request_id: "perm-1",
                title: None,
                options: &serde_json::json!([]),
                tool_call: &serde_json::json!({}),
                expires_in: Duration::from_secs(600),
            })
            .await
            .unwrap();
        w.commit().await.unwrap();
        let egress = uuid::Uuid::now_v7();
        sqlx::query(
            "INSERT INTO egress_requests (id, user_id, instance_id, host, run_id) VALUES ($1, $2, $3, 'x.example', $4)",
        )
        .bind(egress)
        .bind(s.bob.0)
        .bind(s.b.id.0)
        .bind(c.id.0)
        .execute(db.pool())
        .await
        .unwrap();
        let mut w = db.worker().await.unwrap();
        if path == "subtree" {
            w.cancel_project_subtree(r, "stopped", true, false)
                .await
                .unwrap();
        } else {
            w.cancel_descendants(r, "the parent run failed")
                .await
                .unwrap();
        }
        w.commit().await.unwrap();
        let (a_state, e_state): (String, String) = sqlx::query_as(
            "SELECT (SELECT state FROM approvals WHERE id = $1), (SELECT status FROM egress_requests WHERE id = $2)",
        )
        .bind(approval.approval.id.0)
        .bind(egress)
        .fetch_one(db.pool())
        .await
        .unwrap();
        assert_eq!(
            (a_state.as_str(), e_state.as_str()),
            ("cancelled", "expired"),
            "{path}"
        );
        assert_eq!(run_row(db, c.id).await.0, "cancelled", "{path}");
        sqlx::query("UPDATE runs SET state = 'cancelled', finished_at = now() WHERE id = $1 AND state <> 'cancelled'")
            .bind(r.0)
            .execute(db.pool())
            .await
            .unwrap();
    }
}

/// bob 按“全部停止”（库里的两步：记下时间、吊销授权）：之后派给 b 的活等他确认。
async fn stop_bob(db: &Db, s: &Shared) {
    let mut w = db.worker().await.unwrap();
    w.mark_stopped_all(s.bob).await.unwrap();
    w.revoke_user_grants(s.bob, crate::STOP_ALL_REASON)
        .await
        .unwrap();
    w.commit().await.unwrap();
}

/// 等主人确认的子运行。
fn held(r: ProjectChildResult) -> proto::domain::Run {
    match r {
        ProjectChildResult::Created {
            run, held: true, ..
        } => run,
        other => panic!("{other:?}"),
    }
}

/// 给主人记一条等确认的提醒，指着这个运行（编排器的 `notify_held` 写的那种）。
async fn remind(db: &Db, owner: UserId, run: RunId, instance: InstanceId) {
    let mut w = db.worker().await.unwrap();
    w.insert_inbox(
        owner,
        &crate::NewInboxItem {
            kind: "info".into(),
            title: "Confirm a project task".into(),
            instance_id: Some(instance),
            run_id: Some(run),
            subtype: Some(crate::OWNER_CONFIRM_WAIT.into()),
            dedupe_key: Some(format!("owner_confirm:{run}")),
            ..Default::default()
        },
    )
    .await
    .unwrap()
    .expect("a new reminder");
    w.commit().await.unwrap();
}

/// 这些运行里等确认的提醒还没读的。
async fn unread_reminders(db: &Db, runs: &[RunId]) -> Vec<RunId> {
    let ids: Vec<uuid::Uuid> = runs.iter().map(|r| r.0).collect();
    let unread: Vec<uuid::Uuid> = sqlx::query_scalar(
        "SELECT run_id FROM inbox_items WHERE run_id = ANY($1) AND subtype = $2 AND read_at IS NULL \
          ORDER BY run_id",
    )
    .bind(&ids)
    .bind(crate::OWNER_CONFIRM_WAIT)
    .fetch_all(db.pool())
    .await
    .unwrap();
    unread.into_iter().map(RunId).collect()
}

/// 后台兜底取消等确认的任务（终审 #6）：bob 按了全部停止，a 问 b 的问题过了 30 分钟的回答期限被取消、a 委派给 b 的子任务
/// 在负责人的运行结束以后被取消，这两个的提醒都算已读；别的还在等确认的任务的提醒不动。
#[tokio::test]
async fn held_reminders_are_read_when_a_sweep_cancels_the_task() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017341).await;
    let r = lead_run(db, &s).await;
    stop_bob(db, &s).await;
    let keep = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert!(keep.needs_confirmation);
    remind(db, s.bob, keep.run.id, s.b.id).await;
    // 等确认的提问留着回答期限：过了期限，提问的清理取消它。
    let q = held(child(db, r, s.p, s.b.id, &ask("what is the deadline?")).await);
    remind(db, s.bob, q.id, s.b.id).await;
    sqlx::query("UPDATE runs SET answer_deadline = now() - interval '1 minute' WHERE id = $1")
        .bind(q.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    let gone: Vec<RunId> = w
        .cancel_stale_asks(10)
        .await
        .unwrap()
        .into_iter()
        .map(|r| r.id)
        .collect();
    w.commit().await.unwrap();
    assert_eq!(gone, vec![q.id]);
    assert_eq!(
        unread_reminders(db, &[keep.run.id, q.id]).await,
        vec![keep.run.id]
    );
    // 负责人的运行结束了：兜底取消它委派出去、还在等确认的子任务。
    let d = held(child(db, r, s.p, s.b.id, &delegate("check numbers")).await);
    remind(db, s.bob, d.id, s.b.id).await;
    sqlx::query("UPDATE runs SET state = 'cancelled', finished_at = now() WHERE id = $1")
        .bind(r.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.cancel_orphaned_project_children(10).await.unwrap(),
        vec![(d.id, s.b.id)]
    );
    w.commit().await.unwrap();
    assert_eq!(
        unread_reminders(db, &[keep.run.id, d.id]).await,
        vec![keep.run.id]
    );
    assert_eq!(run_row(db, keep.run.id).await.0, "queued");
}

/// 主人、项目那边停下等确认的任务（终审 #6）：bob 再按一次全部停止（冻结也是这条路）、撤下 b、alice 归档项目（关派单
/// 开关也是这条路），每次被取消的任务的提醒都算已读。
#[tokio::test]
async fn held_reminders_are_read_when_the_owner_or_the_project_stops() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017351).await;
    stop_bob(db, &s).await;
    let held_task = || async {
        let d = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
        assert!(d.needs_confirmation);
        remind(db, s.bob, d.run.id, s.b.id).await;
        assert_eq!(unread_reminders(db, &[d.run.id]).await, vec![d.run.id]);
        d.run.id
    };
    let x = held_task().await;
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.cancel_user_runs(s.bob, "stopped by the user")
            .await
            .unwrap(),
        1
    );
    w.commit().await.unwrap();
    assert!(unread_reminders(db, &[x]).await.is_empty(), "stop all");
    let y = held_task().await;
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.bob, s.p, s.b.id).await.unwrap();
    w.commit().await.unwrap();
    assert_eq!(run_row(db, y).await.0, "cancelled");
    assert!(unread_reminders(db, &[y]).await.is_empty(), "withdraw");
    // b 回来（还是专属的，加入的时间在全部停止之前：还要确认）。
    sqlx::query("UPDATE project_agents SET left_at = NULL WHERE instance_id = $1")
        .bind(s.b.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let z = held_task().await;
    let mut w = db.worker().await.unwrap();
    assert!(w.archive_project(s.alice, s.p).await.unwrap());
    w.commit().await.unwrap();
    assert_eq!(run_row(db, z).await.0, "cancelled");
    assert!(unread_reminders(db, &[z]).await.is_empty(), "archive");
}

/// 主人自己那边取消等确认的任务（终审 #6，租户的两条路）：bob 关了 b 的“允许别的 agent 问我”（问 b 的问题取消）、删了 b
/// （b 上的任务取消），被取消的任务的提醒都算已读。
#[tokio::test]
async fn held_reminders_are_read_when_the_owner_closes_or_deletes_the_botin() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017361).await;
    let r = lead_run(db, &s).await;
    stop_bob(db, &s).await;
    let q = held(child(db, r, s.p, s.b.id, &ask("what is the deadline?")).await);
    remind(db, s.bob, q.id, s.b.id).await;
    let mut tx = db.tenant(s.bob).await.unwrap();
    let gone: Vec<RunId> = tx
        .cancel_asks_to(s.b.id, "the agent stopped taking questions")
        .await
        .unwrap()
        .into_iter()
        .map(|r| r.id)
        .collect();
    tx.commit().await.unwrap();
    assert_eq!(gone, vec![q.id]);
    assert!(unread_reminders(db, &[q.id]).await.is_empty(), "questions");
    let x = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
    assert!(x.needs_confirmation);
    remind(db, s.bob, x.run.id, s.b.id).await;
    let mut tx = db.tenant(s.bob).await.unwrap();
    tx.remove_instance(s.b.id).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(run_row(db, x.run.id).await.0, "cancelled");
    assert!(unread_reminders(db, &[x.run.id]).await.is_empty(), "delete");
}

/// 主人从私人那边取消等确认的任务（终审 #6）：bob 拿着运行 id 用私人的取消接口停 b 上等确认的任务（单个、整棵树），
/// 被取消的那个的提醒算已读，别的不动。
#[tokio::test]
async fn held_reminders_are_read_when_the_owner_cancels_privately() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017371).await;
    stop_bob(db, &s).await;
    let mut held = Vec::new();
    for _ in 0..2 {
        let d = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap();
        assert!(d.needs_confirmation);
        remind(db, s.bob, d.run.id, s.b.id).await;
        held.push(d.run.id);
    }
    let (x, y) = (held[0], held[1]);
    let mut tx = db.tenant(s.bob).await.unwrap();
    tx.cancel_run(x, None).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(unread_reminders(db, &[x, y]).await, vec![y], "one run");
    let mut tx = db.tenant(s.bob).await.unwrap();
    assert_eq!(tx.cancel_run_tree(y, "stopped by user").await.unwrap(), 1);
    tx.commit().await.unwrap();
    assert!(unread_reminders(db, &[y]).await.is_empty(), "whole tree");
}

async fn post(
    db: &Db,
    by: BoardWriter,
    p: ProjectId,
    body: &str,
) -> crate::Result<(proto::domain::BoardPostId, u64)> {
    let mut w = db.worker().await.unwrap();
    let r = w
        .post_to_project_board(
            by,
            p,
            &NewProjectBoardPost {
                body: body.into(),
                tags: vec!["plan".into()],
            },
        )
        .await;
    if r.is_ok() {
        w.commit().await.unwrap();
    }
    r
}

async fn board(
    db: &Db,
    who: UserId,
    p: ProjectId,
    archived: bool,
) -> crate::Result<Vec<proto::domain::ProjectBoardPost>> {
    let mut m = db.member(who).await?;
    let r = m
        .project_board(
            p,
            &BoardFilter {
                archived,
                limit: 50,
                ..BoardFilter::default()
            },
        )
        .await;
    m.finish().await?;
    r
}

/// 项目看板（8.17 测试 12）：成员、成员的 agent 写；成员读得到（作者、是不是自己的、能不能管），外人、退出的读不到；
/// 私人看板的老读法碰不到项目条目，租户对这张表没有权限；只有作者和创建者能归档、删；成员每天手动写的有上限；agent 只能
/// 用在这个项目里的运行写；作者注销了条目还在。
#[tokio::test]
async fn project_board_isolation() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017221).await;
    let (from_alice, _) = post(db, BoardWriter::Member(s.alice), s.p, "kickoff notes")
        .await
        .unwrap();
    let (from_bob, _) = post(db, BoardWriter::Member(s.bob), s.p, "my plan")
        .await
        .unwrap();
    let r = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap().run.id;
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(r.0)
        .execute(db.pool())
        .await
        .unwrap();
    let (from_b, _) = post(db, BoardWriter::Agent(r), s.p, "draft is ready")
        .await
        .unwrap();
    let seen = board(db, s.bob, s.p, false).await.unwrap();
    let ids: Vec<_> = seen.iter().map(|x| x.id).collect();
    assert_eq!(ids, vec![from_b, from_bob, from_alice]);
    let b_post = &seen[0];
    assert!(b_post.ai_generated && b_post.mine && b_post.can_manage);
    assert_eq!(b_post.author_instance_id, Some(s.b.id));
    assert_eq!(b_post.run_id, Some(r));
    assert!(
        !seen[2].mine && !seen[2].can_manage,
        "bob cannot manage alice's post"
    );
    assert_eq!(seen[2].author.user_id, Some(s.alice));
    let alice_view = board(db, s.alice, s.p, false).await.unwrap();
    assert!(
        alice_view.iter().all(|x| x.can_manage),
        "the creator manages every post"
    );
    // 外人读不到。
    assert!(matches!(
        board(db, s.carol, s.p, false).await,
        Err(Error::NotFound)
    ));
    // 私人看板、租户：碰不到。
    let mut ta = db.tenant(s.alice).await.unwrap();
    let mine = ta
        .board_posts(&BoardFilter {
            limit: 50,
            ..BoardFilter::default()
        })
        .await
        .unwrap();
    assert!(mine.is_empty());
    assert!(matches!(
        ta.delete_board_post(from_alice).await,
        Err(Error::NotFound)
    ));
    ta.rollback().await.unwrap();
    let mut ta = db.tenant(s.alice).await.unwrap();
    let err = sqlx::query("SELECT count(*) FROM project_board_posts")
        .execute(ta.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    ta.rollback().await.unwrap();
    // 成员角色直接查：不是成员的 carol 一条也看不到（库里的策略，不只是接口按项目过滤）。
    let mut mc = db.member(s.carol).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM project_board_posts")
        .fetch_one(mc.conn())
        .await
        .unwrap();
    assert_eq!(n, 0);
    mc.finish().await.unwrap();
    // worker 往私人看板写一条挂着项目运行的（触发器按运行填上项目）：私人看板不收项目的条目。
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(
        "INSERT INTO board_posts (id, user_id, author_instance_id, run_id, by_agent, body) VALUES ($1, $2, $3, $4, true, 'x')",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(s.bob.0)
    .bind(s.b.id.0)
    .bind(r.0)
    .execute(w.conn())
    .await
    .unwrap_err();
    assert!(
        err.as_database_error().and_then(|d| d.constraint()) == Some("board_posts_private"),
        "{err}"
    );
    w.rollback().await.unwrap();
    // 管理：bob 不能归档 alice 的；alice（创建者）能归档 bob 的，也能删。
    let mut w = db.worker().await.unwrap();
    let err = w
        .set_project_board_post_archived(s.bob, s.p, from_alice, true)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.set_project_board_post_archived(s.alice, s.p, from_bob, true)
        .await
        .unwrap();
    w.delete_project_board_post(s.alice, s.p, from_b)
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(
        board(db, s.bob, s.p, true)
            .await
            .unwrap()
            .iter()
            .map(|x| x.id)
            .collect::<Vec<_>>(),
        vec![from_bob]
    );
    assert_eq!(board(db, s.bob, s.p, false).await.unwrap().len(), 1);
    // agent 只能用这个项目里的运行写：不在项目里的运行（私人的）找不到。
    let private = super::queue_run(db, s.alice, &s.m, "private").await;
    assert!(matches!(
        post(db, BoardWriter::Agent(private.id), s.p, "leak").await,
        Err(Error::NotFound)
    ));
    // 库里也挡着：agent 写的条目要和它的运行对得上。
    let err = sqlx::query(
        "INSERT INTO project_board_posts (id, project_id, author_user_id, author_instance_id, run_id, by_agent, body) \
         VALUES ($1, $2, $3, $4, NULL, true, 'x')",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(s.p.0)
    .bind(s.bob.0)
    .bind(s.b.id.0)
    .execute(db.pool())
    .await
    .unwrap_err();
    assert!(err.to_string().contains("does not match its run"), "{err}");
    // 每天手动写的上限：bob 再写 49 条到 50 条，第 51 条不行。
    for i in 0..49 {
        post(db, BoardWriter::Member(s.bob), s.p, &format!("note {i}"))
            .await
            .unwrap();
    }
    // 要等到窗口里最早的一条满 24 小时：最早那条是 10 小时前写的，就还要等 14 小时左右。
    sqlx::query(
        "UPDATE project_board_posts SET created_at = now() - interval '10 hours' WHERE id = $1",
    )
    .bind(from_bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    let Err(Error::RetryAfter(wait)) =
        post(db, BoardWriter::Member(s.bob), s.p, "one too many").await
    else {
        panic!("the 51st post today should be refused");
    };
    assert!((14 * 3600 - 60..=14 * 3600).contains(&wait), "{wait}");
    // bob 退出：读不到了；他写的还在（作者显示已退出）。
    let mut w = db.worker().await.unwrap();
    w.leave_project(s.bob, s.p).await.unwrap();
    w.commit().await.unwrap();
    assert!(matches!(
        board(db, s.bob, s.p, false).await,
        Err(Error::NotFound)
    ));
    let after = board(db, s.alice, s.p, true).await.unwrap();
    let bobs = after.iter().find(|x| x.id == from_bob).unwrap();
    assert_eq!(bobs.author.status, proto::domain::ProjectAuthorStatus::Left);
    assert_eq!(bobs.author.user_id, None);
}

/// 项目看板的条数上限（8.17 测试 12 的一半）：没归档的满 200 条再写，最早的自动归档；满的时候不能取消归档。
#[tokio::test]
async fn project_board_keeps_two_hundred_live() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017231).await;
    sqlx::query(
        "INSERT INTO project_board_posts (id, project_id, author_user_id, by_agent, body, created_at) \
         SELECT uuidv7_like, $1, $2, false, 'old', now() - interval '2 days' + n * interval '1 second' \
           FROM (SELECT gen_random_uuid() AS uuidv7_like, n FROM generate_series(1, 199) n) x",
    )
    .bind(s.p.0)
    .bind(s.alice.0)
    .execute(db.pool())
    .await
    .unwrap();
    let (_, archived) = post(db, BoardWriter::Member(s.alice), s.p, "200th")
        .await
        .unwrap();
    assert_eq!(archived, 0);
    let (_, archived) = post(db, BoardWriter::Member(s.alice), s.p, "201st")
        .await
        .unwrap();
    assert_eq!(archived, 1);
    let live: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM project_board_posts WHERE project_id = $1 AND archived_at IS NULL",
    )
    .bind(s.p.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!(live, 200);
    let gone: uuid::Uuid = sqlx::query_scalar(
        "SELECT id FROM project_board_posts WHERE project_id = $1 AND archived_at IS NOT NULL",
    )
    .bind(s.p.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    let err = w
        .set_project_board_post_archived(s.alice, s.p, proto::domain::BoardPostId(gone), false)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
}

/// 删项目以后后台把项目看板清掉（8.17 测试 17）；归档太久的维护任务删掉。
#[tokio::test]
async fn purge_removes_project_board_and_pipelines() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017241).await;
    let (old, _) = post(db, BoardWriter::Member(s.alice), s.p, "old")
        .await
        .unwrap();
    post(db, BoardWriter::Member(s.bob), s.p, "new")
        .await
        .unwrap();
    // 一条流水线（迁移 0065）：随根运行一起清掉。
    start_pipeline(db, s.alice, s.p, &[step("a", s.b.id, "find facts", &[])])
        .await
        .unwrap();
    sqlx::query(
        "UPDATE project_board_posts SET archived_at = now() - interval '40 days' WHERE id = $1",
    )
    .bind(old.0)
    .execute(db.pool())
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(
        w.purge_archived_project_board_posts(crate::BOARD_ARCHIVE_RETENTION)
            .await
            .unwrap(),
        1
    );
    w.delete_project(s.alice, s.p, true).await.unwrap();
    w.commit().await.unwrap();
    loop {
        let mut w = db.worker().await.unwrap();
        let n = w.purge_deleted_projects(50, Duration::ZERO).await.unwrap();
        w.commit().await.unwrap();
        if n == 0 {
            break;
        }
    }
    let left: i64 =
        sqlx::query_scalar("SELECT count(*) FROM project_board_posts WHERE project_id = $1")
            .bind(s.p.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(left, 0);
    let left: i64 =
        sqlx::query_scalar("SELECT count(*) FROM project_pipelines WHERE project_id = $1")
            .bind(s.p.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(left, 0);
}

/// 只按项目、按项目和作者找看板条目的（删项目后的清理、“还剩没有”、两个外键的级联删除）走索引（迁移 0066），不扫全表。
#[tokio::test]
async fn project_board_lookups_by_project_use_an_index() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let mut conn = db.pool().acquire().await.unwrap();
    sqlx::query("SET plan_cache_mode = force_generic_plan")
        .execute(&mut *conn)
        .await
        .unwrap();
    let id = "'00000000-0000-0000-0000-000000000000'";
    for (sql, args) in [
        // 外键 project_id → projects 的级联删除。
        (
            "DELETE FROM ONLY project_board_posts WHERE project_id = $1",
            id.to_string(),
        ),
        // 外键 (project_id, author_user_id) → project_members 的级联删除。
        (
            "DELETE FROM ONLY project_board_posts WHERE project_id = $1 AND author_user_id = $2",
            format!("{id}, {id}"),
        ),
        // 清理时的“还剩没有”。
        (
            "SELECT EXISTS (SELECT 1 FROM project_board_posts WHERE project_id = $1)",
            id.to_string(),
        ),
    ] {
        sqlx::query(sqlx::AssertSqlSafe(format!("PREPARE q AS {sql}")))
            .execute(&mut *conn)
            .await
            .unwrap();
        let plan: Vec<String> =
            sqlx::query_scalar(sqlx::AssertSqlSafe(format!("EXPLAIN EXECUTE q({args})")))
                .fetch_all(&mut *conn)
                .await
                .unwrap();
        sqlx::query("DEALLOCATE q")
            .execute(&mut *conn)
            .await
            .unwrap();
        let plan = plan.join("\n");
        assert!(plan.contains("project_board_posts_member"), "{sql}: {plan}");
    }
}

// ---------- 项目流水线（8.17，迁移 0065） ----------

fn step(
    key: &str,
    instance: InstanceId,
    prompt: &str,
    deps: &[&str],
) -> proto::domain::ProjectPipelineStep {
    proto::domain::ProjectPipelineStep {
        key: key.into(),
        instance_id: instance,
        prompt: prompt.into(),
        depends_on: deps.iter().map(|d| d.to_string()).collect(),
    }
}

async fn start_pipeline(
    db: &Db,
    by: UserId,
    p: ProjectId,
    steps: &[proto::domain::ProjectPipelineStep],
) -> crate::Result<proto::domain::Run> {
    let mut w = db.worker().await.unwrap();
    let r = w
        .start_project_pipeline(by, p, "Launch report", "Ship the report", steps)
        .await;
    if r.is_ok() {
        w.commit().await.unwrap();
    }
    r
}

/// 开始项目流水线（S13）：只有创建者（成员 NotPermitted、外人 NotFound）；键、依赖、步数、要求都查；混用的 botin
/// AgentNotIsolated；根运行挂在创建者自己的专属 botin 上（不带授权，kind、source 都是 pipeline），步骤记下每个 botin 的
/// 主人；自己没有专属 botin 的 Invalid；开关关着 DispatchOff。成员看得到标题、各步，看不到主人；外人看不到。
#[tokio::test]
async fn project_pipeline_start_rules() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017301).await;
    let good = [
        step("fetch", s.b.id, "find three facts", &[]),
        step("write", s.a.id, "write it up", &["fetch"]),
    ];
    assert!(matches!(
        start_pipeline(db, s.bob, s.p, &good).await,
        Err(Error::NotPermitted(_))
    ));
    assert!(matches!(
        start_pipeline(db, s.carol, s.p, &good).await,
        Err(Error::NotFound)
    ));
    for bad in [
        vec![
            step("a", s.a.id, "x", &["b"]),
            step("b", s.a.id, "y", &["a"]),
        ],
        vec![step("Bad Key", s.a.id, "x", &[])],
        vec![step("a", s.a.id, "  ", &[])],
        vec![step("a", s.a.id, "x", &["nope"])],
        (0..21)
            .map(|i| step(&format!("s{i}"), s.a.id, "x", &[]))
            .collect(),
        vec![],
        vec![step("a", InstanceId::new(), "x", &[])],
    ] {
        assert!(
            matches!(
                start_pipeline(db, s.alice, s.p, &bad).await,
                Err(Error::Invalid(_))
            ),
            "{bad:?}"
        );
    }
    assert!(matches!(
        start_pipeline(db, s.alice, s.p, &[step("a", s.m.id, "x", &[])]).await,
        Err(Error::AgentNotIsolated)
    ));
    let root = start_pipeline(db, s.alice, s.p, &good).await.unwrap();
    assert_eq!(
        (
            root.kind,
            root.source,
            root.state,
            root.instance_id,
            root.prompt.as_str()
        ),
        (
            proto::domain::RunKind::Pipeline,
            RunSource::Pipeline,
            RunState::Queued,
            s.a.id,
            "Ship the report"
        )
    );
    let (_, _, grant, owner) = run_row(db, root.id).await;
    assert_eq!((grant, owner), (None, s.alice.0));
    let mut w = db.worker().await.unwrap();
    let pl = w.project_pipeline(root.id).await.unwrap().unwrap();
    assert_eq!(pl.created_by, s.alice);
    assert_eq!(
        pl.steps.iter().map(|x| x.user_id).collect::<Vec<_>>(),
        vec![s.bob, s.alice]
    );
    assert_eq!(
        w.due_project_pipelines(10).await.unwrap(),
        vec![(root.id, s.p)]
    );
    w.rollback().await.unwrap();
    // 成员看到的：没有主人。外人看不到。
    let mut m = db.member(s.bob).await.unwrap();
    let seen = m.project_pipeline(s.p, root.id).await.unwrap();
    m.finish().await.unwrap();
    assert_eq!(seen.title, "Launch report");
    assert_eq!(seen.goal, "Ship the report");
    assert_eq!(seen.steps.len(), 2);
    assert!(
        !serde_json::to_string(&seen)
            .unwrap()
            .contains(&s.bob.to_string())
    );
    let mut m = db.member(s.carol).await.unwrap();
    assert!(m.project_pipeline(s.p, root.id).await.is_err());
    m.finish().await.unwrap();
    // 没写目标：读回来目标是空的，不是标题。
    let mut w = db.worker().await.unwrap();
    let bare = w
        .start_project_pipeline(s.alice, s.p, " Launch report ", "  ", &good)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let mut m = db.member(s.bob).await.unwrap();
    let seen = m.project_pipeline(s.p, bare.id).await.unwrap();
    m.finish().await.unwrap();
    assert_eq!(
        (seen.title.as_str(), seen.goal.as_str()),
        ("Launch report", "")
    );
    // 开关关着。
    let mut w = db.worker().await.unwrap();
    w.set_project_dispatch(false, "test", None).await.unwrap();
    w.commit().await.unwrap();
    assert!(matches!(
        start_pipeline(db, s.alice, s.p, &good).await,
        Err(Error::DispatchOff)
    ));
    let mut w = db.worker().await.unwrap();
    w.set_project_dispatch(true, "test", None).await.unwrap();
    w.commit().await.unwrap();
    // alice 撤下她的专属 botin 以后，自己没有专属的了：开始不了（步骤都在 bob 的上也不行）。
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.alice, s.p, s.a.id)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let err = start_pipeline(db, s.alice, s.p, &[step("a", s.b.id, "x", &[])])
        .await
        .unwrap_err();
    assert!(
        matches!(&err, Error::Invalid(m) if m.contains("your own dedicated botins")),
        "{err:?}"
    );
}

/// 开项目流水线的步骤（S13）：按 D4 加锁拿到根运行；一步用那个 botin 自己的常设授权、它主人的名下；主人按了“全部停止”的
/// 先等确认；botin 撤下了的开不了（平台的说明）。
#[tokio::test]
async fn project_pipeline_steps() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017311).await;
    let root = start_pipeline(
        db,
        s.alice,
        s.p,
        &[
            step("fetch", s.b.id, "find three facts", &[]),
            step("write", s.a.id, "write it up", &[]),
        ],
    )
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    let (rec, pl) = w.lock_project_pipeline(root.id).await.unwrap().unwrap();
    // 另一个副本：被项目锁挡住，这里不等它，看根运行被锁着时跳过。
    let started = w
        .project_step_run(&rec, &pl.steps[1], "write it up\n---", TTL)
        .await
        .unwrap();
    let crate::ProjectStepStart::Started {
        run, held: false, ..
    } = started
    else {
        panic!("{started:?}")
    };
    w.commit().await.unwrap();
    let (state, _, grant, owner) = run_row(db, run.id).await;
    assert_eq!((state.as_str(), owner), ("queued", s.alice.0));
    let parent: Option<uuid::Uuid> =
        sqlx::query_scalar("SELECT parent_id FROM run_grants WHERE id = $1")
            .bind(grant.unwrap())
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(
        parent, None,
        "a step runs on the agent's own standing grant"
    );
    assert_eq!(run.step_key.as_deref(), Some("write"));
    assert_eq!(run.parent_run_id, Some(root.id));
    // bob 按了全部停止：他那一步先等确认。
    let mut w = db.worker().await.unwrap();
    w.mark_stopped_all(s.bob).await.unwrap();
    w.revoke_user_grants(s.bob, crate::STOP_ALL_REASON)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let (rec, pl) = w.lock_project_pipeline(root.id).await.unwrap().unwrap();
    let started = w
        .project_step_run(&rec, &pl.steps[0], "find three facts\n---", TTL)
        .await
        .unwrap();
    let crate::ProjectStepStart::Started {
        run: held,
        held: true,
        ..
    } = started
    else {
        panic!("{started:?}")
    };
    w.rollback().await.unwrap();
    let _ = held;
    // 根运行被别人锁着：这一轮跳过。
    let mut other = db.pool().begin().await.unwrap();
    sqlx::query("SELECT 1 FROM runs WHERE id = $1 FOR UPDATE")
        .bind(root.id.0)
        .execute(&mut *other)
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(w.lock_project_pipeline(root.id).await.unwrap().is_none());
    w.rollback().await.unwrap();
    other.rollback().await.unwrap();
    // bob 撤下了 b：那一步开不了。
    let mut w = db.worker().await.unwrap();
    w.withdraw_project_agent(s.bob, s.p, s.b.id).await.unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let (rec, pl) = w.lock_project_pipeline(root.id).await.unwrap().unwrap();
    let refused = w
        .project_step_run(&rec, &pl.steps[0], "find three facts", TTL)
        .await
        .unwrap();
    assert!(
        matches!(&refused, crate::ProjectStepStart::Refused(m) if m == "the agent for step fetch cannot take project work now"),
        "{refused:?}"
    );
    w.rollback().await.unwrap();
}

/// 排满了的 botin 上的步骤（终审 #8）：步骤也守“每个 botin 最多排 10 个项目任务”。开始时一个 botin 上的步骤多于 10 个
/// 不拒绝（还没排），已经排满的拒绝（AgentBusy）。开步骤时满了的 Deferred（不是 Refused，流水线不失败），同一轮里刚开的
/// 也算；排着的做完以后照常开。
#[tokio::test]
async fn project_pipeline_steps_wait_for_a_full_queue() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017331).await;
    let steps: Vec<_> = (0..12)
        .map(|i| step(&format!("s{i}"), s.b.id, "find a fact", &[]))
        .collect();
    let root = start_pipeline(db, s.alice, s.p, &steps).await.unwrap();
    // b 排满了创建者派的 10 个任务：再开始一条用 b 的流水线不行。
    let mut tasks = Vec::new();
    for _ in 0..10 {
        tasks.push(task(db, s.alice, s.p, Some(s.b.id)).await.unwrap().run.id);
    }
    let err = start_pipeline(db, s.alice, s.p, &[step("x", s.b.id, "x", &[])])
        .await
        .unwrap_err();
    assert!(matches!(err, Error::AgentBusy), "{err:?}");
    // 已经开始的那条：b 的步骤先不开。
    let mut w = db.worker().await.unwrap();
    let (rec, pl) = w.lock_project_pipeline(root.id).await.unwrap().unwrap();
    let r = w
        .project_step_run(&rec, &pl.steps[0], "find a fact", TTL)
        .await
        .unwrap();
    assert!(matches!(r, crate::ProjectStepStart::Deferred), "{r:?}");
    w.rollback().await.unwrap();
    // 排着的做完了：同一轮里开到 10 个，第 11 个起再等。
    for id in &tasks {
        sqlx::query("UPDATE runs SET state = 'succeeded', finished_at = now() WHERE id = $1")
            .bind(id.0)
            .execute(db.pool())
            .await
            .unwrap();
    }
    let mut w = db.worker().await.unwrap();
    let (rec, pl) = w.lock_project_pipeline(root.id).await.unwrap().unwrap();
    for (i, st) in pl.steps.iter().enumerate() {
        let r = w
            .project_step_run(&rec, st, "find a fact", TTL)
            .await
            .unwrap();
        if i < 10 {
            assert!(
                matches!(r, crate::ProjectStepStart::Started { held: false, .. }),
                "{i}: {r:?}"
            );
        } else {
            assert!(matches!(r, crate::ProjectStepStart::Deferred), "{i}: {r:?}");
        }
    }
    w.commit().await.unwrap();
}

/// 同一个 botin 上排着的几个任务不各花一遍限额（终审第四轮 F1）：派单时两个任务记的都是当时还剩的 20,000；第一个
/// 跑完用了 15,000，第二个被领走时自己的上限收紧到还剩的 5000。重试再领（已经开始过）不再收：执行器算的是它从头到现在
/// 的用量，余额里已经扣过它自己的。
#[tokio::test]
async fn queued_runs_on_one_botin_share_its_limit() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017351).await;
    let mut w = db.worker().await.unwrap();
    w.set_project_agent_limits(
        s.bob,
        s.p,
        s.b.id,
        AgentLimits {
            daily_token_limit: Some(20_000),
            total_token_limit: None,
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let first = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap().run.id;
    let second = task(db, s.alice, s.p, Some(s.b.id)).await.unwrap().run.id;
    assert_eq!(caps(db, first).await.1, Some(20_000));
    assert_eq!(caps(db, second).await.1, Some(20_000));
    let claim = || async {
        let mut w = db.worker().await.unwrap();
        let rec = w
            .claim_next_run("w1", Duration::from_secs(60))
            .await
            .unwrap()
            .expect("a run to claim");
        w.commit().await.unwrap();
        rec
    };
    let rec = claim().await;
    assert_eq!(
        (rec.run.id, rec.budget.own_max_tokens),
        (first, Some(20_000))
    );
    sqlx::query(
        "UPDATE runs SET state = 'succeeded', started_at = now(), finished_at = now(), tokens_used = 15000, \
           lease_owner = NULL WHERE id = $1",
    )
    .bind(first.0)
    .execute(db.pool())
    .await
    .unwrap();
    let rec = claim().await;
    assert_eq!(
        (rec.run.id, rec.budget.own_max_tokens),
        (second, Some(5000))
    );
    assert_eq!(caps(db, second).await.1, Some(5000));
    // 第二个用了 1000 以后退避重试：再领时上限还是 5000（不是 4000）。
    sqlx::query(
        "UPDATE runs SET state = 'backoff', started_at = now(), tokens_used = 1000, lease_owner = NULL, \
           lease_expires_at = NULL, not_before = now() WHERE id = $1",
    )
    .bind(second.0)
    .execute(db.pool())
    .await
    .unwrap();
    let rec = claim().await;
    assert_eq!(
        (rec.run.id, rec.budget.own_max_tokens),
        (second, Some(5000))
    );
}

/// 流水线后面的步骤（终审修复的复查 N1、B1）：同一个主人前面的步骤用掉的在同一棵树里，执行器会算进树共用的上限，所以它
/// 是成员预算还剩的加上前面用掉的；这一步自己的上限是这个 botin 的限额还剩的（只算这个 botin 用的）。
#[tokio::test]
async fn later_pipeline_steps_count_earlier_spend_once() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let s = shared(db, 13800017341).await;
    let mut w = db.worker().await.unwrap();
    w.set_project_agent_limits(
        s.bob,
        s.p,
        s.b.id,
        AgentLimits {
            daily_token_limit: Some(20_000),
            total_token_limit: None,
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let steps = [
        step("fetch", s.b.id, "find a fact", &[]),
        step("write", s.b.id, "write it up", &["fetch"]),
    ];
    let root = start_pipeline(db, s.alice, s.p, &steps).await.unwrap();
    let start = |key: &'static str| async move {
        let mut w = db.worker().await.unwrap();
        let (rec, pl) = w.lock_project_pipeline(root.id).await.unwrap().unwrap();
        let st = pl.steps.iter().find(|st| st.key == key).unwrap().clone();
        let r = w.project_step_run(&rec, &st, "go", TTL).await.unwrap();
        w.commit().await.unwrap();
        match r {
            crate::ProjectStepStart::Started { run, .. } => run.id,
            other => panic!("{other:?}"),
        }
    };
    let fetch = start("fetch").await;
    assert_eq!(caps(db, fetch).await, (Some(1_000_000), Some(20_000)));
    sqlx::query(
        "UPDATE runs SET state = 'succeeded', tokens_used = 12000, finished_at = now() WHERE id = $1",
    )
    .bind(fetch.0)
    .execute(db.pool())
    .await
    .unwrap();
    // 树共用的（成员预算）：还剩的 988,000 加上树里 fetch 用掉的 12,000；这一步自己的：b 的限额还剩 8000。
    let write = start("write").await;
    assert_eq!(caps(db, write).await, (Some(1_000_000), Some(8000)));
}

/// 项目的新表租户一点权限都没有（S16）：派单开关、项目看板、项目流水线。
#[tokio::test]
async fn tenants_cannot_touch_project_collaboration_tables() {
    let Some(t) = TestDb::new().await else { return };
    for table in [
        "project_dispatch",
        "project_board_posts",
        "project_pipelines",
    ] {
        let any: bool = sqlx::query_scalar(
            "SELECT has_table_privilege('thinktin_app', $1, 'SELECT, INSERT, UPDATE, DELETE') \
                 OR has_any_column_privilege('thinktin_app', $1, 'SELECT, INSERT, UPDATE')",
        )
        .bind(table)
        .fetch_one(t.db.pool())
        .await
        .unwrap();
        assert!(!any, "tenants must not touch {table}");
    }
}
