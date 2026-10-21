//! IM 渠道（10.5）：通知按订阅的事件进出箱，投递时解开凭证、限流、按结果停用或记下错误。
//! 需要 DATABASE_URL（没有时跳过）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use keyvault::{Kms, LocalKms, WebhookSecret};
use notify::filter::KeywordFilter;
use notify::im::{ImHook, ImMessage, ImSender};
use notify::{PushKind, PushMessage, PushOutcome, PushTarget};
use orchestrator::artifacts::user_vault;
use orchestrator::outbox::{Claims, Dispatcher, DispatcherConfig, IM, Notice, im_item, notify};
use proto::domain::{ImChannelId, ImEvent, ImVendor, Locale, UserId};
use serde_json::Value;
use store::testing::TestDb;
use store::{ImChannelChange, NewImChannel};

type Sent = (ImVendor, String, Option<String>, ImMessage);

#[derive(Default)]
struct Recording {
    outcomes: Mutex<HashMap<String, PushOutcome>>,
    /// 发到这个 token 要等这么久（厂商慢、连不上时等到超时）。
    delays: Mutex<HashMap<String, Duration>>,
    sent: Mutex<Vec<Sent>>,
}

impl Recording {
    fn set(&self, token: &str, outcome: PushOutcome) {
        self.outcomes.lock().unwrap().insert(token.into(), outcome);
    }
    fn sent(&self) -> Vec<Sent> {
        std::mem::take(&mut self.sent.lock().unwrap())
    }
}

#[async_trait]
impl ImSender for Recording {
    async fn send(&self, hook: &ImHook, message: &ImMessage) -> PushOutcome {
        let token = hook.token.as_str().to_owned();
        let delay = self.delays.lock().unwrap().get(&token).copied();
        if let Some(delay) = delay {
            tokio::time::sleep(delay).await;
        }
        self.sent.lock().unwrap().push((
            hook.vendor,
            token.clone(),
            hook.secret.as_ref().map(|s| s.as_str().to_owned()),
            message.clone(),
        ));
        self.outcomes
            .lock()
            .unwrap()
            .get(&token)
            .cloned()
            .unwrap_or(PushOutcome::Delivered { id: None })
    }
}

fn kms() -> Arc<dyn Kms> {
    Arc::new(LocalKms::new("local-1", &[7u8; 32]))
}

async fn user(t: &TestDb, phone: &str) -> UserId {
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone(phone).await.unwrap();
    w.commit().await.unwrap();
    user.id
}

