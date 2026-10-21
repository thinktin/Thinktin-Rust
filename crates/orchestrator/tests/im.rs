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
use orchestrator::outbox::{Dispatcher, DispatcherConfig, IM, Notice, im_item, notify};
use proto::domain::{ImChannelId, ImEvent, ImVendor, Locale, UserId};
use serde_json::Value;
use store::NewImChannel;
use store::testing::TestDb;

type Sent = (ImVendor, String, Option<String>, ImMessage);

#[derive(Default)]
struct Recording {
    outcomes: Mutex<HashMap<String, PushOutcome>>,
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
    tx.create_im_channel(&NewImChannel {
        id,
        vendor,
        label: "家庭群".into(),
        sealed,
        hint: proto::im::hint(token),
        has_secret: !secret.is_empty(),
        events: events.to_vec(),
    })
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
async fn a_full_rate_window_defers_without_spending_attempts() {
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
    sqlx::query(
        "UPDATE im_channels SET rate_window_start = now(), rate_window_count = 18 WHERE id = $1",
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
    assert!((50.0..=61.0).contains(&wait), "{wait}");
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
