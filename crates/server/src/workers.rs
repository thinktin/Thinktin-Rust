//! 后台任务的组装：调度循环、流水线推进、执行器、出箱投递、电脑审批提醒、实例巡检、数据维护。

use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use chrono::{Datelike, NaiveDate, Utc};
use control::{BuiltinTemplates, Lifecycle};
use notify::apns::{ApnsClient, ApnsConfig};
use notify::fcm::{FcmClient, FcmConfig, ServiceAccount};
use notify::filter::KeywordFilter;
use notify::im::ImClient;
use notify::jpush::{JpushClient, JpushConfig};
use orchestrator::artifacts::ArtifactStore;
use orchestrator::computer::{DeviceCalls, notify_approval_requests};
use orchestrator::delegate::DelegateTools;
use orchestrator::exec::{ExecConfig, ExecConnector};
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::live::{LiveConfig, LiveDispatcher};
use orchestrator::outbox::{Claims, Dispatcher, DispatcherConfig};
use orchestrator::pipeline::{HandoffCopier, PipelineConfig, PipelineDriver};
use orchestrator::scheduler::{Scheduler, SchedulerConfig};
use orchestrator::shim::PlatformTools;
use orchestrator::tools::{ArtifactTools, ScheduleTools, ToolSet};
use orchestrator::vault::VaultTools;
use orchestrator::workspaces::ObjectWorkspaceStore;
use proto::domain::PushChannelKind;
use sandbox::SandboxProvider;
use sandbox::acs::AcsProvider;
use sandbox::cube::CubeProvider;
use sandbox::local::LocalProvider;
use store::Db;
use tracing::{error, info, warn};
use zeroize::Zeroizing;

use crate::{Background, Config, ShutdownListener};

/// 事件保留期（4.8）。
const EVENT_RETENTION_DAYS: i64 = 30;
/// 登录验证码保留多久（排查问题用），之后删除。
const LOGIN_CODE_RETENTION: Duration = Duration::from_secs(7 * 24 * 3600);
/// 会话失效（过期或吊销）多久以后清掉它的刷新令牌历史。
const REFRESH_HISTORY_RETENTION: Duration = Duration::from_secs(30 * 24 * 3600);
/// 送达（或放弃）的推送记录留几天（排查送达问题用），之后删掉：载荷里有通知的正文。
const OUTBOX_RETENTION: Duration = Duration::from_secs(7 * 24 * 3600);
/// 电脑工具的调用（参数和结果里可能有文件内容、截图）、手机和电脑之间的消息留多久（14.1）。
/// 消息本身 24 小时就过期。
const DEVICE_TRAFFIC_RETENTION: Duration = Duration::from_secs(24 * 3600);
/// 实时活动最多显示 8 小时，结束后在锁屏上最多再留 4 小时：一天前开的早就不显示了。
const LIVE_ACTIVITY_RETENTION: Duration = Duration::from_secs(24 * 3600);
/// 多久看一次有没有要推送的电脑审批请求（14.2），一次最多领多少条。
const DEVICE_NOTICE_EVERY: Duration = Duration::from_secs(2);
const DEVICE_NOTICE_BATCH: i64 = 100;

async fn stopped(mut stop: ShutdownListener) {
    stop.wait().await;
}

