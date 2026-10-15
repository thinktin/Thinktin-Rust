//! client-core 对着真实的接入网关跑：登录、令牌刷新、会话失效、事件流续传和去重、离线收件箱、
//! 给原生端的 FFI 对象。需要 DATABASE_URL（没有时跳过）。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::service::{AuthConfig, AuthService};
use auth::signed::{Signer25519, Verifier25519};
use auth::sms::RecordingSms;
use client_core::ClientError;
use client_core::api::{Api, ApiConfig, MemorySessionStore, Session, SessionStore};
use client_core::cache::Cache;
use client_core::client::Client;
use client_core::events::{EventSink, StreamConfig, StreamStatus};
use client_core::ffi;
use control::BuiltinTemplates;
use gateway::{AppState, EventHub, GatewayConfig, Inner};
use keyvault::LocalKms;
use proto::domain::{DevicePlatform, InboxItemId, InstanceEvent, InstanceId, UserId, UserStatus};
use serde_json::json;
use store::NewInboxItem;
use store::testing::TestDb;
use zeroize::Zeroizing;

struct Env {
    t: TestDb,
    base: String,
    sms: Arc<RecordingSms>,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let signer = Signer25519::generate("a1").unwrap();
    let mut verifier = Verifier25519::new();
    verifier
        .add_key_b64("a1", &signer.verifying_key_b64())
        .unwrap();
    let sms = Arc::new(RecordingSms::default());
    let auth = AuthService::new(
        t.db.clone(),
        AuthConfig {
            code_resend_interval: Duration::ZERO,
            ..AuthConfig::default()
        },
        Zeroizing::new(vec![3u8; 32]),
        AccessTokenIssuer(signer),
        AccessTokenVerifier(verifier),
        sms.clone(),
    )
    .unwrap();
    let hub = EventHub::new();
    let state = AppState::new(Inner {
        db: t.db.clone(),
        auth: Arc::new(auth),
        templates: Arc::new(BuiltinTemplates),
        kms: Arc::new(LocalKms::new("kms1", &[9; 32])),
        hub: hub.clone(),
        artifacts: None,
        cfg: GatewayConfig {
            ws_heartbeat: Duration::from_millis(300),
            ..GatewayConfig::default()
        },
    });
    tokio::spawn(hub.listen(t.db.pool().clone(), std::future::pending()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        axum::serve(listener, gateway::router(state)).await.unwrap();
    });
    Some(Env { t, base, sms })
}

impl Env {
    fn api(&self, store: Arc<dyn SessionStore>) -> Api {
        self.api_at(&self.base, store)
    }

    fn api_at(&self, base: &str, store: Arc<dyn SessionStore>) -> Api {
        Api::new(
            ApiConfig {
                base_url: base.into(),
                platform: DevicePlatform::Ios,
                device_name: "iPhone".into(),
                timeout: Duration::from_secs(10),
            },
            store,
        )
        .unwrap()
    }

    async fn login(&self, api: &Api, phone: &str) {
        api.send_code(phone).await.unwrap();
        let code = self.sms.last_code(&format!("+86{phone}")).unwrap();
        api.login(phone, &code, None).await.unwrap();
    }

    async fn append(&self, user: UserId, instance: InstanceId, n: u32) {
        let mut t = self.t.db.tenant(user).await.unwrap();
        t.append_event(instance, None, "agent.message", &json!({ "text": n }))
            .await
            .unwrap();
        t.commit().await.unwrap();
    }
}

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<InstanceEvent>>,
    statuses: Mutex<Vec<StreamStatus>>,
    resets: Mutex<Vec<u64>>,
}

impl EventSink for Sink {
    fn on_event(&self, event: &InstanceEvent) {
        self.events.lock().unwrap().push(event.clone());
    }
    fn on_reset(&self, oldest_seq: u64, _latest: Option<u64>) {
        self.resets.lock().unwrap().push(oldest_seq);
    }
    fn on_status(&self, status: StreamStatus) {
        self.statuses.lock().unwrap().push(status);
    }
}

impl Sink {
    fn seqs(&self) -> Vec<u64> {
        self.events.lock().unwrap().iter().map(|e| e.seq).collect()
    }

