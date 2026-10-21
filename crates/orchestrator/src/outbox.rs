//! 出箱投递（WBS 7.5）：领取出箱条目，按用户设备的推送通道发送，失败按退避重试。
//!
//! 状态变更和通知在同一个事务里写进出箱（见 [`push_item`]），这里异步投递：
//! 状态改了通知一定会发；投递器崩溃后锁过期，别的副本接着发。
//!
//! IM 渠道（10.5）：用户绑定的群机器人订了的事件，每个渠道一条出箱条目（[`im_item`]），独立重试、独立限流。
//! 载荷里只有渠道 id 和消息，webhook 的 token 和签名密钥发送时才从密钥库解开。IM 条目由单独的投递器发
//! （[`Claims::Im`]）：第三方的群机器人慢了、挂了，不拖累设备推送；每个渠道按顺序一条条发，几个渠道同时发。

use std::collections::HashMap;

use futures_util::StreamExt;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use keyvault::Kms;
use notify::filter::{self, AllowAll, ContentFilter, Verdict};
use notify::im::{ImHook, ImMessage, ImSender};
use notify::{PushChannel, PushKind, PushMessage, PushOutcome, PushTarget};
use proto::domain::{
    ApprovalId, ImChannelId, ImEvent, ImVendor, InboxItemId, InstanceId, Locale, PlanId,
    PushChannelKind, RunId, UserId,
};
use serde::{Deserialize, Serialize};
use store::{Db, ImSlot, NewInboxItem, NewOutboxItem, OutboxItem, Tenant, Tx, Worker};
use tracing::{error, info, warn};
use zeroize::Zeroizing;

/// 推送类出箱条目的 kind；载荷是 [`PushMessage`]。
pub const PUSH: &str = "push";
/// IM 渠道的出箱条目（10.5）；载荷是 [`ImPayload`]。
pub const IM: &str = "im";

/// IM 出箱条目的载荷：发到哪个渠道、发什么（不含凭证）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImPayload {
    pub channel: ImChannelId,
    pub message: PushMessage,
}

/// IM 消息最多等这么久：发不出去的（群机器人限流、厂商出故障）过了这个时间就不发了，群里不会收到几小时前的通知，
/// 排队的条目也不会越积越多。
pub const IM_TTL: Duration = Duration::from_secs(3600);

/// 发到一个 IM 渠道。`dedupe_key` 和推送的分开（出箱的去重键是按用户唯一的）。
pub fn im_item(
    channel: ImChannelId,
    message: &PushMessage,
    dedupe_key: Option<String>,
) -> NewOutboxItem {
    let mut message = message.clone();
    message.ttl = Some(message.ttl.map_or(IM_TTL, |t| t.min(IM_TTL)));
    NewOutboxItem {
        kind: IM.into(),
        payload: serde_json::to_value(ImPayload { channel, message })
            .expect("im payload serializes"),
        dedupe_key,
        available_at: None,
    }
}

/// 会发到 IM 群里的事件（和系统推送的重要事件一致）。
fn im_event(kind: PushKind) -> Option<ImEvent> {
    match kind {
        PushKind::RunFinished => Some(ImEvent::RunFinished),
        PushKind::RunFailed => Some(ImEvent::RunFailed),
        PushKind::Approval => Some(ImEvent::Approval),
        PushKind::ComputerApproval | PushKind::Info => None,
    }
}

/// 同一个群机器人两条消息之间至少隔多久（各家的上限：飞书 / Lark 每分钟 100 条、每秒 5 条，企业微信、钉钉每分钟
/// 20 条，钉钉超了会被限 10 分钟）。可以连着发两条，所以任何一分钟里最多 61 条（飞书）、19 条（企业微信、钉钉）。
pub fn im_interval(vendor: ImVendor) -> Duration {
    match vendor {
        ImVendor::Feishu | ImVendor::Lark => Duration::from_secs(1),
        ImVendor::Wecom | ImVendor::Dingtalk => Duration::from_millis(3334),
    }
}

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

    /// 推送消息：只带 id，客户端打开后按 id 取内容。`locale` 是收件人的语言（1.6）。
    pub fn push(&self, inbox: Option<InboxItemId>, locale: Locale) -> PushMessage {
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
            locale,
        }
    }
}

