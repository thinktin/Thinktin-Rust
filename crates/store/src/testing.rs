//! 测试辅助：每个测试一个新建的数据库，跑完迁移；测试结束时删掉。
//!
//! 连接串取 `DATABASE_URL`（本地用 `tools/dev/setup-db.sh` 起库）。没设置时 [`TestDb::new`]
//! 返回 None，测试跳过；设置了 `THINKTIN_REQUIRE_DB=1` 时改为直接失败，避免 CI 里悄悄跳过。

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Connection, PgConnection};

use crate::Db;

pub struct TestDb {
    pub db: Db,
    admin: PgConnectOptions,
    name: String,
}

impl TestDb {
    pub async fn new() -> Option<TestDb> {
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
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE DATABASE {name}")))
            .execute(&mut conn)
            .await
            .expect("create test database");
        conn.close().await.ok();
        let pool = PgPoolOptions::new()
            .max_connections(16)
            .connect_with(admin.clone().database(&name))
            .await
            .expect("connect to test database");
        let db = Db::from_pool(pool);
        db.migrate().await.expect("migrate test database");
        Some(TestDb { db, admin, name })
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