    /// 测试追加的消息（payload 里的 text），忽略领养等其他事件。
    fn texts(&self) -> Vec<u64> {
        texts(&self.events.lock().unwrap())
    }

    async fn wait_for(&self, what: &str, f: impl Fn(&Self) -> bool) {
        for _ in 0..100 {
            if f(self) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!(
            "timed out waiting for {what}: events {:?}, statuses {:?}",
            self.seqs(),
            self.statuses.lock().unwrap()
        );
    }
}

fn texts(events: &[InstanceEvent]) -> Vec<u64> {
    events
        .iter()
        .filter(|e| e.kind == "agent.message")
        .filter_map(|e| e.payload["text"].as_u64())
        .collect()
}

fn fast() -> StreamConfig {
    StreamConfig {
        min_backoff: Duration::from_millis(50),
        max_backoff: Duration::from_millis(200),
        idle_timeout: Duration::from_secs(5),
        connect_timeout: Duration::from_secs(5),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn login_refresh_and_signed_out() {
    let Some(e) = env().await else { return };
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    assert!(matches!(api.me().await, Err(ClientError::SignedOut)));
    e.login(&api, "13800138500").await;
    let me = api.me().await.unwrap();
    assert_eq!(me.phone, "+8613800138500");
    let session = store.load().unwrap();
    assert_eq!(session.user_id, me.id.to_string());

    // 访问令牌失效（过期）：并发的几个请求只刷新一次，都成功；新令牌存回去。
    let stale = Session {
        access_token: "tta1.expired".into(),
        ..session.clone()
    };
    let store2 = Arc::new(MemorySessionStore::default());
    store2.save(Some(stale));
    let api2 = Arc::new(e.api(store2.clone()));
    let calls: Vec<_> = (0..5)
        .map(|_| {
            let a = api2.clone();
            tokio::spawn(async move { a.me().await })
        })
        .collect();
    for c in calls {
        assert_eq!(c.await.unwrap().unwrap().id, me.id);
    }
    let renewed = store2.load().unwrap();
    assert_ne!(renewed.access_token, "tta1.expired");
    assert_ne!(renewed.refresh_token, session.refresh_token, "rotated");

    // 业务错误原样带回错误码。
    let err = api2.instance(InstanceId::new()).await.unwrap_err();
    assert!(err.is_not_found(), "{err:?}");

    // 设备被远程下线：刷新失败，会话清掉，之后都是 SignedOut。
    let other = e.api(Arc::new(MemorySessionStore::default()));
    e.login(&other, "13800138500").await;
    let devices: serde_json::Value = reqwest::Client::new()
        .get(format!("{}/v1/devices", e.base))
        .bearer_auth(other.bearer().unwrap())
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let mine = &renewed.device_id;
    let r = reqwest::Client::new()
        .delete(format!("{}/v1/devices/{mine}", e.base))
        .bearer_auth(other.bearer().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 204, "{devices}");
    let err = api2.me().await.unwrap_err();
    assert_eq!(err, ClientError::SignedOut);
    assert!(
        store2.load().is_none(),
        "session removed from secure storage"
    );
    assert!(matches!(api2.me().await, Err(ClientError::SignedOut)));

    // 退出登录只影响本设备。
    api.logout().await.unwrap();
    assert!(store.load().is_none());
    assert!(other.me().await.is_ok());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn event_stream_resumes_dedupes_and_refreshes() {
    let Some(e) = env().await else { return };
    let dir = tempfile::tempdir().unwrap();
    let cache_path = dir.path().join("cache.db");
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    e.login(&api, "13800138501").await;
    let client = Client::new(api, Some(Cache::open(&cache_path).unwrap())).unwrap();
    let user: UserId = store.load().unwrap().user_id.parse().unwrap();
    let inst = client.api.adopt("claude", "助手", None).await.unwrap().id;
    let rt = tokio::runtime::Handle::current();

    e.append(user, inst, 1).await;
    e.append(user, inst, 2).await;
    let sink = Arc::new(Sink::default());
    let h = client.subscribe(&rt, inst, sink.clone(), fast());
    sink.wait_for("backlog", |s| s.texts() == [1, 2]).await;
    e.append(user, inst, 3).await;
    sink.wait_for("live event", |s| s.texts() == [1, 2, 3])
        .await;
    let last = *sink.seqs().last().unwrap();
    let mut sorted = sink.seqs();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(sorted, sink.seqs(), "in order, no duplicates");
    assert!(sink.statuses.lock().unwrap().contains(&StreamStatus::Live));
    h.stop();
    sink.wait_for("stop", |s| {
        s.statuses.lock().unwrap().last() == Some(&StreamStatus::Stopped)
    })
    .await;
    assert_eq!(client.cache().unwrap().cursor(inst).unwrap(), Some(last));

    // 断开期间来的事件，重连后从缓存的续传位置补上，不重复。
    e.append(user, inst, 4).await;
    let sink2 = Arc::new(Sink::default());
    let _h2 = client.subscribe(&rt, inst, sink2.clone(), fast());
    sink2.wait_for("resume", |s| s.seqs() == [last + 1]).await;
    assert_eq!(sink2.texts(), [4]);
    let cached = client.cached_events(inst, 0, 100).unwrap();
    assert_eq!(texts(&cached), [1, 2, 3, 4]);

    // 访问令牌过期：握手被拒（401），刷新后连上。
    let s = store.load().unwrap();
    let stale_store = Arc::new(MemorySessionStore::default());
    stale_store.save(Some(Session {
        access_token: "tta1.expired".into(),
        ..s
    }));
    let stale = Client::new(e.api(stale_store.clone()), None).unwrap();
    let sink3 = Arc::new(Sink::default());
    let _h3 = stale.subscribe(&rt, inst, sink3.clone(), fast());
    sink3
        .wait_for("refresh and replay", |s| s.texts() == [1, 2, 3, 4])
        .await;
    assert_ne!(stale_store.load().unwrap().access_token, "tta1.expired");

    // 实例不属于自己：停止，不重试。
    let sink4 = Arc::new(Sink::default());
    let _h4 = client.subscribe(&rt, InstanceId::new(), sink4.clone(), fast());
    sink4
        .wait_for("not found", |s| {
            s.statuses.lock().unwrap().last() == Some(&StreamStatus::NotFound)
        })
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stream_stops_when_the_session_is_revoked() {
    let Some(e) = env().await else { return };
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    e.login(&api, "13800138502").await;
    let client = Client::new(api, Some(Cache::in_memory().unwrap())).unwrap();
    let inst = client.api.adopt("claude", "助手", None).await.unwrap().id;
    client.instances().await.unwrap();
    assert_eq!(client.cached_instances().unwrap().len(), 1);
    let sink = Arc::new(Sink::default());
    let _h = client.subscribe(
        &tokio::runtime::Handle::current(),
        inst,
        sink.clone(),
        fast(),
    );
    sink.wait_for("live", |s| {
        s.statuses.lock().unwrap().contains(&StreamStatus::Live)
    })
    .await;
    // 退出登录（服务端吊销会话）：心跳时服务端以 4001 关闭，刷新失败，事件流以 SignedOut 结束。
    reqwest::Client::new()
        .post(format!("{}/v1/auth/logout", e.base))
        .bearer_auth(client.api.bearer().unwrap())
        .send()
        .await
        .unwrap();
    sink.wait_for("signed out", |s| {
        s.statuses.lock().unwrap().last() == Some(&StreamStatus::SignedOut)
    })
    .await;
    assert!(store.load().is_none());
    // 事件流发现会话没了：本地缓存（上一个人的数据）一并清掉。
    assert!(client.cached_instances().unwrap().is_empty());
    assert!(client.cache().unwrap().instances().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn frozen_accounts_stop_the_stream_but_keep_the_session() {
    let Some(e) = env().await else { return };
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    e.login(&api, "13800138503").await;
    let user: UserId = store.load().unwrap().user_id.parse().unwrap();
    let client = Client::new(api, Some(Cache::in_memory().unwrap())).unwrap();
    let inst = client.api.adopt("claude", "助手", None).await.unwrap().id;
    client.instances().await.unwrap();
    let set_status = |status: UserStatus| {
        let db = e.t.db.clone();
        async move {
            let mut w = db.worker().await.unwrap();
            w.set_user_status(user, status).await.unwrap();
            w.commit().await.unwrap();
        }
    };
    let sink = Arc::new(Sink::default());
    let _h = client.subscribe(
        &tokio::runtime::Handle::current(),
        inst,
        sink.clone(),
        fast(),
    );
    sink.wait_for("live", |s| {
        s.statuses.lock().unwrap().contains(&StreamStatus::Live)
    })
    .await;

    // 冻结（4.6）：心跳时服务端以 4003 关闭，事件流以 AccountFrozen 结束；接口和刷新都返回
    // AccountFrozen，会话留着（解冻后接着用）。
    set_status(UserStatus::Frozen).await;
    sink.wait_for("frozen", |s| {
        s.statuses.lock().unwrap().last() == Some(&StreamStatus::AccountFrozen)
    })
    .await;
    assert_eq!(
        client.api.me().await.unwrap_err(),
        ClientError::AccountFrozen
    );
    assert_eq!(
        client.api.refresh().await.unwrap_err(),
        ClientError::AccountFrozen
    );
    assert!(store.load().is_some(), "freezing keeps the session");
    assert_eq!(client.cached_instances().unwrap().len(), 1);

    // 冻结期间连事件流：握手被拒，问过接口后以 AccountFrozen 结束。
    let sink2 = Arc::new(Sink::default());
    let _h2 = client.subscribe(
        &tokio::runtime::Handle::current(),
        inst,
        sink2.clone(),
        fast(),
    );
    sink2
        .wait_for("frozen at connect", |s| {
            s.statuses.lock().unwrap().last() == Some(&StreamStatus::AccountFrozen)
        })
        .await;

    set_status(UserStatus::Active).await;
    client.api.me().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn offline_inbox_reads_are_flushed_later() {
    let Some(e) = env().await else { return };
    let dir = tempfile::tempdir().unwrap();
    let cache_path = dir.path().join("cache.db");
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    e.login(&api, "13800138503").await;
    let user: UserId = store.load().unwrap().user_id.parse().unwrap();
    let mut w = e.t.db.worker().await.unwrap();
    let mut ids: Vec<InboxItemId> = Vec::new();
    for n in 0..3 {
        let id = w
            .insert_inbox(
                user,
                &NewInboxItem {
                    kind: "run_finished".into(),
                    title: format!("早报 {n}"),
                    body: "完成".into(),
                    ..NewInboxItem::default()
                },
            )
            .await
            .unwrap()
            .unwrap();
        ids.push(id);
    }
    w.commit().await.unwrap();

    let online = Client::new(api, Some(Cache::open(&cache_path).unwrap())).unwrap();
    let page = online.sync_inbox(50).await.unwrap();
    assert_eq!(page.unread, 3);
    assert_eq!(page.items[0].title, "早报 2");

    // 没网：本地立即已读，记进待同步。
    let offline = Client::new(
        e.api_at("http://127.0.0.1:9", store.clone()),
        Some(Cache::open(&cache_path).unwrap()),
    )
    .unwrap();
    assert_eq!(offline.mark_inbox_read(&[ids[0]], None).await.unwrap(), 2);
    assert!(offline.sync_inbox(50).await.unwrap_err().retryable());
    assert_eq!(offline.cached_unread().unwrap(), 2);
    assert_eq!(offline.cache().unwrap().pending_reads().unwrap(), [ids[0]]);
    let mut t = e.t.db.tenant(user).await.unwrap();
    assert_eq!(
        t.inbox_unread().await.unwrap(),
        3,
        "server has not heard yet"
    );
    t.rollback().await.unwrap();

    // 联网后同步：先补发，再合并（不会被服务端的旧状态覆盖）。
    let page = online.sync_inbox(50).await.unwrap();
    assert_eq!(page.unread, 2);
    assert!(online.cache().unwrap().pending_reads().unwrap().is_empty());
    let mut t = e.t.db.tenant(user).await.unwrap();
    assert_eq!(t.inbox_unread().await.unwrap(), 2);
    t.rollback().await.unwrap();

    // 全部已读（到最新一条为止）。
    assert_eq!(online.mark_inbox_read(&[], Some(ids[2])).await.unwrap(), 0);
    let mut t = e.t.db.tenant(user).await.unwrap();
    assert_eq!(t.inbox_unread().await.unwrap(), 0);
    t.rollback().await.unwrap();

    // 退出登录清缓存。
    online.logout().await.unwrap();
    assert!(online.cached_inbox(None, 50).unwrap().is_empty());
}

struct Listener(Mutex<Vec<ffi::InstanceEvent>>);

impl ffi::EventListener for Listener {
    fn on_event(&self, event: ffi::InstanceEvent) {
        self.0.lock().unwrap().push(event);
    }
    fn on_reset(&self, _oldest_seq: u64, _latest_seq: Option<u64>) {}
    fn on_status(&self, _status: StreamStatus) {}
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ffi_client_round_trip() {
    let Some(e) = env().await else { return };
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(MemorySessionStore::default());
    let config = ffi::ClientConfig {
        base_url: e.base.clone(),
        cache_path: Some(dir.path().join("c.db").display().to_string()),
        platform: "android".into(),
        device_name: "Pixel".into(),
        timeout_secs: 10,
    };
    assert!(matches!(
        ffi::ThinktinClient::new(
            ffi::ClientConfig {
                platform: "symbian".into(),
                ..config.clone()
            },
            store.clone()
        ),
        Err(ClientError::InvalidArgument { .. })
    ));
    let c = ffi::ThinktinClient::new(config.clone(), store.clone()).unwrap();
    assert!(!c.signed_in());
    c.send_code("13800138504".into()).await.unwrap();
    let code = e.sms.last_code("+8613800138504").unwrap();
    let r = c
        .login(
            "13800138504".into(),
            code,
            Some("unipush".into()),
            Some("1a0018970a8b7c6d5e4".into()),
        )
        .await
        .unwrap();
    assert!(r.new_user);
    assert!(c.signed_in());
    let agents = c.agents().await.unwrap();
    assert!(agents.iter().any(|a| a.id == "claude"));
    let inst = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    assert_eq!(c.instances().await.unwrap().len(), 1);
    assert_eq!(c.cached_instances().unwrap()[0].id, inst.id);
    let run = c
        .create_run(inst.id.clone(), "写个周报".into())
        .await
        .unwrap();
    assert_eq!(run.state, "queued");
    assert_eq!(c.runs(inst.id.clone(), 10).await.unwrap()[0].id, run.id);
    assert_eq!(c.cached_runs(inst.id.clone(), 10).unwrap().len(), 1);
    let cancelled = c.cancel_run(run.id.clone(), true).await.unwrap();
    assert_eq!(cancelled.state, "cancelled");

    let plan = c
        .create_plan(ffi::NewPlan {
            instance_id: inst.id.clone(),
            title: "早报".into(),
            goal: "每天早上汇总新闻".into(),
            triggers: vec![ffi::Schedule::Cron {
                expr: "0 8 * * *".into(),
                tz: "Asia/Shanghai".into(),
            }],
            steps: Vec::new(),
        })
        .await
        .unwrap();
    assert_eq!(plan.triggers.len(), 1);
    assert!(plan.triggers[0].next_fire_at_ms.is_some());
    let paused = c.set_plan_paused(plan.id.clone(), true).await.unwrap();
    assert!(paused.paused);
    assert_eq!(c.plans(Some(inst.id.clone())).await.unwrap().len(), 1);
    let err = c.get_plan("not-an-id".into()).await.unwrap_err();
    assert!(matches!(err, ClientError::InvalidArgument { .. }));

    let listener = Arc::new(Listener(Mutex::new(Vec::new())));
    let sub = c.subscribe(inst.id.clone(), listener.clone()).unwrap();
    let user: UserId = store.load().unwrap().user_id.parse().unwrap();
    e.append(user, inst.id.parse().unwrap(), 7).await;
    for _ in 0..100 {
        if listener
            .0
            .lock()
            .unwrap()
            .iter()
            .any(|ev| ev.payload_json.contains('7'))
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let got = listener.0.lock().unwrap().clone();
    assert!(
        got.iter()
            .any(|ev| ev.kind == "agent.message" && ev.payload_json == r#"{"text":7}"#),
        "{got:?}"
    );
    sub.stop();
    assert!(!c.cached_events(inst.id.clone(), 0, 100).unwrap().is_empty());

    c.logout().await.unwrap();
    assert!(!c.signed_in());
    assert!(c.cached_instances().unwrap().is_empty());
    drop(c);
}
