//! `thinktin-relay`：设备中继（WBS 14.1）。说明见 [`relay`] 库和 docs/relay.md。

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::Context;
use auth::access_token::AccessTokenVerifier;
use auth::signed::Verifier25519;
use clap::Parser;
use relay::{Relay, RelayConfig};
use tracing::{error, info};

#[derive(Parser)]
#[command(
    name = "thinktin-relay",
    version,
    about = "ThinkTin 设备中继：电脑主动连出的长连接，转发电脑工具调用和手机电脑之间的消息"
)]
struct Cli {
    #[arg(long, env = "THINKTIN_RELAY_LISTEN", default_value = "127.0.0.1:8792")]
    listen: SocketAddr,
    /// 控制面数据库。登录账号要有 thinktin_relay 角色的成员身份
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,
    #[arg(long, default_value_t = 16)]
    db_connections: u32,
    /// 控制面签访问令牌的公钥，格式 `kid=base64url`，可重复（轮换时新旧都给）。
    /// `thinktin-server check` 会打印它
    #[arg(
        long = "access-key",
        env = "THINKTIN_ACCESS_TOKEN_KEYS",
        value_delimiter = ',',
        required = true
    )]
    access_keys: Vec<String>,
    /// 副本名（记进电脑的在线状态，排查用），默认主机名
    #[arg(long, env = "THINKTIN_NODE_ID")]
    node: Option<String>,
    /// 心跳间隔（秒），要明显短于 90 秒（平台判断电脑离线的时限）
    #[arg(long, default_value_t = 20)]
    heartbeat_secs: u64,
    /// 同时保持的电脑连接数上限
    #[arg(long, default_value_t = 50_000)]
    max_connections: usize,
    /// 停机时等连接收尾最多多少秒
    #[arg(long, default_value_t = 10)]
    grace_secs: u64,
    /// 日志输出 JSON
    #[arg(long)]
    log_json: bool,
    /// Prometheus `/metrics` 的监听地址（只给内网的抓取方）
    #[arg(long)]
    metrics_listen: Option<SocketAddr>,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into());
    if cli.log_json {
        tracing_subscriber::fmt()
            .json()
            .with_env_filter(filter)
            .with_writer(std::io::stderr)
            .init();
    } else {
        tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_writer(std::io::stderr)
            .init();
    }
    if !(1..=30).contains(&cli.heartbeat_secs) {
        anyhow::bail!("--heartbeat-secs must be between 1 and 30");
    }
    let mut keys = Verifier25519::new();
    for entry in &cli.access_keys {
        let (kid, key) = entry
            .trim()
            .split_once('=')
            .context("--access-key must look like kid=base64url")?;
        keys.add_key_b64(kid, key)
            .with_context(|| format!("bad --access-key for {kid}"))?;
    }
    let node = cli.node.clone().unwrap_or_else(|| {
        std::env::var("HOSTNAME")
            .ok()
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| "relay".into())
    });
    let cfg = RelayConfig {
        node,
        heartbeat: Duration::from_secs(cli.heartbeat_secs),
        max_connections: cli.max_connections,
        grace: Duration::from_secs(cli.grace_secs),
        ..RelayConfig::default()
    };
    tokio::runtime::Runtime::new()?.block_on(async move {
        let db = store::Db::connect(&cli.database_url, cli.db_connections)
            .await
            .context("connect to database")?;
        // 迁移由控制面的发布流程执行；这一版要的都执行过才启动（2.9）。
        db.check_migrations()
            .await
            .context("checking the database migrations")?;
        if let Some(addr) = cli.metrics_listen {
            let handle = metrics_exporter_prometheus::PrometheusBuilder::new()
                .install_recorder()
                .context("installing the metrics recorder")?;
            let l = tokio::net::TcpListener::bind(addr)
                .await
                .with_context(|| format!("bind {addr}"))?;
            let app = axum::Router::new().route(
                "/metrics",
                axum::routing::get(move || {
                    let h = handle.clone();
                    async move { h.render() }
                }),
            );
            tokio::spawn(async move {
                if let Err(e) = axum::serve(l, app).await {
                    error!(error = %e, "metrics endpoint stopped");
                }
            });
            info!(%addr, "metrics endpoint started");
        }
        let listener = tokio::net::TcpListener::bind(cli.listen)
            .await
            .with_context(|| format!("bind {}", cli.listen))?;
        let relay = Relay::new(db.clone(), AccessTokenVerifier(keys), cfg);
        relay.serve(listener, os_signal()).await?;
        db.pool().close().await;
        Ok(())
    })
}

/// SIGTERM（容器编排）或 Ctrl-C。
async fn os_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            error!(error = %e, "cannot listen for ctrl-c");
            std::future::pending::<()>().await;
        }
    };
    #[cfg(unix)]
    let term = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(e) => {
                error!(error = %e, "cannot listen for SIGTERM");
                std::future::pending::<()>().await;
            }
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {}
        () = term => {}
    }
    info!("shutdown requested");
}