/// 写收件箱并入出箱（后台任务的事务）。同一个去重键已经通知过就什么都不做。
/// 标题和正文由调用方按用户的语言写好（见 [`crate::texts`]）。
/// 用户订了这个事件的 IM 渠道，每个一条（收件箱那条通知的 id 做去重键）。
pub async fn notify(w: &mut Tx<Worker>, user: UserId, notice: &Notice) -> store::Result<()> {
    if let Some(id) = w.insert_inbox(user, &notice.inbox()).await? {
        let locale = w.user_locale(user).await?;
        let message = notice.push(Some(id), locale);
        w.enqueue_outbox(user, &push_item(&message, notice.dedupe_key.clone()))
            .await?;
        if let Some(event) = im_event(notice.kind) {
            for channel in w.im_channels_for(user, event).await? {
                w.enqueue_outbox(
                    user,
                    &im_item(channel, &message, Some(format!("im:{channel}:{id}"))),
                )
                .await?;
            }
        }
    }
    Ok(())
}

/// 同 [`notify`]，在用户自己的事务里（平台工具代表用户操作时）。
pub async fn notify_tenant(t: &mut Tx<Tenant>, notice: &Notice) -> store::Result<()> {
    let user = t.user();
    if let Some(id) = t.insert_inbox(user, &notice.inbox()).await? {
        let locale = t.user_locale(user).await?;
        let message = notice.push(Some(id), locale);
        t.enqueue_outbox(&push_item(&message, notice.dedupe_key.clone()))
            .await?;
        if let Some(event) = im_event(notice.kind) {
            for channel in t.im_channels_for(user, event).await? {
                t.enqueue_outbox(&im_item(
                    channel,
                    &message,
                    Some(format!("im:{channel}:{id}")),
                ))
                .await?;
            }
        }
    }
    Ok(())
}

/// 投递器领哪些出箱条目。生产环境推送和 IM 各一个投递器（各自的循环），测试里一个投递器两种都领。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Claims {
    Push,
    Im,
    Both,
}

#[derive(Debug, Clone)]
pub struct DispatcherConfig {
    pub tick: Duration,
    pub batch: i64,
    pub claims: Claims,
    /// 同时发几条（IM：不同渠道的条目并发；推送按顺序发）。
    pub concurrency: usize,
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
            claims: Claims::Both,
            concurrency: 1,
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
    im: Option<(Arc<dyn ImSender>, Arc<dyn Kms>)>,
    filter: Arc<dyn ContentFilter>,
    cfg: DispatcherConfig,
}

enum Outcome {
    Delivered,
    Dropped,
    Retried,
    Skipped,
}

enum Settle {
    Done(Option<String>),
    Retry(String, Duration),
    /// 自己的限流：到时候再发，不算一次尝试。
    Defer(String, chrono::DateTime<Utc>),
}

impl Dispatcher {
    pub fn new(db: Db, node_id: impl Into<String>, cfg: DispatcherConfig) -> Self {
        Self {
            db,
            node_id: node_id.into(),
            channels: HashMap::new(),
            im: None,
            filter: Arc::new(AllowAll),
            cfg,
        }
    }

    /// IM 渠道（10.5）的发送实现，和解开 webhook 凭证用的 KMS。不配的话 IM 条目直接放弃。
    pub fn with_im(mut self, sender: Arc<dyn ImSender>, kms: Arc<dyn Kms>) -> Self {
        self.im = Some((sender, kms));
        self
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
        let mut outcomes = Vec::new();
        if self.cfg.claims != Claims::Im {
            let mut w = self.db.worker().await?;
            let items = w
                .claim_outbox_of(
                    &self.node_id,
                    self.cfg.lock_for,
                    self.cfg.batch,
                    Some(&[PUSH]),
                )
                .await?;
            w.commit().await?;
            for item in items {
                outcomes.push(self.handle(item).await?);
            }
        }
        if self.cfg.claims != Claims::Push {
            let mut w = self.db.worker().await?;
            let items = w
                .claim_im_outbox(&self.node_id, self.cfg.lock_for, self.cfg.batch)
                .await?;
            w.commit().await?;
            let done: Vec<store::Result<Outcome>> =
                futures_util::stream::iter(items.into_iter().map(|i| self.handle(i)))
                    .buffer_unordered(self.cfg.concurrency.max(1))
                    .collect()
                    .await;
            for o in done {
                outcomes.push(o?);
            }
        }
        for o in outcomes {
            match o {
                Outcome::Delivered => report.delivered += 1,
                Outcome::Dropped => report.dropped += 1,
                Outcome::Retried => report.retried += 1,
                Outcome::Skipped => {}
            }
        }
        Ok(report)
    }

