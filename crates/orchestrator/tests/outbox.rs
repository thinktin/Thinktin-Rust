//! 出箱投递：按设备通道发送、失效令牌清理、重试与放弃、过期。需要 DATABASE_URL（没有时跳过）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use notify::{PushChannel, PushKind, PushMessage, PushOutcome, PushTarget};
use orchestrator::computer::notify_approval_requests;
use orchestrator::outbox::{Dispatcher, DispatcherConfig, push_item};
use proto::domain::{DeviceMessageKind, DevicePlatform, PushChannelKind, UserId};
use store::testing::TestDb;

#[derive(Default)]
struct Scripted {
    outcomes: Mutex<HashMap<String, PushOutcome>>,
    sent: Mutex<Vec<String>>,
}

impl Scripted {
    fn set(&self, token: &str, outcome: PushOutcome) {
        self.outcomes.lock().unwrap().insert(token.into(), outcome);
    }
    fn sent(&self) -> Vec<String> {
        std::mem::take(&mut self.sent.lock().unwrap())
    }
}

#[async_trait]
impl PushChannel for Scripted {
    fn name(&self) -> &'static str {
        "scripted"
    }
    async fn send(&self, token: &str, _message: &PushMessage) -> PushOutcome {
        self.sent.lock().unwrap().push(token.into());
        self.outcomes
            .lock()
            .unwrap()
            .get(token)
            .cloned()
            .unwrap_or(PushOutcome::Delivered { id: None })
    }
}

fn message(ttl: Option<Duration>) -> PushMessage {
    PushMessage {
        kind: PushKind::RunFinished,
        title: "Claude".into(),
        body: "Daily news is ready".into(),
        thread_id: Some("run-1".into()),
        collapse_id: None,
        target: PushTarget::default(),
        ttl,
        ai_generated: false,
        locale: Default::default(),
        subtype: None,
        badge: None,
    }
}

async fn user_with_devices(t: &TestDb, devices: &[(PushChannelKind, &str)]) -> UserId {
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    for (kind, token) in devices {
        let device = w
            .create_device(user.id, DevicePlatform::Ios, "d", Some((*kind, token)))
            .await
            .unwrap();
        w.create_session(
            proto::domain::SessionId::new(),
            user.id,
            device,
            b"refresh",
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    }
    w.commit().await.unwrap();
    user.id
}

async fn enqueue(t: &TestDb, user: UserId, msg: &PushMessage, key: &str) {
    let mut tx = t.db.tenant(user).await.unwrap();
    assert!(
        tx.enqueue_outbox(&push_item(msg, Some(key.into())))
            .await
            .unwrap()
    );
    tx.commit().await.unwrap();
}

fn dispatcher(t: &TestDb, apns: Arc<Scripted>, cfg: DispatcherConfig) -> Dispatcher {
    Dispatcher::new(t.db.clone(), "node-a", cfg).with_channel(PushChannelKind::Apns, apns)
}

#[tokio::test]
async fn delivers_to_devices_and_clears_dead_tokens() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(
        &t,
        &[
            (PushChannelKind::Apns, "tok-live"),
            (PushChannelKind::Apns, "tok-dead"),
            (PushChannelKind::Hms, "tok-huawei"),
        ],
    )
    .await;
    let apns = Arc::new(Scripted::default());
    apns.set(
        "tok-dead",
        PushOutcome::InvalidToken {
            reason: "Unregistered".into(),
        },
    );
    let d = dispatcher(&t, apns.clone(), DispatcherConfig::default());
    enqueue(&t, user, &message(None), "run_finished:1").await;

    let report = d.tick().await.unwrap();
    assert_eq!(
        (report.delivered, report.retried, report.dropped),
        (1, 0, 0)
    );
    let mut sent = apns.sent();
    sent.sort();
    assert_eq!(sent, ["tok-dead", "tok-live"], "no HMS channel configured");
    let mut w = t.db.worker().await.unwrap();
    let targets: Vec<String> = w
        .push_targets(user)
        .await
        .unwrap()
        .into_iter()
        .map(|(_, _, tok)| tok)
        .collect();
    assert!(!targets.contains(&"tok-dead".to_string()));
    w.rollback().await.unwrap();
    assert_eq!(d.tick().await.unwrap(), Default::default(), "sent once");
}

