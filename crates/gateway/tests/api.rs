//! 接入网关的接口：起一个真实的 HTTP 服务（带事件监听），用 reqwest 和 WebSocket 客户端调用。
//! 需要 DATABASE_URL（没有时跳过）。

use std::sync::Arc;
use std::time::Duration;

use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::service::{AuthConfig, AuthService};
use auth::signed::{Signer25519, Verifier25519};
use auth::sms::RecordingSms;
use control::BuiltinTemplates;
use futures_util::StreamExt;
use gateway::{AppState, EventHub, GatewayConfig, Inner};
use keyvault::secrecy::ExposeSecret;
use keyvault::{KeyStore, KeyVault, LocalKms, MemoryKeyStore, SealedSecret, WrappedKey};
use orchestrator::artifacts::{ArtifactStore, LocalBlobStore, Origin};
use proto::domain::{ApprovalState, InstanceId, RunId, UserId};
use reqwest::{Method, StatusCode};
use serde_json::{Value, json};
use store::testing::TestDb;
use tokio_tungstenite::tungstenite;
use zeroize::Zeroizing;

const KMS_KEY: [u8; 32] = [9; 32];

struct Api {
    t: TestDb,
    base: String,
    http: reqwest::Client,
    sms: Arc<RecordingSms>,
    artifacts: Arc<ArtifactStore>,
    _blobs: tempfile::TempDir,
}

