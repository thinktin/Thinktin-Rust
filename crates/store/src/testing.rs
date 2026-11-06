//! 测试辅助：每个测试一个新建的数据库，跑完迁移；测试结束时删掉。
//!
//! 连接串取 `DATABASE_URL`（本地用 `tools/dev/setup-db.sh` 起库）。没设置时 [`TestDb::new`]
//! 返回 None，测试跳过；设置了 `THINKTIN_REQUIRE_DB=1` 时改为直接失败，避免 CI 里悄悄跳过。

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Connection, PgConnection};

use crate::Db;

pub struct TestDb {
    /// 超级用户的连接池（测试里的原始 SQL 照常绕过行级安全）。
    pub db: Db,
    admin: PgConnectOptions,
    /// 表的属主：不是超级用户、不能建角色、不绕过行级安全，和生产的迁移账号一样（docs/deploy-checklist.md 第 3 节）。
    owner: PgConnectOptions,
    name: String,
}

/// 测试库的属主账号（整个集群共享，没有就建）。
const OWNER: &str = "thinktin_test_owner";

impl TestDb {
    /// 新建一个库，用属主账号跑完全部迁移，打开派单开关（8.17：测试里项目运行照常能写；测开关本身的测试自己关）。
    pub async fn new() -> Option<TestDb> {
        let t = Self::empty().await?;
        t.migrate_rest().await;
        let mut w = t.db.worker().await.expect("worker transaction");
        w.set_project_dispatch(true, "test", None)
            .await
            .expect("switch project dispatch on");
        w.commit().await.expect("commit");
        Some(t)
    }

    /// 新建一个库，只跑到第 `version` 号迁移（测迁移本身用，之后 [`TestDb::migrate_rest`]）。
    pub async fn up_to(version: i64) -> Option<TestDb> {
        let t = Self::empty().await?;
        let pool = t.owner_pool().await;
        crate::schema::migrator()
            .run_to(version, &pool)
            .await
            .expect("migrate test database");
        pool.close().await;
        Some(t)
    }

    /// 用属主账号跑完剩下的迁移。
    pub async fn migrate_rest(&self) {
        self.try_migrate_rest()
            .await
            .expect("migrate test database");
    }

    /// 同 [`TestDb::migrate_rest`]，失败时返回错误（测迁移该失败的情况）。
    pub async fn try_migrate_rest(&self) -> Result<(), sqlx::migrate::MigrateError> {
        let pool = self.owner_pool().await;
        let r = crate::schema::migrator().run(&pool).await;
        pool.close().await;
        r
    }

    /// 以属主账号（不是超级用户、不是任何服务角色的成员）连上测试库，测启动核对之类的用。
    pub async fn owner_db(&self) -> Db {
        Db::from_pool(self.owner_pool().await)
    }

    /// 只有一个连接的属主连接池：迁移时别的连接都不碰这个库（不进事务的迁移文件不会互相等）。
    async fn owner_pool(&self) -> sqlx::PgPool {
        PgPoolOptions::new()
            .max_connections(1)
            .connect_with(self.owner.clone())
            .await
            .expect("connect to the test database as its owner")
    }

    async fn empty() -> Option<TestDb> {
        let Ok(url) = std::env::var("DATABASE_URL") else {
            if std::env::var("THINKTIN_REQUIRE_DB").is_ok_and(|v| v == "1") {
                panic!("DATABASE_URL is not set (THINKTIN_REQUIRE_DB=1)");
            }
            eprintln!("skipping: DATABASE_URL is not set (see tools/dev/setup-db.sh)");
            return None;
        };
        let admin: PgConnectOptions = url.parse().expect("DATABASE_URL");
        let name = format!("thinktin_test_{}", uuid::Uuid::now_v7().simple());
        let mut conn = PgConnection::connect_with(&admin)
            .await
            .expect("connect to DATABASE_URL");
        // 角色是整个集群共享的：由超级用户先建好（属主账号建不了），并行的测试排队建。
        sqlx::query("SELECT pg_advisory_lock(hashtextextended('thinktin-test-roles', 0))")
            .execute(&mut conn)
            .await
            .expect("lock test roles");
        sqlx::raw_sql(
            "DO $$ BEGIN
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_app') THEN
                 CREATE ROLE thinktin_app NOLOGIN NOBYPASSRLS; END IF;
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_worker') THEN
                 CREATE ROLE thinktin_worker NOLOGIN BYPASSRLS; END IF;
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_llmgw') THEN
                 CREATE ROLE thinktin_llmgw NOLOGIN BYPASSRLS; END IF;
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_relay') THEN
                 CREATE ROLE thinktin_relay NOLOGIN BYPASSRLS; END IF;
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_member') THEN
                 CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS; END IF;
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_project_definer') THEN
                 CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT; END IF;
               IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_test_owner') THEN
                 CREATE ROLE thinktin_test_owner LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS
                   PASSWORD 'thinktin_test_owner'; END IF;
             END $$;
             -- 和生产一样（docs/deploy-checklist.md 第 3 节）：迁移账号能 SET ROLE 到定义者（把函数交给它），不继承它。
             GRANT thinktin_project_definer TO thinktin_test_owner WITH INHERIT FALSE, SET TRUE",
        )
        .execute(&mut conn)
        .await
        .expect("create test roles");
        sqlx::query("SELECT pg_advisory_unlock(hashtextextended('thinktin-test-roles', 0))")
            .execute(&mut conn)
            .await
            .expect("unlock test roles");
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "CREATE DATABASE {name} OWNER {OWNER}"
        )))
        .execute(&mut conn)
        .await
        .expect("create test database");
        conn.close().await.ok();
        let pool = PgPoolOptions::new()
            .max_connections(16)
            .connect_with(
                admin
                    .clone()
                    .database(&name)
                    .application_name(crate::APPLICATION_NAME),
            )
            .await
            .expect("connect to test database");
        let owner = admin
            .clone()
            .database(&name)
            .username(OWNER)
            .password(OWNER);
        Some(TestDb {
            db: Db::from_pool(pool),
            admin,
            owner,
            name,
        })
    }
}