/// 开发包的令牌（APNs 沙盒环境，10.7）发到沙盒环境，正式包的发到生产环境。
#[tokio::test]
async fn sandbox_tokens_go_to_the_sandbox() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(
        &t,
        &[
            (PushChannelKind::Apns, "tok-store"),
            (PushChannelKind::ApnsSandbox, "tok-xcode"),
        ],
    )
    .await;
    let (production, sandbox) = (Arc::new(Scripted::default()), Arc::new(Scripted::default()));
    let d = dispatcher(&t, production.clone(), DispatcherConfig::default())
        .with_channel(PushChannelKind::ApnsSandbox, sandbox.clone());
    enqueue(&t, user, &message(None), "run_finished:1").await;
    d.tick().await.unwrap();
    assert_eq!(
        (production.sent(), sandbox.sent()),
        (vec!["tok-store".to_owned()], vec!["tok-xcode".to_owned()])
    );
}

#[tokio::test]
async fn retries_then_gives_up_and_drops_expired() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(&t, &[(PushChannelKind::Apns, "tok")]).await;
    let apns = Arc::new(Scripted::default());
    apns.set(
        "tok",
        PushOutcome::Retry {
            after: None,
            reason: "503".into(),
        },
    );
    let d = dispatcher(
        &t,
        apns.clone(),
        DispatcherConfig {
            max_attempts: 2,
            backoff_base: Duration::ZERO,
            ..DispatcherConfig::default()
        },
    );
    enqueue(&t, user, &message(None), "k1").await;
    assert_eq!(d.tick().await.unwrap().retried, 1);
    assert_eq!(
        d.tick().await.unwrap().dropped,
        1,
        "gave up after 2 attempts"
    );
    assert_eq!(apns.sent().len(), 2);

    // 退避期内不再领取。
    let slow = dispatcher(&t, apns.clone(), DispatcherConfig::default());
    enqueue(&t, user, &message(None), "k2").await;
    assert_eq!(slow.tick().await.unwrap().retried, 1);
    assert_eq!(slow.tick().await.unwrap(), Default::default());

    // 过了有效期的通知直接丢弃（比如审批已经超时）。
    enqueue(&t, user, &message(Some(Duration::ZERO)), "k3").await;
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert_eq!(slow.tick().await.unwrap().dropped, 1);
    assert!(apns.sent().len() == 1, "only the k2 attempt was sent");
}

#[tokio::test]
async fn filtered_push_text_is_replaced_not_dropped() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(&t, &[(PushChannelKind::Apns, "tok")]).await;
    let rec = Arc::new(notify::RecordingChannel::default());
    let d = Dispatcher::new(t.db.clone(), "node-a", DispatcherConfig::default())
        .with_channel(PushChannelKind::Apns, rec.clone())
        .with_filter(Arc::new(notify::filter::KeywordFilter::new(["坏词"])));
    let mut bad = message(None);
    bad.body = "这里有坏词".into();
    bad.ai_generated = true;
    enqueue(&t, user, &bad, "a").await;
    let mut good = message(None);
    good.ai_generated = true;
    enqueue(&t, user, &good, "b").await;
    assert_eq!(d.tick().await.unwrap().delivered, 2);
    let sent: Vec<PushMessage> = rec
        .sent
        .lock()
        .unwrap()
        .iter()
        .map(|(_, m)| m.clone())
        .collect();
    let bodies: Vec<String> = sent.iter().map(PushMessage::display_body).collect();
    assert!(
        bodies.contains(&notify::filter::BLOCKED_BODY.to_string()),
        "{bodies:?}"
    );
    assert!(
        bodies.contains(&"【AI 生成】Daily news is ready".to_string()),
        "{bodies:?}"
    );
}

/// 角标（10.7）：发的时候收件箱里还有几条没读。
#[tokio::test]
async fn pushes_carry_the_unread_count() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(&t, &[(PushChannelKind::Apns, "tok")]).await;
    let rec = Arc::new(notify::RecordingChannel::default());
    let d = Dispatcher::new(t.db.clone(), "node-a", DispatcherConfig::default())
        .with_channel(PushChannelKind::Apns, rec.clone());
    let mut w = t.db.worker().await.unwrap();
    for n in 0..2 {
        let notice = orchestrator::outbox::Notice {
            dedupe_key: Some(format!("n{n}")),
            ..orchestrator::outbox::Notice::new(PushKind::RunFinished, "Claude", "done")
        };
        orchestrator::outbox::notify(&mut w, user, &notice)
            .await
            .unwrap();
    }
    w.commit().await.unwrap();
    // 读了一条以后才发出去：角标是 1，不是写进出箱时的 2。
    let mut tx = t.db.tenant(user).await.unwrap();
    let first = tx.inbox(None, 10, false).await.unwrap()[1].id;
    tx.mark_inbox_read(Some(&[first]), None).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(d.tick().await.unwrap().delivered, 2);
    let badges: Vec<Option<u32>> = rec
        .sent
        .lock()
        .unwrap()
        .iter()
        .map(|(_, m)| m.badge)
        .collect();
    assert_eq!(badges, [Some(1), Some(1)]);
}

