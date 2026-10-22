//! 实时活动（WBS 10.6）：iOS 的灵动岛、锁屏上显示运行的进度。
//!
//! App 开了实时活动后登记它的推送令牌；计划到点开始的根运行，按设备的推送开启令牌远程开启（领取运行时记下待开启的，
//! 见 [`queue_starts`]）。这里定时领该发的：运行的状态、步数和上次发的不一样就发更新（几次变化合成一次，只发现在的
//! 样子；只是步数变了的隔一阵才发），运行结束发 end。
//!
//! 和 App 的约定（Swift 的 `ActivityAttributes`，见 `docs/live-activities.md`）：类型名 [`ATTRIBUTES_TYPE`]，
//! 静态属性 `{runId, instanceId, title}`，动态内容 `{state, steps, startedAt?, endedAt?}`（时间是 Unix 秒）。
//! 推送里没有运行的摘要、agent 写的文字：锁屏上谁都看得见。

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use futures_util::StreamExt;
use notify::filter::{AllowAll, ContentFilter, Verdict};
use notify::{LiveActivityChannel, LiveEvent, LivePush, PushOutcome};
use proto::domain::{RunId, RunSource};
use serde_json::{Value, json};
use store::{Db, LiveActivity, LiveSettle, RunRecord, Tx, Worker};
use tracing::{error, info, warn};

/// App 里 `ActivityAttributes` 的类型名（远程开启时按它找到要开哪种实时活动）。
pub const ATTRIBUTES_TYPE: &str = "RunActivityAttributes";

/// 一台设备同时开着的、远程开启的实时活动最多几个（苹果对远程开启有预算，锁屏上也放不下太多）。
pub const MAX_PUSHED_OPEN: u32 = 2;

/// App 一台设备同时开着的最多几个（登记令牌时检查）。
pub const MAX_OPEN: u32 = 10;

/// 计划到点开始的根运行（第一次领取时；有步骤的计划是流水线开始时）：给开了远程开启的设备记下待开启的实时活动。
/// 和领取运行在同一个事务里。用户自己发起的运行由 App 自己开；子运行、流水线的步骤不单独开（步数算在根运行上）。
pub async fn queue_starts(w: &mut Tx<Worker>, rec: &RunRecord) -> store::Result<()> {
    let run = &rec.run;
    if run.attempt <= 1 && run.parent_run_id.is_none() && run.source == RunSource::Plan {
        w.queue_live_starts(rec.user_id, run.id, MAX_PUSHED_OPEN)
            .await?;
    }
    Ok(())
}

/// 实时活动的动态内容。
pub fn content_state(a: &LiveActivity) -> Value {
    let mut v = json!({"state": a.state.as_str(), "steps": a.steps});
    if let Some(t) = a.started_at {
        v["startedAt"] = json!(t.timestamp());
    }
    if let Some(t) = a.finished_at {
        v["endedAt"] = json!(t.timestamp());
    }
    v
}

/// 远程开启时的静态属性。
pub fn attributes(run: RunId, instance: &str, title: &str) -> Value {
    json!({"runId": run.to_string(), "instanceId": instance, "title": title})
}

#[derive(Debug, Clone)]
pub struct LiveConfig {
    pub tick: Duration,
    pub batch: i64,
    /// 一个用户一次最多领几个（先轮每个用户的第一个，再轮第二个）。
    pub per_user: i64,
    /// 同时发几条。
    pub concurrency: usize,
    pub lock_for: Duration,
    /// 状态变了：离上次发至少隔这么久（同一秒里的两次更新，系统会丢掉后一次）。
    pub state_gap: Duration,
    /// 只是步数变了：离上次发至少隔这么久。
    pub step_gap: Duration,
    /// 连着失败几次就不再发（默认 13 次，按退避算一个小时出头：苹果那边短时间出问题，实时活动不能就此停住）。
    pub max_attempts: u32,
    pub backoff_base: Duration,
    pub backoff_max: Duration,
}