async fn channel(
    t: &TestDb,
    user: UserId,
    vendor: ImVendor,
    token: &str,
    secret: &str,
    events: &[ImEvent],
) -> ImChannelId {
    let id = ImChannelId::new();
    let vault = user_vault(&t.db, kms(), user, true).await.unwrap();
    let hook = WebhookSecret {
        token: token.into(),
        secret: secret.into(),
    };
    let sealed = vault
        .seal_webhook(&user.to_string(), &id.to_string(), &hook)
        .await
        .unwrap();
    let mut tx = t.db.tenant(user).await.unwrap();
    tx.create_im_channel(
        &NewImChannel {
            id,
            vendor,
            label: "家庭群".into(),
            sealed,
            hint: proto::im::hint(token),
            has_secret: !secret.is_empty(),
            events: events.to_vec(),
        },
        20,
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    id
}

fn notice(kind: PushKind, key: &str) -> Notice {
    let mut n = Notice::new(kind, "每日新闻", "今天的三条要闻");
    n.dedupe_key = Some(key.into());
    n.ai_generated = kind == PushKind::RunFinished;
    n
}

async fn send(t: &TestDb, user: UserId, n: &Notice) {
    let mut w = t.db.worker().await.unwrap();
    notify(&mut w, user, n).await.unwrap();
    w.commit().await.unwrap();
}

async fn outbox(t: &TestDb, user: UserId) -> Vec<(String, Option<String>, Value)> {
    sqlx::query_as("SELECT kind, dedupe_key, payload FROM outbox WHERE user_id = $1 ORDER BY id")
        .bind(user.0)
        .fetch_all(t.db.pool())
        .await
        .unwrap()
}

fn dispatcher(t: &TestDb, im: Arc<Recording>) -> Dispatcher {
    Dispatcher::new(
        t.db.clone(),
        "node-a",
        DispatcherConfig {
            backoff_base: Duration::ZERO,
            ..Default::default()
        },
    )
    .with_im(im, kms())
}

/// 只投 IM 的条目（推送条目留着，免得这些测试还要建设备）。
async fn drain_push(t: &TestDb) {
    sqlx::query("UPDATE outbox SET delivered_at = now() WHERE kind = 'push'")
        .execute(t.db.pool())
        .await
        .unwrap();
}

#[tokio::test]
async fn notices_go_to_each_subscribed_enabled_channel_once() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000021").await;
    let all = channel(
        &t,
        u,
        ImVendor::Feishu,
        "feishu-token-0001",
        "s3cret-feishu",
        ImEvent::ALL,
    )
    .await;
    let approvals = channel(
        &t,
        u,
        ImVendor::Wecom,
        "wecom-key-00001",
        "",
        &[ImEvent::Approval],
    )
    .await;
    let off = channel(
        &t,
        u,
        ImVendor::Dingtalk,
        "ding-token-0001",
        "",
        ImEvent::ALL,
    )
    .await;
    let mut tx = t.db.tenant(u).await.unwrap();
    tx.update_im_channel(
        off,
        &store::ImChannelChange {
            enabled: Some(false),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();

    send(&t, u, &notice(PushKind::RunFinished, "run:1:succeeded")).await;
    send(&t, u, &notice(PushKind::RunFinished, "run:1:succeeded")).await; // 同一件事只通知一次
    send(&t, u, &notice(PushKind::Info, "info:1")).await; // 一般提醒不发到群里
    let rows = outbox(&t, u).await;
    let kinds: Vec<_> = rows.iter().map(|(k, _, _)| k.as_str()).collect();
    assert_eq!(kinds, vec!["push", IM, "push"]);
    let (_, key, payload) = &rows[1];
    assert!(key.as_deref().unwrap().starts_with(&format!("im:{all}:")));
    assert_eq!(payload["channel"], all.to_string());
    // 载荷里没有凭证。
    let text = payload.to_string();
    assert!(!text.contains("feishu-token-0001") && !text.contains("s3cret"));

    send(&t, u, &notice(PushKind::Approval, "approval:1")).await;
    let rows = outbox(&t, u).await;
    let im: Vec<_> = rows
        .iter()
        .filter(|(k, _, _)| k == IM)
        .map(|(_, _, p)| p["channel"].clone())
        .collect();
    assert_eq!(im.len(), 3);
    assert!(im.contains(&Value::String(approvals.to_string())));
    assert!(!im.contains(&Value::String(off.to_string())));
}

#[tokio::test]
async fn delivered_messages_carry_the_brand_label_and_approval_hint() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000022").await;
    let ch = channel(
        &t,
        u,
        ImVendor::Dingtalk,
        "ding-token-0002",
        "SECding-secret",
        ImEvent::ALL,
    )
    .await;
    send(&t, u, &notice(PushKind::RunFinished, "run:2:succeeded")).await;
    drain_push(&t).await;
    let rec = Arc::new(Recording::default());
    let d = dispatcher(&t, rec.clone());
    let report = d.tick().await.unwrap();
    assert_eq!(
        (report.delivered, report.retried, report.dropped),
        (1, 0, 0)
    );
    let sent = rec.sent();
    let (vendor, token, secret, msg) = &sent[0];
    assert_eq!(
        (*vendor, token.as_str(), secret.as_deref()),
        (
            ImVendor::Dingtalk,
            "ding-token-0002",
            Some("SECding-secret")
        )
    );
    assert_eq!(msg.title, "【ThinkTin】每日新闻");
    assert_eq!(msg.text, "【AI 生成】今天的三条要闻");
    let mut tx = t.db.tenant(u).await.unwrap();
    let got = tx.im_channel(ch).await.unwrap();
    assert!(got.last_sent_at.is_some() && got.last_error.is_none());
    tx.rollback().await.unwrap();

    // 审批：群消息只是提醒，说明要去 App 里审批。英文用户收到英文。
    let mut tx = t.db.tenant(u).await.unwrap();
    tx.enqueue_outbox(&im_item(
        ch,
        &PushMessage {
            kind: PushKind::Approval,
            title: "Needs approval".into(),
            body: "Delete 3 files".into(),
            thread_id: None,
            collapse_id: None,
            target: PushTarget::default(),
            ttl: Some(Duration::from_secs(3600)),
            ai_generated: true,
            locale: Locale::En,
        },
        None,
    ))
    .await
    .unwrap();
    tx.commit().await.unwrap();
    d.tick().await.unwrap();
    let (_, _, _, msg) = &rec.sent()[0];
    assert_eq!(msg.title, "[ThinkTin] Needs approval");
    assert!(
        msg.text.starts_with("[AI-generated] Delete 3 files\n"),
        "{}",
        msg.text
    );
    assert!(msg.text.contains("ThinkTin app"));
}

#[tokio::test]
async fn dead_bots_disable_the_channel_and_tell_the_user_once() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000023").await;
    let ch = channel(&t, u, ImVendor::Wecom, "wecom-dead-0001", "", ImEvent::ALL).await;
    let rec = Arc::new(Recording::default());
    rec.set(
        "wecom-dead-0001",
        PushOutcome::InvalidToken {
            reason: "wecom 93000: the webhook is invalid".into(),
        },
    );
    send(&t, u, &notice(PushKind::RunFailed, "run:3:failed")).await;
    drain_push(&t).await;
    let d = dispatcher(&t, rec.clone());
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    let mut tx = t.db.tenant(u).await.unwrap();
    let got = tx.im_channel(ch).await.unwrap();
    assert!(!got.enabled);
    assert_eq!(
        got.last_error.as_deref(),
        Some("wecom 93000: the webhook is invalid")
    );
    let inbox = tx.inbox(None, 10, false).await.unwrap();
    assert!(
        inbox
            .iter()
            .any(|i| i.title == "IM 群提醒已停用" && i.body.contains("「家庭群」")),
        "{inbox:?}"
    );
    tx.rollback().await.unwrap();
    // 停用以后不再发到这个群。
    send(&t, u, &notice(PushKind::RunFailed, "run:4:failed")).await;
    assert!(
        outbox(&t, u)
            .await
            .iter()
            .filter(|(k, _, _)| k == IM)
            .count()
            == 1
    );
}