/// 推送服务给一个离谱的 Retry-After：截到退避上限，投递器不能因为时间溢出崩掉。
#[tokio::test]
async fn absurd_retry_after_is_clamped() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(&t, &[(PushChannelKind::Apns, "tok")]).await;
    let apns = Arc::new(Scripted::default());
    apns.set(
        "tok",
        PushOutcome::Retry {
            after: Some(Duration::from_secs(10_000_000_000_000)),
            reason: "429".into(),
        },
    );
    // 退避上限设成 0：截断生效的话，下一轮马上又能领到。
    let d = dispatcher(
        &t,
        apns,
        DispatcherConfig {
            backoff_base: Duration::ZERO,
            backoff_max: Duration::ZERO,
            ..DispatcherConfig::default()
        },
    );
    enqueue(&t, user, &message(None), "k").await;
    assert_eq!(d.tick().await.unwrap().retried, 1);
    assert_eq!(d.tick().await.unwrap().retried, 1);
}

/// 审批提醒发出前再看一眼：用户已经在别的设备上处理了（或者运行结束了），就不推了。
#[tokio::test]
async fn settled_approvals_are_not_pushed() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(&t, &[(PushChannelKind::Apns, "tok")]).await;
    let mut tx = t.db.tenant(user).await.unwrap();
    let inst = tx
        .create_instance(&store::NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "ws".into(),
            limits: Default::default(),
        })
        .await
        .unwrap();
    let run = tx
        .create_run(&store::NewRun::new(
            inst.id,
            proto::domain::RunSource::User,
            "hi",
            "1",
        ))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut approvals = Vec::new();
    let mut w = t.db.worker().await.unwrap();
    for request in ["1:p1", "1:p2"] {
        let a = w
            .create_approval(&store::NewApproval {
                user,
                instance: inst.id,
                run: run.id,
                request_id: request,
                title: Some("Delete old reports"),
                options: &serde_json::json!([]),
                tool_call: &serde_json::json!({}),
                expires_in: Duration::from_secs(600),
            })
            .await
            .unwrap();
        approvals.push(a.approval.id);
    }
    // 第一个已经由预授权策略了结。
    w.settle_approval(
        run.id,
        "1:p1",
        proto::domain::ApprovalState::Cancelled,
        Some("allow"),
        "policy",
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    for (i, id) in approvals.iter().enumerate() {
        let mut msg = message(None);
        msg.kind = PushKind::Approval;
        msg.target.approval_id = Some(id.to_string());
        enqueue(&t, user, &msg, &format!("approval:{i}")).await;
    }
    let apns = Arc::new(Scripted::default());
    let d = dispatcher(&t, apns.clone(), DispatcherConfig::default());
    let report = d.tick().await.unwrap();
    assert_eq!((report.delivered, report.dropped), (1, 1));
    assert_eq!(apns.sent(), ["tok"]);
}

