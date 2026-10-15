//! 后台任务的组装：调度循环、流水线推进、执行器、出箱投递、实例巡检、数据维护。

use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use chrono::{Datelike, NaiveDate, Utc};
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use notify::apns::{ApnsClient, ApnsConfig};
use notify::filter::KeywordFilter;
use notify::jpush::{JpushClient, JpushConfig};
use orchestrator::exec::{ExecConfig, ExecConnector};
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::outbox::{Dispatcher, DispatcherConfig};
use orchestrator::pipeline::{HandoffCopier, PipelineConfig, PipelineDriver};
use orchestrator::scheduler::{Scheduler, SchedulerConfig};
use orchestrator::shim::PlatformTools;
use orchestrator::tools::{ArtifactTools, ScheduleTools, ToolSet};
use proto::domain::PushChannelKind;
use sandbox::SandboxProvider;
use sandbox::local::LocalProvider;
use store::Db;
use tracing::{error, info};
use zeroize::Zeroizing;

use crate::{Background, Config, ShutdownListener};

/// 事件保留期（4.8）。
const EVENT_RETENTION_DAYS: i64 = 30;
/// 登录验证码保留多久（排查问题用），之后删除。
const LOGIN_CODE_RETENTION: Duration = Duration::from_secs(7 * 24 * 3600);
/// 会话失效（过期或吊销）多久以后清掉它的刷新令牌历史。
const REFRESH_HISTORY_RETENTION: Duration = Duration::from_secs(30 * 24 * 3600);

async fn stopped(mut stop: ShutdownListener) {
    stop.wait().await;
}

