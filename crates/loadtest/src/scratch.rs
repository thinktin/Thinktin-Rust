//! 临时库：在给定的 Postgres 服务器上新建一个库、跑迁移，压测完删掉。连接账号要有建库权限。

use std::time::Duration;

use anyhow::Context;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Connection, PgConnection};
use store::Db;

pub struct ScratchDb {
    pub db: Db,
    pub name: String,
    admin: PgConnectOptions,
}

impl ScratchDb {
    /// `url` 指向服务器上任意一个能连的库（通常是 `postgres`）。`max_connections` 是被测组件共用的连接池大小。
    pub async fn create(url: &str, max_connections: u32) -> anyhow::Result<Self> {
        let admin: PgConnectOptions = url.parse().context("parse database url")?;
        let name = format!("thinktin_loadtest_{}", uuid::Uuid::now_v7().simple());
        let mut conn = PgConnection::connect_with(&admin)
            .await
            .context("connect to the database server")?;
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE DATABASE {name}")))
            .execute(&mut conn)
            .await
            .context("create the scratch database")?;
        conn.close().await.ok();
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(Duration::from_secs(60))
            .connect_with(admin.clone().database(&name))
            .await
            .context("connect to the scratch database")?;
        let db = Db::from_pool(pool);
        db.migrate().await.context("migrate the scratch database")?;
        Ok(Self { db, name, admin })
    }

    /// 关掉连接池、删库。
    pub async fn drop_db(self) -> anyhow::Result<()> {
        self.db.pool().close().await;
        let mut conn = PgConnection::connect_with(&self.admin).await?;
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE)",
            self.name
        )))
        .execute(&mut conn)
        .await?;
        conn.close().await.ok();
        Ok(())
    }
}