#[tokio::test]
async fn rejected_messages_record_the_reason_and_keep_the_channel() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000024").await;
    let ch = channel(&t, u, ImVendor::Feishu, "feishu-kw-00001", "", ImEvent::ALL).await;
    let rec = Arc::new(Recording::default());
    rec.set(
        "feishu-kw-00001",
        PushOutcome::Rejected {
            reason: "feishu 19024: no custom keyword".into(),
        },
    );
    send(&t, u, &notice(PushKind::RunFinished, "run:5:succeeded")).await;
    drain_push(&t).await;
    assert_eq!(dispatcher(&t, rec.clone()).tick().await.unwrap().dropped, 1);
    let mut tx = t.db.tenant(u).await.unwrap();
    let got = tx.im_channel(ch).await.unwrap();
    assert!(got.enabled);
    assert_eq!(
        got.last_error.as_deref(),
        Some("feishu 19024: no custom keyword")
    );
}

#[tokio::test]
async fn a_busy_channel_defers_without_spending_attempts() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000025").await;
    let ch = channel(
        &t,
        u,
        ImVendor::Dingtalk,
        "ding-busy-00001",
        "",
        ImEvent::ALL,
    )
    .await;
    // 上一条刚发过：钉钉两条之间隔 3.3 秒，可以连着发两条，再往后排就要等。
    sqlx::query(
        "UPDATE im_channels SET next_slot_at = now() + interval '30 seconds' WHERE id = $1",
    )
    .bind(ch.0)
    .execute(t.db.pool())
    .await
    .unwrap();
    send(&t, u, &notice(PushKind::RunFinished, "run:6:succeeded")).await;
    drain_push(&t).await;
    let rec = Arc::new(Recording::default());
    let report = dispatcher(&t, rec.clone()).tick().await.unwrap();
    assert_eq!(
        (report.delivered, report.retried, report.dropped),
        (0, 1, 0)
    );
    assert!(rec.sent().is_empty());
    let (attempts, wait): (i32, f64) = sqlx::query_as(
        "SELECT attempts, extract(epoch FROM available_at - now())::float8 FROM outbox WHERE kind = 'im'",
    )
    .fetch_one(t.db.pool())
    .await
    .unwrap();
    assert_eq!(attempts, 0);
    assert!((20.0..=27.0).contains(&wait), "{wait}");
}