    /// 投递一条并记下结果。
    async fn handle(&self, item: OutboxItem) -> store::Result<Outcome> {
        let mut w = self.db.worker().await?;
        let held = w
            .extend_outbox_lock(item.id, &self.node_id, self.cfg.lock_for)
            .await?;
        w.commit().await?;
        if !held {
            warn!(
                item = item.id,
                "outbox lock expired before sending, leaving it to the new holder"
            );
            return Ok(Outcome::Skipped);
        }
        let settle = if item.kind == IM {
            self.deliver_im(&item).await?
        } else {
            self.deliver(&item).await?
        };
        let metric = if item.kind == IM {
            "thinktin_im_total"
        } else {
            "thinktin_push_total"
        };
        let mut w = self.db.worker().await?;
        let (outcome, result) = match settle {
            Settle::Done(None) => {
                metrics::counter!(metric, "result" => "delivered").increment(1);
                (
                    Outcome::Delivered,
                    w.finish_outbox(item.id, &self.node_id, None).await,
                )
            }
            Settle::Done(Some(reason)) => {
                metrics::counter!(metric, "result" => "dropped").increment(1);
                (
                    Outcome::Dropped,
                    w.finish_outbox(item.id, &self.node_id, Some(&reason)).await,
                )
            }
            Settle::Defer(reason, at) => {
                metrics::counter!(metric, "result" => "deferred").increment(1);
                (
                    Outcome::Retried,
                    w.defer_outbox(item.id, &self.node_id, &reason, at).await,
                )
            }
            Settle::Retry(reason, _) if item.attempts >= self.cfg.max_attempts => {
                metrics::counter!(metric, "result" => "dropped").increment(1);
                let reason = format!("gave up after {} attempts: {reason}", item.attempts);
                (
                    Outcome::Dropped,
                    w.finish_outbox(item.id, &self.node_id, Some(&reason)).await,
                )
            }
            Settle::Retry(reason, after) => {
                metrics::counter!(metric, "result" => "retried").increment(1);
                // 推送服务给的 Retry-After 不可信：太大的值会让时间相加溢出、让投递器崩溃。
                let delay = after
                    .max(self.backoff(item.attempts))
                    .min(self.cfg.backoff_max);
                let at = chrono::Duration::from_std(delay)
                    .ok()
                    .and_then(|d| Utc::now().checked_add_signed(d))
                    .unwrap_or_else(Utc::now);
                (
                    Outcome::Retried,
                    w.retry_outbox(item.id, &self.node_id, &reason, at).await,
                )
            }
        };
        match result {
            Ok(()) => w.commit().await?,
            // 处理太久，锁过期后被别的投递器领走了：交给对方。
            Err(store::Error::LeaseLost { .. }) => {
                warn!(item = item.id, "outbox lock expired during delivery");
                return Ok(Outcome::Skipped);
            }
            Err(e) => return Err(e),
        }
        Ok(outcome)
    }

    fn backoff(&self, attempts: u32) -> Duration {
        let exp = attempts.saturating_sub(1).min(16);
        self.cfg
            .backoff_base
            .saturating_mul(1 << exp)
            .min(self.cfg.backoff_max)
    }

    /// 推送和 IM 共用的前几步：过滤文字、过期的不发、处理过的审批不发。返回 Some 就是不必再发了。
    async fn screen(
        &self,
        item: &OutboxItem,
        message: &mut PushMessage,
    ) -> store::Result<Option<Settle>> {
        // 系统通知栏、群聊都是公开展示的地方：命中过滤的换成中性提示，原文留在收件箱。
        for text in [message.title.clone(), message.body.clone()] {
            if let Verdict::Block { reason } = self.filter.check(&text) {
                info!(item = item.id, %reason, "push text filtered");
                message.title = crate::texts::APP_NAME.into();
                message.body = filter::blocked_body(message.locale).into();
                message.ai_generated = false;
                break;
            }
        }
        // 审批提醒：用户已经在别的设备上处理了、过期了，或者运行已经结束，就不必再推。放在过期检查前面：
        // 审批的有效期可能只有一分钟，排队时过期是常事，按“处理过了”了结，不当成发送失败。
        if message.kind == PushKind::Approval
            && let Some(id) = message.target.approval_id.as_deref()
            && let Ok(id) = id.parse::<ApprovalId>()
        {
            let mut w = self.db.worker().await?;
            let pending = w.approval_pending(id).await?;
            w.rollback().await?;
            if !pending {
                return Ok(Some(Settle::Done(Some(
                    "approval no longer pending".into(),
                ))));
            }
        }
        if let Some(ttl) = message.ttl {
            let age = (Utc::now() - item.created_at).to_std().unwrap_or_default();
            if age > ttl {
                return Ok(Some(Settle::Done(Some("expired before delivery".into()))));
            }
        }
        Ok(None)
    }

