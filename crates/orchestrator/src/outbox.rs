//! 出箱投递（WBS 7.5）：领取出箱条目，按用户设备的推送通道发送，失败按退避重试。
//!
//! 状态变更和通知在同一个事务里写进出箱（见 [`push_item`]），这里异步投递：
//! 状态改了通知一定会发；投递器崩溃后锁过期，别的副本接着发。

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use notify::filter::{self, AllowAll, ContentFilter, Verdict};
use notify::{PushChannel, PushKind, PushMessage, PushOutcome, PushTarget};
use proto::domain::{ApprovalId, InboxItemId, InstanceId, PlanId, PushChannelKind, RunId, UserId};
use store::{Db, NewInboxItem, NewOutboxItem, OutboxItem, Tenant, Tx, Worker};
use tracing::{error, info, warn};

/// 推送类出箱条目的 kind；载荷是 [`PushMessage`]。
pub const PUSH: &str = "push";

/// 写一条推送通知进出箱（和状态变更放在同一个事务里）。`dedupe_key` 防止重复通知同一件事。
pub fn push_item(message: &PushMessage, dedupe_key: Option<String>) -> NewOutboxItem {
    NewOutboxItem {
        kind: PUSH.into(),
        payload: serde_json::to_value(message).expect("push message serializes"),
        dedupe_key,
        available_at: None,
    }
}

/// 给用户的一条通知：写进收件箱（10.4），再推送到用户的设备。
/// 和引起它的状态变更放在同一个事务里写（见 [`notify`]）。
#[derive(Debug, Clone)]
pub struct Notice {
    pub kind: PushKind,
    /// 标题，比如计划名、实例名。
    pub title: String,
    /// 摘要，一两句话，不含对话正文。
    pub body: String,
    pub instance: Option<InstanceId>,
    pub run: Option<RunId>,
    pub plan: Option<PlanId>,
    pub approval: Option<ApprovalId>,
    /// 推送分组（同一个运行的通知归成一组）。
    pub thread_id: Option<String>,
    /// 推送替换（同一个 id 的新通知替换旧的）。
    pub collapse_id: Option<String>,
    /// 过了这个时间推送就不必再送达（收件箱照样留着）。
    pub ttl: Option<Duration>,
    /// 同一件事只记一条、只推一次（收件箱和出箱共用）。
    pub dedupe_key: Option<String>,
    /// 正文是 agent 生成的（运行摘要、工具调用的标题）：显示时带“AI 生成”标识。
    pub ai_generated: bool,
}

impl Notice {
    pub fn new(kind: PushKind, title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            kind,
            title: title.into(),
            body: body.into(),
            instance: None,
            run: None,
            plan: None,
            approval: None,
            thread_id: None,
            collapse_id: None,
            ttl: None,
            dedupe_key: None,
            ai_generated: false,
        }
    }

    fn inbox(&self) -> NewInboxItem {
        NewInboxItem {
            kind: self.kind.as_str().into(),
            title: self.title.clone(),
            body: self.body.clone(),
            instance_id: self.instance,
            run_id: self.run,
            plan_id: self.plan,
            approval_id: self.approval,
            dedupe_key: self.dedupe_key.clone(),
            ai_generated: self.ai_generated,
        }
    }

    /// 推送消息：只带 id，客户端打开后按 id 取内容。
    pub fn push(&self, inbox: Option<InboxItemId>) -> PushMessage {
        PushMessage {
            kind: self.kind,
            title: self.title.clone(),
            body: self.body.clone(),
            thread_id: self.thread_id.clone(),
            collapse_id: self.collapse_id.clone(),
            target: PushTarget {
                instance_id: self.instance.map(|i| i.to_string()),
                run_id: self.run.map(|r| r.to_string()),
                approval_id: self.approval.map(|a| a.to_string()),
                plan_id: self.plan.map(|p| p.to_string()),
                inbox_id: inbox.map(|i| i.to_string()),
            },
            ttl: self.ttl,
            ai_generated: self.ai_generated,
        }
    }
}

/// 写收件箱并入出箱（后台任务的事务）。同一个去重键已经通知过就什么都不做。
pub async fn notify(w: &mut Tx<Worker>, user: UserId, notice: &Notice) -> store::Result<()> {
    if let Some(id) = w.insert_inbox(user, &notice.inbox()).await? {
        w.enqueue_outbox(
            user,
            &push_item(&notice.push(Some(id)), notice.dedupe_key.clone()),
        )
        .await?;
    }
    Ok(())
}

