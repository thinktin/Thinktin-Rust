//! 设备中继（14.1）的集成测试：真实数据库、进程里的中继，用 tokio-tungstenite 扮演电脑，
//! 平台一侧用 `orchestrator::computer::DeviceCalls`。没有 DATABASE_URL 时跳过。

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::signed::{Signer25519, Verifier25519};
use futures_util::{SinkExt, StreamExt};
use orchestrator::computer::{CallError, DeviceCalls};
use proto::domain::{
    DeviceId, DeviceMessageKind, DevicePlatform, RunSource, RunState, SessionId, UserId, UserStatus,
};
use proto::relay::{ComputerFrame, RelayFrame};
use relay::{Relay, RelayConfig};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{NewInstance, NewRun, RunChange};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite;

const WAIT: Duration = Duration::from_secs(10);

struct Env {
    t: TestDb,
    relay: Arc<Relay>,
    addr: SocketAddr,
    issuer: AccessTokenIssuer,
    calls: DeviceCalls,
    stop: Option<oneshot::Sender<()>>,
    served: Option<tokio::task::JoinHandle<anyhow::Result<()>>>,
}

#[derive(Debug, Clone, Copy)]
struct Account {
    user: UserId,
    mac: DeviceId,
    mac_session: SessionId,
    phone: DeviceId,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

impl Env {
    async fn new(heartbeat: Duration) -> Option<Env> {
        let t = TestDb::new().await?;
        let signer = Signer25519::generate("a1").unwrap();
        let mut keys = Verifier25519::new();
        keys.add_key_b64("a1", &signer.verifying_key_b64()).unwrap();
        let relay = Relay::new(
            t.db.clone(),
            AccessTokenVerifier(keys),
            RelayConfig {
                node: "relay-test".into(),
                heartbeat,
                grace: Duration::from_secs(5),
                ..RelayConfig::default()
            },
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel::<()>();
        let served = tokio::spawn(relay.clone().serve(listener, async move {
            let _ = stopped.await;
        }));
        let calls = DeviceCalls::new(t.db.clone());
        let listening = calls.clone();
        tokio::spawn(async move { listening.listen(std::future::pending()).await });
        Some(Env {
            t,
            relay,
            addr,
            issuer: AccessTokenIssuer(signer),
            calls,
            stop: Some(stop),
            served: Some(served),
        })
    }

    /// 一个用户：一台电脑、一部手机，各自登录着。
    async fn account(&self, phone: &str) -> Account {
        let mut w = self.t.db.worker().await.unwrap();
        let (u, _) = w.upsert_user_by_phone(phone).await.unwrap();
        let mac = w
            .create_device(u.id, DevicePlatform::Macos, "MacBook", None)
            .await
            .unwrap();
        let mac_session = SessionId::new();
        w.create_session(
            mac_session,
            u.id,
            mac,
            mac_session.0.as_bytes(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
        let phone_device = w
            .create_device(u.id, DevicePlatform::Ios, "iPhone", None)
            .await
            .unwrap();
        w.commit().await.unwrap();
        Account {
            user: u.id,
            mac,
            mac_session,
            phone: phone_device,
        }
    }

    fn token(&self, user: UserId, device: DeviceId, session: SessionId) -> String {
        self.issuer
            .issue(
                &user.to_string(),
                &device.to_string(),
                &session.to_string(),
                now(),
            )
            .unwrap()
    }

    fn mac_token(&self, a: &Account) -> String {
        self.token(a.user, a.mac, a.mac_session)
    }

    async fn connect(&self, token: &str) -> Result<Mac, tungstenite::Error> {
        mac(self.addr, token).await
    }

    /// 连上并收到 welcome。
    async fn online(&self, a: &Account) -> Mac {
        let mut m = self.connect(&self.mac_token(a)).await.unwrap();
        match m.next().await {
            RelayFrame::Welcome { device, .. } => assert_eq!(device, a.mac),
            other => panic!("expected welcome, got {other:?}"),
        }
        m
    }

    /// 等到库里看得到电脑报上来的工具（hello 处理完了）。
    async fn wait_for_tools(&self, user: UserId, tools: &[&str]) {
        tokio::time::timeout(WAIT, async {
            loop {
                let mut w = self.t.db.worker().await.unwrap();
                let online = w.online_computer(user).await.unwrap();
                w.rollback().await.unwrap();
                if online
                    .is_some_and(|(_, t)| t.iter().map(String::as_str).eq(tools.iter().copied()))
                {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("the hello is stored");
    }

    async fn linked(&self, device: DeviceId) -> bool {
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM device_links WHERE device_id = $1")
            .bind(device.0)
            .fetch_one(self.t.db.pool())
            .await
            .unwrap();
        n == 1
    }

    async fn wait_unlinked(&self, device: DeviceId) {
        tokio::time::timeout(WAIT, async {
            while self.linked(device).await {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("the computer goes offline");
    }
}

/// 扮演电脑：后台一直读（tungstenite 读的时候自动回 pong），收到的帧放进队列。
struct Mac {
    frames: mpsc::UnboundedReceiver<RelayFrame>,
    out: mpsc::UnboundedSender<Out>,
    closed: Option<oneshot::Receiver<Option<u16>>>,
}

enum Out {
    Frame(ComputerFrame),
    Raw(String),
    Close,
}

async fn mac(addr: SocketAddr, token: &str) -> Result<Mac, tungstenite::Error> {
    use tungstenite::client::IntoClientRequest;
    let mut req = format!("ws://{addr}/v1/connect")
        .into_client_request()
        .unwrap();
    req.headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    let (mut ws, _) = tokio_tungstenite::connect_async(req).await?;
    let (frames_tx, frames) = mpsc::unbounded_channel();
    let (out, mut out_rx) = mpsc::unbounded_channel::<Out>();
    let (closed_tx, closed) = oneshot::channel();
    tokio::spawn(async move {
        let code = loop {
            tokio::select! {
                msg = ws.next() => match msg {
                    Some(Ok(tungstenite::Message::Text(t))) => {
                        let frame: RelayFrame = serde_json::from_str(&t).unwrap();
                        let _ = frames_tx.send(frame);
                    }
                    Some(Ok(tungstenite::Message::Close(frame))) => {
                        break frame.map(|f| u16::from(f.code));
                    }
                    Some(Ok(_)) => {}
                    Some(Err(_)) | None => break None,
                },
                o = out_rx.recv() => {
                    let text = match o {
                        Some(Out::Frame(f)) => serde_json::to_string(&f).unwrap(),
                        Some(Out::Raw(s)) => s,
                        Some(Out::Close) | None => {
                            let _ = ws.close(None).await;
                            break None;
                        }
                    };
                    if ws.send(tungstenite::Message::Text(text.into())).await.is_err() {
                        break None;
                    }
                }
            }
        };
        let _ = closed_tx.send(code);
    });
    Ok(Mac {
        frames,
        out,
        closed: Some(closed),
    })
}

impl Mac {
    async fn next(&mut self) -> RelayFrame {
        tokio::time::timeout(WAIT, self.frames.recv())
            .await
            .expect("a frame in time")
            .expect("the connection is open")
    }

    fn send(&self, frame: ComputerFrame) {
        let _ = self.out.send(Out::Frame(frame));
    }

    fn raw(&self, text: &str) {
        let _ = self.out.send(Out::Raw(text.to_owned()));
    }

    fn hang_up(&self) {
        let _ = self.out.send(Out::Close);
    }

    /// 等中继关掉连接，返回关闭码。
    async fn closed(&mut self) -> Option<u16> {
        tokio::time::timeout(WAIT, self.closed.take().unwrap())
            .await
            .expect("the connection closes in time")
            .unwrap_or(None)
    }

    /// 等一个调用转过来。
    async fn call(&mut self) -> (proto::domain::DeviceCallId, String, Value) {
        match self.next().await {
            RelayFrame::Call {
                id,
                tool,
                arguments,
                ..
            } => (id, tool, arguments),
            other => panic!("expected a call, got {other:?}"),
        }
    }
}

fn text(s: &str) -> Vec<Value> {
    vec![json!({ "type": "text", "text": s })]
}

fn refused_with(r: Result<Mac, tungstenite::Error>) -> u16 {
    match r {
        Err(tungstenite::Error::Http(resp)) => resp.status().as_u16(),
        Err(e) => panic!("unexpected error {e}"),
        Ok(_) => panic!("the relay accepted the connection"),
    }
}

/// 只有登录着的电脑能连；平台按会话绑定找到用户自己在线的电脑，调用转过去、结果拿回来；
/// 电脑上线时唤醒等电脑的运行；超时、断线、不支持的工具各有说法；停机时电脑被告知重连。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn computers_connect_and_answer_calls() {
    let Some(mut env) = Env::new(Duration::from_secs(5)).await else {
        return;
    };
    let alice = env.account("+8613700000001").await;
    let bob = env.account("+8613700000002").await;
    let phone_session = SessionId::new();
    let mut w = env.t.db.worker().await.unwrap();
    w.create_session(
        phone_session,
        alice.user,
        alice.phone,
        phone_session.0.as_bytes(),
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();

    // 手机、坏令牌、别人的会话配自己的设备都连不上。
    assert_eq!(
        refused_with(
            env.connect(&env.token(alice.user, alice.phone, phone_session))
                .await
        ),
        403
    );
    assert_eq!(refused_with(env.connect("tta1.a1.bogus").await), 401);
    assert_eq!(
        refused_with(
            env.connect(&env.token(alice.user, alice.mac, bob.mac_session))
                .await
        ),
        401
    );

    // 电脑还没连：平台知道它离线；bob 没登录电脑。
    assert!(matches!(
        env.calls
            .call(
                alice.user,
                None,
                "fs_read",
                json!({}),
                Duration::from_secs(1)
            )
            .await,
        Err(CallError::Offline)
    ));
    let mut w = env.t.db.worker().await.unwrap();
    w.revoke_user_sessions(bob.user, "test").await.unwrap();
    w.commit().await.unwrap();
    assert!(matches!(
        env.calls
            .call(bob.user, None, "fs_read", json!({}), Duration::from_secs(1))
            .await,
        Err(CallError::NoComputer)
    ));

    // 一个运行在等电脑上线（7.11）。
    let mut t = env.t.db.tenant(alice.user).await.unwrap();
    let inst = t
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "vol-1".into(),
            limits: Default::default(),
        })
        .await
        .unwrap();
    let run = t
        .create_run(&NewRun::new(inst.id, RunSource::User, "整理桌面", "1"))
        .await
        .unwrap();
    t.commit().await.unwrap();
    let mut w = env.t.db.worker().await.unwrap();
    let lease = Duration::from_secs(60);
    w.claim_next_run("x", lease).await.unwrap().unwrap();
    w.transition_run(run.id, "x", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    let later = chrono::Utc::now() + chrono::Duration::hours(1);
    w.transition_run(
        run.id,
        "x",
        RunState::WaitingDevice,
        &RunChange {
            not_before: Some(later),
            release_lease: true,
            wait_deadline: Some(later),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();

    // 电脑连上：在线，等它的运行马上能领起来。
    let mut m = env.online(&alice).await;
    assert!(env.linked(alice.mac).await);
    let mut w = env.t.db.worker().await.unwrap();
    assert_eq!(
        w.claim_next_run("y", lease)
            .await
            .unwrap()
            .map(|c| c.run.id),
        Some(run.id)
    );
    w.commit().await.unwrap();
    m.send(ComputerFrame::Hello {
        tools: vec!["fs_read".into(), "screenshot".into()],
        app_version: "1.0.0".into(),
    });
    env.wait_for_tools(alice.user, &["fs_read", "screenshot"])
        .await;

    // 调用转过去、结果拿回来。
    let calls = env.calls.clone();
    let user = alice.user;
    let waiting = tokio::spawn(async move {
        calls
            .call(
                user,
                Some(run.id),
                "fs_read",
                json!({ "path": "/Users/a/notes.md" }),
                Duration::from_secs(10),
            )
            .await
    });
    let (id, tool, args) = m.call().await;
    assert_eq!(
        (tool.as_str(), args),
        ("fs_read", json!({ "path": "/Users/a/notes.md" }))
    );
    m.send(ComputerFrame::CallResult {
        call: id,
        content: text("# notes"),
        is_error: false,
    });
    let out = waiting.await.unwrap().unwrap();
    assert_eq!(
        (out.device, out.content, out.is_error),
        (alice.mac, text("# notes"), false)
    );

    // 电脑没报的工具不转。
    assert!(matches!(
        env.calls
            .call(
                alice.user,
                None,
                "keyboard_type",
                json!({}),
                Duration::from_secs(1)
            )
            .await,
        Err(CallError::Unsupported(_))
    ));

    // 电脑没按时回：平台不等了，晚到的结果不收。
    let calls = env.calls.clone();
    let waiting = tokio::spawn(async move {
        calls
            .call(
                user,
                None,
                "screenshot",
                json!({}),
                Duration::from_millis(500),
            )
            .await
    });
    let (late, _, _) = m.call().await;
    assert!(matches!(waiting.await.unwrap(), Err(CallError::Timeout)));
    m.send(ComputerFrame::CallResult {
        call: late,
        content: text("too late"),
        is_error: false,
    });
    match m.next().await {
        RelayFrame::Error { code, .. } => assert_eq!(code, "not_found"),
        other => panic!("expected an error, got {other:?}"),
    }

    // 转过去以后电脑断线：马上判失败，不用等到超时。
    let calls = env.calls.clone();
    let waiting = tokio::spawn(async move {
        calls
            .call(user, None, "screenshot", json!({}), Duration::from_secs(30))
            .await
    });
    m.call().await;
    m.hang_up();
    let started = std::time::Instant::now();
    assert!(matches!(
        tokio::time::timeout(WAIT, waiting).await.unwrap().unwrap(),
        Err(CallError::Failed(_))
    ));
    assert!(started.elapsed() < Duration::from_secs(10));
    env.wait_unlinked(alice.mac).await;
    assert!(matches!(
        env.calls
            .call(
                alice.user,
                None,
                "fs_read",
                json!({}),
                Duration::from_secs(1)
            )
            .await,
        Err(CallError::Offline)
    ));

    // 停机：电脑收到 1012（马上重连到别的副本），在线状态去掉。
    let mut m = env.online(&alice).await;
    assert!(env.linked(alice.mac).await);
    env.stop.take().unwrap().send(()).unwrap();
    assert_eq!(m.closed().await, Some(1012));
    env.served.take().unwrap().await.unwrap().unwrap();
    assert!(!env.linked(alice.mac).await);
    assert_eq!(env.relay.connections(), 0);
}

/// 同一台电脑又连了一次：旧连接以 4009 关闭，调用转给新连接。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_connection_replaces_the_old_one() {
    let Some(env) = Env::new(Duration::from_secs(5)).await else {
        return;
    };
    let alice = env.account("+8613700000011").await;
    let mut old = env.online(&alice).await;
    let mut new = env.online(&alice).await;
    assert_eq!(old.closed().await, Some(4009));
    let calls = env.calls.clone();
    let user = alice.user;
    let waiting = tokio::spawn(async move {
        calls
            .call(user, None, "fs_list", json!({}), Duration::from_secs(10))
            .await
    });
    let (id, _, _) = new.call().await;
    new.send(ComputerFrame::CallResult {
        call: id,
        content: text("a.txt"),
        is_error: true,
    });
    let out = waiting.await.unwrap().unwrap();
    assert!(out.is_error);
    assert!(env.linked(alice.mac).await);
}

/// 心跳时核对会话：电脑被远程下线以 4001 关闭，账号被冻结以 4003 关闭；
/// 不说话的电脑三个心跳周期后断开、标记离线。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn heartbeats_drop_revoked_frozen_and_silent_computers() {
    let Some(env) = Env::new(Duration::from_millis(200)).await else {
        return;
    };
    let alice = env.account("+8613700000021").await;
    let mut m = env.online(&alice).await;
    let mut t = env.t.db.tenant(alice.user).await.unwrap();
    t.revoke_device(alice.mac, "signed out from the phone")
        .await
        .unwrap();
    t.commit().await.unwrap();
    assert_eq!(m.closed().await, Some(4001));
    env.wait_unlinked(alice.mac).await;
    // 下线的电脑再也连不上。
    assert_eq!(refused_with(env.connect(&env.mac_token(&alice)).await), 401);

    let bob = env.account("+8613700000022").await;
    let mut m = env.online(&bob).await;
    let mut w = env.t.db.worker().await.unwrap();
    w.set_user_status(bob.user, UserStatus::Frozen)
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(m.closed().await, Some(4003));
    assert_eq!(refused_with(env.connect(&env.mac_token(&bob)).await), 403);

    // 连上以后一直不读（不回 pong）：中继断开、去掉在线状态。
    let carol = env.account("+8613700000023").await;
    use tungstenite::client::IntoClientRequest;
    let mut req = format!("ws://{}/v1/connect", env.addr)
        .into_client_request()
        .unwrap();
    req.headers_mut().insert(
        "authorization",
        format!("Bearer {}", env.mac_token(&carol)).parse().unwrap(),
    );
    let (silent, _) = tokio_tungstenite::connect_async(req).await.unwrap();
    tokio::time::timeout(WAIT, async {
        while !env.linked(carol.mac).await {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    env.wait_unlinked(carol.mac).await;
    drop(silent);
}

/// 手机和电脑之间的消息：电脑不在线时排队，连上后投递；电脑确认后不再投，没确认的下次连上再投；
/// 电脑发给手机的审批请求存进手机的收件队列；方向不对、发给别人的设备都被拒绝。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn messages_queue_until_the_other_side_is_online() {
    let Some(env) = Env::new(Duration::from_secs(5)).await else {
        return;
    };
    let alice = env.account("+8613700000031").await;
    let bob = env.account("+8613700000032").await;
    let send_from_phone = |body: Value| {
        let db = env.t.db.clone();
        async move {
            let mut t = db.tenant(alice.user).await.unwrap();
            let m = t
                .send_device_message(alice.phone, alice.mac, DeviceMessageKind::Capability, &body)
                .await
                .unwrap();
            t.commit().await.unwrap();
            m
        }
    };
    let first = send_from_phone(json!({ "grant": 1 })).await;

    // 电脑连上：排着的消息投过来，确认后不再投。
    let mut m = env.online(&alice).await;
    match m.next().await {
        RelayFrame::Message { message } => assert_eq!(message, first),
        other => panic!("expected a message, got {other:?}"),
    }
    m.send(ComputerFrame::Ack { message: first.id });
    // 在线时发来的直接投递；这条不确认。
    let second = send_from_phone(json!({ "grant": 2 })).await;
    match m.next().await {
        RelayFrame::Message { message } => assert_eq!(message, second),
        other => panic!("expected a message, got {other:?}"),
    }

    // 电脑发给手机：审批请求存下、回 sent；方向不对、发给别人都报错，连接不断。
    m.send(ComputerFrame::Send {
        to: alice.phone,
        kind: DeviceMessageKind::ApprovalRequest,
        body: json!({ "tool": "rm", "args": "~/Downloads/a.zip" }),
        reference: Some("r1".into()),
    });
    let sent = match m.next().await {
        RelayFrame::Sent { id, reference } => {
            assert_eq!(reference.as_deref(), Some("r1"));
            id
        }
        other => panic!("expected sent, got {other:?}"),
    };
    m.send(ComputerFrame::Send {
        to: alice.phone,
        kind: DeviceMessageKind::Capability,
        body: json!({}),
        reference: Some("r2".into()),
    });
    match m.next().await {
        RelayFrame::Error {
            code, reference, ..
        } => {
            assert_eq!(
                (code.as_str(), reference.as_deref()),
                ("invalid", Some("r2"))
            );
        }
        other => panic!("expected an error, got {other:?}"),
    }
    m.send(ComputerFrame::Send {
        to: bob.phone,
        kind: DeviceMessageKind::ApprovalRequest,
        body: json!({}),
        reference: Some("r3".into()),
    });
    match m.next().await {
        RelayFrame::Error { code, .. } => assert_eq!(code, "not_found"),
        other => panic!("expected an error, got {other:?}"),
    }
    m.send(ComputerFrame::Send {
        to: alice.phone,
        kind: DeviceMessageKind::ApprovalRequest,
        body: json!({ "pad": "x".repeat(70_000) }),
        reference: None,
    });
    match m.next().await {
        RelayFrame::Error { code, .. } => assert_eq!(code, "too_large"),
        other => panic!("expected an error, got {other:?}"),
    }
    let mut t = env.t.db.tenant(alice.user).await.unwrap();
    let inbox = t.pending_device_messages(alice.phone, 10).await.unwrap();
    t.rollback().await.unwrap();
    assert_eq!(inbox.iter().map(|m| m.id).collect::<Vec<_>>(), [sent]);
    assert_eq!(inbox[0].kind, DeviceMessageKind::ApprovalRequest);

    // 坏帧回错误、连接不断。
    m.raw(r#"{"type":"bogus"}"#);
    match m.next().await {
        RelayFrame::Error { code, .. } => assert_eq!(code, "invalid"),
        other => panic!("expected an error, got {other:?}"),
    }
    m.raw("not json");
    match m.next().await {
        RelayFrame::Error { code, .. } => assert_eq!(code, "invalid"),
        other => panic!("expected an error, got {other:?}"),
    }
    m.hang_up();
    assert_eq!(m.closed().await, None);
    env.wait_unlinked(alice.mac).await;

    // 没确认的那条，下次连上再投一次。
    let mut m = env.online(&alice).await;
    match m.next().await {
        RelayFrame::Message { message } => assert_eq!(message.id, second.id),
        other => panic!("expected the unacknowledged message again, got {other:?}"),
    }
}