    async fn deliver(&self, item: &OutboxItem) -> store::Result<Settle> {
        let mut message: PushMessage = match serde_json::from_value(item.payload.clone()) {
            Ok(m) => m,
            Err(e) => return Ok(Settle::Done(Some(format!("bad push payload: {e}")))),
        };
        if let Some(done) = self.screen(item, &mut message).await? {
            return Ok(done);
        }
        let mut w = self.db.worker().await?;
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

    /// 发到一个 IM 渠道（10.5）。发不出去的原因都记在渠道上（`last_error`），用户在 App 里看得到。
    async fn deliver_im(&self, item: &OutboxItem) -> store::Result<Settle> {
        let ImPayload {
            channel: id,
            mut message,
        } = match serde_json::from_value(item.payload.clone()) {
            Ok(p) => p,
            Err(e) => return Ok(Settle::Done(Some(format!("bad im payload: {e}")))),
        };
        let mut w = self.db.worker().await?;
        let ch = w.sealed_im_channel(id).await?;
        // 条目都是按用户自己的渠道写的；对不上就只放弃这一条，不碰那个渠道排着的别的条目。
        if ch.as_ref().is_some_and(|ch| ch.user_id != item.user_id) {
            w.rollback().await?;
            return Ok(Settle::Done(Some(
                "im channel belongs to another user".into(),
            )));
        }
        let gone = match &ch {
            None => Some("im channel deleted"),
            Some(ch) if !ch.channel.enabled => Some("im channel disabled"),
            _ => None,
        };
        if let Some(reason) = gone {
            // 后面排着的一起放弃：一条条领出来再放弃太慢。
            w.drop_im_backlog(id, reason).await?;
            w.commit().await?;
            return Ok(Settle::Done(Some(reason.into())));
        }
        w.rollback().await?;
        let ch = ch.expect("checked above");
        let rev = ch.webhook_rev;
        let Some((sender, kms)) = &self.im else {
            let mut w = self.db.worker().await?;
            w.record_im_result(
                id,
                rev,
                Some("IM sending is turned off on this server"),
                false,
            )
            .await?;
            w.commit().await?;
            return Ok(Settle::Done(Some("im channels are not configured".into())));
        };
        // 用户在排队期间退订了这个事件：不发了（测试消息、渠道停用的通知不属于哪个事件，照发）。
        if let Some(event) = im_event(message.kind)
            && !ch.channel.events.contains(&event)
        {
            return Ok(Settle::Done(Some("im channel no longer subscribed".into())));
        }
        if let Some(done) = self.screen(item, &mut message).await? {
            // 只有排满一个小时的才记到渠道上（审批提醒的有效期可能只有一分钟，过期是正常的）。
            let age = (Utc::now() - item.created_at).to_std().unwrap_or_default();
            if age > IM_TTL
                && matches!(&done, Settle::Done(Some(r)) if r == "expired before delivery")
            {
                let mut w = self.db.worker().await?;
                w.record_im_result(
                    id,
                    rev,
                    Some("a message was not sent within an hour and was dropped"),
                    false,
                )
                .await?;
                w.commit().await?;
            }
            return Ok(done);
        }
        // 先占名额并提交：多个副本共用这个渠道的发送节奏。
        let mut w = self.db.worker().await?;
        let slot = w.take_im_slot(id, im_interval(ch.channel.vendor)).await?;
        w.commit().await?;
        match slot {
            ImSlot::Go => {}
            ImSlot::Wait(at) => return Ok(Settle::Defer("im channel rate limit".into(), at)),
            ImSlot::Gone => return Ok(Settle::Done(Some("im channel disabled".into()))),
        }
        let uid = item.user_id.to_string();
        let opened =
            match crate::artifacts::user_vault(&self.db, kms.clone(), item.user_id, false).await {
                Ok(vault) => vault.open_webhook(&uid, &id.to_string(), &ch.sealed).await,
                Err(crate::artifacts::ArtifactError::Crypto(e)) => Err(e),
                Err(crate::artifacts::ArtifactError::Store(e)) => return Err(e),
                Err(e) => Err(keyvault::Error::Kms(e.to_string())),
            };
        let secret = match opened {
            Ok(s) => s,
            // 账号注销了（DEK 删了）或者密文对不上：没法再发，排着的一起放弃。
            Err(
                e @ (keyvault::Error::NoUserKey(_)
                | keyvault::Error::Decrypt
                | keyvault::Error::Malformed),
            ) => {
                warn!(channel = %id, error = %e, "cannot open the stored webhook");
                let mut w = self.db.worker().await?;
                w.record_im_result(
                    id,
                    rev,
                    Some("the stored webhook cannot be opened; enter the address again"),
                    false,
                )
                .await?;
                w.drop_im_backlog(id, "cannot open the webhook").await?;
                w.commit().await?;
                return Ok(Settle::Done(Some(format!("cannot open the webhook: {e}"))));
            }
            // 密钥服务暂时不可用：过一阵再试，和厂商的暂时故障一样记在渠道上（不带密钥服务的原话）。
            Err(e) => {
                warn!(channel = %id, error = %e, "key vault unavailable for an im message");
                let shown = if item.attempts >= self.cfg.max_attempts {
                    format!(
                        "gave up after {} attempts: the server could not open the stored webhook",
                        item.attempts
                    )
                } else {
                    "the server could not open the stored webhook (retrying)".to_owned()
                };
                let mut w = self.db.worker().await?;
                w.record_im_result(id, rev, Some(&shown), false).await?;
                w.commit().await?;
                return Ok(Settle::Retry(format!("key vault: {e}"), Duration::ZERO));
            }
        };
        let hook = ImHook {
            vendor: ch.channel.vendor,
            token: Zeroizing::new(secret.token.clone()),
            secret: (!secret.secret.is_empty()).then(|| Zeroizing::new(secret.secret.clone())),
        };
        drop(secret);
        let locale = message.locale;
        let mut text = message.display_body();
        if message.kind == PushKind::Approval {
            text = format!("{text}\n{}", crate::texts::im_approval_hint(locale));
        }
        let im = ImMessage {
            title: crate::texts::im_title(locale, &message.title),
            text,
            locale,
        };
        let vendor = ch.channel.vendor.as_str();
        let outcome = sender.send(&hook, &im).await;
        let mut w = self.db.worker().await?;
        let settle = match outcome {
            PushOutcome::Delivered { .. } => {
                w.record_im_result(id, rev, None, false).await?;
                Settle::Done(None)
            }
            PushOutcome::InvalidToken { reason } => {
                info!(channel = %id, vendor, %reason, "im bot is gone, disabling the channel");
                if w.record_im_result(id, rev, Some(&reason), true).await? {
                    // 只在这次真把渠道停掉时说一次（同一个地址只说一次）。
                    let (title, body) =
                        crate::texts::im_channel_disabled(locale, &ch.channel.label);
                    let mut notice = Notice::new(PushKind::Info, title, body);
                    notice.dedupe_key = Some(format!("im-disabled:{id}:{rev}"));
                    notify(&mut w, item.user_id, &notice).await?;
                    w.drop_im_backlog(id, "im channel disabled").await?;
                }
                Settle::Done(Some(reason))
            }
            PushOutcome::Rejected { reason } => {
                warn!(channel = %id, vendor, %reason, "im message rejected");
                w.record_im_result(id, rev, Some(&reason), false).await?;
                Settle::Done(Some(reason))
            }
            // 厂商说限流了：这个渠道一段时间都不发，排着的跟着等，不算一次尝试。
            PushOutcome::Retry {
                after: Some(after),
                reason,
            } => {
                let until = chrono::Duration::from_std(after.min(Duration::from_secs(3600)))
                    .ok()
                    .and_then(|d| Utc::now().checked_add_signed(d))
                    .unwrap_or_else(Utc::now);
                w.throttle_im_channel(id, until).await?;
                Settle::Defer(reason, until)
            }
            PushOutcome::Retry {
                after: None,
                reason,
            } => {
                let shown = if item.attempts >= self.cfg.max_attempts {
                    format!("gave up after {} attempts: {reason}", item.attempts)
                } else {
                    format!("{reason} (retrying)")
                };
                w.record_im_result(id, rev, Some(&shown), false).await?;
                Settle::Retry(reason, Duration::ZERO)
            }
        };
        w.commit().await?;
        Ok(settle)
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