pub fn spawn(cfg: &Config, db: &Db, node_id: &str, bg: &mut Background) -> anyhow::Result<()> {
    let provider: Arc<dyn SandboxProvider> = Arc::new(
        LocalProvider::new(&cfg.sandbox.local_root)
            .with_context(|| format!("sandbox root {}", cfg.sandbox.local_root.display()))?,
    );
    let lifecycle = Arc::new(Lifecycle::new(
        db.clone(),
        provider.clone(),
        Arc::new(BuiltinTemplates),
        LifecycleConfig {
            network_allow: cfg.sandbox.network_allow.clone(),
            ..LifecycleConfig::default()
        },
    ));
    let seed = cfg
        .sandbox_token_seed
        .as_deref()
        .context("THINKTIN_SANDBOX_TOKEN_SEED is not set")?;
    let issuer = SandboxTokenIssuer::from_seed_b64(cfg.sandbox.token_kid.clone(), seed)
        .context("THINKTIN_SANDBOX_TOKEN_SEED")?;
    let grants = Arc::new(GrantService::new(
        db.clone(),
        GrantConfig::default(),
        issuer,
    ));
    let exec_cfg = ExecConfig {
        shim_path: cfg.sandbox.shim_path.clone(),
        gateway_url: cfg.sandbox.gateway_url.clone(),
        manifest_override: cfg.sandbox.manifest_override.clone(),
        ..ExecConfig::default()
    };
    let workdir = exec_cfg.workdir.clone();
    let connector = Arc::new(ExecConnector::new(provider.clone(), exec_cfg));
    let artifacts = crate::artifact_store(cfg, db, crate::kms(cfg)?)?;
    let tools: Vec<Arc<dyn PlatformTools>> = vec![
        Arc::new(ScheduleTools::new(db.clone())),
        Arc::new(ArtifactTools::new(
            db.clone(),
            artifacts.clone(),
            provider.clone(),
            workdir.clone(),
        )),
    ];
    let executor = Arc::new(
        Executor::new(
            db.clone(),
            node_id,
            lifecycle.clone(),
            grants,
            connector,
            Arc::new(ToolSet::new(tools)),
            ExecutorConfig {
                max_concurrent: cfg.worker.max_concurrent_runs,
                ..ExecutorConfig::default()
            },
        )
        .with_handoff(Arc::new(HandoffCopier::new(
            db.clone(),
            artifacts,
            provider,
            workdir,
        ))),
    );
    let pipelines = PipelineDriver::new(db.clone(), PipelineConfig::default());
    let scheduler = Scheduler::new(db.clone(), SchedulerConfig::default());
    let mut dispatcher = Dispatcher::new(db.clone(), node_id, DispatcherConfig::default());
    if let Some(path) = &cfg.compliance.push_keywords_file {
        let filter = KeywordFilter::load(path)
            .with_context(|| format!("reading push keywords {}", path.display()))?;
        info!(keywords = filter.len(), "push content filter loaded");
        dispatcher = dispatcher.with_filter(Arc::new(filter));
    }
    if let Some(apns) = &cfg.push.apns {
        let key = std::fs::read_to_string(&apns.key_path)
            .with_context(|| format!("reading APNs key {}", apns.key_path.display()))?;
        let client = ApnsClient::new(ApnsConfig {
            endpoint: apns.endpoint.clone(),
            topic: apns.topic.clone(),
            team_id: apns.team_id.clone(),
            key_id: apns.key_id.clone(),
            key_pem: Zeroizing::new(key),
        })
        .context("APNs client")?;
        dispatcher = dispatcher.with_channel(PushChannelKind::Apns, Arc::new(client));
    }
    if let Some(jpush) = &cfg.push.jpush {
        let client = JpushClient::new(JpushConfig {
            endpoint: jpush.endpoint.clone(),
            app_key: jpush.app_key.clone(),
            master_secret: Zeroizing::new(cfg.jpush_master_secret.clone().unwrap_or_default()),
            vendors: jpush.vendors.clone(),
            approval_channel: jpush.approval_channel.clone(),
            default_channel: jpush.default_channel.clone(),
        })
        .context("JPush client")?;
        dispatcher = dispatcher.with_channel(PushChannelKind::Unipush, Arc::new(client));
    }

    bg.spawn("scheduler", move |stop| async move {
        scheduler.run(stopped(stop)).await;
        Ok(())
    });
    bg.spawn("pipelines", move |stop| async move {
        pipelines.run(stopped(stop)).await;
        Ok(())
    });
    bg.spawn("executor", move |stop| async move {
        executor.run(stopped(stop)).await;
        Ok(())
    });
    bg.spawn("outbox", move |stop| async move {
        dispatcher.run(stopped(stop)).await;
        Ok(())
    });
    let sweep_every = Duration::from_secs(cfg.worker.sweep_every_secs.max(1));
    bg.spawn("sweeper", move |stop| async move {
        every(sweep_every, stop, || async {
            match lifecycle.sweep().await {
                Ok(r) if r.paused + r.archived + r.purged + r.failed > 0 => info!(
                    paused = r.paused,
                    archived = r.archived,
                    purged = r.purged,
                    failed = r.failed,
                    "instance sweep"
                ),
                Ok(_) => {}
                Err(e) => error!(error = %e, "instance sweep failed"),
            }
        })
        .await;
        Ok(())
    });
    let maintenance_every = Duration::from_secs(cfg.worker.maintenance_every_secs.max(60));
    let db = db.clone();
    bg.spawn("maintenance", move |stop| async move {
        every(maintenance_every, stop, || async {
            if let Err(e) = maintain(&db).await {
                error!(error = %e, "maintenance failed");
            }
        })
        .await;
        Ok(())
    });
    info!("background workers started");
    Ok(())
}

/// 每隔 `period` 跑一次 `f`（启动时先跑一次），直到停机。
async fn every<F, Fut>(period: Duration, mut stop: ShutdownListener, mut f: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let mut tick = tokio::time::interval(period);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            () = stop.wait() => return,
            _ = tick.tick() => f().await,
        }
    }
}

/// 事件分区提前建好、过期的删掉；清理过期的登录验证码。
async fn maintain(db: &Db) -> store::Result<()> {
    let today = Utc::now().date_naive();
    let this_month = NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap_or(today);
    let mut w = db.worker().await?;
    w.ensure_event_partitions(this_month, 3).await?;
    let dropped = w
        .drop_event_partitions_before(today - chrono::Duration::days(EVENT_RETENTION_DAYS))
        .await?;
    let purged = w.purge_login_codes(LOGIN_CODE_RETENTION).await?
        + w.purge_refresh_history(REFRESH_HISTORY_RETENTION).await?;
    w.commit().await?;
    if dropped > 0 || purged > 0 {
        info!(
            dropped_partitions = dropped,
            purged_codes = purged,
            "maintenance"
        );
    }
    Ok(())
}
