//! client-core 对着真实的接入网关跑：登录、令牌刷新、会话失效、事件流续传和去重、离线收件箱、
//! 给原生端的 FFI 对象。需要 DATABASE_URL（没有时跳过）。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::service::{AuthConfig, AuthService};
use auth::signed::{Signer25519, Verifier25519};
use auth::sms::RecordingSms;
use client_core::ClientError;
use client_core::api::{
    Api, ApiConfig, MemorySessionStore, NewVaultItem, Session, SessionStore, VaultItemUpdate,
};
use client_core::cache::Cache;
use client_core::client::Client;
use client_core::events::{EventSink, StreamConfig, StreamStatus};
use client_core::ffi;
use control::BuiltinTemplates;
use gateway::{AppState, EventHub, GatewayConfig, Inner};
use keyvault::LocalKms;
use proto::domain::{
    DevicePlatform, InboxItemId, InstanceEvent, InstanceId, UserId, UserStatus, VaultRequestStatus,
};
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
                accept_language: None,
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
    // 往前翻：最后一屏、再往上一屏。
    let tail = client.cached_events_before(inst, None, 2).unwrap();
    assert_eq!(tail, cached[cached.len() - 2..]);
    let above = client
        .cached_events_before(inst, Some(tail[0].seq), 100)
        .unwrap();
    assert_eq!(above, cached[..cached.len() - 2]);

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
        accept_language: None,
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
    let claude = agents.iter().find(|a| a.id == "claude").unwrap();
    assert_eq!(
        (claude.protocols.clone(), claude.active_protocol.as_deref()),
        (vec!["anthropic".to_string()], Some("anthropic"))
    );
    assert!(!claude.description.is_empty() && claude.upstream.starts_with("https://"));
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
            policy: None,
            catch_up: None,
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
    assert!(
        !c.cached_events_before(inst.id.clone(), None, 10)
            .unwrap()
            .is_empty()
    );

    c.logout().await.unwrap();
    assert!(!c.signed_in());
    assert!(c.cached_instances().unwrap().is_empty());
    assert!(
        c.cached_events_before(inst.id.clone(), None, 10)
            .unwrap()
            .is_empty()
    );
    drop(c);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn vault_and_secrets_in_messages() {
    let Some(e) = env().await else { return };
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    e.login(&api, "13800138505").await;
    let user: UserId = store.load().unwrap().user_id.parse().unwrap();
    let client = Client::new(api, None).unwrap();
    let inst = client.api.adopt("claude", "助手", None).await.unwrap().id;

    // 消息里有密码：不发，什么都没建。
    let msg = "帮我登录邮箱，mail 密码是 Abc12345，账号 bob@example.com";
    let err = client.send_message(inst, msg, false).await.unwrap_err();
    assert_eq!(err, ClientError::ContainsSecrets { count: 1 });
    assert!(client.api.runs(inst, None, 10).await.unwrap().is_empty());

    // 存进保险箱，消息里换成引用，再发就放行；服务端只收到引用。
    let found = client_core::secrets::detect(msg);
    assert_eq!(found[0].suggested_name, "mail");
    let (item, text) = client
        .save_secret_from_message(
            msg,
            &found[0].value,
            &NewVaultItem {
                name: found[0].suggested_name.clone(),
                purpose: "收邮件".into(),
                username: "bob@example.com".into(),
                password: found[0].value.clone(),
                instance_ids: vec![inst],
            },
        )
        .await
        .unwrap();
    assert_eq!(item.name, "mail");
    assert_eq!(item.instance_ids, vec![inst]);
    assert!(!text.contains("Abc12345"));
    assert!(text.contains("[vault:mail]"), "{text}");
    let run = client.send_message(inst, &text, false).await.unwrap();
    assert_eq!(client.api.run(run.id).await.unwrap().id, run.id);

    // 重名：409，消息不动。
    let err = client
        .save_secret_from_message(
            msg,
            "Abc12345",
            &NewVaultItem {
                name: "mail".into(),
                password: "Abc12345".into(),
                ..NewVaultItem::default()
            },
        )
        .await
        .unwrap_err();
    assert!(
        matches!(&err, ClientError::Api { code, .. } if code == "conflict"),
        "{err:?}"
    );

    // 用户坚持要发也行（比如是测试账号）。
    client.send_message(inst, msg, true).await.unwrap();

    // 列表和详情：没有密码，详情有账号；改密码不动账号；删除。
    let items = client.api.vault_items().await.unwrap();
    assert_eq!(items.len(), 1);
    let detail = client.api.vault_item(item.id).await.unwrap();
    assert_eq!(detail.username, "bob@example.com");
    assert_eq!(detail.item.id, item.id);
    let updated = client
        .api
        .update_vault_item(
            item.id,
            &VaultItemUpdate {
                password: Some("N3w-secret!".into()),
                instance_ids: Some(Vec::new()),
                ..VaultItemUpdate::default()
            },
        )
        .await
        .unwrap();
    assert!(updated.instance_ids.is_empty());
    assert!(updated.has_username);
    assert_eq!(
        client.api.vault_item(item.id).await.unwrap().username,
        "bob@example.com"
    );
    let raw = reqwest::Client::new()
        .get(format!("{}/v1/vault/{}", e.base, item.id))
        .bearer_auth(client.api.bearer().unwrap())
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(!raw.contains("N3w-secret!") && !raw.contains("Abc12345"));

    // agent 的填写请求：拒绝一个、填一个。
    let mut t = e.t.db.tenant(user).await.unwrap();
    let mut ids = Vec::new();
    for name in ["github", "db"] {
        let (r, _) = t
            .create_vault_request(&store::NewVaultRequest {
                instance_id: inst,
                run_id: None,
                name: name.into(),
                purpose: "推代码".into(),
                fields: vec!["username".into(), "password".into()],
                expires_in: Duration::from_secs(3600),
            })
            .await
            .unwrap();
        ids.push(r.id);
    }
    t.commit().await.unwrap();
    assert_eq!(client.api.vault_requests(false).await.unwrap().len(), 2);
    let declined = client.api.decline_vault_request(ids[1]).await.unwrap();
    assert_eq!(declined.status, VaultRequestStatus::Declined);
    let done = client
        .api
        .fulfill_vault_request(ids[0], "octocat", "gh-pass-123", None)
        .await
        .unwrap();
    assert_eq!(done.status, VaultRequestStatus::Fulfilled);
    assert!(client.api.vault_requests(false).await.unwrap().is_empty());
    assert_eq!(client.api.vault_requests(true).await.unwrap().len(), 2);
    let names: Vec<String> = client
        .api
        .vault_items()
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.name)
        .collect();
    assert!(names.contains(&"github".to_owned()), "{names:?}");

    client.api.delete_vault_item(item.id).await.unwrap();
    assert!(
        client
            .api
            .vault_item(item.id)
            .await
            .unwrap_err()
            .is_not_found()
    );

    // FFI：本地识别（UTF-16 下标）和换成引用。
    let text = "😀 token: ghp_0123456789abcdefABCDEF0123456789abcd";
    let hits = ffi::detect_secrets(text.into());
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].kind, "api_key");
    assert_eq!(hits[0].suggested_name, "github");
    let utf16: Vec<u16> = text.encode_utf16().collect();
    assert_eq!(
        String::from_utf16(&utf16[hits[0].start as usize..hits[0].end as usize]).unwrap(),
        hits[0].value
    );
    assert_eq!(
        ffi::redact_message(
            text.into(),
            vec![ffi::SecretReference {
                value: hits[0].value.clone(),
                name: "github".into()
            }]
        ),
        "😀 token: [vault:github]"
    );
    assert_eq!(
        ffi::unique_vault_name("github".into(), vec!["github".into()]),
        "github_2"
    );
}