impl Default for LiveConfig {
    fn default() -> Self {
        Self {
            tick: Duration::from_secs(1),
            batch: 50,
            per_user: 5,
            concurrency: 8,
            lock_for: Duration::from_secs(60),
            state_gap: Duration::from_secs(2),
            step_gap: Duration::from_secs(20),
            max_attempts: 13,
            backoff_base: Duration::from_secs(5),
            backoff_max: Duration::from_secs(600),
        }
    }
}

pub struct LiveDispatcher {
    db: Db,
    node_id: String,
    channel: Arc<dyn LiveActivityChannel>,
    filter: Arc<dyn ContentFilter>,
    cfg: LiveConfig,
}

impl LiveDispatcher {
    pub fn new(
        db: Db,
        node_id: impl Into<String>,
        channel: Arc<dyn LiveActivityChannel>,
        cfg: LiveConfig,
    ) -> Self {
        Self {
            db,
            node_id: node_id.into(),
            channel,
            filter: Arc::new(AllowAll),
            cfg,
        }
    }

    /// 锁屏上显示的文字（实例名）的内容安全过滤（16.3）。
    pub fn with_filter(mut self, filter: Arc<dyn ContentFilter>) -> Self {
        self.filter = filter;
        self
    }

    /// 领一批、发完。返回处理了几个。
    pub async fn tick(&self) -> store::Result<usize> {
        let mut w = self.db.worker().await?;
        let due = w
            .claim_live_activities(
                &self.node_id,
                self.cfg.lock_for,
                self.cfg.batch,
                self.cfg.per_user,
                self.cfg.state_gap,
                self.cfg.step_gap,
            )
            .await?;
        w.commit().await?;
        let n = due.len();
        let done: Vec<store::Result<()>> =
            futures_util::stream::iter(due.into_iter().map(|a| self.handle(a)))
                .buffer_unordered(self.cfg.concurrency.max(1))
                .collect()
                .await;
        for d in done {
            d?;
        }
        Ok(n)
    }

    async fn handle(&self, a: LiveActivity) -> store::Result<()> {
        // 前面的发得慢，锁可能已经过期、被别的副本领去发了：续不上锁就不发（远程开启发两次就是两个实时活动）。
        // 领了以后不该发了的（App 关掉了、同一台手机换了账号、关掉了远程开启）也不发；锁会过期，下一轮再看。
        let start_token = a
            .start_token
            .as_deref()
            .filter(|_| a.push_token.is_none() && !a.start_sent);
        let mut w = self.db.worker().await?;
        let mine = w
            .extend_live_lock(
                a.device_id,
                a.run_id,
                &self.node_id,
                self.cfg.lock_for,
                start_token,
            )
            .await?;
        w.commit().await?;
        if !mine {
            info!(run = %a.run_id, "live activity no longer due when its turn came");
            return Ok(());
        }
        let settle = match a.push_token.clone() {
            Some(token) => self.update(&a, &token).await,
            None => self.start(&a).await?,
        };
        let result = match &settle {
            LiveSettle::Sent { .. } => "sent",
            LiveSettle::Retry { .. } => "retried",
            LiveSettle::End { error: None } => "ended",
            LiveSettle::End { error: Some(_) } | LiveSettle::GiveUp { .. } => "dropped",
        };
        metrics::counter!("thinktin_live_activity_total", "result" => result).increment(1);
        let mut w = self.db.worker().await?;
        match w
            .settle_live_activity(
                a.device_id,
                a.run_id,
                &self.node_id,
                a.push_token.as_deref(),
                &settle,
            )
            .await
        {
            Ok(()) => w.commit().await?,
            // 锁过期后被别人领了：交给新的那一轮。
            Err(store::Error::LeaseLost { .. }) => {
                warn!(run = %a.run_id, "live activity changed hands during delivery");
            }
            Err(e) => return Err(e),
        }
        Ok(())
    }