impl Drop for TestDb {
    fn drop(&mut self) {
        let admin = self.admin.clone();
        let name = std::mem::take(&mut self.name);
        // 测试运行时里不能再起运行时，换个线程同步删库。WITH (FORCE) 断开连接池里剩下的连接。
        let dropped = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            rt.block_on(async move {
                let mut conn = PgConnection::connect_with(&admin).await?;
                sqlx::query(sqlx::AssertSqlSafe(format!(
                    "DROP DATABASE IF EXISTS {name} WITH (FORCE)"
                )))
                .execute(&mut conn)
                .await?;
                conn.close().await
            })
            .map_err(std::io::Error::other)
        })
        .join();
        if !matches!(dropped, Ok(Ok(()))) {
            eprintln!("warning: could not drop test database");
        }
    }
}

/// 测试里用原始 SQL 写项目运行、项目授权、拿项目运行的租约（8.16、8.17 的栅栏）：在 `conn` 的事务里切到 worker，声明隔离
/// 级别 `level`（专属的 1、混用的 2）和这一版的项目协议。要在事务里调（设置只在这个事务里有效）。
pub async fn project_writer(conn: &mut PgConnection, level: u8) {
    sqlx::query(
        "SELECT set_config('role', 'thinktin_worker', true), set_config('thinktin.isolation', $1, true), \
                set_config('thinktin.project_protocol', $2, true)",
    )
    .bind(level.to_string())
    .bind(crate::PROJECT_PROTOCOL.to_string())
    .execute(conn)
    .await
    .expect("project writer settings");
}

/// 测试里一个排队的项目任务（8.17 之前没有派单接口的老测试用；派单本身的测试走 store 的派单）：给 (项目, 实例) 签一个
/// 项目授权，建一个带着它、用户发起的 agent 运行，主人是实例的主人。实例要是这个项目里还在的 agent。
pub async fn seed_project_run(
    db: &Db,
    project: proto::domain::ProjectId,
    instance: proto::domain::InstanceId,
    prompt: &str,
) -> (proto::domain::RunId, proto::domain::GrantId) {
    let (run, grant) = (proto::domain::RunId::new(), proto::domain::GrantId::new());
    let mut tx = db.pool().begin().await.expect("begin");
    project_writer(&mut tx, 2).await;
    sqlx::query(
        "INSERT INTO run_grants (id, user_id, instance_id, scope, expires_at, project_id) \
         SELECT $1, user_id, id, $2, now() + interval '30 days', $3 FROM instances WHERE id = $4",
    )
    .bind(grant.0)
    .bind(crate::to_json(&proto::domain::GrantScope::default()).expect("scope"))
    .bind(project.0)
    .bind(instance.0)
    .execute(&mut *tx)
    .await
    .expect("project grant");
    sqlx::query(
        "INSERT INTO runs (id, user_id, instance_id, project_id, root_run_id, source, prompt, agent_version, \
                           run_grant_id) \
         SELECT $1, user_id, id, $2, $1, 'user', $3, agent_version, $4 FROM instances WHERE id = $5",
    )
    .bind(run.0)
    .bind(project.0)
    .bind(prompt)
    .bind(grant.0)
    .bind(instance.0)
    .execute(&mut *tx)
    .await
    .expect("project run");
    tx.commit().await.expect("commit");
    (run, grant)
}