#[tokio::test]
async fn filtered_text_deleted_channels_and_erased_accounts() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000026").await;
    let ch = channel(&t, u, ImVendor::Lark, "lark-token-0001", "", ImEvent::ALL).await;
    let rec = Arc::new(Recording::default());
    let d = dispatcher(&t, rec.clone()).with_filter(Arc::new(KeywordFilter::new(["坏词"])));
    let mut bad = notice(PushKind::RunFinished, "run:7:succeeded");
    bad.body = "里面有坏词".into();
    send(&t, u, &bad).await;
    drain_push(&t).await;
    d.tick().await.unwrap();
    let (_, _, _, msg) = &rec.sent()[0];
    assert_eq!(msg.title, "ThinkTin");
    assert!(
        !msg.text.contains("坏词") && !msg.text.contains("AI"),
        "{}",
        msg.text
    );

    // 投递前渠道删了：放弃。
    send(&t, u, &notice(PushKind::RunFinished, "run:8:succeeded")).await;
    drain_push(&t).await;
    let mut tx = t.db.tenant(u).await.unwrap();
    tx.delete_im_channel(ch).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    assert!(rec.sent().is_empty());

    // 账号的 DEK 没了（注销）：解不开，放弃。
    let ch2 = channel(&t, u, ImVendor::Lark, "lark-token-0002", "", ImEvent::ALL).await;
    send(&t, u, &notice(PushKind::RunFinished, "run:9:succeeded")).await;
    drain_push(&t).await;
    sqlx::query("DELETE FROM user_keys WHERE user_id = $1")
        .bind(u.0)
        .execute(t.db.pool())
        .await
        .unwrap();
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    assert!(rec.sent().is_empty());
    let _ = ch2;

    // 没配 IM 的投递器：放弃，不会卡住。
    let u2 = user(&t, "+8613800000027").await;
    channel(&t, u2, ImVendor::Lark, "lark-token-0003", "", ImEvent::ALL).await;
    send(&t, u2, &notice(PushKind::RunFinished, "run:10:succeeded")).await;
    drain_push(&t).await;
    let bare = Dispatcher::new(t.db.clone(), "node-b", DispatcherConfig::default());
    assert_eq!(bare.tick().await.unwrap().dropped, 1);
}

async fn channel_row(t: &TestDb, user: UserId, ch: ImChannelId) -> proto::domain::ImChannel {
    let mut tx = t.db.tenant(user).await.unwrap();
    let got = tx.im_channel(ch).await.unwrap();
    tx.rollback().await.unwrap();
    got
}

async fn im_rows(t: &TestDb, user: UserId) -> Vec<(i32, Option<String>, bool)> {
    sqlx::query_as(
        "SELECT attempts, last_error, delivered_at IS NOT NULL FROM outbox WHERE user_id = $1 AND kind = 'im' ORDER BY id",
    )
    .bind(user.0)
    .fetch_all(t.db.pool())
    .await
    .unwrap()
}