/// 手机和电脑之间的消息（14.1）：手机在设备列表里看得到自己的电脑和它在不在线；手机发给电脑的消息
/// 电脑收得到，电脑发来的审批请求手机收得到，确认后不再返回；方向不对、发给别人的设备都被拒绝。
/// 电脑平时经设备中继收发（见 relay 的测试），这里两边都用接口。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn phones_and_computers_exchange_messages() {
    use proto::domain::DeviceMessageKind;

    let Some(e) = env().await else { return };
    let phone = e.api(Arc::new(MemorySessionStore::default()));
    e.login(&phone, "13800138071").await;
    let mac = Api::new(
        ApiConfig {
            base_url: e.base.clone(),
            platform: DevicePlatform::Macos,
            device_name: "MacBook".into(),
            timeout: Duration::from_secs(10),
            accept_language: None,
        },
        Arc::new(MemorySessionStore::default()),
    )
    .unwrap();
    e.login(&mac, "13800138071").await;
    let other = e.api(Arc::new(MemorySessionStore::default()));
    e.login(&other, "13800138072").await;

    let devices = phone.devices().await.unwrap();
    assert_eq!(devices.len(), 2, "{devices:?}");
    let me = devices.iter().find(|d| d.current).unwrap().device.id;
    let computer = devices
        .iter()
        .find(|d| d.device.platform == DevicePlatform::Macos)
        .unwrap();
    assert!(!computer.online && !computer.current);
    let computer = computer.device.id;

    // 电脑连着中继就算在线（这里直接记在线状态；中继本身的测试在 relay 里）。
    let user = phone.me().await.unwrap().id;
    let mut r = e.t.db.relay().await.unwrap();
    r.link_device(&store::NewLink {
        device: computer,
        user,
        node: "relay-1".into(),
        connection: uuid::Uuid::now_v7(),
    })
    .await
    .unwrap();
    r.commit().await.unwrap();
    assert!(
        phone
            .devices()
            .await
            .unwrap()
            .iter()
            .any(|d| d.device.id == computer && d.online)
    );

    // 手机 → 电脑：能力令牌。
    let grant = phone
        .send_device_message(
            computer,
            DeviceMessageKind::Capability,
            &json!({ "dirs": ["/Users/a/Documents"] }),
        )
        .await
        .unwrap();
    assert_eq!((grant.from_device, grant.to_device), (me, computer));
    // 审批请求只能电脑发；不能发给自己；别人的设备不存在。
    let invalid =
        |r: Result<_, ClientError>| matches!(r, Err(ClientError::Api { status: 422, .. }));
    assert!(invalid(
        phone
            .send_device_message(computer, DeviceMessageKind::ApprovalRequest, &json!({}))
            .await
    ));
    assert!(invalid(
        phone
            .send_device_message(me, DeviceMessageKind::Capability, &json!({}))
            .await
    ));
    let strangers = other.devices().await.unwrap()[0].device.id;
    assert!(matches!(
        phone
            .send_device_message(strangers, DeviceMessageKind::Capability, &json!({}))
            .await,
        Err(ClientError::Api { status: 404, .. })
    ));

    // 电脑收到、确认。
    let inbox = mac.device_messages().await.unwrap();
    assert_eq!(inbox, vec![grant.clone()]);
    assert_eq!(mac.ack_device_messages(&[grant.id]).await.unwrap(), 1);
    assert!(mac.device_messages().await.unwrap().is_empty());

    // 电脑 → 手机：审批请求。手机收到、确认后不再返回。
    let ask = mac
        .send_device_message(
            me,
            DeviceMessageKind::ApprovalRequest,
            &json!({ "tool": "fs_delete", "summary": "删除 ~/Downloads/a.zip" }),
        )
        .await
        .unwrap();
    assert_eq!(phone.device_messages().await.unwrap(), vec![ask.clone()]);
    assert!(other.device_messages().await.unwrap().is_empty());
    assert_eq!(phone.ack_device_messages(&[ask.id]).await.unwrap(), 1);
    assert_eq!(phone.ack_device_messages(&[ask.id]).await.unwrap(), 0);
    assert!(phone.device_messages().await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn im_channels_round_trip() {
    let Some(e) = env().await else { return };
    let store = Arc::new(MemorySessionStore::default());
    let api = e.api(store.clone());
    e.login(&api, "13800138506").await;
    let ch = api
        .add_im_channel(&client_core::api::NewImChannel {
            webhook_url:
                "https://open.feishu.cn/open-apis/bot/v2/hook/abcdef01-2345-6789-abcd-ef0123456789"
                    .into(),
            secret: Some("feishu-sign-secret".into()),
            label: "家庭群".into(),
            events: Some(vec!["run_finished".into()]),
        })
        .await
        .unwrap();
    assert_eq!(
        (ch.vendor.as_str(), ch.hint.as_str(), ch.has_secret),
        ("feishu", "…6789", true)
    );
    let off = api
        .update_im_channel(ch.id, None, Some(&["approval".to_owned()]), Some(false))
        .await
        .unwrap();
    assert!(!off.enabled);
    assert_eq!(off.events, vec![proto::domain::ImEvent::Approval]);
    let err = api.test_im_channel(ch.id).await.unwrap_err();
    assert!(
        matches!(err, ClientError::Api { status: 422, .. }),
        "{err:?}"
    );
    api.update_im_channel(ch.id, None, None, Some(true))
        .await
        .unwrap();
    api.test_im_channel(ch.id).await.unwrap();
    let rotated = api
        .replace_im_webhook(
            ch.id,
            "https://open.feishu.cn/open-apis/bot/v2/hook/0000aaaa-bbbb-cccc-dddd-eeeeffff1111",
            None,
        )
        .await
        .unwrap();
    assert_eq!(
        (rotated.hint.as_str(), rotated.has_secret),
        ("…1111", false)
    );
    assert_eq!(api.im_channels().await.unwrap().len(), 1);
    api.delete_im_channel(ch.id).await.unwrap();
    assert!(api.im_channels().await.unwrap().is_empty());
}

/// 11.7：设备列表和吊销、改昵称、注销账号（经 UniFFI 的客户端）。
async fn ffi_login(
    e: &Env,
    phone: &str,
    platform: &str,
    device: &str,
) -> (
    Arc<ffi::ThinktinClient>,
    Arc<MemorySessionStore>,
    tempfile::TempDir,
) {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(MemorySessionStore::default());
    let c = ffi::ThinktinClient::new(
        ffi::ClientConfig {
            base_url: e.base.clone(),
            cache_path: Some(dir.path().join("c.db").display().to_string()),
            platform: platform.into(),
            device_name: device.into(),
            timeout_secs: 10,
            accept_language: None,
        },
        store.clone(),
    )
    .unwrap();
    c.send_code(phone.into()).await.unwrap();
    let code = e.sms.last_code(&format!("+86{phone}")).unwrap();
    c.login(phone.into(), code, None, None).await.unwrap();
    (c, store, dir)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ffi_account_and_devices() {
    let Some(e) = env().await else { return };
    let (phone, _ps, _pd) = ffi_login(&e, "13800138507", "ios", "iPhone").await;
    let (laptop, _ls, _ld) = ffi_login(&e, "13800138507", "macos", "MacBook").await;

    let me = phone.update_profile(Some("小明".into())).await.unwrap();
    assert_eq!(me.display_name.as_deref(), Some("小明"));
    assert_eq!(phone.update_profile(None).await.unwrap().display_name, None);

    let devices = phone.devices().await.unwrap();
    assert_eq!(devices.len(), 2);
    let mine = devices.iter().find(|d| d.current).unwrap();
    assert_eq!(
        (mine.platform.as_str(), mine.name.as_str()),
        ("ios", "iPhone")
    );
    let mac = devices.iter().find(|d| !d.current).unwrap();
    assert_eq!(mac.platform, "macos");
    assert!(matches!(
        phone.revoke_device("not-an-id".into()).await,
        Err(ClientError::InvalidArgument { .. })
    ));
    phone.revoke_device(mac.id.clone()).await.unwrap();
    assert!(matches!(laptop.me().await, Err(ClientError::SignedOut)));
    assert_eq!(phone.devices().await.unwrap().len(), 1);

    // 注销：验证码发到自己的手机号；错的码不行；成功后本地也退出登录。
    phone.send_self_code("delete_account".into()).await.unwrap();
    assert!(matches!(
        phone.send_self_code("nonsense".into()).await,
        Err(ClientError::Api { status: 422, .. })
    ));
    let code = e.sms.last_code("+8613800138507").unwrap();
    let wrong = if code == "000000" { "111111" } else { "000000" };
    assert!(phone.delete_account(wrong.into()).await.is_err());
    assert!(phone.signed_in(), "a wrong code changes nothing");
    phone.delete_account(code).await.unwrap();
    assert!(!phone.signed_in());
    assert!(phone.cached_instances().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ffi_plan_editing_and_triggers() {
    let Some(e) = env().await else { return };
    let (c, _s, _d) = ffi_login(&e, "13800138508", "android", "Pixel").await;
    let inst = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    let policy = ffi::PlanPolicy {
        preauthorized_tools: vec!["read".into(), "search".into()],
        approval_timeout_secs: 3600,
        on_approval_timeout: "skip".into(),
        max_tokens: Some(200_000),
        max_duration_secs: 1800,
        max_steps: None,
        daily_token_limit: Some(1_000_000),
        wait_timeout_secs: 7200,
    };
    let plan = c
        .create_plan(ffi::NewPlan {
            instance_id: inst.id.clone(),
            title: "早报".into(),
            goal: "每天八点整理新闻".into(),
            triggers: vec![ffi::Schedule::Cron {
                expr: "0 8 * * *".into(),
                tz: "Asia/Shanghai".into(),
            }],
            steps: vec![],
            policy: Some(policy.clone()),
            catch_up: Some("skip".into()),
        })
        .await
        .unwrap();
    assert_eq!(
        (plan.policy.clone(), plan.catch_up.as_str()),
        (policy.clone(), "skip")
    );
    assert!(plan.policy_json.contains("\"preauthorized_tools\""));

    let edited = c
        .update_plan(
            plan.id.clone(),
            ffi::PlanChange {
                title: Some("晨报".into()),
                policy: Some(ffi::PlanPolicy {
                    on_approval_timeout: "fail".into(),
                    ..policy.clone()
                }),
                catch_up: Some("all".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(
        (
            edited.title.as_str(),
            edited.goal.as_str(),
            edited.catch_up.as_str()
        ),
        ("晨报", "每天八点整理新闻", "all")
    );
    assert_eq!(edited.policy.on_approval_timeout, "fail");
    assert_eq!(edited.triggers.len(), 1);
    // 列表里也有触发器和下次运行时间（11.8）；暂停了就没有下次。
    let listed = c.plans(Some(inst.id.clone())).await.unwrap();
    assert_eq!(listed[0].triggers.len(), 1);
    assert_eq!(
        (listed[0].next_fire_at_ms, listed[0].invalid_triggers),
        (listed[0].triggers[0].next_fire_at_ms, 0)
    );
    assert!(listed[0].next_fire_at_ms.is_some());
    assert!(matches!(
        c.update_plan(
            plan.id.clone(),
            ffi::PlanChange {
                catch_up: Some("sometimes".into()),
                ..Default::default()
            }
        )
        .await,
        Err(ClientError::InvalidArgument { .. })
    ));
    assert!(matches!(
        c.update_plan(
            plan.id.clone(),
            ffi::PlanChange {
                title: Some(" ".into()),
                ..Default::default()
            }
        )
        .await,
        Err(ClientError::Api { status: 422, .. })
    ));

    let t = c
        .add_trigger(
            plan.id.clone(),
            ffi::Schedule::Cron {
                expr: "30 18 * * 1-5".into(),
                tz: "Asia/Shanghai".into(),
            },
        )
        .await
        .unwrap();
    assert!(t.next_fire_at_ms.is_some());
    assert_eq!(c.get_plan(plan.id.clone()).await.unwrap().triggers.len(), 2);
    c.delete_trigger(t.id.clone()).await.unwrap();
    assert!(matches!(
        c.delete_trigger(t.id).await,
        Err(ClientError::Api { status: 404, .. })
    ));
    assert_eq!(c.get_plan(plan.id).await.unwrap().triggers.len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ffi_keys_runs_artifacts_and_inbox_items() {
    let Some(e) = env().await else { return };
    let (c, store, _d) = ffi_login(&e, "13800138509", "ios", "iPhone").await;
    let user: UserId = store.load().unwrap().user_id.parse().unwrap();

    // key：改备注、停用、换 key（只显示新的后 4 位）。
    let cred = c
        .add_credential(ffi::NewCredential {
            vendor: "deepseek".into(),
            label: "工作".into(),
            api_key: "sk-0123456789abcdef".into(),
            anthropic_base: None,
            openai_base: None,
            responses_base: None,
            daily_token_limit: None,
        })
        .await
        .unwrap();
    let off = c
        .update_credential(cred.id.clone(), Some("备用".into()), Some(true))
        .await
        .unwrap();
    assert_eq!((off.label.as_str(), off.disabled), ("备用", true));
    let swapped = c
        .replace_credential_secret(cred.id.clone(), "sk-fedcba9876543210".into())
        .await
        .unwrap();
    assert_eq!(swapped.last4, "3210");
    assert!(matches!(
        c.replace_credential_secret(cred.id, "short".into()).await,
        Err(ClientError::Api { status: 422, .. })
    ));

    // 运行往下翻页；单个实例；实例的产出物。
    let inst = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    for n in 0..3 {
        c.create_run(inst.id.clone(), format!("第 {n} 个"))
            .await
            .unwrap();
    }
    let first = c.runs(inst.id.clone(), 2).await.unwrap();
    assert_eq!(first.len(), 2);
    let older = c
        .older_runs(inst.id.clone(), first[1].id.clone(), 2)
        .await
        .unwrap();
    assert_eq!(older.len(), 1);
    assert!(first.iter().all(|r| r.id != older[0].id));
    assert_eq!(c.cached_runs(inst.id.clone(), 10).unwrap().len(), 3);
    assert_eq!(c.instance(inst.id.clone()).await.unwrap().name, "助手");
    assert!(
        c.instance_artifacts(inst.id.clone(), 10)
            .await
            .unwrap()
            .is_empty()
    );

    // 收件箱：单条、标回未读、删除，缓存跟着变。
    let mut w = e.t.db.worker().await.unwrap();
    let mut ids = Vec::new();
    for n in 0..2 {
        ids.push(
            w.insert_inbox(
                user,
                &NewInboxItem {
                    kind: "info".into(),
                    title: format!("通知 {n}"),
                    ..NewInboxItem::default()
                },
            )
            .await
            .unwrap()
            .unwrap()
            .to_string(),
        );
    }
    w.commit().await.unwrap();
    c.sync_inbox(20).await.unwrap();
    assert_eq!(
        c.mark_inbox_read(vec![ids[0].clone()], None).await.unwrap(),
        1
    );
    assert!(c.inbox_item(ids[0].clone()).await.unwrap().read);
    assert_eq!(c.mark_inbox_unread(ids[0].clone()).await.unwrap(), 2);
    assert!(!c.inbox_item(ids[0].clone()).await.unwrap().read);
    assert_eq!(c.cached_unread().unwrap(), 2);
    c.delete_inbox_item(ids[1].clone()).await.unwrap();
    assert_eq!(c.cached_inbox(None, 20).unwrap().len(), 1);
    assert!(matches!(
        c.inbox_item(ids[1].clone()).await,
        Err(ClientError::Api { status: 404, .. })
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ffi_teams_and_templates() {
    let Some(e) = env().await else { return };
    let (c, _s, _d) = ffi_login(&e, "13800138510", "android", "Pixel").await;
    let lead = c.adopt("claude".into(), "主编".into(), None).await.unwrap();
    let writer = c.adopt("codex".into(), "写手".into(), None).await.unwrap();
    let member = |inst: &ffi::Instance, role: &str, position: u32| ffi::TeamMember {
        instance_id: inst.id.clone(),
        role: role.into(),
        position,
    };
    assert!(matches!(
        c.create_team("编辑部".into(), vec![member(&lead, "boss", 0)])
            .await,
        Err(ClientError::InvalidArgument { .. })
    ));
    let team = c
        .create_team(
            "编辑部".into(),
            vec![member(&lead, "lead", 0), member(&writer, "member", 1)],
        )
        .await
        .unwrap();
    assert_eq!(team.members.len(), 2);
    assert_eq!(c.teams().await.unwrap().len(), 1);
    let renamed = c
        .update_team(
            team.id.clone(),
            Some("新编辑部".into()),
            Some(vec![member(&writer, "lead", 0), member(&lead, "member", 1)]),
        )
        .await
        .unwrap();
    assert_eq!(renamed.name, "新编辑部");
    assert_eq!(
        c.team(team.id.clone()).await.unwrap().members[0].instance_id,
        writer.id
    );

    // 模板：从团队生成、直接给成员；一键领养出新团队和新实例。
    let tpl = c
        .create_team_template_from_team("编辑部模板".into(), team.id.clone())
        .await
        .unwrap();
    assert_eq!(tpl.members.len(), 2);
    assert!(
        tpl.members
            .iter()
            .any(|m| m.agent_id == "codex" && m.role == "lead")
    );
    let direct = c
        .create_team_template(
            "单人".into(),
            vec![ffi::TemplateMember {
                agent_id: "claude".into(),
                harness: Some("cli".into()),
                name: "助手".into(),
                role: "lead".into(),
            }],
        )
        .await
        .unwrap();
    assert_eq!(c.team_templates().await.unwrap().len(), 2);
    let adopted = c
        .adopt_team_template(tpl.id.clone(), Some("第二编辑部".into()))
        .await
        .unwrap();
    assert_eq!(
        (adopted.name.as_str(), adopted.members.len()),
        ("第二编辑部", 2)
    );
    assert_eq!(c.instances().await.unwrap().len(), 4);
    c.delete_team_template(direct.id).await.unwrap();
    assert_eq!(c.team_templates().await.unwrap().len(), 1);
    c.delete_team(team.id.clone()).await.unwrap();
    assert!(matches!(
        c.team(team.id).await,
        Err(ClientError::Api { status: 404, .. })
    ));
    assert_eq!(
        c.instances().await.unwrap().len(),
        4,
        "deleting a team keeps its instances"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ffi_device_messages() {
    let Some(e) = env().await else { return };
    let (phone, _ps, _pd) = ffi_login(&e, "13800138511", "ios", "iPhone").await;
    let (mac, _ms, _md) = ffi_login(&e, "13800138511", "macos", "MacBook").await;
    let devices = phone.devices().await.unwrap();
    let mac_id = devices
        .iter()
        .find(|d| d.platform == "macos")
        .unwrap()
        .id
        .clone();
    let phone_id = devices.iter().find(|d| d.current).unwrap().id.clone();
    assert!(matches!(
        phone
            .send_device_message(mac_id.clone(), "pair_response".into(), "{not json".into())
            .await,
        Err(ClientError::InvalidArgument { .. })
    ));
    assert!(matches!(
        phone
            .send_device_message(mac_id.clone(), "gossip".into(), "{}".into())
            .await,
        Err(ClientError::InvalidArgument { .. })
    ));
    let sent = phone
        .send_device_message(
            mac_id.clone(),
            "pair_response".into(),
            r#"{"nonce":"abc"}"#.into(),
        )
        .await
        .unwrap();
    assert_eq!(
        (sent.from_device_id.as_str(), sent.to_device_id.as_str()),
        (phone_id.as_str(), mac_id.as_str())
    );
    let got = mac.device_messages().await.unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].kind, "pair_response");
    let body: serde_json::Value = serde_json::from_str(&got[0].body_json).unwrap();
    assert_eq!(body["nonce"], "abc");
    assert_eq!(
        mac.ack_device_messages(vec![got[0].id.clone()])
            .await
            .unwrap(),
        1
    );
    assert!(mac.device_messages().await.unwrap().is_empty());
    mac.send_device_message(phone_id, "pair_confirm".into(), r#"{"ok":true}"#.into())
        .await
        .unwrap();
    assert_eq!(
        phone.device_messages().await.unwrap()[0].kind,
        "pair_confirm"
    );
}

#[tokio::test]
async fn ffi_live_activities() {
    let Some(e) = env().await else { return };
    let (c, _store, _d) = ffi_login(&e, "13800138520", "ios", "iPhone").await;
    let inst = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    let run = c
        .create_run(inst.id.clone(), "整理邮件".into())
        .await
        .unwrap();
    let token = "ab".repeat(40);
    c.register_live_activity(run.id.clone(), token.clone())
        .await
        .unwrap();
    assert!(matches!(
        c.register_live_activity(run.id.clone(), "nope".into())
            .await,
        Err(ClientError::Api { status: 422, .. })
    ));
    // 后台领得到，带着登记的令牌。
    let mut w = e.t.db.worker().await.unwrap();
    let due = w
        .claim_live_activities(
            "test",
            std::time::Duration::from_secs(60),
            10,
            10,
            std::time::Duration::ZERO,
            std::time::Duration::ZERO,
        )
        .await
        .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].run_id.to_string(), run.id);
    assert_eq!(due[0].push_token.as_deref(), Some(token.as_str()));
    c.end_live_activity(run.id.clone()).await.unwrap();

    c.set_live_activity_start_token(Some("cd".repeat(40)))
        .await
        .unwrap();
    c.set_live_activity_start_token(None).await.unwrap();
    // Android 上没有实时活动。
    let (droid, _s, _d2) = ffi_login(&e, "13800138521", "android", "Pixel").await;
    assert!(matches!(
        droid
            .set_live_activity_start_token(Some("cd".repeat(40)))
            .await,
        Err(ClientError::Api { status: 422, .. })
    ));
}

#[tokio::test]
async fn ffi_content_reports() {
    let Some(e) = env().await else { return };
    let (c, _store, _d) = ffi_login(&e, "13800138522", "ios", "iPhone").await;
    let inst = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    let run = c
        .create_run(inst.id.clone(), "写一首诗".into())
        .await
        .unwrap();
    let r = c
        .report_content(
            run.id.clone(),
            None,
            None,
            "misinformation".into(),
            Some("编造的数据".into()),
        )
        .await
        .unwrap();
    assert_eq!(
        (r.state.as_str(), r.reason.as_str(), r.run_id.as_str()),
        ("open", "misinformation", run.id.as_str())
    );
    assert!(matches!(
        c.report_content(run.id.clone(), None, None, "boring".into(), None)
            .await,
        Err(ClientError::InvalidArgument { .. })
    ));
    let mine = c.reports().await.unwrap();
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0].id, r.id);
}

/// 绑定里 `PlanPolicy` 的默认值和服务端的默认策略一样（`PlanPolicy()` 在 App 里就是默认策略）。
#[test]
fn ffi_plan_policy_defaults_match_the_server() {
    let p: ffi::PlanPolicy = proto::domain::PlanPolicy::default().into();
    assert_eq!(
        (
            p.preauthorized_tools.len(),
            p.approval_timeout_secs,
            p.on_approval_timeout.as_str(),
            p.max_tokens,
            p.max_duration_secs,
            p.max_steps,
            p.daily_token_limit,
            p.wait_timeout_secs,
        ),
        (0, 86400, "pause_plan", None, 21600, None, None, 86400)
    );
    assert_eq!(proto::domain::CatchUp::default().as_str(), "once");
}

/// 新用户的语言按设备的 `Accept-Language` 定（11.8），已有的用户不变。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn new_users_get_the_device_language() {
    let Some(e) = env().await else { return };
    let dir = tempfile::tempdir().unwrap();
    let client = |lang: &str| {
        ffi::ThinktinClient::new(
            ffi::ClientConfig {
                base_url: e.base.clone(),
                cache_path: Some(dir.path().join("c.db").display().to_string()),
                platform: "ios".into(),
                device_name: "iPhone".into(),
                timeout_secs: 10,
                accept_language: Some(ffi::accept_language_header(vec![lang.into(), "en".into()])),
            },
            Arc::new(MemorySessionStore::default()),
        )
        .unwrap()
    };
    let sms = &e.sms;
    let login = |c: Arc<ffi::ThinktinClient>| async move {
        c.send_code("13800138523".into()).await.unwrap();
        let code = sms.last_code("+8613800138523").unwrap();
        c.login("13800138523".into(), code, None, None)
            .await
            .unwrap()
    };
    let first = login(client("en-GB")).await;
    assert!(first.new_user);
    assert_eq!(first.user.locale, "en");
    let again = login(client("zh-Hans-CN")).await;
    assert_eq!((again.new_user, again.user.locale.as_str()), (false, "en"));
}

/// 运行在等什么（11.8）：等 key 的运行带着结构化的原因。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ffi_runs_say_what_they_wait_for() {
    use proto::domain::{RunId, RunState};
    use store::RunChange;
    let Some(e) = env().await else { return };
    let (c, _store, _d) = ffi_login(&e, "13800138524", "ios", "iPhone").await;
    let inst = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    let run = c
        .create_run(inst.id.clone(), "整理邮件".into())
        .await
        .unwrap();
    assert_eq!(run.wait_code, None);
    let id: RunId = run.id.parse().unwrap();
    let mut w = e.t.db.worker().await.unwrap();
    w.claim_next_run("n1", std::time::Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    w.transition_run(id, "n1", RunState::Running, &RunChange::default())
        .await
        .unwrap();
    w.transition_run(
        id,
        "n1",
        RunState::WaitingQuota,
        &RunChange {
            reason: Some("欠费".into()),
            release_lease: true,
            wait_code: Some("no_balance"),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    assert_eq!(
        c.get_run(run.id.clone())
            .await
            .unwrap()
            .wait_code
            .as_deref(),
        Some("no_balance")
    );
    let listed = c.runs(inst.id.clone(), 10).await.unwrap();
    assert_eq!(listed[0].wait_code.as_deref(), Some("no_balance"));
}

/// 跨实例的运行列表（11.8）：全部、没结束的、往下翻；顺便更新每个实例的缓存。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ffi_runs_across_instances() {
    let Some(e) = env().await else { return };
    let (c, _store, _d) = ffi_login(&e, "13800138525", "ios", "iPhone").await;
    let a = c.adopt("claude".into(), "助手".into(), None).await.unwrap();
    let b = c.adopt("codex".into(), "写手".into(), None).await.unwrap();
    let mut ids = Vec::new();
    for (inst, p) in [(&a, "一"), (&a, "二"), (&b, "三")] {
        ids.push(c.create_run(inst.id.clone(), p.into()).await.unwrap().id);
    }
    let all = c
        .list_runs(ffi::RunFilter::default(), None, 10)
        .await
        .unwrap();
    assert_eq!(
        all.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
        ids.iter().rev().cloned().collect::<Vec<_>>()
    );
    c.cancel_run(ids[0].clone(), false).await.unwrap();
    let active = c
        .list_runs(
            ffi::RunFilter {
                active_only: true,
                ..Default::default()
            },
            None,
            10,
        )
        .await
        .unwrap();
    assert_eq!(active.len(), 2);
    let page = c
        .list_runs(ffi::RunFilter::default(), None, 2)
        .await
        .unwrap();
    let rest = c
        .list_runs(ffi::RunFilter::default(), Some(page[1].id.clone()), 10)
        .await
        .unwrap();
    assert_eq!(rest.len(), 1);
    assert_eq!(rest[0].id, ids[0]);
    assert!(
        c.cached_runs(b.id.clone(), 10)
            .unwrap()
            .iter()
            .any(|r| r.id == ids[2])
    );
    assert!(matches!(
        c.list_runs(
            ffi::RunFilter {
                plan_id: Some("nope".into()),
                ..Default::default()
            },
            None,
            10
        )
        .await,
        Err(ClientError::InvalidArgument { .. })
    ));
}