/// 电脑发给手机的审批请求（14.2）：记进收件箱、推送到手机，只提醒一次。
/// 手机已经取走的、请求已经过期的不提醒；别的消息（比如配对确认）不提醒。
#[tokio::test]
async fn computer_approval_requests_are_pushed_once() {
    let Some(t) = TestDb::new().await else { return };
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000002").await.unwrap();
    let user = user.id;
    let phone = w
        .create_device(
            user,
            DevicePlatform::Ios,
            "iPhone",
            Some((PushChannelKind::Apns, "tok")),
        )
        .await
        .unwrap();
    let mac = w
        .create_device(user, DevicePlatform::Macos, "MacBook", None)
        .await
        .unwrap();
    // 推送只发给登录着的设备。
    w.create_session(
        proto::domain::SessionId::new(),
        user,
        phone,
        b"refresh",
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();

    let now = chrono::Utc::now().timestamp();
    let request = |id: &str, summary: &str, expires_at: i64| {
        serde_json::json!({ "request": {
            "desktop_id": mac.to_string(),
            "request_id": id,
            "tool": "computer_run",
            "arguments_json": "{}",
            "summary": summary,
            "issued_at": now,
            "expires_at": expires_at,
        } })
    };
    let mut r = t.db.relay().await.unwrap();
    let send = [
        (
            DeviceMessageKind::ApprovalRequest,
            request(
                "r1",
                "运行 rm -rf ~/Downloads/old\n理由：清理旧文件",
                now + 900,
            ),
        ),
        (
            DeviceMessageKind::ApprovalRequest,
            request("r2", "已经过期", now - 1),
        ),
        (
            DeviceMessageKind::ApprovalRequest,
            request("r3", "手机已经取走", now + 900),
        ),
        (
            DeviceMessageKind::PairConfirm,
            serde_json::json!({ "confirm": "x" }),
        ),
    ];
    let mut sent = Vec::new();
    for (kind, body) in &send {
        sent.push(
            r.send_device_message(user, mac, phone, *kind, body)
                .await
                .unwrap(),
        );
    }
    r.commit().await.unwrap();
    // 手机开着 App，已经取走了 r3。
    let mut tx = t.db.tenant(user).await.unwrap();
    tx.ack_device_messages(phone, &[sent[2].id]).await.unwrap();
    tx.commit().await.unwrap();

    // r1 提醒；r2 过期了，领走但不提醒。
    assert_eq!(notify_approval_requests(&t.db, 10).await.unwrap(), 2);
    assert_eq!(notify_approval_requests(&t.db, 10).await.unwrap(), 0);

    let mut tx = t.db.tenant(user).await.unwrap();
    let inbox = tx.inbox(None, 100, false).await.unwrap();
    tx.rollback().await.unwrap();
    assert_eq!(inbox.len(), 1, "{inbox:?}");
    assert_eq!(
        (
            inbox[0].kind.as_str(),
            inbox[0].title.as_str(),
            inbox[0].body.as_str(),
            inbox[0].ai_generated
        ),
        (
            "computer_approval",
            "电脑上的操作需要你批准",
            "运行 rm -rf ~/Downloads/old",
            true
        )
    );

    let rec = Arc::new(notify::RecordingChannel::default());
    let d = Dispatcher::new(t.db.clone(), "node-a", DispatcherConfig::default())
        .with_channel(PushChannelKind::Apns, rec.clone());
    assert_eq!(d.tick().await.unwrap().delivered, 1);
    let pushed = rec.sent.lock().unwrap().clone();
    assert_eq!(pushed.len(), 1);
    let (token, m) = &pushed[0];
    assert_eq!(token, "tok");
    assert_eq!(m.kind, PushKind::ComputerApproval);
    assert_eq!(
        m.collapse_id.as_deref(),
        Some(format!("device_message:{}", sent[0].id).as_str())
    );
    let ttl = m.ttl.expect("the push expires with the request");
    assert!(
        ttl > Duration::from_secs(800) && ttl <= Duration::from_secs(900),
        "{ttl:?}"
    );
    assert_eq!(m.target.inbox_id, Some(inbox[0].id.to_string()));
}

/// 一批按顺序发，前面慢了，后面的锁过期被别的投递器领走：不再发一遍。
#[tokio::test]
async fn items_whose_lock_expired_are_not_sent_twice() {
    let Some(t) = TestDb::new().await else { return };
    let user = user_with_devices(&t, &[(PushChannelKind::Apns, "tok")]).await;
    enqueue(&t, user, &message(None), "k1").await;
    // 另一个投递器领了（锁立即过期），再被第三个投递器接手。
    let mut w = t.db.worker().await.unwrap();
    assert_eq!(
        w.claim_outbox("node-b", Duration::ZERO, 10)
            .await
            .unwrap()
            .len(),
        1
    );
    w.commit().await.unwrap();
    let mut w = t.db.worker().await.unwrap();
    let mut w2 = t.db.worker().await.unwrap();
    let item = w2
        .claim_outbox("node-c", Duration::from_secs(60), 10)
        .await
        .unwrap();
    w2.commit().await.unwrap();
    assert_eq!(item.len(), 1);
    // node-b 的锁已经不在了。
    assert!(
        !w.extend_outbox_lock(item[0].id, "node-b", Duration::from_secs(60))
            .await
            .unwrap()
    );
    assert!(
        w.extend_outbox_lock(item[0].id, "node-c", Duration::from_secs(60))
            .await
            .unwrap()
    );
    w.rollback().await.unwrap();
}