#[tokio::test]
async fn unsubscribing_stops_queued_messages_for_that_event() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000031").await;
    let ch = channel(&t, u, ImVendor::Wecom, "wecom-unsub-001", "", ImEvent::ALL).await;
    send(&t, u, &notice(PushKind::RunFinished, "run:31:succeeded")).await;
    drain_push(&t).await;
    let mut tx = t.db.tenant(u).await.unwrap();
    tx.update_im_channel(
        ch,
        &ImChannelChange {
            events: Some(vec![ImEvent::Approval]),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let rec = Arc::new(Recording::default());
    assert_eq!(dispatcher(&t, rec.clone()).tick().await.unwrap().dropped, 1);
    assert!(rec.sent().is_empty());
    assert_eq!(
        im_rows(&t, u).await[0].1.as_deref(),
        Some("im channel no longer subscribed")
    );
}

#[tokio::test]
async fn vendor_rate_limits_hold_the_channel_without_spending_attempts() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000032").await;
    let ch = channel(
        &t,
        u,
        ImVendor::Dingtalk,
        "ding-throttle-01",
        "",
        ImEvent::ALL,
    )
    .await;
    let rec = Arc::new(Recording::default());
    rec.set(
        "ding-throttle-01",
        PushOutcome::Retry {
            after: Some(Duration::from_secs(600)),
            reason: "dingtalk 410100: rate limited".into(),
        },
    );
    for i in 0..3 {
        send(
            &t,
            u,
            &notice(PushKind::RunFinished, &format!("run:32{i}:succeeded")),
        )
        .await;
    }
    drain_push(&t).await;
    let d = dispatcher(&t, rec.clone());
    let report = d.tick().await.unwrap();
    assert_eq!(
        (report.delivered, report.retried, report.dropped),
        (0, 1, 0)
    );
    // 只碰了厂商一次；后面排着的跟着等，不会再去撞限流。
    assert_eq!(rec.sent().len(), 1);
    assert_eq!(d.tick().await.unwrap(), Default::default());
    let rows = im_rows(&t, u).await;
    assert_eq!(
        rows.iter().map(|r| r.0).collect::<Vec<_>>(),
        vec![0, 0, 0],
        "no attempts spent"
    );
    let wait: f64 = sqlx::query_scalar(
        "SELECT extract(epoch FROM next_slot_at - now())::float8 FROM im_channels WHERE id = $1",
    )
    .bind(ch.0)
    .fetch_one(t.db.pool())
    .await
    .unwrap();
    assert!((590.0..=600.0).contains(&wait), "{wait}");
}