pub fn spawn(cfg: &Config, db: &Db, node_id: &str, bg: &mut Background) -> anyhow::Result<()> {
    let provider: Arc<dyn SandboxProvider> = match cfg.sandbox.provider.as_str() {
        "cube" => Arc::new(
            CubeProvider::new(cfg.sandbox.cube.to_config(cfg.cube_api_key.clone()))
                .context("sandbox.cube")?,
        ),
        "acs" => Arc::new(
            AcsProvider::new(cfg.sandbox.acs.to_config(cfg.acs_api_key.clone()))
                .context("sandbox.acs")?,
        ),
        _ => {
            let local = LocalProvider::new(&cfg.sandbox.local_root)
                .with_context(|| format!("sandbox root {}", cfg.sandbox.local_root.display()))?;
            // 本地开发也能走一遍对象存储的归档：工作区不放卷上。
            Arc::new(if cfg.sandbox.workspace.object() {
                local.without_volumes()
            } else {
                local
            })
        }
    };
    let kms = crate::kms(cfg)?;
    let blob_store = crate::blob_store(cfg)?;
    let mut lifecycle = Lifecycle::new(
        db.clone(),
        provider.clone(),
        Arc::new(BuiltinTemplates),
        cfg.sandbox.lifecycle_config(),
    );
    if cfg.sandbox.workspace.object() {
        lifecycle = lifecycle.with_workspace_store(Arc::new(ObjectWorkspaceStore::new(
            db.clone(),
            blob_store.clone(),
            kms.clone(),
            &cfg.sandbox.workspace.temp_dir,
            cfg.sandbox.workspace.temp_budget_bytes,
            Duration::from_secs(cfg.sandbox.workspace.archive_timeout_secs),
        )));
    }
    let lifecycle = Arc::new(lifecycle);
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
    let artifacts = crate::artifact_store(db, blob_store, kms.clone());
    let blobs = artifacts.clone();
    let tools: Vec<Arc<dyn PlatformTools>> = vec![
        Arc::new(ScheduleTools::new(db.clone())),
        Arc::new(ArtifactTools::new(
            db.clone(),
            artifacts.clone(),
            provider.clone(),
            workdir.clone(),
        )),
        Arc::new(VaultTools::new(db.clone())),
        Arc::new(DelegateTools::new(db.clone())),
    ];
    // 用户电脑上的工具（14.2）：调用经设备中继转给用户自己的电脑，结果靠数据库通知取回。
    let computer = Arc::new(DeviceCalls::new(db.clone()));
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
                lease: Duration::from_secs(cfg.worker.lease_secs),
                renew_every: Duration::from_secs(cfg.worker.lease_secs) / 4,
                takeover_every: Duration::from_secs(cfg.worker.takeover_every_secs),
                backoff_base: Duration::from_secs(cfg.worker.retry_backoff_secs),
                ..ExecutorConfig::default()
            },
        )
        .with_handoff(Arc::new(HandoffCopier::new(
            db.clone(),
            artifacts,
            provider,
            workdir,
        )))
        .with_vault(kms.clone())
        .with_computer(computer.clone()),
    );
    let pipelines = PipelineDriver::new(db.clone(), PipelineConfig::default());
    let scheduler = Scheduler::new(db.clone(), SchedulerConfig::default());
    // 设备推送和 IM 群消息各一个投递器（各自的循环）：第三方的群机器人慢了、挂了，不拖累设备推送。
    let mut dispatcher = Dispatcher::new(
        db.clone(),
        node_id,
        DispatcherConfig {
            claims: Claims::Push,
            ..DispatcherConfig::default()
        },
    );
    // IM：每个渠道一次领一条，最多 8 条同时在发，发完一条补领一条（不等同一批里最慢的）。
    let mut im_dispatcher = Dispatcher::new(
        db.clone(),
        node_id,
        DispatcherConfig {
            claims: Claims::Im,
            batch: 16,
            concurrency: 8,
            ..DispatcherConfig::default()
        },
    );
    let mut push_filter = None;
    if let Some(path) = &cfg.compliance.push_keywords_file {
        let filter = Arc::new(
            KeywordFilter::load(path)
                .with_context(|| format!("reading push keywords {}", path.display()))?,
        );
        info!(keywords = filter.len(), "push content filter loaded");
        dispatcher = dispatcher.with_filter(filter.clone());
        im_dispatcher = im_dispatcher.with_filter(filter.clone());
        push_filter = Some(filter);
    }
    if cfg.push.im.enabled {
        let client = ImClient::new().context("IM channel client")?;
        im_dispatcher = im_dispatcher.with_im(Arc::new(client), kms);
    }
    let mut live = None;
    if let Some(apns) = &cfg.push.apns {
        let key = Zeroizing::new(
            std::fs::read_to_string(&apns.key_path)
                .with_context(|| format!("reading APNs key {}", apns.key_path.display()))?,
        );
        // 生产环境和沙盒环境（开发包，10.7）用同一把密钥，按设备登记的通道分开发。
        let client = |endpoint: &str| {
            ApnsClient::new(ApnsConfig {
                endpoint: endpoint.to_owned(),
                topic: apns.topic.clone(),
                team_id: apns.team_id.clone(),
                key_id: apns.key_id.clone(),
                key_pem: key.clone(),
            })
            .map(Arc::new)
            .context("APNs client")
        };
        let production = client(&apns.endpoint)?;
        let sandbox = client(&apns.sandbox_endpoint)?;
        dispatcher = dispatcher
            .with_channel(PushChannelKind::Apns, production.clone())
            .with_channel(PushChannelKind::ApnsSandbox, sandbox.clone());
        // 实时活动（10.6）也走 APNs。
        let mut d = LiveDispatcher::new(db.clone(), node_id, production, LiveConfig::default())
            .with_sandbox(sandbox);
        if let Some(filter) = &push_filter {
            d = d.with_filter(filter.clone());
        }
        live = Some(d);
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
    if let Some(fcm) = &cfg.push.fcm {
        let text = Zeroizing::new(
            std::fs::read_to_string(&fcm.service_account_path).with_context(|| {
                format!(
                    "reading the FCM service account {}",
                    fcm.service_account_path.display()
                )
            })?,
        );
        let account: ServiceAccount =
            serde_json::from_str(&text).context("FCM service account JSON")?;
        let client = FcmClient::new(FcmConfig {
            endpoint: fcm.endpoint.clone(),
            account,
            approval_channel: fcm.approval_channel.clone(),
            default_channel: fcm.default_channel.clone(),
        })
        .context("FCM client")?;
        dispatcher = dispatcher.with_channel(PushChannelKind::Fcm, Arc::new(client));
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
    bg.spawn("device-calls", move |stop| async move {
        computer.listen(stopped(stop)).await;
        Ok(())
    });
    bg.spawn("outbox", move |stop| async move {
        dispatcher.run(stopped(stop)).await;
        Ok(())
    });
    bg.spawn("outbox-im", move |stop| async move {
        im_dispatcher.run(stopped(stop)).await;
        Ok(())
    });
    if let Some(live) = live {
        bg.spawn("live-activities", move |stop| async move {
            live.run(stopped(stop)).await;
            Ok(())
        });
    }
    let sweep_every = Duration::from_secs(cfg.worker.sweep_every_secs.max(1));
    bg.spawn("sweeper", move |stop| async move {
        every(sweep_every, stop, || async {
            match lifecycle.sweep().await {
                Ok(r) if r.prewarmed + r.paused + r.archived + r.purged + r.failed > 0 => info!(
                    prewarmed = r.prewarmed,
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
    // 电脑发给手机的审批请求（14.2）：推送提醒用户打开 App 批准。
    let notices_db = db.clone();
    bg.spawn("device-notices", move |stop| async move {
        every(DEVICE_NOTICE_EVERY, stop, || async {
            loop {
                match notify_approval_requests(&notices_db, DEVICE_NOTICE_BATCH).await {
                    // 一批满了：可能还有，接着领。
                    Ok(n) if n as i64 >= DEVICE_NOTICE_BATCH => {}
                    Ok(_) => break,
                    Err(e) => {
                        error!(error = %e, "notifying computer approval requests failed");
                        break;
                    }
                }
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
            if let Err(e) = purge_blobs(&db, &blobs).await {
                error!(error = %e, "purging deleted artifact blobs failed");
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

/// 删掉的产出物：对象存储里的密文按队列删掉（每轮最多 1000 个，删不掉的下轮再试）。
async fn purge_blobs(db: &Db, artifacts: &ArtifactStore) -> anyhow::Result<()> {
    let mut w = db.worker().await?;
    let keys = w.blob_purge_batch(1000).await?;
    let mut done = Vec::with_capacity(keys.len());
    for key in keys {
        match artifacts.delete_blob(&key).await {
            Ok(()) => done.push(key),
            Err(e) => warn!(%key, error = %e, "could not delete an artifact blob"),
        }
    }
    w.forget_blob_purge(&done).await?;
    w.commit().await?;
    if !done.is_empty() {
        info!(blobs = done.len(), "purged deleted artifact blobs");
    }
    Ok(())
}

/// 事件分区提前建好、过期的删掉；清理过期的登录验证码、送达的推送记录、电脑工具的调用和设备间的消息。
async fn maintain(db: &Db) -> store::Result<()> {
    let today = Utc::now().date_naive();
    let this_month = NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap_or(today);
    let mut w = db.worker().await?;
    w.ensure_event_partitions(this_month, 3).await?;
    let dropped = w
        .drop_event_partitions_before(today - chrono::Duration::days(EVENT_RETENTION_DAYS))
        .await?;
    let purged = w.purge_login_codes(LOGIN_CODE_RETENTION).await?
        + w.purge_refresh_history(REFRESH_HISTORY_RETENTION).await?
        + w.purge_delivered_outbox(OUTBOX_RETENTION).await?
        + w.purge_device_traffic(DEVICE_TRAFFIC_RETENTION).await?
        + w.purge_im_bot_slots().await?
        + w.purge_live_activities(LIVE_ACTIVITY_RETENTION).await?;
    // 内容举报（5.5）的待处理队列：几条、最早的一条等了多久（告警看它）。
    let (open, oldest) = w.report_backlog().await?;
    w.commit().await?;
    metrics::gauge!("thinktin_content_reports_open").set(open as f64);
    metrics::gauge!("thinktin_content_report_oldest_seconds")
        .set(oldest.map_or(0.0, |t| (Utc::now() - t).num_seconds().max(0) as f64));
    if dropped > 0 || purged > 0 {
        info!(
            dropped_partitions = dropped,
            purged_codes = purged,
            "maintenance"
        );
    }
    Ok(())
}