/// 同 [`notify`]，在用户自己的事务里（平台工具代表用户操作时）。
pub async fn notify_tenant(t: &mut Tx<Tenant>, notice: &Notice) -> store::Result<()> {
    let user = t.user();
    if let Some(id) = t.insert_inbox(user, &notice.inbox()).await? {
        t.enqueue_outbox(&push_item(
            &notice.push(Some(id)),
            notice.dedupe_key.clone(),
        ))
        .await?;
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct DispatcherConfig {
    pub tick: Duration,
    pub batch: i64,
    /// 领取后锁多久（投递器崩溃后过了这么久别人才能接手）。
    pub lock_for: Duration,
    /// 最多尝试几次，之后放弃。
    pub max_attempts: u32,
    /// 退避的起点和上限（指数增长）。
    pub backoff_base: Duration,
    pub backoff_max: Duration,
}

impl Default for DispatcherConfig {
    fn default() -> Self {
        Self {
            tick: Duration::from_secs(1),
            batch: 50,
            lock_for: Duration::from_secs(60),
            max_attempts: 8,
            backoff_base: Duration::from_secs(5),
            backoff_max: Duration::from_secs(3600),
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DispatchReport {
    pub delivered: usize,
    pub retried: usize,
    /// 放弃的（过期、请求被拒、超过尝试次数、没有可用设备）。
    pub dropped: usize,
}

pub struct Dispatcher {
    db: Db,
    node_id: String,
    channels: HashMap<PushChannelKind, Arc<dyn PushChannel>>,
    filter: Arc<dyn ContentFilter>,
    cfg: DispatcherConfig,
}

enum Settle {
    Done(Option<String>),
    Retry(String, Duration),
}

impl Dispatcher {
    pub fn new(db: Db, node_id: impl Into<String>, cfg: DispatcherConfig) -> Self {
        Self {
            db,
            node_id: node_id.into(),
            channels: HashMap::new(),
            filter: Arc::new(AllowAll),
            cfg,
        }
    }

    /// 推送文字的内容安全过滤（16.3）。
    pub fn with_filter(mut self, filter: Arc<dyn ContentFilter>) -> Self {
        self.filter = filter;
        self
    }

    /// 配置某种设备推送通道的发送实现（APNs、各家厂商）。没配的通道跳过。
    pub fn with_channel(mut self, kind: PushChannelKind, channel: Arc<dyn PushChannel>) -> Self {
        self.channels.insert(kind, channel);
        self
    }

    pub async fn tick(&self) -> store::Result<DispatchReport> {
        let mut report = DispatchReport::default();
        let mut w = self.db.worker().await?;
        let items = w
            .claim_outbox(&self.node_id, self.cfg.lock_for, self.cfg.batch)
            .await?;
        w.commit().await?;
        for item in items {
            let settle = self.deliver(&item).await?;
            let mut w = self.db.worker().await?;
            let result = match settle {
                Settle::Done(None) => {
                    report.delivered += 1;
                    metrics::counter!("thinktin_push_total", "result" => "delivered").increment(1);
                    w.finish_outbox(item.id, &self.node_id, None).await
                }
                Settle::Done(Some(reason)) => {
                    report.dropped += 1;
                    metrics::counter!("thinktin_push_total", "result" => "dropped").increment(1);
                    w.finish_outbox(item.id, &self.node_id, Some(&reason)).await
                }
                Settle::Retry(reason, _) if item.attempts >= self.cfg.max_attempts => {
                    report.dropped += 1;
                    metrics::counter!("thinktin_push_total", "result" => "dropped").increment(1);
                    w.finish_outbox(
                        item.id,
                        &self.node_id,
                        Some(&format!(
                            "gave up after {} attempts: {reason}",
                            item.attempts
                        )),
                    )
                    .await
                }
                Settle::Retry(reason, after) => {
                    report.retried += 1;
                    metrics::counter!("thinktin_push_total", "result" => "retried").increment(1);
                    // 推送服务给的 Retry-After 不可信：太大的值会让时间相加溢出、让投递器崩溃。
                    let delay = after
                        .max(self.backoff(item.attempts))
                        .min(self.cfg.backoff_max);
                    let at = chrono::Duration::from_std(delay)
                        .ok()
                        .and_then(|d| Utc::now().checked_add_signed(d))
                        .unwrap_or_else(Utc::now);
                    w.retry_outbox(item.id, &self.node_id, &reason, at).await
                }
            };
            match result {
                Ok(()) => w.commit().await?,
                // 处理太久，锁过期后被别的投递器领走了：交给对方。
                Err(store::Error::LeaseLost { .. }) => {
                    warn!(item = item.id, "outbox lock expired during delivery");
                }
                Err(e) => return Err(e),
            }
        }
        Ok(report)
    }

    fn backoff(&self, attempts: u32) -> Duration {
        let exp = attempts.saturating_sub(1).min(16);
        self.cfg
            .backoff_base
            .saturating_mul(1 << exp)
            .min(self.cfg.backoff_max)
    }

    async fn deliver(&self, item: &OutboxItem) -> store::Result<Settle> {
        if item.kind != PUSH {
            return Ok(Settle::Done(Some(format!(
                "unknown outbox kind {}",
                item.kind
            ))));
        }
        let mut message: PushMessage = match serde_json::from_value(item.payload.clone()) {
            Ok(m) => m,
            Err(e) => return Ok(Settle::Done(Some(format!("bad push payload: {e}")))),
        };
        // 系统通知栏是公开展示的地方：命中过滤的换成中性提示，原文留在收件箱。
        for text in [message.title.clone(), message.body.clone()] {
            if let Verdict::Block { reason } = self.filter.check(&text) {
                info!(item = item.id, %reason, "push text filtered");
                message.title = "ThinkTin".into();
                message.body = filter::BLOCKED_BODY.into();
                message.ai_generated = false;
                break;
            }
        }
        if let Some(ttl) = message.ttl {
            let age = (Utc::now() - item.created_at).to_std().unwrap_or_default();
            if age > ttl {
                return Ok(Settle::Done(Some("expired before delivery".into())));
            }
        }
        let mut w = self.db.worker().await?;
        // 审批提醒：用户已经在别的设备上处理了、过期了，或者运行已经结束，就不必再推。
        if message.kind == PushKind::Approval
            && let Some(id) = message.target.approval_id.as_deref()
            && let Ok(id) = id.parse::<ApprovalId>()
            && !w.approval_pending(id).await?
        {
            w.rollback().await?;
            return Ok(Settle::Done(Some("approval no longer pending".into())));
        }
        let targets = w.push_targets(item.user_id).await?;
        w.rollback().await?;
        let mut delivered = 0;
        let mut retry: Option<(String, Duration)> = None;
        let mut last_error = None;
        for (device, kind, token) in &targets {
            let Some(channel) = self.channels.get(kind) else {
                last_error = Some(format!("no {kind} channel configured"));
                continue;
            };
            match channel.send(token, &message).await {
                PushOutcome::Delivered { .. } => delivered += 1,
                PushOutcome::InvalidToken { reason } => {
                    info!(%device, %reason, "push token is no longer valid, clearing it");
                    let mut w = self.db.worker().await?;
                    w.clear_push_token(*device, token).await?;
                    w.commit().await?;
                    last_error = Some(reason);
                }
                PushOutcome::Retry { after, reason } => {
                    let after = after.unwrap_or_default();
                    retry = Some(match retry {
                        Some((r, a)) => (r, a.max(after)),
                        None => (reason, after),
                    });
                }
                PushOutcome::Rejected { reason } => {
                    warn!(%device, %reason, "push rejected");
                    last_error = Some(reason);
                }
            }
        }
        // 有一台设备收到就算送达（重试会让收到的设备再收一遍）；全部暂时失败才重试。
        Ok(if delivered > 0 {
            Settle::Done(None)
        } else if let Some((reason, after)) = retry {
            Settle::Retry(reason, after)
        } else if targets.is_empty() {
            Settle::Done(Some("no devices with push enabled".into()))
        } else {
            Settle::Done(last_error.or(Some("not delivered".into())))
        })
    }

    pub async fn run(&self, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let mut tick = tokio::time::interval(self.cfg.tick);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        info!("outbox dispatcher started");
        loop {
            tokio::select! {
                () = &mut stop => break,
                _ = tick.tick() => {
                    if let Err(e) = self.tick().await {
                        error!(error = %e, "outbox dispatch failed");
                    }
                }
            }
        }
        info!("outbox dispatcher stopped");
    }
}