#[tokio::test]
async fn retryable_failures_show_on_the_channel_and_giving_up_too() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000033").await;
    let ch = channel(&t, u, ImVendor::Lark, "lark-timeout-01", "", ImEvent::ALL).await;
    let rec = Arc::new(Recording::default());
    rec.set(
        "lark-timeout-01",
        PushOutcome::Retry {
            after: None,
            reason: "lark: network: connection timed out".into(),
        },
    );
    send(&t, u, &notice(PushKind::RunFinished, "run:33:succeeded")).await;
    drain_push(&t).await;
    let d = Dispatcher::new(
        t.db.clone(),
        "node-a",
        DispatcherConfig {
            backoff_base: Duration::ZERO,
            max_attempts: 2,
            ..Default::default()
        },
    )
    .with_im(rec.clone(), kms());
    assert_eq!(d.tick().await.unwrap().retried, 1);
    assert_eq!(
        channel_row(&t, u, ch).await.last_error.as_deref(),
        Some("lark: network: connection timed out (retrying)")
    );
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    let got = channel_row(&t, u, ch).await;
    assert_eq!(
        got.last_error.as_deref(),
        Some("gave up after 2 attempts: lark: network: connection timed out")
    );
    assert!(got.enabled && got.last_sent_at.is_none());

    // 后台没开 IM：也记在渠道上（测试消息发不出去，用户要知道为什么）。
    send(&t, u, &notice(PushKind::RunFinished, "run:34:succeeded")).await;
    drain_push(&t).await;
    let bare = Dispatcher::new(t.db.clone(), "node-b", DispatcherConfig::default());
    assert_eq!(bare.tick().await.unwrap().dropped, 1);
    assert_eq!(
        channel_row(&t, u, ch).await.last_error.as_deref(),
        Some("IM sending is turned off on this server")
    );

    // 排了一个多小时还没发出去的：不发了，记在渠道上。
    send(&t, u, &notice(PushKind::RunFinished, "run:35:succeeded")).await;
    drain_push(&t).await;
    sqlx::query("UPDATE outbox SET created_at = now() - interval '2 hours' WHERE kind = 'im' AND delivered_at IS NULL")
        .execute(t.db.pool())
        .await
        .unwrap();
    rec.set("lark-timeout-01", PushOutcome::Delivered { id: None });
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    assert!(rec.sent().iter().all(|s| s.3.title.contains("每日新闻")));
    assert_eq!(
        channel_row(&t, u, ch).await.last_error.as_deref(),
        Some("a message was not sent within an hour and was dropped")
    );

    // 审批提醒的有效期短（这里一分钟），排队时过期了是正常的：不发，也不算渠道出错。
    send(&t, u, &notice(PushKind::RunFinished, "run:36:succeeded")).await;
    drain_push(&t).await;
    sqlx::query("UPDATE im_channels SET next_slot_at = NULL")
        .execute(t.db.pool())
        .await
        .unwrap();
    assert_eq!(d.tick().await.unwrap().delivered, 1);
    let mut n = notice(PushKind::Approval, "approval:36");
    n.ttl = Some(Duration::from_secs(60));
    send(&t, u, &n).await;
    drain_push(&t).await;
    sqlx::query("UPDATE outbox SET created_at = now() - interval '5 minutes' WHERE kind = 'im' AND delivered_at IS NULL")
        .execute(t.db.pool())
        .await
        .unwrap();
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    assert_eq!(channel_row(&t, u, ch).await.last_error, None);
}

/// 解不开数据密钥的 KMS（云 KMS 限流、权限出错）。
struct DownKms;

#[async_trait]
impl Kms for DownKms {
    fn current_key_id(&self) -> &str {
        "local-1"
    }
    async fn wrap(&self, _: &[u8; 32], _: &str) -> keyvault::Result<keyvault::WrappedKey> {
        Err(keyvault::Error::Kms("ThrottlingException".into()))
    }
    async fn unwrap(
        &self,
        _: &keyvault::WrappedKey,
        _: &str,
    ) -> keyvault::Result<zeroize::Zeroizing<[u8; 32]>> {
        Err(keyvault::Error::Kms("ThrottlingException".into()))
    }
}

#[tokio::test]
async fn key_vault_failures_show_on_the_channel() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000037").await;
    let ch = channel(&t, u, ImVendor::Feishu, "feishu-kms-0001", "", ImEvent::ALL).await;
    send(&t, u, &notice(PushKind::RunFailed, "run:37:failed")).await;
    drain_push(&t).await;
    let rec = Arc::new(Recording::default());
    let d = Dispatcher::new(
        t.db.clone(),
        "node-a",
        DispatcherConfig {
            backoff_base: Duration::ZERO,
            max_attempts: 2,
            ..Default::default()
        },
    )
    .with_im(rec.clone(), Arc::new(DownKms));
    assert_eq!(d.tick().await.unwrap().retried, 1);
    assert_eq!(
        channel_row(&t, u, ch).await.last_error.as_deref(),
        Some("the server could not open the stored webhook (retrying)")
    );
    sqlx::query("UPDATE im_channels SET next_slot_at = NULL")
        .execute(t.db.pool())
        .await
        .unwrap();
    assert_eq!(d.tick().await.unwrap().dropped, 1);
    let got = channel_row(&t, u, ch).await;
    assert_eq!(
        got.last_error.as_deref(),
        Some("gave up after 2 attempts: the server could not open the stored webhook")
    );
    assert!(got.enabled && got.last_sent_at.is_none());
    assert!(rec.sent().is_empty());

    // 密文坏了：没法再发，排着的一起放弃，渠道上说要重新填地址。
    sqlx::query(
        "UPDATE im_channels SET sealed = '\\x00'::bytea, next_slot_at = NULL WHERE id = $1",
    )
    .bind(ch.0)
    .execute(t.db.pool())
    .await
    .unwrap();
    send(&t, u, &notice(PushKind::RunFailed, "run:38:failed")).await;
    send(&t, u, &notice(PushKind::RunFailed, "run:39:failed")).await;
    drain_push(&t).await;
    assert_eq!(dispatcher(&t, rec.clone()).tick().await.unwrap().dropped, 1);
    assert_eq!(
        channel_row(&t, u, ch).await.last_error.as_deref(),
        Some("the stored webhook cannot be opened; enter the address again")
    );
    assert!(
        im_rows(&t, u).await.iter().all(|r| r.2),
        "the backlog is dropped too"
    );
    assert!(rec.sent().is_empty());
}

