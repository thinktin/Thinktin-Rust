//! 控制面主程序（WBS 3.5）：模块化单体，把接入网关、编排、通知等模块组装到一个进程里。
//!
//! 停机顺序：收到信号 → 就绪检查转为 503、后台任务停止领取新工作 → 等 `drain`（负载均衡摘除）
//! → 停止接新连接，等进行中的请求 → 等后台任务收尾（最多 `grace`）→ 关闭数据库连接池。

mod api;
pub mod config;
mod http;
mod lifecycle;
mod workers;

use std::future::{Future, IntoFuture};
use std::time::Duration;

use std::sync::Arc;

use anyhow::Context;
use keyvault::{Kms, LocalKms};
use orchestrator::artifacts::{ArtifactStore, LocalBlobStore};
use store::Db;
use tokio::net::TcpListener;
use tracing::{error, info, warn};

pub use config::Config;
pub use lifecycle::{Background, ShutdownListener, ShutdownSignal};

/// 测试用的替换件（生产用 [`serve`]，全部默认）。
#[derive(Default, Clone)]
pub struct Hooks {
    /// 短信发送：端到端测试用 `auth::sms::RecordingSms` 读验证码。
    pub sms: Option<std::sync::Arc<dyn auth::sms::SmsSender>>,
}

/// 连接数据库、按需迁移、监听端口，一直运行到收到停机信号。
pub async fn run(cfg: Config) -> anyhow::Result<()> {
    let db = Db::connect(cfg.database_url(), cfg.database.max_connections)
        .await
        .context("connect to database")?;
    if cfg.database.migrate_on_start {
        db.migrate().await.context("migrate")?;
        info!("migrations applied");
    }
    let listener = TcpListener::bind(cfg.listen)
        .await
        .with_context(|| format!("listen on {}", cfg.listen))?;
    serve(&cfg, db, listener, os_signal()).await
}

/// 在给定的监听上运行，`stop` 完成时开始停机。测试直接调用它。
pub async fn serve(
    cfg: &Config,
    db: Db,
    listener: TcpListener,
    stop: impl Future<Output = ()> + Send,
) -> anyhow::Result<()> {
    serve_with(cfg, db, listener, stop, Hooks::default()).await
}

/// 同 [`serve`]，带测试用的替换件。
pub async fn serve_with(
    cfg: &Config,
    db: Db,
    listener: TcpListener,
    stop: impl Future<Output = ()> + Send,
    hooks: Hooks,
) -> anyhow::Result<()> {
    let node_id = cfg.node_id();
    let addr = listener.local_addr()?;
    let shutdown = ShutdownSignal::new();
    let mut background = Background::new(shutdown.clone());
    if cfg.worker.enabled {
        workers::spawn(cfg, &db, &node_id, &mut background)?;
    }
    let api = if cfg.api.enabled {
        Some(api::build(cfg, &db, &mut background, &hooks)?)
    } else {
        None
    };
    let router = http::router(
        http::AppState {
            db: db.clone(),
            shutdown: shutdown.subscribe(),
        },
        api,
    );
    let drain = cfg.drain();
    let mut draining = shutdown.subscribe();
    let server = axum::serve(listener, router).with_graceful_shutdown(async move {
        draining.wait().await;
        tokio::time::sleep(drain).await;
    });
    let mut server = tokio::spawn(server.into_future());
    info!(%addr, node = %node_id, "server started");

    let mut failure = None;
    tokio::select! {
        () = stop => info!("shutdown requested"),
        Some((name, result)) = background.next_exit() => {
            // 后台任务应该一直跑到停机；提前退出说明出了问题，整个副本重启比带病运行好。
            let err = result.err().unwrap_or_else(|| anyhow::anyhow!("exited early"));
            error!(task = name, error = %err, "background task stopped, shutting down");
            failure = Some(err.context(format!("background task {name}")));
        }
        res = &mut server => {
            return match res {
                Ok(Ok(())) => Err(anyhow::anyhow!("http server stopped unexpectedly")),
                Ok(Err(e)) => Err(e).context("http server"),
                Err(e) => Err(e).context("http server task"),
            };
        }
    }

    shutdown.trigger();
    let grace = cfg.grace();
    match tokio::time::timeout(drain + grace, &mut server).await {
        Ok(Ok(Ok(()))) => info!("http server drained"),
        Ok(Ok(Err(e))) => warn!(error = %e, "http server error during shutdown"),
        Ok(Err(e)) => warn!(error = %e, "http server task failed"),
        Err(_) => {
            warn!(
                ?grace,
                "requests still running after grace period, dropping them"
            );
            server.abort();
        }
    }
    background.shutdown(grace).await;
    db.pool().close().await;
    info!("stopped");
    match failure {
        Some(err) => Err(err),
        None => Ok(()),
    }
}

/// 用户 DEK 的包裹密钥（本地 KMS；生产换成云 KMS）。
fn kms(cfg: &Config) -> anyhow::Result<Arc<dyn Kms>> {
    let kms = LocalKms::from_hex(
        cfg.api.kms_key_id.clone(),
        cfg.api_secrets.kms_key.as_deref().unwrap_or_default(),
    )
    .context("THINKTIN_KMS_KEY must be 64 hex characters")?;
    Ok(Arc::new(kms))
}

/// 产出物存储：接口（下载）和后台任务（发布、交接）共用。
fn artifact_store(cfg: &Config, db: &Db, kms: Arc<dyn Kms>) -> anyhow::Result<Arc<ArtifactStore>> {
    let blobs = LocalBlobStore::new(&cfg.storage.local_root)
        .with_context(|| format!("storage root {}", cfg.storage.local_root.display()))?;
    Ok(Arc::new(ArtifactStore::new(
        db.clone(),
        Arc::new(blobs),
        kms,
    )))
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
}

/// 就绪检查里数据库探活的上限。
const READY_PING_TIMEOUT: Duration = Duration::from_secs(2);