    /// 远程开启（还没有这个实时活动的令牌）。运行已经结束、开启令牌没了的，了结掉。
    async fn start(&self, a: &LiveActivity) -> store::Result<LiveSettle> {
        let Some(token) = a.start_token.as_deref().filter(|_| !a.start_sent) else {
            return Ok(LiveSettle::End { error: None });
        };
        if a.state.is_terminal() {
            return Ok(LiveSettle::End { error: None });
        }
        let mut w = self.db.worker().await?;
        let locale = w.user_locale(a.user_id).await?;
        w.rollback().await?;
        let title = match self.filter.check(&a.instance_name) {
            Verdict::Block { reason } => {
                info!(run = %a.run_id, %reason, "live activity title filtered");
                crate::texts::APP_NAME.to_owned()
            }
            Verdict::Pass => a.instance_name.clone(),
        };
        let push = LivePush {
            event: LiveEvent::Start,
            content_state: content_state(a),
            urgent: true,
            attributes: Some((
                ATTRIBUTES_TYPE.into(),
                attributes(a.run_id, &a.instance_id.to_string(), &title),
            )),
            alert: Some((title, crate::texts::live_started(locale).into())),
        };
        Ok(match self.channel.send_live(token, &push).await {
            PushOutcome::Delivered { .. } => LiveSettle::Sent {
                state: a.state,
                steps: a.steps,
                started: true,
                ended: false,
            },
            PushOutcome::InvalidToken { reason } => {
                info!(device = %a.device_id, %reason, "live activity start token is no longer valid");
                let mut w = self.db.worker().await?;
                w.clear_activity_start_token(a.device_id, token).await?;
                w.commit().await?;
                LiveSettle::End {
                    error: Some(reason),
                }
            }
            PushOutcome::Rejected { reason } => {
                warn!(run = %a.run_id, %reason, "live activity start rejected");
                LiveSettle::End {
                    error: Some(reason),
                }
            }
            PushOutcome::Retry { after, reason } => self.retry(a, reason, after),
        })
    }

    async fn update(&self, a: &LiveActivity, token: &str) -> LiveSettle {
        let ended = a.state.is_terminal();
        let push = LivePush {
            event: if ended {
                LiveEvent::End
            } else {
                LiveEvent::Update
            },
            content_state: content_state(a),
            urgent: ended || a.sent_state != Some(a.state),
            attributes: None,
            alert: None,
        };
        match self.channel.send_live(token, &push).await {
            PushOutcome::Delivered { .. } => LiveSettle::Sent {
                state: a.state,
                steps: a.steps,
                started: false,
                ended,
            },
            // 实时活动结束了（用户划掉了、系统结束了）令牌就失效：不再发。
            PushOutcome::InvalidToken { reason } | PushOutcome::Rejected { reason } => {
                LiveSettle::End {
                    error: Some(reason),
                }
            }
            PushOutcome::Retry { after, reason } => self.retry(a, reason, after),
        }
    }

    fn retry(&self, a: &LiveActivity, reason: String, after: Option<Duration>) -> LiveSettle {
        let attempts = a.attempts + 1;
        if attempts >= self.cfg.max_attempts {
            return LiveSettle::GiveUp {
                error: format!("gave up after {attempts} attempts: {reason}"),
            };
        }
        let backoff = self
            .cfg
            .backoff_base
            .saturating_mul(1 << a.attempts.min(16))
            .min(self.cfg.backoff_max);
        // APNs 给的 Retry-After 不可信：太大的值会让时间相加溢出。
        let delay = after
            .unwrap_or_default()
            .max(backoff)
            .min(self.cfg.backoff_max);
        let at = chrono::Duration::from_std(delay)
            .ok()
            .and_then(|d| Utc::now().checked_add_signed(d))
            .unwrap_or_else(Utc::now);
        LiveSettle::Retry { error: reason, at }
    }

    pub async fn run(&self, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let mut tick = tokio::time::interval(self.cfg.tick);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        info!("live activity dispatcher started");
        loop {
            tokio::select! {
                () = &mut stop => break,
                _ = tick.tick() => {
                    if let Err(e) = self.tick().await {
                        error!(error = %e, "live activity dispatch failed");
                    }
                }
            }
        }
        info!("live activity dispatcher stopped");
    }
}