#[tokio::test]
async fn a_dead_bot_is_reported_once_and_a_new_address_turns_the_channel_back_on() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000034").await;
    let ch = channel(
        &t,
        u,
        ImVendor::Feishu,
        "feishu-dead-0001",
        "",
        ImEvent::ALL,
    )
    .await;
    let rec = Arc::new(Recording::default());
    rec.set(
        "feishu-dead-0001",
        PushOutcome::InvalidToken {
            reason: "feishu 19001: bot removed".into(),
        },
    );
    for i in 0..3 {
        send(
            &t,
            u,
            &notice(PushKind::RunFailed, &format!("run:34{i}:failed")),
        )
        .await;
    }
    drain_push(&t).await;
    let d = dispatcher(&t, rec.clone());
    d.tick().await.unwrap();
    // 排着的另外两条一起放弃，只通知一次。
    assert_eq!(rec.sent().len(), 1);
    let rows = im_rows(&t, u).await;
    assert!(rows.iter().all(|r| r.2), "{rows:?}");
    let notices: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM inbox_items WHERE user_id = $1 AND title = 'IM 群提醒已停用'",
    )
    .bind(u.0)
    .fetch_one(t.db.pool())
    .await
    .unwrap();
    assert_eq!(notices, 1);
    // 照通知说的，换上新地址：渠道重新打开，接着发。
    let vault = user_vault(&t.db, kms(), u, false).await.unwrap();
    let sealed = vault
        .seal_webhook(
            &u.to_string(),
            &ch.to_string(),
            &WebhookSecret {
                token: "feishu-new-00001".into(),
                secret: String::new(),
            },
        )
        .await
        .unwrap();
    let mut tx = t.db.tenant(u).await.unwrap();
    let back = tx
        .update_im_channel(
            ch,
            &ImChannelChange {
                webhook: Some((
                    ImVendor::Feishu,
                    sealed,
                    proto::im::hint("feishu-new-00001"),
                    false,
                )),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert!(back.enabled && back.last_error.is_none());
    send(&t, u, &notice(PushKind::RunFailed, "run:349:failed")).await;
    drain_push(&t).await;
    assert_eq!(d.tick().await.unwrap().delivered, 1);
    assert_eq!(rec.sent()[0].1, "feishu-new-00001");
}

#[tokio::test]
async fn push_and_im_dispatchers_claim_their_own_rows_and_channels_go_in_parallel() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000035").await;
    let a = channel(&t, u, ImVendor::Feishu, "feishu-par-0001", "", ImEvent::ALL).await;
    let b = channel(&t, u, ImVendor::Lark, "lark-par-00001", "", ImEvent::ALL).await;
    for i in 0..2 {
        send(
            &t,
            u,
            &notice(PushKind::RunFinished, &format!("run:35{i}:succeeded")),
        )
        .await;
    }
    let rec = Arc::new(Recording::default());
    // 推送的投递器不碰 IM 条目。
    let push = Dispatcher::new(
        t.db.clone(),
        "node-p",
        DispatcherConfig {
            claims: Claims::Push,
            ..Default::default()
        },
    );
    push.tick().await.unwrap();
    assert_eq!(im_rows(&t, u).await.iter().filter(|r| r.0 > 0).count(), 0);
    let pending_push: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM outbox WHERE kind = 'push' AND delivered_at IS NULL",
    )
    .fetch_one(t.db.pool())
    .await
    .unwrap();
    assert_eq!(pending_push, 0, "push rows settled (no devices)");
    // IM 的投递器：每个渠道一次一条，两个渠道同时发；同一个渠道按顺序。
    let im = Dispatcher::new(
        t.db.clone(),
        "node-i",
        DispatcherConfig {
            claims: Claims::Im,
            concurrency: 8,
            ..Default::default()
        },
    )
    .with_im(rec.clone(), kms());
    assert_eq!(im.tick().await.unwrap().delivered, 2);
    let first: Vec<String> = rec.sent().into_iter().map(|s| s.1).collect();
    assert_eq!(first.len(), 2);
    assert!(
        first.contains(&"feishu-par-0001".to_owned())
            && first.contains(&"lark-par-00001".to_owned())
    );
    sqlx::query("UPDATE im_channels SET next_slot_at = NULL")
        .execute(t.db.pool())
        .await
        .unwrap();
    assert_eq!(im.tick().await.unwrap().delivered, 2);
    let _ = (a, b);
}