async fn api() -> Option<Api> {
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
    let kms = Arc::new(LocalKms::new("kms1", &KMS_KEY));
    let blobs = tempfile::tempdir().unwrap();
    let artifacts = Arc::new(ArtifactStore::new(
        t.db.clone(),
        Arc::new(LocalBlobStore::new(blobs.path()).unwrap()),
        kms.clone(),
    ));
    let state = AppState::new(Inner {
        db: t.db.clone(),
        auth: Arc::new(auth),
        templates: Arc::new(BuiltinTemplates),
        kms,
        hub: hub.clone(),
        artifacts: Some(artifacts.clone()),
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
    Some(Api {
        t,
        base,
        http: reqwest::Client::new(),
        sms,
        artifacts,
        _blobs: blobs,
    })
}

struct User {
    access: String,
    refresh: String,
}

impl Api {
    async fn call(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut req = self.http.request(method, format!("{}{path}", self.base));
        if let Some(t) = token {
            req = req.bearer_auth(t);
        }
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req.send().await.unwrap();
        let status = resp.status();
        let text = resp.text().await.unwrap();
        (status, serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    async fn login(&self, phone: &str) -> User {
        let (st, _) = self
            .call(
                Method::POST,
                "/v1/auth/code",
                None,
                Some(json!({ "phone": phone })),
            )
            .await;
        assert_eq!(st, StatusCode::NO_CONTENT);
        let e164 = format!("+86{phone}");
        let code = self.sms.last_code(&e164).unwrap();
        let (st, body) = self
            .call(
                Method::POST,
                "/v1/auth/login",
                None,
                Some(json!({
                    "phone": phone,
                    "code": code,
                    "device": { "platform": "ios", "name": "iPhone", "push_channel": "apns", "push_token": "tok" }
                })),
            )
            .await;
        assert_eq!(st, StatusCode::OK, "{body}");
        User {
            access: body["access_token"].as_str().unwrap().into(),
            refresh: body["refresh_token"].as_str().unwrap().into(),
        }
    }

    async fn adopt(&self, u: &User) -> InstanceId {
        let (st, body) = self
            .call(
                Method::POST,
                "/v1/instances",
                Some(&u.access),
                Some(json!({ "agent_id": "claude", "name": "My Claude" })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().parse().unwrap()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn login_refresh_logout_and_errors() {
    let Some(a) = api().await else { return };
    let (st, body) = a.call(Method::GET, "/v1/me", None, None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "unauthenticated");
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/auth/code",
            None,
            Some(json!({ "phone": "123" })),
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::UNPROCESSABLE_ENTITY, Some("invalid"))
    );
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/auth/login",
            None,
            Some(json!({ "nope": 1 })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    assert_eq!(body["code"], "invalid", "bad JSON uses the error envelope");

    let u = a.login("13800138000").await;
    let (st, me) = a.call(Method::GET, "/v1/me", Some(&u.access), None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(me["phone"], "+8613800138000");
    let (_, devices) = a
        .call(Method::GET, "/v1/devices", Some(&u.access), None)
        .await;
    assert_eq!(devices["devices"][0]["current"], true);
    assert_eq!(devices["devices"][0]["push_channel"], "apns");

    let (st, tokens) = a
        .call(
            Method::POST,
            "/v1/auth/refresh",
            None,
            Some(json!({ "refresh_token": u.refresh })),
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    let access = tokens["access_token"].as_str().unwrap().to_owned();
    let (st, _) = a
        .call(Method::POST, "/v1/auth/logout", Some(&access), None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, body) = a.call(Method::GET, "/v1/me", Some(&access), None).await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("session_revoked"))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn instances_keys_and_routes_are_per_user() {
    let Some(a) = api().await else { return };
    let (_, agents) = a.call(Method::GET, "/v1/agents", None, None).await;
    assert!(
        agents["agents"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["id"] == "claude")
    );

    let alice = a.login("13800138000").await;
    let bob = a.login("13900139000").await;
    let inst = a.adopt(&alice).await;
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/instances",
            Some(&alice.access),
            Some(json!({ "agent_id": "nope", "name": "x" })),
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::NOT_FOUND, Some("not_found"))
    );

    // key：加密保存，只返回后 4 位；用这个用户的 DEK 能解开，记录 id 绑在密文上。
    let (st, cred) = a
        .call(
            Method::POST,
            "/v1/credentials",
            Some(&alice.access),
            Some(
                json!({ "vendor": "anthropic", "label": "work", "api_key": "sk-ant-secret-1234" }),
            ),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{cred}");
    assert_eq!(cred["last4"], "1234");
    assert!(
        !cred.to_string().contains("secret"),
        "the key never comes back"
    );
    let cred_id: proto::domain::CredentialId = cred["id"].as_str().unwrap().parse().unwrap();
    let mut w = a.t.db.worker().await.unwrap();
    let sealed = w.sealed_credential(cred_id).await.unwrap().unwrap();
    let (kms_key_id, wrapped) = w.user_key(sealed.user_id).await.unwrap().unwrap();
    w.rollback().await.unwrap();
    let store = MemoryKeyStore::default();
    let uid = sealed.user_id.to_string();
    store.insert_new(
        &uid,
        WrappedKey {
            kms_key_id,
            ciphertext: wrapped,
        },
    );
    let vault = KeyVault::new(LocalKms::new("kms1", &KMS_KEY), store);
    let plain = vault
        .open(
            &uid,
            &cred_id.to_string(),
            &SealedSecret {
                ciphertext: sealed.sealed.clone(),
                last4: sealed.last4,
            },
        )
        .unwrap();
    assert_eq!(plain.expose_secret(), "sk-ant-secret-1234");
    assert!(
        vault
            .open(
                &uid,
                &proto::domain::CredentialId::new().to_string(),
                &SealedSecret {
                    ciphertext: sealed.sealed,
                    last4: String::new()
                }
            )
            .is_err(),
        "ciphertext is bound to its record"
    );
    // 第二把 key 复用同一个 DEK。
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/credentials",
            Some(&alice.access),
            Some(json!({ "vendor": "deepseek:cn", "api_key": "sk-ds-000000009999" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED);
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/credentials",
            Some(&alice.access),
            Some(json!({ "vendor": "custom", "api_key": "sk-x-12345678" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");

    let routes = json!({ "routes": [{ "alias": "main", "credential_id": cred_id, "upstream_model": "claude-sonnet" }] });
    let (st, body) = a
        .call(
            Method::PUT,
            &format!("/v1/instances/{inst}/routes"),
            Some(&alice.access),
            Some(routes.clone()),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["routes"][0]["alias"], "main");
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/credentials/{cred_id}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT, "still used by a route");

    // Bob 看不到 Alice 的实例和 key，也引用不了她的 key。
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (_, list) = a
        .call(Method::GET, "/v1/credentials", Some(&bob.access), None)
        .await;
    assert_eq!(list["credentials"].as_array().unwrap().len(), 0);
    let bob_inst = a.adopt(&bob).await;
    let (st, _) = a
        .call(
            Method::PUT,
            &format!("/v1/instances/{bob_inst}/routes"),
            Some(&bob.access),
            Some(routes),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);

    // 换 key：后 4 位变了，记录 id 不变。
    let (st, rotated) = a
        .call(
            Method::PUT,
            &format!("/v1/credentials/{cred_id}/secret"),
            Some(&alice.access),
            Some(json!({ "api_key": "sk-ant-secret-5678" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(rotated["last4"], "5678");

    // 删除实例：授权吊销、标记删除。
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/instances/{inst}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn runs_plans_and_approvals() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138000").await;
    let inst = a.adopt(&u).await;

    let (st, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            Some(&u.access),
            Some(json!({ "prompt": "summarize my inbox" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{run}");
    assert_eq!(run["state"], "queued");
    let run_id: RunId = run["id"].as_str().unwrap().parse().unwrap();
    let (st, runs) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/runs"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(runs["runs"].as_array().unwrap().len(), 1);
    let (st, cancelled) = a
        .call(
            Method::POST,
            &format!("/v1/runs/{run_id}/cancel"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(
        (st, cancelled["state"].as_str()),
        (StatusCode::OK, Some("cancelled"))
    );
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/runs/{run_id}/cancel"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::CONFLICT, Some("conflict"))
    );

    // 计划：规则校验、下一次触发时间、暂停与恢复、删除时吊销授权。
    let plan_req = |triggers: Value| json!({ "instance_id": inst, "title": "早报", "goal": "summarize the news", "triggers": triggers });
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/plans",
            Some(&u.access),
            Some(plan_req(
                json!([{ "kind": "cron", "expr": "* * * * *", "tz": "UTC" }]),
            )),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "too frequent: {body}");
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/plans",
            Some(&u.access),
            Some(plan_req(
                json!([{ "kind": "cron", "expr": "0 8 * * *", "tz": "Mars/Base" }]),
            )),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (st, plan) = a
        .call(
            Method::POST,
            "/v1/plans",
            Some(&u.access),
            Some(plan_req(
                json!([{ "kind": "cron", "expr": "0 8 * * *", "tz": "Asia/Shanghai" }]),
            )),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{plan}");
    assert_eq!(plan["triggers"].as_array().unwrap().len(), 1);
    assert!(
        plan["triggers"][0]["next_fire_at"]
            .as_str()
            .unwrap()
            .ends_with("T00:00:00Z")
    );
    let plan_id = plan["id"].as_str().unwrap().to_owned();
    let (_, paused) = a
        .call(
            Method::POST,
            &format!("/v1/plans/{plan_id}/pause"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(paused["paused"], true);
    let (_, resumed) = a
        .call(
            Method::POST,
            &format!("/v1/plans/{plan_id}/resume"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(resumed["paused"], false);
    let (st, updated) = a
        .call(
            Method::PATCH,
            &format!("/v1/plans/{plan_id}"),
            Some(&u.access),
            Some(json!({ "title": "晚报" })),
        )
        .await;
    assert_eq!(
        (st, updated["title"].as_str()),
        (StatusCode::OK, Some("晚报"))
    );
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/plans/{plan_id}"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let mut w = a.t.db.worker().await.unwrap();
    let plan_uuid: proto::domain::PlanId = plan_id.parse().unwrap();
    let grants: Vec<_> = {
        let mut tx =
            a.t.db
                .tenant(w.run_record(run_id).await.unwrap().user_id)
                .await
                .unwrap();
        let g = tx.run_grants(inst).await.unwrap();
        tx.rollback().await.unwrap();
        g
    };
    assert!(
        grants.iter().all(|g| g.plan_id != Some(plan_uuid)),
        "plan grant revoked"
    );

    // 审批：执行器建的审批出现在列表里，用户决定。
    let (_, run2) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            Some(&u.access),
            Some(json!({ "prompt": "clean up" })),
        )
        .await;
    let run2: RunId = run2["id"].as_str().unwrap().parse().unwrap();
    let rec = w.run_record(run2).await.unwrap();
    w.create_approval(&store::NewApproval {
        user: rec.user_id,
        instance: inst,
        run: run2,
        request_id: "p1",
        title: Some("Delete files"),
        options: &json!([{ "option_id": "allow", "name": "Allow", "kind": "allow_once" },
                         { "option_id": "deny", "name": "Deny", "kind": "reject_once" }]),
        tool_call: &json!({}),
        expires_in: Duration::from_secs(3600),
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    let (_, list) = a
        .call(Method::GET, "/v1/approvals", Some(&u.access), None)
        .await;
    let approval_id = list["approvals"][0]["id"].as_str().unwrap().to_owned();
    let (st, decided) = a
        .call(
            Method::POST,
            &format!("/v1/approvals/{approval_id}/decide"),
            Some(&u.access),
            Some(json!({ "option_id": "deny" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{decided}");
    assert_eq!(decided["state"], json!(ApprovalState::Rejected));
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/approvals/{approval_id}/decide"),
            Some(&u.access),
            Some(json!({ "option_id": "allow" })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT, "decided once");
}

async fn ws_connect(
    a: &Api,
    token: Option<&str>,
    inst: InstanceId,
    after: u64,
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    tungstenite::Error,
> {
    use tungstenite::client::IntoClientRequest;
    let url = format!(
        "{}/v1/instances/{inst}/events/ws?after={after}",
        a.base.replace("http", "ws")
    );
    let mut req = url.into_client_request().unwrap();
    if let Some(t) = token {
        req.headers_mut()
            .insert("authorization", format!("Bearer {t}").parse().unwrap());
    }
    tokio_tungstenite::connect_async(req).await.map(|(s, _)| s)
}

async fn next_event<S>(ws: &mut S) -> Value
where
    S: futures_util::Stream<Item = Result<tungstenite::Message, tungstenite::Error>> + Unpin,
{
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("an event in time")
            .unwrap()
            .unwrap();
        if let tungstenite::Message::Text(t) = msg {
            return serde_json::from_str(&t).unwrap();
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn event_stream_replays_then_streams_live() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138000").await;
    let inst = a.adopt(&u).await; // 领养时写了一条 instance.state 事件（seq 1）
    let append = |kind: &'static str, n: i64| {
        let db = a.t.db.clone();
        async move {
            let mut w = db.worker().await.unwrap();
            let ev = w
                .append_event(inst, None, kind, &json!({ "n": n }))
                .await
                .unwrap();
            w.commit().await.unwrap();
            ev.seq
        }
    };
    append("agent.message", 1).await;
    append("agent.message", 2).await;

    assert!(
        ws_connect(&a, None, inst, 0).await.is_err(),
        "needs a token"
    );
    let mut ws = ws_connect(&a, Some(&u.access), inst, 1).await.unwrap();
    let e2 = next_event(&mut ws).await;
    assert_eq!(
        (e2["type"].as_str(), e2["seq"].as_u64()),
        (Some("event"), Some(2))
    );
    assert_eq!(next_event(&mut ws).await["seq"], 3);
    // 实时：别的进程追加事件（提交时 pg_notify），连接被叫醒后推过来。
    let seq = append("run.state", 4).await;
    let live = next_event(&mut ws).await;
    assert_eq!(live["seq"].as_u64(), Some(seq));
    assert_eq!(live["payload"]["n"], 4);
    ws.close(None).await.ok();

    // 断线重连：带上最后的序号，只收之后的。
    append("agent.message", 5).await;
    let mut ws = ws_connect(&a, Some(&u.access), inst, seq).await.unwrap();
    assert_eq!(next_event(&mut ws).await["payload"]["n"], 5);

    // REST 分页补发。
    let (st, page) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/events?after=2&limit=2"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(page["events"].as_array().unwrap().len(), 2);
    assert_eq!(
        (page["oldest_seq"].as_u64(), page["latest_seq"].as_u64()),
        (Some(1), Some(5))
    );

    // 别人订阅不了。
    let bob = a.login("13900139000").await;
    assert!(ws_connect(&a, Some(&bob.access), inst, 0).await.is_err());

    // 会话被吊销：下一次心跳时以 4001 关闭。
    let (st, _) = a
        .call(Method::POST, "/v1/auth/logout", Some(&u.access), None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let closed = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(msg) = ws.next().await {
            if let Ok(tungstenite::Message::Close(Some(frame))) = msg {
                return Some(u16::from(frame.code));
            }
        }
        None
    })
    .await
    .unwrap();
    assert_eq!(closed, Some(4001));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn account_deletion_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138000").await;
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/me/code",
            Some(&u.access),
            Some(json!({ "purpose": "delete_account" })),
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let code = a.sms.last_code("+8613800138000").unwrap();
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/me/delete",
            Some(&u.access),
            Some(json!({ "code": code })),
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a.call(Method::GET, "/v1/me", Some(&u.access), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn teams_pipelines_and_artifacts() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138300").await;
    let other = a.login("13800138301").await;
    let tok = Some(u.access.as_str());
    let lead = a.adopt(&u).await;
    let writer = a.adopt(&u).await;
    let foreign = a.adopt(&other).await;

    // 团队（8.1）
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/teams",
            tok,
            Some(json!({ "name": "研究组", "members": [] })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    let (st, team) = a
        .call(
            Method::POST,
            "/v1/teams",
            tok,
            Some(json!({ "name": "研究组", "members": [
                { "instance_id": lead, "role": "lead", "position": 0 },
                { "instance_id": writer, "role": "member", "position": 1 },
            ] })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{team}");
    let team_id = team["id"].as_str().unwrap().to_owned();
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/teams",
            tok,
            Some(json!({ "name": "抢别人的", "members": [
                { "instance_id": foreign, "role": "lead", "position": 0 },
            ] })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND, "{body}");
    let (st, body) = a
        .call(
            Method::GET,
            &format!("/v1/teams/{team_id}"),
            Some(&other.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND, "{body}");
    let (st, body) = a
        .call(
            Method::PATCH,
            &format!("/v1/teams/{team_id}"),
            tok,
            Some(json!({ "name": "写作组" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["name"], "写作组");
    assert_eq!(body["members"].as_array().unwrap().len(), 2);

    // 团队模板：从现有团队生成，再一键领养。
    let (st, tpl) = a
        .call(
            Method::POST,
            "/v1/team-templates",
            tok,
            Some(json!({ "name": "写作组模板", "team_id": team_id })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{tpl}");
    assert_eq!(tpl["spec"]["members"].as_array().unwrap().len(), 2);
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/team-templates",
            tok,
            Some(json!({ "name": "坏模板", "spec": { "members": [
                { "agent_id": "no-such-agent", "name": "x" },
            ] } })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    let (st, adopted) = a
        .call(
            Method::POST,
            &format!("/v1/team-templates/{}/adopt", tpl["id"].as_str().unwrap()),
            tok,
            Some(json!({})),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{adopted}");
    let members = adopted["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    assert_eq!(members[0]["role"], "lead");
    assert_ne!(members[0]["instance_id"], json!(lead), "new instances");
    let (_, list) = a.call(Method::GET, "/v1/instances", tok, None).await;
    assert_eq!(list["instances"].as_array().unwrap().len(), 4);
    let (_, teams) = a.call(Method::GET, "/v1/teams", tok, None).await;
    assert_eq!(teams["teams"].as_array().unwrap().len(), 2);

    // 流水线计划（8.2）：步骤校验。
    let plan_with = |steps: Value| {
        json!({
            "instance_id": lead,
            "title": "周报",
            "goal": "写一份周报",
            "steps": steps,
        })
    };
    for (steps, why) in [
        (
            json!([
                { "key": "a", "instance_id": lead, "prompt": "x", "depends_on": ["b"] },
                { "key": "b", "instance_id": writer, "prompt": "y", "depends_on": ["a"] },
            ]),
            "cycle",
        ),
        (
            json!([{ "key": "Bad Key", "instance_id": lead, "prompt": "x" }]),
            "bad key",
        ),
        (
            json!([{ "key": "a", "instance_id": lead, "prompt": "x", "depends_on": ["zz"] }]),
            "unknown dependency",
        ),
        (
            json!([{ "key": "a", "instance_id": lead, "prompt": " " }]),
            "empty prompt",
        ),
    ] {
        let (st, body) = a
            .call(Method::POST, "/v1/plans", tok, Some(plan_with(steps)))
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{why}: {body}");
    }
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/plans",
            tok,
            Some(plan_with(
                json!([{ "key": "a", "instance_id": foreign, "prompt": "x" }]),
            )),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND, "{body}");
    let (st, plan) = a
        .call(
            Method::POST,
            "/v1/plans",
            tok,
            Some(plan_with(json!([
                { "key": "research", "instance_id": lead, "prompt": "查资料" },
                { "key": "write", "instance_id": writer, "prompt": "写稿", "depends_on": ["research"] },
            ]))),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{plan}");
    assert_eq!(plan["steps"].as_array().unwrap().len(), 2);
    assert_eq!(plan["steps"][1]["depends_on"], json!(["research"]));
    let plan_path = format!("/v1/plans/{}", plan["id"].as_str().unwrap());
    let (st, body) = a
        .call(Method::PATCH, &plan_path, tok, Some(json!({ "steps": [] })))
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["steps"], json!([]));

    // 产出物（8.4）：worker 发布，客户端列出、下载、删除。
    let (st, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{lead}/runs"),
            tok,
            Some(json!({ "prompt": "写个报告" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{run}");
    let run_id: RunId = run["id"].as_str().unwrap().parse().unwrap();
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let published = a
        .artifacts
        .publish(
            Origin {
                user,
                instance: lead,
                run: run_id,
                root: run_id,
            },
            "report.md",
            "text/markdown",
            "# 周报\n".as_bytes(),
        )
        .await
        .unwrap();
    let art_id = published.artifact.id.to_string();
    let (st, list) = a
        .call(
            Method::GET,
            &format!("/v1/runs/{run_id}/artifacts"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(list["artifacts"][0]["name"], "report.md");
    let (_, list) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{lead}/artifacts"),
            tok,
            None,
        )
        .await;
    assert_eq!(list["artifacts"].as_array().unwrap().len(), 1);
    let resp = a
        .http
        .get(format!("{}/v1/artifacts/{art_id}/content", a.base))
        .bearer_auth(&u.access)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(resp.headers()["content-disposition"], "attachment");
    assert_eq!(resp.headers()["x-content-type-options"], "nosniff");
    // AI 生成内容标识：隐式（元数据头）+ 显式（Markdown 末尾一行）。
    let meta: Value = serde_json::from_str(resp.headers()["x-aigc"].to_str().unwrap()).unwrap();
    assert_eq!(
        meta,
        json!({ "Label": "1", "ContentProducer": "ThinkTin", "ProduceID": art_id })
    );
    assert_eq!(
        resp.text().await.unwrap(),
        format!("# 周报\n{}", proto::labels::text_footer("ThinkTin"))
    );
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/artifacts/{art_id}/content"),
            Some(&other.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND, "other users cannot download");
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/artifacts/{art_id}"),
            Some(&other.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/artifacts/{art_id}"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a
        .call(Method::GET, &format!("/v1/artifacts/{art_id}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);

    // 停掉整棵运行树（8.2）。
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/runs/{run_id}/cancel?tree=true"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["state"], "cancelled");

    // 删除团队不影响实例。
    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/teams/{team_id}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a
        .call(Method::GET, &format!("/v1/instances/{lead}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn inbox_over_http() {
    use notify::PushKind;
    use orchestrator::outbox::{Notice, notify};

    let Some(a) = api().await else { return };
    let u = a.login("13800138400").await;
    let other = a.login("13800138401").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let mut w = a.t.db.worker().await.unwrap();
    for n in 0..3 {
        let notice = Notice {
            instance: Some(inst),
            dedupe_key: Some(format!("n{n}")),
            ..Notice::new(PushKind::RunFinished, format!("早报 {n}"), "完成")
        };
        notify(&mut w, user, &notice).await.unwrap();
        notify(&mut w, user, &notice).await.unwrap();
    }
    w.commit().await.unwrap();

    let (st, body) = a.call(Method::GET, "/v1/inbox", tok, None).await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["unread"], 3, "one item per notice");
    let items = body["items"].as_array().unwrap().clone();
    assert_eq!(items[0]["title"], "早报 2");
    assert_eq!(items[0]["kind"], "run_finished");
    assert_eq!(items[0]["instance_id"], json!(inst));
    let first = items[0]["id"].as_str().unwrap().to_owned();
    let (_, page) = a
        .call(
            Method::GET,
            &format!("/v1/inbox?limit=1&before={first}"),
            tok,
            None,
        )
        .await;
    assert_eq!(page["items"][0]["title"], "早报 1");

    let (_, body) = a
        .call(Method::GET, "/v1/inbox", Some(&other.access), None)
        .await;
    assert_eq!(body["items"], json!([]));
    assert_eq!(body["unread"], 0);
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/inbox/{first}"),
            Some(&other.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);

    let (st, body) = a
        .call(
            Method::POST,
            "/v1/inbox/read",
            tok,
            Some(json!({ "ids": [first] })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(
        (body["marked"].clone(), body["unread"].clone()),
        (json!(1), json!(2))
    );
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/inbox/read",
            tok,
            Some(json!({ "ids": [first], "up_to": first })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (_, body) = a
        .call(Method::GET, &format!("/v1/inbox/{first}"), tok, None)
        .await;
    assert_eq!(body["read"], true);
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/inbox/{first}/unread"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, body) = a
        .call(Method::POST, "/v1/inbox/read", tok, Some(json!({})))
        .await;
    assert_eq!(
        (body["marked"].clone(), body["unread"].clone()),
        (json!(3), json!(0))
    );
    let (_, body) = a
        .call(Method::GET, "/v1/inbox?unread=true", tok, None)
        .await;
    assert_eq!(body["items"], json!([]));
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/inbox/{first}"),
            Some(&other.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/inbox/{first}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, body) = a.call(Method::GET, "/v1/inbox", tok, None).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 2);
}

/// 跨用户访问（15.2）：别人的每一类对象，按 id 读、改、删、操作都当作不存在；列表里也看不到。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn other_users_objects_are_invisible() {
    use orchestrator::artifacts::Origin;

    let Some(a) = api().await else { return };
    let owner = a.login("13800138700").await;
    let thief = a.login("13800138701").await;
    let tok = Some(owner.access.as_str());
    let inst = a.adopt(&owner).await;
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();

    // 主人的各类对象。
    let (_, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            tok,
            Some(json!({ "prompt": "hi" })),
        )
        .await;
    let run = run["id"].as_str().unwrap().to_owned();
    let (_, plan) = a
        .call(
            Method::POST,
            "/v1/plans",
            tok,
            Some(json!({ "instance_id": inst, "title": "t", "goal": "g",
                "triggers": [{ "kind": "cron", "expr": "0 8 * * *", "tz": "Asia/Shanghai" }] })),
        )
        .await;
    let trigger = plan["triggers"][0]["id"].as_str().unwrap().to_owned();
    let plan = plan["id"].as_str().unwrap().to_owned();
    let (_, cred) = a
        .call(
            Method::POST,
            "/v1/credentials",
            tok,
            Some(json!({ "vendor": "deepseek", "api_key": "sk-0123456789abcdef" })),
        )
        .await;
    let cred = cred["id"].as_str().unwrap().to_owned();
    let (_, team) = a
        .call(
            Method::POST,
            "/v1/teams",
            tok,
            Some(json!({ "name": "t", "members": [{ "instance_id": inst, "role": "lead", "position": 0 }] })),
        )
        .await;
    let team = team["id"].as_str().unwrap().to_owned();
    let (_, tpl) = a
        .call(
            Method::POST,
            "/v1/team-templates",
            tok,
            Some(json!({ "name": "t", "team_id": team })),
        )
        .await;
    let tpl = tpl["id"].as_str().unwrap().to_owned();
    let run_id: RunId = run.parse().unwrap();
    let art = a
        .artifacts
        .publish(
            Origin {
                user,
                instance: inst,
                run: run_id,
                root: run_id,
            },
            "a.txt",
            "text/plain",
            b"secret",
        )
        .await
        .unwrap()
        .artifact
        .id
        .to_string();
    let mut w = a.t.db.worker().await.unwrap();
    let inbox = w
        .insert_inbox(
            user,
            &store::NewInboxItem {
                kind: "info".into(),
                title: "t".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .unwrap()
        .to_string();
    w.commit().await.unwrap();
    let approval = {
        let mut w = a.t.db.worker().await.unwrap();
        let rec = w
            .create_approval(&store::NewApproval {
                user,
                instance: inst,
                run: run_id,
                request_id: "r1",
                title: Some("t"),
                options: &json!([{ "option_id": "allow", "name": "Allow", "kind": "allow_once" }]),
                tool_call: &json!({}),
                expires_in: Duration::from_secs(600),
            })
            .await
            .unwrap();
        w.commit().await.unwrap();
        rec.approval.id.to_string()
    };

    let t2 = Some(thief.access.as_str());
    let cases: Vec<(Method, String, Option<Value>)> = vec![
        (Method::GET, format!("/v1/instances/{inst}"), None),
        (
            Method::PATCH,
            format!("/v1/instances/{inst}"),
            Some(json!({ "name": "x" })),
        ),
        (Method::DELETE, format!("/v1/instances/{inst}"), None),
        (Method::GET, format!("/v1/instances/{inst}/routes"), None),
        (
            Method::POST,
            format!("/v1/instances/{inst}/version"),
            Some(json!({})),
        ),
        (
            Method::PUT,
            format!("/v1/instances/{inst}/routes"),
            Some(json!({ "routes": [] })),
        ),
        (Method::GET, format!("/v1/instances/{inst}/runs"), None),
        (
            Method::POST,
            format!("/v1/instances/{inst}/runs"),
            Some(json!({ "prompt": "steal" })),
        ),
        (Method::GET, format!("/v1/instances/{inst}/events"), None),
        (Method::GET, format!("/v1/instances/{inst}/artifacts"), None),
        (Method::GET, format!("/v1/runs/{run}"), None),
        (Method::POST, format!("/v1/runs/{run}/cancel"), None),
        (
            Method::POST,
            format!("/v1/runs/{run}/cancel?tree=true"),
            None,
        ),
        (Method::GET, format!("/v1/runs/{run}/tree"), None),
        (Method::GET, format!("/v1/runs/{run}/artifacts"), None),
        (Method::GET, format!("/v1/plans/{plan}"), None),
        (
            Method::PATCH,
            format!("/v1/plans/{plan}"),
            Some(json!({ "title": "x" })),
        ),
        (Method::DELETE, format!("/v1/plans/{plan}"), None),
        (Method::POST, format!("/v1/plans/{plan}/pause"), None),
        (Method::POST, format!("/v1/plans/{plan}/resume"), None),
        (
            Method::POST,
            format!("/v1/plans/{plan}/triggers"),
            Some(json!({ "spec": { "kind": "cron", "expr": "0 9 * * *", "tz": "Asia/Shanghai" } })),
        ),
        (Method::DELETE, format!("/v1/triggers/{trigger}"), None),
        (
            Method::POST,
            format!("/v1/approvals/{approval}/decide"),
            Some(json!({ "option_id": "allow" })),
        ),
        (
            Method::PATCH,
            format!("/v1/credentials/{cred}"),
            Some(json!({ "label": "x" })),
        ),
        (
            Method::PUT,
            format!("/v1/credentials/{cred}/secret"),
            Some(json!({ "api_key": "sk-stolen-0000000" })),
        ),
        (Method::DELETE, format!("/v1/credentials/{cred}"), None),
        (Method::GET, format!("/v1/teams/{team}"), None),
        (
            Method::PATCH,
            format!("/v1/teams/{team}"),
            Some(json!({ "name": "x" })),
        ),
        (Method::DELETE, format!("/v1/teams/{team}"), None),
        (Method::DELETE, format!("/v1/team-templates/{tpl}"), None),
        (
            Method::POST,
            format!("/v1/team-templates/{tpl}/adopt"),
            Some(json!({})),
        ),
        (Method::GET, format!("/v1/artifacts/{art}"), None),
        (Method::GET, format!("/v1/artifacts/{art}/content"), None),
        (Method::DELETE, format!("/v1/artifacts/{art}"), None),
        (Method::GET, format!("/v1/inbox/{inbox}"), None),
        (Method::POST, format!("/v1/inbox/{inbox}/unread"), None),
        (Method::DELETE, format!("/v1/inbox/{inbox}"), None),
    ];
    for (method, path, body) in cases {
        let (st, resp) = a.call(method.clone(), &path, t2, body).await;
        assert_eq!(st, StatusCode::NOT_FOUND, "{method} {path}: {resp}");
    }
    // 用别人的实例建计划、组团队也不行。
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/plans",
            t2,
            Some(json!({ "instance_id": inst, "title": "t", "goal": "g" })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    // 批量标已读碰不到别人的条目。
    let (_, r) = a
        .call(
            Method::POST,
            "/v1/inbox/read",
            t2,
            Some(json!({ "ids": [inbox] })),
        )
        .await;
    assert_eq!(r["marked"], 0);
    // 列表里看不到。
    for path in [
        "/v1/instances",
        "/v1/plans",
        "/v1/approvals",
        "/v1/credentials",
        "/v1/teams",
        "/v1/team-templates",
        "/v1/inbox",
    ] {
        let (st, body) = a.call(Method::GET, path, t2, None).await;
        assert_eq!(st, StatusCode::OK, "{path}");
        let list = body
            .as_object()
            .unwrap()
            .values()
            .find_map(Value::as_array)
            .unwrap();
        assert!(list.is_empty(), "{path}: {body}");
    }
    // 事件流也连不上。
    let r = a
        .http
        .get(format!("{}/v1/instances/{inst}/events/ws", a.base))
        .bearer_auth(&thief.access)
        .header("connection", "upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-version", "13")
        .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::NOT_FOUND);

    // 主人的东西都还在，一样没被改。
    let (st, i) = a
        .call(Method::GET, &format!("/v1/instances/{inst}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(i["name"], "My Claude");
    let (_, p) = a
        .call(Method::GET, &format!("/v1/plans/{plan}"), tok, None)
        .await;
    assert_eq!(p["title"], "t");
    assert_eq!(p["paused"], false);
    let (_, list) = a.call(Method::GET, "/v1/approvals", tok, None).await;
    assert_eq!(list["approvals"].as_array().unwrap().len(), 1);
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/artifacts/{art}/content"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK);
}

/// 升级、回滚（6.7）：换到存在的版本，下次唤醒时重建；不存在的版本拒绝。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn instance_versions_can_be_switched() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138800").await;
    let tok = Some(u.access.as_str());
    let (_, agents) = a.call(Method::GET, "/v1/agents", None, None).await;
    let claude = agents["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "claude")
        .unwrap()
        .clone();
    assert_eq!(claude["versions"][0], claude["version"], "current first");
    let inst = a.adopt(&u).await;
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/version"),
            tok,
            Some(json!({ "version": "0.0.0-nope" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/version"),
            tok,
            Some(json!({})),
        )
        .await;
    assert_eq!(st, StatusCode::ACCEPTED, "{body}");
    assert_eq!(body["agent_version"], claude["version"]);
    let mut w = a.t.db.worker().await.unwrap();
    assert!(w.instance_runtime(inst).await.unwrap().rebuild_pending);
    w.rollback().await.unwrap();
}

/// 用量看板（9.10）：按天（用户时区）、实例、模型汇总自己的用量；看不到别人的。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn usage_is_summarised_per_day_instance_and_model() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138900").await;
    let other = a.login("13800138901").await;
    let tok = Some(u.access.as_str());
    let i1 = a.adopt(&u).await;
    let i2 = a.adopt(&u).await;
    let foreign = a.adopt(&other).await;
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let (_, them) = a
        .call(Method::GET, "/v1/me", Some(&other.access), None)
        .await;
    let them: UserId = them["id"].as_str().unwrap().parse().unwrap();
    // (用户, 实例, 模型, 计费 token, 时间)
    let rows = [
        (user, i1, "deepseek-chat", 100, "2026-10-13T10:00:00Z"),
        // 上海时间 10 月 14 日凌晨。
        (user, i1, "deepseek-chat", 50, "2026-10-13T17:00:00Z"),
        (user, i2, "glm-4.6", 30, "2026-10-14T03:00:00Z"),
        (them, foreign, "deepseek-chat", 999, "2026-10-14T03:00:00Z"),
    ];
    for (who, inst, model, charged, at) in rows {
        let mut w = a.t.db.worker().await.unwrap();
        w.insert_usage(&store::NewUsage {
            user: who,
            instance: inst,
            alias: "main".into(),
            vendor: "v".into(),
            upstream_model: model.into(),
            endpoint: "chat".into(),
            status: 200,
            outcome: "complete".into(),
            input_tokens: charged,
            charged_tokens: charged,
            ..Default::default()
        })
        .await
        .unwrap();
        w.commit().await.unwrap();
        sqlx::query("UPDATE usage_records SET created_at = $1::timestamptz WHERE created_at > now() - interval '1 minute' AND charged_tokens = $2")
            .bind(at)
            .bind(charged as i64)
            .execute(a.t.db.pool())
            .await
            .unwrap();
    }
    let range = "from=2026-10-01T00:00:00Z&to=2026-10-20T00:00:00Z";
    let (st, body) = a
        .call(Method::GET, &format!("/v1/usage?{range}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    let days: Vec<(String, u64)> = body["buckets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| {
            (
                b["key"].as_str().unwrap().to_owned(),
                b["charged_tokens"].as_u64().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        days,
        [
            ("2026-10-13".to_string(), 100),
            ("2026-10-14".to_string(), 80)
        ],
        "days follow Asia/Shanghai"
    );
    assert_eq!(body["total"]["charged_tokens"], 180, "other users excluded");
    assert_eq!(body["total"]["requests"], 3);
    let (_, utc) = a
        .call(Method::GET, &format!("/v1/usage?{range}&tz=UTC"), tok, None)
        .await;
    assert_eq!(utc["buckets"][0]["charged_tokens"], 150);
    let (_, by_model) = a
        .call(
            Method::GET,
            &format!("/v1/usage?{range}&group=model"),
            tok,
            None,
        )
        .await;
    assert_eq!(by_model["buckets"][0]["key"], "v/deepseek-chat");
    assert_eq!(by_model["buckets"][0]["charged_tokens"], 150);
    let (_, one) = a
        .call(
            Method::GET,
            &format!("/v1/usage?{range}&group=instance&instance_id={i2}"),
            tok,
            None,
        )
        .await;
    assert_eq!(one["buckets"].as_array().unwrap().len(), 1);
    assert_eq!(one["buckets"][0]["key"], i2.to_string());
    for bad in [
        "group=week".to_string(),
        "tz=Mars/Olympus".to_string(),
        "from=2026-10-20T00:00:00Z&to=2026-10-01T00:00:00Z".to_string(),
        "from=2024-01-01T00:00:00Z&to=2026-01-01T00:00:00Z".to_string(),
    ] {
        let (st, _) = a
            .call(Method::GET, &format!("/v1/usage?{bad}"), tok, None)
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad}");
    }
}

/// agent 安排的计划：确认要带上看到的版本；之后又被改过就 409；确认后 agent 签的子授权换成用户签发的授权。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agent_plans_are_confirmed_by_revision() {
    use proto::domain::{CatchUp, GrantScope, PlanAuthor, PlanPolicy, ScheduleSpec};

    let Some(a) = api().await else { return };
    let u = a.login("13800138950").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    // 模拟 agent 在一次运行里建了计划（和 thinktin.schedule 走的同一套存储操作）。
    let mut t = a.t.db.tenant(user).await.unwrap();
    let caller = t
        .create_run_grant(
            inst,
            None,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let plan = t
        .create_plan(&store::NewPlan {
            instance_id: inst,
            title: "早报".into(),
            goal: "news".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::Agent,
            run_grant_id: None,
        })
        .await
        .unwrap();
    let child = t
        .create_plan_child_grant(
            caller.id,
            inst,
            plan.id,
            Duration::from_secs(90 * 24 * 3600),
        )
        .await
        .unwrap();
    t.set_plan_grant(plan.id, child.id).await.unwrap();
    t.add_trigger(
        plan.id,
        &ScheduleSpec::Cron {
            expr: "0 8 * * *".into(),
            tz: "Asia/Shanghai".into(),
        },
        None,
    )
    .await
    .unwrap();
    let shown = t.request_plan_confirmation(plan.id).await.unwrap();
    t.commit().await.unwrap();
    let path = format!("/v1/plans/{}", plan.id);

    let (st, v) = a.call(Method::GET, &path, tok, None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(v["awaiting_confirmation"], true);
    assert_eq!(v["revision"], shown.revision);
    // 不能绕过确认直接恢复。
    let (st, _) = a
        .call(Method::POST, &format!("{path}/resume"), tok, None)
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    // agent 在用户看完之后又改了一次：用户确认的旧版本被拒。
    let mut t = a.t.db.tenant(user).await.unwrap();
    t.request_plan_confirmation(plan.id).await.unwrap();
    t.commit().await.unwrap();
    let (st, _) = a
        .call(
            Method::POST,
            &format!("{path}/confirm"),
            tok,
            Some(json!({ "revision": shown.revision })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (_, v) = a.call(Method::GET, &path, tok, None).await;
    let (st, v) = a
        .call(
            Method::POST,
            &format!("{path}/confirm"),
            tok,
            Some(json!({ "revision": v["revision"] })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{v}");
    assert_eq!(
        (v["paused"].as_bool(), v["awaiting_confirmation"].as_bool()),
        (Some(false), Some(false))
    );
    assert!(v["triggers"][0]["next_fire_at"].is_string());
    // 子授权换成了用户签发的顶层授权，旧的吊销。
    let mut t = a.t.db.tenant(user).await.unwrap();
    let g = t.plan_grant(plan.id).await.unwrap().unwrap();
    assert_eq!(g.parent_id, None);
    assert!(g.is_active(chrono::Utc::now()));
    assert!(
        t.run_grants(inst)
            .await
            .unwrap()
            .iter()
            .all(|x| x.id != child.id)
    );
    t.rollback().await.unwrap();
    // 已经确认过的不能再确认。
    let (st, _) = a
        .call(
            Method::POST,
            &format!("{path}/confirm"),
            tok,
            Some(json!({ "revision": v["revision"] })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
}