#[tokio::test]
async fn a_slow_bot_does_not_hold_up_other_channels() {
    let Some(t) = TestDb::new().await else { return };
    let u = user(&t, "+8613800000040").await;
    let slow = channel(&t, u, ImVendor::Lark, "lark-blackhole-1", "", ImEvent::ALL).await;
    let fast = channel(
        &t,
        u,
        ImVendor::Feishu,
        "feishu-fast-0001",
        "",
        ImEvent::ALL,
    )
    .await;
    let rec = Arc::new(Recording::default());
    rec.delays
        .lock()
        .unwrap()
        .insert("lark-blackhole-1".into(), Duration::from_secs(3));
    let mut w = t.db.worker().await.unwrap();
    let mut msg = notice(PushKind::Info, "x").push(None, Locale::ZhCn);
    msg.ttl = None;
    w.enqueue_outbox(u, &im_item(slow, &msg, None))
        .await
        .unwrap();
    for _ in 0..2 {
        w.enqueue_outbox(u, &im_item(fast, &msg, None))
            .await
            .unwrap();
    }
    w.commit().await.unwrap();
    let d = Arc::new(
        Dispatcher::new(
            t.db.clone(),
            "node-a",
            DispatcherConfig {
                tick: Duration::from_millis(50),
                claims: Claims::Im,
                concurrency: 4,
                ..Default::default()
            },
        )
        .with_im(rec.clone(), kms()),
    );
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let running = tokio::spawn({
        let d = d.clone();
        async move {
            d.run(async {
                let _ = stopped.await;
            })
            .await
        }
    });
    let delivered = |ch: ImChannelId| {
        let pool = t.db.pool().clone();
        async move {
            let n: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM outbox WHERE kind = 'im' AND delivered_at IS NOT NULL \
                 AND payload->>'channel' = $1",
            )
            .bind(ch.to_string())
            .fetch_one(&pool)
            .await
            .unwrap();
            n
        }
    };
    // 慢的那条还在发，快的渠道两条都发完了（以前要等同一批里最慢的那条发完才领下一批）。
    let started = std::time::Instant::now();
    while delivered(fast).await < 2 {
        assert!(
            started.elapsed() < Duration::from_millis(2500),
            "the fast channel waited for the slow one"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(delivered(slow).await, 0);
    // 停下来时把正在发的发完。
    stop.send(()).unwrap();
    running.await.unwrap();
    assert_eq!(delivered(slow).await, 1);
}
