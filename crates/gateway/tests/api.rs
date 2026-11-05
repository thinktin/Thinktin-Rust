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
use gateway::{AppState, EventHub, GatewayConfig, Inner, LimitConfig};
use keyvault::secrecy::ExposeSecret;
use keyvault::{KeyStore, KeyVault, LocalKms, MemoryKeyStore, SealedSecret, WrappedKey};
use orchestrator::artifacts::{ArtifactStore, LocalBlobStore, Origin};
use proto::domain::{ApprovalState, InstanceId, PlanId, RunId, RunSource, RunState, UserId};
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
    api_with(GatewayConfig {
        ws_heartbeat: Duration::from_millis(300),
        cross_user_projects: true,
        ..GatewayConfig::default()
    })
    .await
}

async fn api_with(cfg: GatewayConfig) -> Option<Api> {
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
        cfg,
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
    let claude = agents["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "claude")
        .unwrap()
        .clone();
    assert_eq!(claude["active_protocol"], "anthropic");

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
    assert_eq!(
        cred["protocols"],
        json!(proto::vendors::vendor("anthropic").unwrap().protocols())
    );
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
        .await
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
            .await
            .is_err(),
        "ciphertext is bound to its record"
    );
    // 第二把 key 复用同一个 DEK。
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/credentials",
            Some(&alice.access),
            Some(json!({ "vendor": "deepseek", "api_key": "sk-ds-000000009999" })),
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
    // 自定义端点：配了哪几个地址就能用哪几种协议（地址本身不返回）。
    let (st, custom) = a
        .call(
            Method::POST,
            "/v1/credentials",
            Some(&alice.access),
            Some(json!({
                "vendor": "custom",
                "api_key": "sk-x-12345678",
                "anthropic_base": "https://llm.example.com/anthropic"
            })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{custom}");
    assert_eq!(custom["protocols"], json!(["anthropic"]));
    assert!(!custom.to_string().contains("llm.example.com"));

    // 预置厂商（9.12）：App 从这里选；不认识的厂商、订阅类 key、套餐专用地址都拒绝。
    let (st, vendors) = a.call(Method::GET, "/v1/vendors", None, None).await;
    assert_eq!(st, StatusCode::OK, "{vendors}");
    let ids: Vec<&str> = vendors["vendors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["id"].as_str().unwrap())
        .collect();
    for id in ["anthropic", "openai", "deepseek", "doubao-cn", "hunyuan-cn"] {
        assert!(ids.contains(&id), "{id} missing from {ids:?}");
    }
    assert_eq!(vendors["custom"], "custom");
    // 每家带上订阅类 key 的前缀和套餐专用地址（11.9），和服务端检查的是同一份：按它们填的都被拒绝。
    for v in proto::vendors::VENDORS {
        let entry = vendors["vendors"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["id"] == v.id)
            .unwrap();
        assert_eq!(
            entry["subscription_key_prefixes"],
            json!(v.subscription_key_prefixes)
        );
        assert_eq!(entry["plan_only_bases"], json!(v.plan_only_bases));
        for prefix in v.subscription_key_prefixes {
            let (st, body) = a
                .call(
                    Method::POST,
                    "/v1/credentials",
                    Some(&alice.access),
                    Some(json!({ "vendor": v.id, "api_key": format!("{prefix}0000000000000000") })),
                )
                .await;
            assert_eq!(
                st,
                StatusCode::UNPROCESSABLE_ENTITY,
                "{} {prefix}: {body}",
                v.id
            );
        }
        for base in v.plan_only_bases {
            let (st, body) = a
                .call(
                    Method::POST,
                    "/v1/credentials",
                    Some(&alice.access),
                    Some(json!({ "vendor": "custom", "api_key": "sk-x-12345678", "openai_base": format!("{base}/v3") })),
                )
                .await;
            assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{base}: {body}");
        }
    }
    let deepseek = &vendors["vendors"].as_array().unwrap()[0];
    assert_eq!(
        (&deepseek["id"], &deepseek["plan_only_bases"]),
        (&json!("deepseek"), &json!([]))
    );
    for bad in [
        json!({ "vendor": "deepseek:cn", "api_key": "sk-ds-000000009999" }),
        json!({ "vendor": "anthropic", "api_key": "sk-ant-oat01-0000000000000000" }),
        json!({ "vendor": "hunyuan-cn", "api_key": "sk-tp-0000000000000000" }),
        json!({
            "vendor": "custom",
            "api_key": "sk-x-12345678",
            "openai_base": "https://ark.cn-beijing.volces.com/api/coding/v3"
        }),
    ] {
        let (st, body) = a
            .call(
                Method::POST,
                "/v1/credentials",
                Some(&alice.access),
                Some(bad.clone()),
            )
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad} -> {body}");
    }

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
    // 删了的实例的别名不再占着 key（11.9）：实例在的时候删 key 是 409，现在可以删。
    let (st, body) = a
        .call(
            Method::DELETE,
            &format!("/v1/credentials/{cred_id}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT, "{body}");
}

/// key 的每日上限可以改、可以取消（11.9）：放宽、取消时等 key 的运行接着跑，调低时不动；每次都记审计。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn credential_daily_limit_is_editable() {
    use proto::domain::RunState;
    let Some(a) = api().await else { return };
    let u = a.login("13800138032").await;
    let tok = Some(u.access.as_str());
    let (st, cred) = a
        .call(
            Method::POST,
            "/v1/credentials",
            tok,
            Some(json!({ "vendor": "deepseek", "api_key": "sk-0123456789abcdef", "daily_token_limit": 1000 })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{cred}");
    let path = format!("/v1/credentials/{}", cred["id"].as_str().unwrap());
    let patch = |body: Value| {
        let (a, path) = (&a, path.clone());
        async move { a.call(Method::PATCH, &path, tok, Some(body)).await }
    };
    let (st, body) = patch(json!({ "daily_token_limit": 5000 })).await;
    assert_eq!(
        (st, &body["daily_token_limit"]),
        (StatusCode::OK, &json!(5000))
    );
    // 只改名字：上限不动（不带不是取消）。
    let (_, body) = patch(json!({ "label": "备用" })).await;
    assert_eq!(body["daily_token_limit"], 5000);
    for bad in [
        json!(0),
        json!(-1),
        json!(1.5),
        json!("100"),
        json!(9223372036854775808u64),
    ] {
        let (st, body) = patch(json!({ "daily_token_limit": bad })).await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad}: {body}");
    }
    // 等 key 的运行：调低不唤醒，取消上限唤醒。
    let inst = a.adopt(&u).await;
    let (_, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            tok,
            Some(json!({ "prompt": "x" })),
        )
        .await;
    let run_id: RunId = run["id"].as_str().unwrap().parse().unwrap();
    let mut w = a.t.db.worker().await.unwrap();
    w.claim_next_run("n1", Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    w.transition_run(
        run_id,
        "n1",
        RunState::Running,
        &store::RunChange::default(),
    )
    .await
    .unwrap();
    w.transition_run(
        run_id,
        "n1",
        RunState::WaitingQuota,
        &store::RunChange {
            not_before: Some(chrono::Utc::now() + chrono::Duration::hours(1)),
            release_lease: true,
            wait_code: Some("unavailable"),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let waiting = || async {
        sqlx::query_scalar::<_, bool>("SELECT not_before > now() FROM runs WHERE id = $1")
            .bind(run_id.0)
            .fetch_one(a.t.db.pool())
            .await
            .unwrap()
    };
    let (st, _) = patch(json!({ "daily_token_limit": 100 })).await;
    assert_eq!(st, StatusCode::OK);
    assert!(waiting().await, "lowering the limit does not wake runs");
    let (st, body) = patch(json!({ "daily_token_limit": null })).await;
    assert_eq!(
        (st, &body["daily_token_limit"]),
        (StatusCode::OK, &Value::Null)
    );
    assert!(!waiting().await, "clearing the limit wakes runs");
    let audit: Vec<(String, Value)> = sqlx::query_as(
        "SELECT action, detail FROM audit_log WHERE target = $1 AND action = 'credential.limit' ORDER BY id",
    )
    .bind(cred["id"].as_str().unwrap())
    .fetch_all(a.t.db.pool())
    .await
    .unwrap();
    let details: Vec<Value> = audit.into_iter().map(|(_, d)| d).collect();
    assert_eq!(
        details,
        [
            json!({ "daily_token_limit": 5000, "previous": 1000 }),
            json!({ "daily_token_limit": 100, "previous": 5000 }),
            json!({ "daily_token_limit": null, "previous": 100 }),
        ]
    );
}

/// 删除实例时一并处理它的计划（11.9）：它自己的计划没了；别的实例的流水线有一步在它上面的暂停，改了步骤才能恢复。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deleting_an_instance_deletes_its_plans_and_pauses_pipelines() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138031").await;
    let (gone, stays) = (a.adopt(&u).await, a.adopt(&u).await);
    let tok = Some(u.access.as_str());
    let triggers = json!([{ "kind": "cron", "expr": "0 8 * * *", "tz": "Asia/Shanghai" }]);
    let create = |body: Value| {
        let a = &a;
        async move {
            let (st, plan) = a.call(Method::POST, "/v1/plans", tok, Some(body)).await;
            assert_eq!(st, StatusCode::CREATED, "{plan}");
            plan["id"].as_str().unwrap().to_owned()
        }
    };
    let own =
        create(json!({ "instance_id": gone, "title": "早报", "goal": "g", "triggers": triggers }))
            .await;
    let pipeline = create(json!({
        "instance_id": stays, "title": "周报", "goal": "g", "triggers": triggers,
        "steps": [
            { "key": "r", "instance_id": gone, "prompt": "查资料" },
            { "key": "w", "instance_id": stays, "prompt": "写稿", "depends_on": ["r"] },
        ],
    }))
    .await;
    let other =
        create(json!({ "instance_id": stays, "title": "晚报", "goal": "g", "triggers": triggers }))
            .await;

    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/instances/{gone}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, list) = a.call(Method::GET, "/v1/plans", tok, None).await;
    let by_id = |id: &str| {
        list["plans"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == id)
            .cloned()
    };
    assert!(by_id(&own).is_none(), "{list}");
    let paused = by_id(&pipeline).unwrap();
    assert_eq!(
        (&paused["paused"], &paused["next_fire_at"]),
        (&json!(true), &Value::Null)
    );
    assert_eq!(by_id(&other).unwrap()["paused"], false);
    let (_, mine) = a
        .call(
            Method::GET,
            &format!("/v1/plans?instance_id={gone}"),
            tok,
            None,
        )
        .await;
    assert_eq!(mine["plans"], json!([]));
    for (method, path) in [
        (Method::GET, format!("/v1/plans/{own}")),
        (Method::POST, format!("/v1/plans/{own}/resume")),
    ] {
        let (st, body) = a.call(method, &path, tok, None).await;
        assert_eq!(st, StatusCode::NOT_FOUND, "{path}: {body}");
    }
    // 流水线：步骤还在已删除的实例上时不能恢复；改掉那一步就行。
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/plans/{pipeline}/resume"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT, "{body}");
    assert!(
        body["message"].as_str().unwrap().contains("step r"),
        "{body}"
    );
    let (st, body) = a
        .call(
            Method::PATCH,
            &format!("/v1/plans/{pipeline}"),
            tok,
            Some(json!({ "steps": [{ "key": "w", "instance_id": stays, "prompt": "写稿" }] })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/plans/{pipeline}/resume"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert!(body["next_fire_at"].is_string(), "{body}");
    // 审计里记着处理了哪些计划。
    let details: Value = sqlx::query_scalar(
        "SELECT detail FROM audit_log WHERE action = 'instance.delete' AND target = $1",
    )
    .bind(gone.to_string())
    .fetch_one(a.t.db.pool())
    .await
    .unwrap();
    assert_eq!(
        details,
        json!({ "plans_deleted": [own], "plans_paused": [pipeline] })
    );
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
    // 跨实例的列表：全部、没结束的。
    let count = |path: &'static str| {
        let a = &a;
        let tok = u.access.clone();
        async move {
            let (st, body) = a.call(Method::GET, path, Some(&tok), None).await;
            assert_eq!(st, StatusCode::OK, "{body}");
            body["runs"].as_array().unwrap().len()
        }
    };
    assert_eq!(
        (count("/v1/runs").await, count("/v1/runs?active=true").await),
        (1, 1)
    );
    let (st, _) = a
        .call(Method::GET, "/v1/runs?plan_id=nope", Some(&u.access), None)
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
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
    assert_eq!(
        (count("/v1/runs").await, count("/v1/runs?active=true").await),
        (1, 0)
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
    assert_eq!(plan["next_fire_at"], plan["triggers"][0]["next_fire_at"]);
    // 列表里也有触发器、下次运行时间（之前列表里是空的）。
    let listed = |tok: String| {
        let a = &a;
        let plan_id = plan_id.clone();
        async move {
            let (_, body) = a.call(Method::GET, "/v1/plans", Some(&tok), None).await;
            body["plans"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["id"] == plan_id.as_str())
                .unwrap()
                .clone()
        }
    };
    let row = listed(u.access.clone()).await;
    assert_eq!(row["triggers"].as_array().unwrap().len(), 1);
    assert_eq!(
        (row["next_fire_at"].clone(), row["invalid_triggers"].clone()),
        (plan["triggers"][0]["next_fire_at"].clone(), json!(0))
    );
    let (_, paused) = a
        .call(
            Method::POST,
            &format!("/v1/plans/{plan_id}/pause"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(paused["paused"], true);
    assert!(listed(u.access.clone()).await["next_fire_at"].is_null());
    let (_, resumed) = a
        .call(
            Method::POST,
            &format!("/v1/plans/{plan_id}/resume"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(resumed["paused"], false);
    assert!(listed(u.access.clone()).await["next_fire_at"].is_string());
    // 规则后来解析不了了（时区没了）：恢复时停用它、说明原因，列表里提示有几个失效的。
    sqlx::query(
        "UPDATE triggers SET spec = '{\"kind\":\"cron\",\"expr\":\"0 8 * * *\",\"tz\":\"Mars/Base\"}' \
         WHERE plan_id = $1::uuid",
    )
    .bind(&plan_id)
    .execute(a.t.db.pool())
    .await
    .unwrap();
    for action in ["pause", "resume"] {
        a.call(
            Method::POST,
            &format!("/v1/plans/{plan_id}/{action}"),
            Some(&u.access),
            None,
        )
        .await;
    }
    let row = listed(u.access.clone()).await;
    assert_eq!(
        (
            row["triggers"][0]["enabled"].clone(),
            row["triggers"][0]["disabled_reason"].clone(),
            row["invalid_triggers"].clone(),
            row["next_fire_at"].clone()
        ),
        (json!(false), json!("invalid_rule"), json!(1), Value::Null)
    );
    // 也告诉了用户（10.7）：哪个计划、是哪一种提醒。
    let (_, inbox) = a
        .call(Method::GET, "/v1/inbox", Some(&u.access), None)
        .await;
    let notice = inbox["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["subtype"] == "trigger_disabled")
        .expect("trigger disabled notice");
    assert_eq!(notice["plan_id"], json!(plan_id));
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
        // 执行器存的键是 `第几次尝试:shim 的请求 id`，API 拆开给。
        request_id: "2:perm-1",
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
    assert_eq!(
        (
            &list["approvals"][0]["request_id"],
            &list["approvals"][0]["attempt"]
        ),
        (&json!("perm-1"), &json!(2))
    );
    let one = |tok: String| {
        let a = &a;
        let path = format!("/v1/approvals/{approval_id}");
        async move { a.call(Method::GET, &path, Some(&tok), None).await }
    };
    let (st, got) = one(u.access.clone()).await;
    assert_eq!(st, StatusCode::OK, "{got}");
    assert_eq!(
        (&got["state"], &got["decided_option"], &got["decided_at"]),
        (&json!(ApprovalState::Pending), &Value::Null, &Value::Null)
    );
    let other = a.login("13800138009").await;
    let (st, _) = one(other.access.clone()).await;
    assert_eq!(st, StatusCode::NOT_FOUND, "someone else's approval");
    let (st, _) = a
        .call(Method::GET, "/v1/approvals/nope", Some(&u.access), None)
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
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
    // 处理过的也查得到：点旧推送进来时给“已拒绝”的提示。
    let (st, got) = one(u.access.clone()).await;
    assert_eq!(st, StatusCode::OK, "{got}");
    assert_eq!(
        (&got["state"], &got["decided_option"]),
        (&json!(ApprovalState::Rejected), &json!("deny"))
    );
    assert!(got["decided_at"].is_string(), "{got}");
    // 决定事件带上和 agent.permission_* 对得上的键。
    let (_, page) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/events"),
            Some(&u.access),
            None,
        )
        .await;
    let decided = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["kind"] == "approval.decided")
        .expect("approval.decided event");
    assert_eq!(
        (
            &decided["payload"]["request_id"],
            &decided["payload"]["attempt"],
            &decided["payload"]["approval_id"],
        ),
        (&json!("perm-1"), &json!(2), &json!(approval_id))
    );
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

    // 事件全过了保留期（按月删分区）：续传要先收到 reset，不能悄悄跳过中间那段。
    sqlx::query("DELETE FROM events WHERE instance_id = $1")
        .bind(inst.0)
        .execute(a.t.db.pool())
        .await
        .unwrap();
    let (_, page) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/events?after=2"),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(
        (page["oldest_seq"].as_u64(), page["latest_seq"].as_u64()),
        (Some(6), Some(5))
    );
    let mut resumed = ws_connect(&a, Some(&u.access), inst, 2).await.unwrap();
    let reset = next_event(&mut resumed).await;
    assert_eq!(
        (reset["type"].as_str(), reset["oldest_seq"].as_u64()),
        (Some("reset"), Some(6))
    );
    let seq = append("agent.message", 6).await;
    assert_eq!(next_event(&mut resumed).await["seq"].as_u64(), Some(seq));
    resumed.close(None).await.ok();

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
    let (_, im) = a
        .call(
            Method::POST,
            "/v1/im-channels",
            tok,
            Some(json!({ "webhook_url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=owner-key-00001" })),
        )
        .await;
    let im = im["id"].as_str().unwrap().to_owned();
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
            Method::PATCH,
            format!("/v1/credentials/{cred}"),
            Some(json!({ "daily_token_limit": 1 })),
        ),
        (
            Method::PUT,
            format!("/v1/credentials/{cred}/secret"),
            Some(json!({ "api_key": "sk-stolen-0000000" })),
        ),
        (Method::DELETE, format!("/v1/credentials/{cred}"), None),
        (
            Method::PATCH,
            format!("/v1/im-channels/{im}"),
            Some(json!({ "enabled": false })),
        ),
        (
            Method::PUT,
            format!("/v1/im-channels/{im}/webhook"),
            Some(
                json!({ "webhook_url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=stolen-key-0001" }),
            ),
        ),
        (Method::POST, format!("/v1/im-channels/{im}/test"), None),
        (Method::DELETE, format!("/v1/im-channels/{im}"), None),
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
        "/v1/im-channels",
        "/v1/teams",
        "/v1/team-templates",
        "/v1/inbox",
        "/v1/runs",
        "/v1/runs?active=true",
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

/// 共享看板（8.10）：用户写、按标签读、归档和取消归档、删除；别人看不到、动不了。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn board_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138891").await;
    let bob = a.login("13800138892").await;
    let tok = Some(u.access.as_str());
    let (st, post) = a
        .call(
            Method::POST,
            "/v1/board",
            tok,
            Some(json!({ "body": " Ship on Friday ", "tags": ["Launch"] })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{post}");
    assert_eq!(post["body"], "Ship on Friday");
    assert_eq!(post["tags"], json!(["launch"]));
    assert_eq!(post["ai_generated"], false);
    let id = post["id"].as_str().unwrap().to_owned();
    // 保险箱里的密码换成引用再上看板：所有 agent 都读得到看板。
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/vault",
            tok,
            Some(json!({ "name": "github", "password": "hunter2-secret" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED);
    let (st, scrubbed) = a
        .call(
            Method::POST,
            "/v1/board",
            tok,
            Some(json!({ "body": "the password is hunter2-secret" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{scrubbed}");
    assert_eq!(scrubbed["body"], "the password is [vault:github]");
    let scrubbed_id = scrubbed["id"].as_str().unwrap().to_owned();
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/board/{scrubbed_id}"),
            tok,
            None,
        )
        .await;
    assert!(st.is_success());
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/board",
            tok,
            Some(json!({ "body": "untagged" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED);
    for bad in [
        json!({ "body": "" }),
        json!({ "body": "x", "tags": ["no space"] }),
    ] {
        let (st, body) = a
            .call(Method::POST, "/v1/board", tok, Some(bad.clone()))
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad}: {body}");
    }

    let (_, list) = a.call(Method::GET, "/v1/board", tok, None).await;
    assert_eq!(list["posts"].as_array().unwrap().len(), 2);
    let (_, tagged) = a.call(Method::GET, "/v1/board?tag=LAUNCH", tok, None).await;
    assert_eq!(tagged["posts"].as_array().unwrap().len(), 1);
    let (_, page) = a.call(Method::GET, "/v1/board?limit=1", tok, None).await;
    let last = page["posts"][0]["id"].as_str().unwrap().to_owned();
    let (_, next) = a
        .call(Method::GET, &format!("/v1/board?before={last}"), tok, None)
        .await;
    assert_eq!(next["posts"][0]["id"], json!(id));

    // 别人看不到、动不了。
    let (_, theirs) = a
        .call(Method::GET, "/v1/board", Some(&bob.access), None)
        .await;
    assert!(theirs["posts"].as_array().unwrap().is_empty());
    for (m, path) in [
        (Method::POST, format!("/v1/board/{id}/archive")),
        (Method::DELETE, format!("/v1/board/{id}")),
    ] {
        let (st, _) = a.call(m, &path, Some(&bob.access), None).await;
        assert_eq!(st, StatusCode::NOT_FOUND, "{path}");
    }

    let (st, archived) = a
        .call(Method::POST, &format!("/v1/board/{id}/archive"), tok, None)
        .await;
    assert_eq!(st, StatusCode::OK, "{archived}");
    assert!(archived["archived_at"].is_string());
    let (_, live) = a.call(Method::GET, "/v1/board", tok, None).await;
    assert_eq!(live["posts"].as_array().unwrap().len(), 1);
    let (_, old) = a
        .call(Method::GET, "/v1/board?archived=true", tok, None)
        .await;
    assert_eq!(old["posts"][0]["id"], json!(id));
    let (st, back) = a
        .call(
            Method::POST,
            &format!("/v1/board/{id}/unarchive"),
            tok,
            None,
        )
        .await;
    assert_eq!((st, back["archived_at"].is_null()), (StatusCode::OK, true));
    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/board/{id}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/board/{id}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

/// 实例设置（8.9）：用途说明、“允许其他 agent 查我、问我”，给了才改；关开关记审计。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn instance_settings_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138890").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let path = format!("/v1/instances/{inst}");
    let (_, body) = a.call(Method::GET, &path, tok, None).await;
    assert_eq!(
        (body["purpose"].as_str(), body["peer_access"].as_bool()),
        (Some(""), Some(true))
    );
    // 别的 agent 问它、还没答的问题（8.11）：关掉开关时取消。
    let asker = a.adopt(&u).await;
    let user: UserId = {
        let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
        me["id"].as_str().unwrap().parse().unwrap()
    };
    let mut w = a.t.db.worker().await.unwrap();
    let parent = w
        .create_run(
            user,
            &store::NewRun::new(asker, RunSource::User, "task", "1"),
        )
        .await
        .unwrap()
        .unwrap();
    let mut q = store::NewRun::new(inst, RunSource::Ask, "（说明）\n\n问题", "1");
    q.parent_run_id = Some(parent.id);
    let q = w.create_run(user, &q).await.unwrap().unwrap();
    w.commit().await.unwrap();

    let (st, body) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(json!({ "purpose": "  Finds sources  ", "peer_access": false })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["purpose"], "Finds sources");
    assert_eq!(body["peer_access"], false);
    assert_eq!(body["name"], "My Claude", "the name is kept");
    let mut w = a.t.db.worker().await.unwrap();
    let cancelled = w.run_record(q.id).await.unwrap().run;
    w.rollback().await.unwrap();
    assert_eq!(cancelled.state, RunState::Cancelled);
    assert_eq!(
        cancelled.state_reason.as_deref(),
        Some("the agent stopped taking questions")
    );
    let logged: i64 =
        sqlx::query_scalar("SELECT count(*) FROM events WHERE run_id = $1 AND kind = 'run.state'")
            .bind(q.id.0)
            .fetch_one(a.t.db.pool())
            .await
            .unwrap();
    assert_eq!(logged, 1);
    // 再关一次（没变）：不再记审计。
    let (st, _) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(json!({ "peer_access": false })),
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    // 只改名字：别的不动。
    let (st, body) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(json!({ "name": "Researcher" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(
        (
            body["name"].as_str(),
            body["purpose"].as_str(),
            body["peer_access"].as_bool()
        ),
        (Some("Researcher"), Some("Finds sources"), Some(false))
    );
    for bad in [
        json!({}),
        json!({ "purpose": "x".repeat(201) }),
        json!({ "purpose": "bad\u{7}" }),
        json!({ "name": "" }),
    ] {
        let (st, body) = a.call(Method::PATCH, &path, tok, Some(bad.clone())).await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad}: {body}");
    }
    let audits: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action = 'instance.peer_access' AND target = $1",
    )
    .bind(inst.to_string())
    .fetch_one(a.t.db.pool())
    .await
    .unwrap();
    assert_eq!(audits, 1, "only the actual switch is audited");
}

/// 运行中收消息（8.12）：`delivery` 默认排队，`interrupt` 是紧急消息，排在别的排队消息前面；别的值拒绝。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn urgent_messages_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138893").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let path = format!("/v1/instances/{inst}/runs");
    let (st, normal) = a
        .call(Method::POST, &path, tok, Some(json!({ "prompt": "first" })))
        .await;
    assert_eq!(st, StatusCode::CREATED, "{normal}");
    let (st, urgent) = a
        .call(
            Method::POST,
            &path,
            tok,
            Some(json!({ "prompt": "stop that", "delivery": "interrupt" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{urgent}");
    assert_eq!(urgent["state"], "queued");
    let mut w = a.t.db.worker().await.unwrap();
    let claimed = w
        .claim_next_run("x", Duration::from_secs(60))
        .await
        .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(
        claimed.map(|r| r.run.id.to_string()),
        urgent["id"].as_str().map(String::from),
        "the urgent message goes first"
    );
    let (st, body) = a
        .call(
            Method::POST,
            &path,
            tok,
            Some(json!({ "prompt": "x", "delivery": "shout" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
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
            // 厂商替 agent 搜的次数（docs/search.md）。
            web_searches: u64::from(model == "glm-4.6") * 2,
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
    assert_eq!(body["total"]["web_searches"], 2);
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

/// 停流水线的根运行（不带 tree=true）也停掉它的步骤：根运行自己不跑 agent。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancelling_a_pipeline_root_stops_its_steps() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138000").await;
    let inst = a.adopt(&u).await;
    let mut w = a.t.db.worker().await.unwrap();
    let user = w.instance_runtime(inst).await.unwrap().user_id;
    let mut root = store::NewRun::new(inst, proto::domain::RunSource::Plan, "pipeline", "1");
    root.kind = proto::domain::RunKind::Pipeline;
    let root = w.create_run(user, &root).await.unwrap().unwrap();
    let mut step = store::NewRun::new(inst, proto::domain::RunSource::Pipeline, "step a", "1");
    step.parent_run_id = Some(root.id);
    step.step_key = Some("a".into());
    let step = w.create_run(user, &step).await.unwrap().unwrap();
    w.commit().await.unwrap();

    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/runs/{}/cancel", root.id),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    let mut w = a.t.db.worker().await.unwrap();
    assert_eq!(
        w.run_record(step.id).await.unwrap().run.state,
        proto::domain::RunState::Cancelled
    );
    w.rollback().await.unwrap();
}

/// 实例数上限（11.9）：到了上限领养报 409 `instance_limit`；放不下整个团队的模板领养先拒绝，不领养一半；
/// 删掉一个又能领养；别的用户不受影响。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn instance_limit_over_http() {
    let Some(a) = api_with(GatewayConfig {
        limits: gateway::LimitConfig {
            instances_per_user: 2,
            ..gateway::LimitConfig::default()
        },
        ..GatewayConfig::default()
    })
    .await
    else {
        return;
    };
    let u = a.login("13800138033").await;
    let tok = Some(u.access.as_str());
    let first = a.adopt(&u).await;
    let count = || async {
        let (_, list) = a.call(Method::GET, "/v1/instances", tok, None).await;
        list["instances"].as_array().unwrap().len()
    };
    let (st, tpl) = a
        .call(
            Method::POST,
            "/v1/team-templates",
            tok,
            Some(json!({ "name": "两个人", "spec": { "members": [
                { "agent_id": "claude", "name": "主编", "role": "lead" },
                { "agent_id": "claude", "name": "写手" },
            ] } })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{tpl}");
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/team-templates/{}/adopt", tpl["id"].as_str().unwrap()),
            tok,
            Some(json!({})),
        )
        .await;
    assert_eq!(
        (st, &body["code"]),
        (StatusCode::CONFLICT, &json!("instance_limit")),
        "{body}"
    );
    assert_eq!(count().await, 1, "no half team");
    a.adopt(&u).await;
    let adopt = || async {
        a.call(
            Method::POST,
            "/v1/instances",
            tok,
            Some(json!({ "agent_id": "claude", "name": "第三个" })),
        )
        .await
    };
    let (st, body) = adopt().await;
    assert_eq!(
        (st, &body["code"]),
        (StatusCode::CONFLICT, &json!("instance_limit")),
        "{body}"
    );
    assert!(body["message"].as_str().unwrap().contains('2'), "{body}");
    assert_eq!(count().await, 2);
    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/instances/{first}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, body) = adopt().await;
    assert_eq!(st, StatusCode::CREATED, "{body}");
    let other = a.login("13800138034").await;
    a.adopt(&other).await;
}

/// 团队模板整个在一个事务里领养（11.9）：同时领养两次、只放得下一个团队的，一个成、一个 409 `instance_limit`，
/// 不留下不在团队里的实例；团队名不合法的一个也不领养。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn team_adoption_is_all_or_nothing() {
    let Some(a) = api_with(GatewayConfig {
        limits: gateway::LimitConfig {
            instances_per_user: 4,
            ..gateway::LimitConfig::default()
        },
        ..GatewayConfig::default()
    })
    .await
    else {
        return;
    };
    for round in 0..5 {
        let u = a.login(&format!("1380013807{round}")).await;
        let tok = Some(u.access.as_str());
        let (st, tpl) = a
            .call(
                Method::POST,
                "/v1/team-templates",
                tok,
                Some(json!({ "name": "三个人", "spec": { "members": [
                    { "agent_id": "claude", "name": "主编", "role": "lead" },
                    { "agent_id": "claude", "name": "写手" },
                    { "agent_id": "claude", "name": "校对" },
                ] } })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{tpl}");
        let path = format!("/v1/team-templates/{}/adopt", tpl["id"].as_str().unwrap());
        if round == 0 {
            let (st, body) = a
                .call(
                    Method::POST,
                    &path,
                    tok,
                    Some(json!({ "name": "长".repeat(65) })),
                )
                .await;
            assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
            let (_, list) = a.call(Method::GET, "/v1/instances", tok, None).await;
            assert_eq!(list["instances"].as_array().unwrap().len(), 0, "{list}");
        }
        let ((s1, b1), (s2, b2)) = tokio::join!(
            a.call(Method::POST, &path, tok, Some(json!({}))),
            a.call(Method::POST, &path, tok, Some(json!({}))),
        );
        let mut got = [(s1, b1["code"].clone()), (s2, b2["code"].clone())];
        got.sort_by_key(|(st, _)| st.as_u16());
        assert_eq!(
            got,
            [
                (StatusCode::CREATED, Value::Null),
                (StatusCode::CONFLICT, json!("instance_limit")),
            ],
            "{b1} {b2}"
        );
        let (_, list) = a.call(Method::GET, "/v1/instances", tok, None).await;
        assert_eq!(list["instances"].as_array().unwrap().len(), 3, "{list}");
        let (_, teams) = a.call(Method::GET, "/v1/teams", tok, None).await;
        assert_eq!(teams["teams"].as_array().unwrap().len(), 1, "{teams}");
    }
}

/// 领养到一半失败（第二个成员的接入方式不存在；两个负责人）：实例、授权、事件、审计、团队（项目）一个都不留。
#[tokio::test]
async fn team_adoption_rolls_back_when_a_member_fails() {
    let Some(a) = api().await else { return };
    for (round, members) in [
        json!([
            { "agent_id": "claude", "name": "主编", "role": "lead" },
            { "agent_id": "claude", "harness": "no-such-harness", "name": "写手" },
        ]),
        json!([
            { "agent_id": "claude", "name": "主编", "role": "lead" },
            { "agent_id": "claude", "name": "写手", "role": "lead" },
        ]),
    ]
    .into_iter()
    .enumerate()
    {
        let phone = format!("1380013808{round}");
        let u = a.login(&phone).await;
        let tok = Some(u.access.as_str());
        let (st, tpl) = a
            .call(
                Method::POST,
                "/v1/team-templates",
                tok,
                Some(json!({ "name": "两个人", "spec": { "members": members } })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{tpl}");
        let path = format!("/v1/team-templates/{}/adopt", tpl["id"].as_str().unwrap());
        let (st, body) = a.call(Method::POST, &path, tok, Some(json!({}))).await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
        let user: uuid::Uuid = sqlx::query_scalar("SELECT id FROM users WHERE phone = $1")
            .bind(format!("+86{phone}"))
            .fetch_one(a.t.db.pool())
            .await
            .unwrap();
        for (what, sql) in [
            (
                "instances",
                "SELECT count(*) FROM instances WHERE user_id = $1",
            ),
            (
                "grants",
                "SELECT count(*) FROM run_grants WHERE user_id = $1",
            ),
            ("events", "SELECT count(*) FROM events WHERE user_id = $1"),
            (
                "audit",
                "SELECT count(*) FROM audit_log WHERE user_id = $1 AND action = 'instance.adopt'",
            ),
            ("teams", "SELECT count(*) FROM teams WHERE user_id = $1"),
            (
                "projects",
                "SELECT count(*) FROM projects WHERE creator_id = $1",
            ),
            (
                "members",
                "SELECT count(*) FROM project_members WHERE user_id = $1",
            ),
            (
                "agents",
                "SELECT count(*) FROM project_agents WHERE user_id = $1",
            ),
        ] {
            let n: i64 = sqlx::query_scalar(sql)
                .bind(user)
                .fetch_one(a.t.db.pool())
                .await
                .unwrap();
            assert_eq!(n, 0, "round {round}: {what} left behind");
        }
        let (_, teams) = a.call(Method::GET, "/v1/teams", tok, None).await;
        assert_eq!(teams["teams"], json!([]), "{teams}");
    }
}

/// 旧的团队接口（8.13 起是单人项目上的一层）：返回的 JSON 一样，读写的是项目表；去掉再加回来的成员只有一行；删掉负责人的
/// 实例以后能换新负责人；共享过的项目只能看（8.14 起）；删除团队不删实例。
#[tokio::test]
async fn old_team_api_is_backed_by_projects() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138090").await;
    let tok = Some(u.access.as_str());
    let lead = a.adopt(&u).await;
    let writer = a.adopt(&u).await;
    let other = a.adopt(&u).await;
    let (st, team) = a
        .call(
            Method::POST,
            "/v1/teams",
            tok,
            Some(json!({ "name": "编辑部", "members": [
                { "instance_id": lead, "role": "lead", "position": 0 },
                { "instance_id": writer, "role": "member", "position": 1 },
            ] })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{team}");
    let mut keys: Vec<&str> = team
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(keys, ["created_at", "id", "members", "name"]);
    let mut member_keys: Vec<&str> = team["members"][0]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    member_keys.sort_unstable();
    assert_eq!(member_keys, ["instance_id", "position", "role"]);
    let id: uuid::Uuid = team["id"].as_str().unwrap().parse().unwrap();
    let count = |sql: &'static str| {
        let pool = a.t.db.pool().clone();
        async move {
            sqlx::query_scalar::<_, i64>(sql)
                .bind(id)
                .fetch_one(&pool)
                .await
                .unwrap()
        }
    };
    assert_eq!(
        count("SELECT count(*) FROM projects WHERE id = $1").await,
        1
    );
    assert_eq!(
        count("SELECT count(*) FROM project_members WHERE project_id = $1 AND role = 'creator'")
            .await,
        1
    );
    assert_eq!(
        count("SELECT count(*) FROM project_agents WHERE project_id = $1 AND left_at IS NULL")
            .await,
        2
    );
    assert_eq!(count("SELECT count(*) FROM teams WHERE id = $1").await, 0);
    let path = format!("/v1/teams/{id}");
    // 去掉再加回来：还是同一行。
    for members in [
        json!([{ "instance_id": lead, "role": "lead", "position": 0 }]),
        json!([
            { "instance_id": lead, "role": "lead", "position": 0 },
            { "instance_id": writer, "role": "member", "position": 1 },
        ]),
    ] {
        let (st, body) = a
            .call(
                Method::PATCH,
                &path,
                tok,
                Some(json!({ "members": members })),
            )
            .await;
        assert_eq!(st, StatusCode::OK, "{body}");
    }
    assert_eq!(
        count("SELECT count(*) FROM project_agents WHERE project_id = $1").await,
        2
    );
    // 删掉负责人的实例：团队里只剩一个，可以换新负责人。
    let (st, _) = a
        .call(Method::DELETE, &format!("/v1/instances/{lead}"), tok, None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, body) = a.call(Method::GET, &path, tok, None).await;
    assert_eq!(body["members"].as_array().unwrap().len(), 1, "{body}");
    let (st, body) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(json!({ "members": [
                { "instance_id": writer, "role": "member", "position": 0 },
                { "instance_id": other, "role": "lead", "position": 1 },
            ] })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    // 共享过的项目：只能看。
    sqlx::query("UPDATE projects SET shared_at = now() WHERE id = $1")
        .bind(id)
        .execute(a.t.db.pool())
        .await
        .unwrap();
    let (st, body) = a
        .call(Method::PATCH, &path, tok, Some(json!({ "name": "x" })))
        .await;
    assert_eq!(st, StatusCode::CONFLICT, "{body}");
    let (st, _) = a.call(Method::DELETE, &path, tok, None).await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (st, _) = a.call(Method::GET, &path, tok, None).await;
    assert_eq!(st, StatusCode::OK);
    // 删掉：项目没了，实例还在。
    sqlx::query("UPDATE projects SET shared_at = NULL WHERE id = $1")
        .bind(id)
        .execute(a.t.db.pool())
        .await
        .unwrap();
    let (st, _) = a.call(Method::DELETE, &path, tok, None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert_eq!(
        count("SELECT count(*) FROM projects WHERE id = $1").await,
        0
    );
    assert_eq!(
        count("SELECT count(*) FROM project_agents WHERE project_id = $1").await,
        0
    );
    let (_, list) = a.call(Method::GET, "/v1/instances", tok, None).await;
    assert_eq!(list["instances"].as_array().unwrap().len(), 2, "{list}");
}

#[tokio::test]
async fn rate_limits_and_signup_cap() {
    let Some(a) = api_with(GatewayConfig {
        limits: gateway::LimitConfig {
            device_per_minute: 3,
            signups_per_hour: 1,
            ..gateway::LimitConfig::default()
        },
        ..GatewayConfig::default()
    })
    .await
    else {
        return;
    };
    // 第一个新手机号能注册；全站每小时只放一个，第二个新号码被拦下。
    let u = a.login("13800138500").await;
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/auth/code",
            None,
            Some(json!({ "phone": "13800138501" })),
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let code = a.sms.last_code("+8613800138501").unwrap();
    let login = json!({
        "phone": "13800138501",
        "code": code,
        "device": { "platform": "android", "name": "Pixel" }
    });
    let (st, body) = a
        .call(Method::POST, "/v1/auth/login", None, Some(login))
        .await;
    assert_eq!(st, StatusCode::TOO_MANY_REQUESTS, "{body}");
    assert_eq!(body["code"], "rate_limited");
    assert!(body["retry_after_secs"].as_u64().unwrap() > 0);
    // 已注册的账号照常登录。
    a.login("13800138500").await;

    // 每台设备每分钟 3 次（登录后的第一个请求已经算一次以外再数）：超了返回 429 和 Retry-After。
    let mut limited = None;
    for _ in 0..5 {
        let resp = a
            .http
            .get(format!("{}/v1/me", a.base))
            .bearer_auth(&u.access)
            .send()
            .await
            .unwrap();
        if resp.status() == StatusCode::TOO_MANY_REQUESTS {
            limited = Some(resp);
            break;
        }
        assert_eq!(resp.status(), StatusCode::OK);
    }
    let resp = limited.expect("the device limit kicks in");
    let retry: u64 = resp.headers()["retry-after"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=20).contains(&retry), "{retry}");
}

/// 全部停止、下线其他设备、账号冻结（4.6）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stop_all_sign_out_others_and_frozen_accounts() {
    let Some(a) = api().await else { return };
    let phone = a.login("13800138000").await;
    let ipad = a.login("13800138000").await;
    let (_, me) = a
        .call(Method::GET, "/v1/me", Some(&phone.access), None)
        .await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let inst = a.adopt(&phone).await;
    let (st, plan) = a
        .call(
            Method::POST,
            "/v1/plans",
            Some(&phone.access),
            Some(json!({
                "instance_id": inst,
                "title": "早报",
                "goal": "summarize the news",
                "triggers": [{ "kind": "cron", "expr": "0 8 * * *", "tz": "Asia/Shanghai" }]
            })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{plan}");
    let plan_id: PlanId = plan["id"].as_str().unwrap().parse().unwrap();
    let runs = format!("/v1/instances/{inst}/runs");
    let (st, run) = a
        .call(
            Method::POST,
            &runs,
            Some(&phone.access),
            Some(json!({ "prompt": "hello" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{run}");

    // 全部停止：运行取消、授权吊销、计划暂停。
    let (st, body) = a
        .call(Method::POST, "/v1/me/stop-all", Some(&phone.access), None)
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(
        body,
        json!({ "runs_cancelled": 1, "grants_revoked": 2, "plans_paused": 1 })
    );
    let (_, run) = a
        .call(
            Method::GET,
            &format!("/v1/runs/{}", run["id"].as_str().unwrap()),
            Some(&phone.access),
            None,
        )
        .await;
    assert_eq!(run["state"], "cancelled");
    let mut t = a.t.db.tenant(user).await.unwrap();
    assert!(t.run_grants(inst).await.unwrap().is_empty());
    t.rollback().await.unwrap();

    // 再发起运行、恢复计划时重新签发授权；已经有了就不再签。
    let (st, _) = a
        .call(
            Method::POST,
            &runs,
            Some(&phone.access),
            Some(json!({ "prompt": "again" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED);
    for _ in 0..2 {
        let (st, resumed) = a
            .call(
                Method::POST,
                &format!("/v1/plans/{plan_id}/resume"),
                Some(&phone.access),
                None,
            )
            .await;
        assert_eq!(
            (st, resumed["paused"].as_bool()),
            (StatusCode::OK, Some(false)),
            "{resumed}"
        );
    }
    let mut t = a.t.db.tenant(user).await.unwrap();
    let grants = t.run_grants(inst).await.unwrap();
    assert_eq!(grants.len(), 2, "{grants:?}");
    assert!(grants.iter().any(|g| g.plan_id.is_none()));
    let plan_grant = t.plan_grant(plan_id).await.unwrap().unwrap();
    assert!(plan_grant.is_active(chrono::Utc::now()));
    t.rollback().await.unwrap();

    // 下线其他设备，顺带全部停止。
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/devices/sign-out-others",
            Some(&phone.access),
            Some(json!({ "stop_agents": true })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(
        body,
        json!({
            "devices_signed_out": 1,
            "stopped": { "runs_cancelled": 1, "grants_revoked": 2, "plans_paused": 1 }
        })
    );
    let (st, body) = a
        .call(Method::GET, "/v1/me", Some(&ipad.access), None)
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("session_revoked"))
    );
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/devices/sign-out-others",
            Some(&phone.access),
            Some(json!({})),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body, json!({ "devices_signed_out": 0, "stopped": null }));

    // 冻结：接口和刷新都是 403 account_frozen，事件流以 4003 关闭、握手被拒；解冻后恢复。
    let mut ws = ws_connect(&a, Some(&phone.access), inst, 0).await.unwrap();
    orchestrator::account::freeze(&a.t.db, user, "ops-li", "suspicious login")
        .await
        .unwrap();
    let (st, body) = a
        .call(Method::GET, "/v1/me", Some(&phone.access), None)
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::FORBIDDEN, Some("account_frozen"))
    );
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/auth/refresh",
            None,
            Some(json!({ "refresh_token": phone.refresh })),
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::FORBIDDEN, Some("account_frozen"))
    );
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
    assert_eq!(closed, Some(4003));
    match ws_connect(&a, Some(&phone.access), inst, 0).await {
        Err(tungstenite::Error::Http(resp)) => assert_eq!(resp.status().as_u16(), 403),
        Err(e) => panic!("unexpected error: {e}"),
        Ok(_) => panic!("a frozen account must not open the event stream"),
    }
    orchestrator::account::unfreeze(&a.t.db, user, "ops-li", "verified by phone")
        .await
        .unwrap();
    let (st, _) = a
        .call(Method::GET, "/v1/me", Some(&phone.access), None)
        .await;
    assert_eq!(st, StatusCode::OK);
}

/// 密码保险箱（9.11）：响应里从不出现密码，库里只有密文；别人看不到、改不了；
/// agent 的填写请求由用户填好或拒绝，填好后在实例上接着跑一轮。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn vault_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138000").await;
    let bob = a.login("13900139000").await;
    let (_, me) = a.call(Method::GET, "/v1/me", Some(&u.access), None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let inst = a.adopt(&u).await;

    let (st, item) = a
        .call(
            Method::POST,
            "/v1/vault",
            Some(&u.access),
            Some(json!({
                "name": "github",
                "purpose": "推代码",
                "username": "octocat",
                "password": "hunter2-secret"
            })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{item}");
    assert!(!item.to_string().contains("hunter2"), "{item}");
    assert_eq!(item["has_username"], true);
    let id = item["id"].as_str().unwrap().to_owned();
    let item_id: uuid::Uuid = id.parse().unwrap();
    for bad in [
        json!({ "name": "Git.Hub", "password": "long enough" }),
        json!({ "name": "short", "password": "abc" }),
        json!({ "name": "ctrl", "password": "line\nbreak" }),
        json!({ "name": "inst", "password": "long enough", "instance_ids": [uuid::Uuid::nil()] }),
    ] {
        let (st, body) = a
            .call(Method::POST, "/v1/vault", Some(&u.access), Some(bad))
            .await;
        assert!(
            st == StatusCode::UNPROCESSABLE_ENTITY || st == StatusCode::NOT_FOUND,
            "{st} {body}"
        );
    }
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/vault",
            Some(&u.access),
            Some(json!({ "name": "github", "password": "another one" })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);

    let (_, list) = a
        .call(Method::GET, "/v1/vault", Some(&u.access), None)
        .await;
    assert_eq!(list["items"].as_array().unwrap().len(), 1, "{list}");
    assert!(!list.to_string().contains("hunter2"));
    let path = format!("/v1/vault/{id}");
    let (st, detail) = a.call(Method::GET, &path, Some(&u.access), None).await;
    assert_eq!(st, StatusCode::OK, "{detail}");
    assert_eq!(detail["username"], "octocat");
    assert!(!detail.to_string().contains("hunter2"));
    let raw: Vec<u8> = sqlx::query_scalar("SELECT sealed FROM vault_items WHERE id = $1")
        .bind(item_id)
        .fetch_one(a.t.db.pool())
        .await
        .unwrap();
    assert!(!String::from_utf8_lossy(&raw).contains("hunter2"));
    assert!(!String::from_utf8_lossy(&raw).contains("octocat"));

    // 只改密码：账号留着；密文解开是新密码。
    let (st, updated) = a
        .call(
            Method::PATCH,
            &path,
            Some(&u.access),
            Some(json!({ "password": "new-secret-123", "purpose": "推代码、开 PR" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{updated}");
    assert_eq!(updated["purpose"], "推代码、开 PR");
    let (_, detail) = a.call(Method::GET, &path, Some(&u.access), None).await;
    assert_eq!(detail["username"], "octocat");
    let sealed: Vec<u8> = sqlx::query_scalar("SELECT sealed FROM vault_items WHERE id = $1")
        .bind(item_id)
        .fetch_one(a.t.db.pool())
        .await
        .unwrap();
    let vault = orchestrator::artifacts::user_vault(
        &a.t.db,
        Arc::new(LocalKms::new("kms1", &KMS_KEY)),
        user,
        false,
    )
    .await
    .unwrap();
    let secret = vault
        .open_vault(&user.to_string(), &id, &sealed)
        .await
        .unwrap();
    assert_eq!(
        (secret.username.as_str(), secret.password.as_str()),
        ("octocat", "new-secret-123")
    );

    // 别人的条目当作不存在。
    for method in [Method::GET, Method::PATCH, Method::DELETE] {
        let body = (method == Method::PATCH).then(|| json!({ "purpose": "x" }));
        let (st, _) = a.call(method, &path, Some(&bob.access), body).await;
        assert_eq!(st, StatusCode::NOT_FOUND);
    }

    // agent 的填写请求（平台工具建的，这里直接写库）。
    let new_request = |name: &str| store::NewVaultRequest {
        instance_id: inst,
        run_id: None,
        name: name.into(),
        purpose: "收邮件".into(),
        fields: vec!["username".into(), "password".into()],
        expires_in: Duration::from_secs(3600),
    };
    let mut t = a.t.db.tenant(user).await.unwrap();
    let (mail, _) = t.create_vault_request(&new_request("mail")).await.unwrap();
    let (other, _) = t.create_vault_request(&new_request("other")).await.unwrap();
    t.commit().await.unwrap();
    let (_, pending) = a
        .call(Method::GET, "/v1/vault/requests", Some(&u.access), None)
        .await;
    assert_eq!(
        pending["requests"].as_array().unwrap().len(),
        2,
        "{pending}"
    );
    let (_, theirs) = a
        .call(Method::GET, "/v1/vault/requests", Some(&bob.access), None)
        .await;
    assert!(theirs["requests"].as_array().unwrap().is_empty());
    let fulfill = format!("/v1/vault/requests/{}/fulfill", mail.id);
    let (st, _) = a
        .call(
            Method::POST,
            &fulfill,
            Some(&bob.access),
            Some(json!({ "password": "mail-pass-1" })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (st, _) = a
        .call(
            Method::POST,
            &fulfill,
            Some(&u.access),
            Some(json!({ "password": "abc" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (st, done) = a
        .call(
            Method::POST,
            &fulfill,
            Some(&u.access),
            Some(json!({ "username": "me@example.com", "password": "mail-pass-1" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{done}");
    assert_eq!(done["status"], "fulfilled");
    assert!(!done.to_string().contains("mail-pass-1"));
    let (st, _) = a
        .call(
            Method::POST,
            &fulfill,
            Some(&u.access),
            Some(json!({ "password": "mail-pass-2" })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (_, list) = a
        .call(Method::GET, "/v1/vault", Some(&u.access), None)
        .await;
    let mail_item = list["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["name"] == "mail")
        .cloned()
        .unwrap();
    assert_eq!(mail_item["instance_ids"], json!([inst]));
    assert_eq!(done["item_id"], mail_item["id"]);
    // 发起请求时没有在跑的运行：在实例上接着跑一轮，告诉 agent 可以用了。
    let (_, runs) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/runs"),
            Some(&u.access),
            None,
        )
        .await;
    let runs = runs["runs"].as_array().unwrap();
    assert_eq!(runs.len(), 1);
    let prompt = runs[0]["prompt"].as_str().unwrap();
    assert!(
        prompt.contains("mail") && !prompt.contains("mail-pass-1"),
        "{prompt}"
    );

    let (st, declined) = a
        .call(
            Method::POST,
            &format!("/v1/vault/requests/{}/decline", other.id),
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(
        (st, declined["status"].as_str()),
        (StatusCode::OK, Some("declined"))
    );
    let (_, all) = a
        .call(
            Method::GET,
            "/v1/vault/requests?all=true",
            Some(&u.access),
            None,
        )
        .await;
    assert_eq!(all["requests"].as_array().unwrap().len(), 2);
    let (_, pending) = a
        .call(Method::GET, "/v1/vault/requests", Some(&u.access), None)
        .await;
    assert!(pending["requests"].as_array().unwrap().is_empty());

    // 消息里漏发了保险箱里的密码（客户端没拦下来，11.6）：存库前换成引用，agent 和模型都看不到。
    let (st, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            Some(&u.access),
            Some(json!({ "prompt": "用 new-secret-123 推代码，邮箱密码 mail-pass-1" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{run}");
    assert_eq!(
        run["prompt"],
        "用 [vault:github] 推代码，邮箱密码 [vault:mail]"
    );
    let stored: String = sqlx::query_scalar("SELECT prompt FROM runs WHERE id = $1")
        .bind(run["id"].as_str().unwrap().parse::<uuid::Uuid>().unwrap())
        .fetch_one(a.t.db.pool())
        .await
        .unwrap();
    assert!(!stored.contains("new-secret-123"), "{stored}");
    // 别人发同样的文字不受影响（只抹自己保险箱里的）。
    let bob_inst = a.adopt(&bob).await;
    let (_, theirs) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{bob_inst}/runs"),
            Some(&bob.access),
            Some(json!({ "prompt": "用 new-secret-123 推代码" })),
        )
        .await;
    assert_eq!(theirs["prompt"], "用 new-secret-123 推代码");

    let (st, _) = a.call(Method::DELETE, &path, Some(&u.access), None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a.call(Method::GET, &path, Some(&u.access), None).await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn language_preference() {
    let Some(a) = api().await else { return };
    // 没带系统语言的新用户按中文。
    let u = a.login("13800138500").await;
    let tok = Some(u.access.as_str());
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    assert_eq!(me["locale"], "zh-CN");
    // 只改名字不动语言、只改语言不动名字；系统的语言标签也认。
    let (st, me) = a
        .call(
            Method::PATCH,
            "/v1/me",
            tok,
            Some(json!({ "display_name": "Ann" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{me}");
    let (st, me) = a
        .call(
            Method::PATCH,
            "/v1/me",
            tok,
            Some(json!({ "locale": "en_US" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{me}");
    assert_eq!(
        (me["locale"].as_str(), me["display_name"].as_str()),
        (Some("en"), Some("Ann"))
    );
    let (st, body) = a
        .call(
            Method::PATCH,
            "/v1/me",
            tok,
            Some(json!({ "locale": "ja-JP" })),
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::UNPROCESSABLE_ENTITY, Some("invalid"))
    );
    let (_, me) = a
        .call(
            Method::PATCH,
            "/v1/me",
            tok,
            Some(json!({ "display_name": null })),
        )
        .await;
    assert_eq!(me["locale"], "en");
    assert_eq!(me["display_name"], Value::Null);

    // 服务端写的通知按用户的语言：收件箱和推送都是英文，推送带上语言（显式标识也按它显示）。
    let (st, body) = a.call(Method::POST, "/v1/me/stop-all", tok, None).await;
    assert_eq!(st, StatusCode::OK, "{body}");
    let (_, inbox) = a.call(Method::GET, "/v1/inbox", tok, None).await;
    assert_eq!(inbox["items"][0]["title"], "Everything stopped", "{inbox}");
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let pushed: Vec<Value> = sqlx::query_scalar("SELECT payload FROM outbox WHERE user_id = $1")
        .bind(user.0)
        .fetch_all(a.t.db.pool())
        .await
        .unwrap();
    assert!(
        pushed
            .iter()
            .any(|p| p["locale"] == "en" && p["title"] == "Everything stopped"),
        "{pushed:?}"
    );

    // 新用户按设备的系统语言；老用户再登录不改。
    let login = |phone: &'static str, lang: &'static str| {
        let a = &a;
        async move {
            let (st, _) = a
                .call(
                    Method::POST,
                    "/v1/auth/code",
                    None,
                    Some(json!({ "phone": phone })),
                )
                .await;
            assert_eq!(st, StatusCode::NO_CONTENT);
            let code = a.sms.last_code(&format!("+86{phone}")).unwrap();
            let resp = a
                .http
                .post(format!("{}/v1/auth/login", a.base))
                .header("accept-language", lang)
                .json(&json!({ "phone": phone, "code": code, "device": { "platform": "ios" } }))
                .send()
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            resp.json::<Value>().await.unwrap()
        }
    };
    let body = login("13800138501", "en-GB,en;q=0.9,zh-CN;q=0.5").await;
    assert_eq!(body["new_user"], true);
    assert_eq!(body["user"]["locale"], "en");
    let (_, me) = a
        .call(Method::GET, "/v1/me", body["access_token"].as_str(), None)
        .await;
    assert_eq!(me["locale"], "en");
    let body = login("13800138500", "zh-CN").await;
    assert_eq!(body["new_user"], false);
    assert_eq!(body["user"]["locale"], "en", "keeps the user's own choice");
    let body = login("13800138502", "ja-JP,ko;q=0.8").await;
    assert_eq!(
        body["user"]["locale"], "zh-CN",
        "unsupported languages fall back"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn im_channels_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138010").await;
    let tok = Some(u.access.as_str());
    let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
    let user: UserId = me["id"].as_str().unwrap().parse().unwrap();
    let token = "0123456789abcdef0123456789abcdef";
    let (st, ch) = a
        .call(
            Method::POST,
            "/v1/im-channels",
            tok,
            Some(json!({
                "webhook_url": format!("https://oapi.dingtalk.com/robot/send?access_token={token}"),
                "secret": "SECsigning-secret-1",
                "label": "运维群",
                "events": ["run_failed", "approval"]
            })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{ch}");
    assert_eq!(ch["vendor"], "dingtalk");
    assert_eq!(ch["hint"], "…cdef");
    assert_eq!(ch["has_secret"], true);
    assert_eq!(ch["events"], json!(["approval", "run_failed"]));
    assert!(!ch.to_string().contains(token) && !ch.to_string().contains("signing-secret"));
    let id = ch["id"].as_str().unwrap().to_owned();
    let channel_id: proto::domain::ImChannelId = id.parse().unwrap();
    // 同一个群机器人不能绑两次（每条通知会发两遍）。
    let (st, err) = a
        .call(
            Method::POST,
            "/v1/im-channels",
            tok,
            Some(json!({
                "webhook_url": format!("https://oapi.dingtalk.com/robot/send?access_token={token}"),
            })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT, "{err}");

    // 库里只有密文；用这个用户的 DEK、这个渠道的 id 才解得开。
    let raw: Vec<u8> = sqlx::query_scalar("SELECT sealed FROM im_channels WHERE id = $1")
        .bind(channel_id.0)
        .fetch_one(a.t.db.pool())
        .await
        .unwrap();
    assert!(!String::from_utf8_lossy(&raw).contains(token));
    let kms: Arc<dyn keyvault::Kms> = Arc::new(LocalKms::new("kms1", &KMS_KEY));
    let vault = orchestrator::artifacts::user_vault(&a.t.db, kms, user, false)
        .await
        .unwrap();
    let opened = vault
        .open_webhook(&user.to_string(), &id, &raw)
        .await
        .unwrap();
    assert_eq!(
        (opened.token.as_str(), opened.secret.as_str()),
        (token, "SECsigning-secret-1")
    );
    assert!(
        vault
            .open_webhook(&user.to_string(), &uuid::Uuid::nil().to_string(), &raw)
            .await
            .is_err()
    );

    for bad in [
        json!({ "webhook_url": format!("http://oapi.dingtalk.com/robot/send?access_token={token}") }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com:8443/robot/send?access_token={token}") }),
        json!({ "webhook_url": format!("https://user@oapi.dingtalk.com/robot/send?access_token={token}") }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com./robot/send?access_token={token}") }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com.evil.com/robot/send?access_token={token}") }),
        json!({ "webhook_url": format!("https://10.0.0.1/robot/send?access_token={token}") }),
        json!({ "webhook_url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send" }),
        json!({ "webhook_url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wecom-key-000001", "secret": "secret-123" }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com/robot/send?access_token={token}"), "secret": "not-a-ding-secret" }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com/robot/send?access_token={token}"), "events": ["info"] }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com/robot/send?access_token={token}"), "events": [] }),
        json!({ "webhook_url": format!("https://oapi.dingtalk.com/robot/send?access_token={token}"), "label": "a\nb" }),
    ] {
        let (st, body) = a
            .call(Method::POST, "/v1/im-channels", tok, Some(bad.clone()))
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad} -> {body}");
        assert!(!body.to_string().contains(token), "{body}");
    }

    let path = format!("/v1/im-channels/{id}");
    let (st, updated) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(json!({ "enabled": false, "label": "值班群" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{updated}");
    assert_eq!(
        (updated["enabled"].clone(), updated["label"].clone()),
        (json!(false), json!("值班群"))
    );
    // 关着的渠道不能发测试消息。
    let (st, _) = a
        .call(Method::POST, &format!("{path}/test"), tok, None)
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    a.call(Method::PATCH, &path, tok, Some(json!({ "enabled": true })))
        .await;

    // 换地址：同一家可以，换成别家的不行。
    let (st, rotated) = a
        .call(
            Method::PUT,
            &format!("{path}/webhook"),
            tok,
            Some(json!({ "webhook_url": "https://oapi.dingtalk.com/robot/send?access_token=fedcba9876543210" })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{rotated}");
    assert_eq!(
        (rotated["hint"].clone(), rotated["has_secret"].clone()),
        (json!("…3210"), json!(false))
    );
    let (st, _) = a
        .call(
            Method::PUT,
            &format!("{path}/webhook"),
            tok,
            Some(json!({ "webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/abcdef0123456789" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);

    // 测试消息进出箱（不带凭证），用户的语言。
    let (st, body) = a
        .call(Method::POST, &format!("{path}/test"), tok, None)
        .await;
    assert_eq!(st, StatusCode::ACCEPTED, "{body}");
    let payload: Value =
        sqlx::query_scalar("SELECT payload FROM outbox WHERE user_id = $1 AND kind = 'im'")
            .bind(user.0)
            .fetch_one(a.t.db.pool())
            .await
            .unwrap();
    assert_eq!(payload["channel"], id);
    assert_eq!(payload["message"]["title"], "测试消息");
    assert!(!payload.to_string().contains("fedcba9876543210"));

    let (_, list) = a.call(Method::GET, "/v1/im-channels", tok, None).await;
    assert_eq!(list["channels"].as_array().unwrap().len(), 1);
    let actions: Vec<String> =
        sqlx::query_scalar("SELECT action FROM audit_log WHERE target = $1 ORDER BY id")
            .bind(&id)
            .fetch_all(a.t.db.pool())
            .await
            .unwrap();
    assert_eq!(
        actions,
        [
            "im_channel.create",
            "im_channel.update",
            "im_channel.update",
            "im_channel.rotate",
            "im_channel.test"
        ]
    );
    let details: Vec<Value> = sqlx::query_scalar("SELECT detail FROM audit_log WHERE target = $1")
        .bind(&id)
        .fetch_all(a.t.db.pool())
        .await
        .unwrap();
    assert!(
        details
            .iter()
            .all(|d| !d.to_string().contains("0123456789abcdef0123")
                && !d.to_string().contains("fedcba98"))
    );

    let (st, _) = a.call(Method::DELETE, &path, tok, None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a.call(Method::DELETE, &path, tok, None).await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn im_test_messages_are_rate_limited() {
    let Some(a) = api_with(GatewayConfig {
        limits: LimitConfig {
            im_tests_per_hour: 1,
            ..LimitConfig::default()
        },
        ..GatewayConfig::default()
    })
    .await
    else {
        return;
    };
    let u = a.login("13800138011").await;
    let tok = Some(u.access.as_str());
    let (_, ch) = a
        .call(
            Method::POST,
            "/v1/im-channels",
            tok,
            Some(json!({ "webhook_url": "https://open.larksuite.com/open-apis/bot/v2/hook/lark-token-0001" })),
        )
        .await;
    let path = format!("/v1/im-channels/{}/test", ch["id"].as_str().unwrap());
    let (st, _) = a.call(Method::POST, &path, tok, None).await;
    assert_eq!(st, StatusCode::ACCEPTED);
    let (st, body) = a.call(Method::POST, &path, tok, None).await;
    assert_eq!(st, StatusCode::TOO_MANY_REQUESTS, "{body}");
}

#[tokio::test]
async fn live_activities_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138030").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let (st, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            tok,
            Some(json!({ "prompt": "整理邮件" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{run}");
    let run_id: RunId = run["id"].as_str().unwrap().parse().unwrap();
    let path = format!("/v1/runs/{run_id}/live-activity");
    let token = "ab".repeat(40);
    let stored = |run: RunId| {
        let pool = a.t.db.pool().clone();
        async move {
            let row: Option<(Option<String>, bool)> = sqlx::query_as(
                "SELECT push_token, ended_at IS NOT NULL FROM live_activities WHERE run_id = $1",
            )
            .bind(run.0)
            .fetch_optional(&pool)
            .await
            .unwrap();
            row
        }
    };

    // 登记这台 iPhone 上的实时活动；不是 ActivityKit 的令牌不收；别人的运行登记不了。
    let (st, body) = a
        .call(Method::PUT, &path, tok, Some(json!({ "token": token })))
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT, "{body}");
    assert_eq!(stored(run_id).await, Some((Some(token.clone()), false)));
    let (st, _) = a
        .call(
            Method::PUT,
            &path,
            tok,
            Some(json!({ "token": "not-a-token" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let other = a.login("13800138031").await;
    let (st, _) = a
        .call(
            Method::PUT,
            &path,
            Some(&other.access),
            Some(json!({ "token": token })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    // App 关掉了：不再推送。
    let (st, _) = a.call(Method::DELETE, &path, tok, None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert_eq!(stored(run_id).await, Some((Some(token.clone()), true)));

    // 推送开启令牌：登记、同一个令牌换到别的账号上（同一台手机换了人登录）、清掉。
    let start = "cd".repeat(40);
    let start_path = "/v1/devices/current/live-activity-start";
    let start_tokens = || {
        let pool = a.t.db.pool().clone();
        async move {
            let n: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM devices WHERE activity_start_token IS NOT NULL",
            )
            .fetch_one(&pool)
            .await
            .unwrap();
            n
        }
    };
    let (st, body) = a
        .call(
            Method::PUT,
            start_path,
            tok,
            Some(json!({ "token": start })),
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT, "{body}");
    assert_eq!(start_tokens().await, 1);
    let (st, _) = a
        .call(
            Method::PUT,
            start_path,
            Some(&other.access),
            Some(json!({ "token": start })),
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert_eq!(
        start_tokens().await,
        1,
        "the token moved to the new account"
    );
    let (st, _) = a
        .call(Method::DELETE, start_path, Some(&other.access), None)
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert_eq!(start_tokens().await, 0);
}

#[tokio::test]
async fn content_reports_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138040").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let (st, run) = a
        .call(
            Method::POST,
            &format!("/v1/instances/{inst}/runs"),
            tok,
            Some(json!({ "prompt": "写一首诗" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{run}");
    let run_id: RunId = run["id"].as_str().unwrap().parse().unwrap();
    let mut w = a.t.db.worker().await.unwrap();
    let seq = w
        .append_event(
            inst,
            Some(run_id),
            "agent.message",
            &json!({ "text": "一段不该出现的回复" }),
        )
        .await
        .unwrap()
        .seq;
    w.commit().await.unwrap();

    // 举报这一条：进待处理队列，复制下来的内容不回显。
    let body = json!({ "run_id": run_id.to_string(), "event_seq": seq, "reason": "harmful", "note": "  教唆  " });
    let (st, first) = a
        .call(Method::POST, "/v1/reports", tok, Some(body.clone()))
        .await;
    assert_eq!(st, StatusCode::CREATED, "{first}");
    assert_eq!(
        (
            first["state"].as_str(),
            first["note"].as_str(),
            first["event_seq"].as_u64()
        ),
        (Some("open"), Some("教唆"), Some(seq))
    );
    assert!(first.get("snapshot").is_none());
    // 再点一次：还是那一条。
    let (st, again) = a.call(Method::POST, "/v1/reports", tok, Some(body)).await;
    assert_eq!((st, &again["id"]), (StatusCode::OK, &first["id"]));
    let mut w = a.t.db.worker().await.unwrap();
    let open = w.open_reports(10).await.unwrap();
    w.rollback().await.unwrap();
    assert_eq!(open.len(), 1);
    assert_eq!(
        open[0].snapshot["event"]["payload"]["text"],
        "一段不该出现的回复"
    );
    assert_eq!(open[0].snapshot["run"]["prompt"], "写一首诗");

    // 整个运行也能举报；原因不认识、事件不是这个运行的、别人的运行都不行。
    let whole = json!({ "run_id": run_id.to_string(), "reason": "other" });
    let (st, _) = a.call(Method::POST, "/v1/reports", tok, Some(whole)).await;
    assert_eq!(st, StatusCode::CREATED);
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/reports",
            tok,
            Some(json!({ "run_id": run_id.to_string(), "reason": "boring" })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/reports",
            tok,
            Some(
                json!({ "run_id": run_id.to_string(), "event_seq": seq + 100, "reason": "other" }),
            ),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let other = a.login("13800138041").await;
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/reports",
            Some(&other.access),
            Some(json!({ "run_id": run_id.to_string(), "event_seq": seq, "reason": "harmful" })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);

    // 自己的举报和处理结果。
    let (st, mine) = a.call(Method::GET, "/v1/reports", tok, None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(mine["reports"].as_array().unwrap().len(), 2);
    let (_, theirs) = a
        .call(Method::GET, "/v1/reports", Some(&other.access), None)
        .await;
    assert_eq!(theirs["reports"].as_array().unwrap().len(), 0);
}

/// 计划的 webhook（7.1）：建的时候要同意；收到事件按计划起一次运行，内容附在目标后面、注明来自外部；列表里没有
/// 令牌；别人看不到；只收 JSON 和文本；令牌不对、停用了、换掉的旧地址都 404；排着太多 429；删了就失效。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn plan_webhooks_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138896").await;
    let other = a.login("13800138897").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let (st, plan) = a
        .call(
            Method::POST,
            "/v1/plans",
            tok,
            Some(json!({ "instance_id": inst, "title": "邮件", "goal": "看看这封邮件要不要处理" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED, "{plan}");
    let hooks = format!("/v1/plans/{}/hooks", plan["id"].as_str().unwrap());
    let (st, _) = a.call(Method::POST, &hooks, tok, Some(json!({}))).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "consent is required");
    let (st, created) = a
        .call(Method::POST, &hooks, tok, Some(json!({ "consent": true })))
        .await;
    assert_eq!(st, StatusCode::CREATED, "{created}");
    let token = created["token"].as_str().unwrap().to_owned();
    let path = created["path"].as_str().unwrap().to_owned();
    assert_eq!(path, format!("/v1/webhooks/{token}"));
    let hook_id = created["hook"]["id"].as_str().unwrap().to_owned();
    let (_, list) = a.call(Method::GET, &hooks, tok, None).await;
    assert_eq!(list["hooks"].as_array().unwrap().len(), 1);
    assert!(!list.to_string().contains(&token));
    let (st, _) = a
        .call(Method::GET, &hooks, Some(other.access.as_str()), None)
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);

    let send = |path: String, ct: &'static str, body: &'static str| {
        let req = a
            .http
            .post(format!("{}{path}", a.base))
            .header("content-type", ct)
            .body(body);
        async move { req.send().await.unwrap().status() }
    };
    assert_eq!(
        send(
            path.clone(),
            "application/json",
            r#"{"subject":"invoice #42"}"#
        )
        .await,
        StatusCode::ACCEPTED
    );
    let (_, runs) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/runs"),
            tok,
            None,
        )
        .await;
    let run = &runs["runs"][0];
    assert_eq!(run["source"], "plan");
    let run_id = run["id"].as_str().unwrap().to_owned();
    let prompt = run["prompt"].as_str().unwrap();
    // 内容前后有发送方猜不到的标记。
    let boundary = prompt.rsplit('\n').next().unwrap().trim_end_matches(">>>");
    assert!(
        prompt.starts_with("看看这封邮件要不要处理")
            && prompt.contains("来自外部")
            && boundary.len() == 12
            && prompt.contains(&format!(
                "<<<{boundary}\n{{\"subject\":\"invoice #42\"}}\n{boundary}>>>"
            )),
        "{prompt}"
    );
    // 飞书、Slack 保存地址时的验证：原样回 challenge，不起运行。
    let (st, echoed) = {
        let r = a
            .http
            .post(format!("{}{path}", a.base))
            .json(&json!({ "type": "url_verification", "challenge": "c-123", "token": "x" }))
            .send()
            .await
            .unwrap();
        (r.status(), r.json::<serde_json::Value>().await.unwrap())
    };
    assert_eq!(
        (st, echoed),
        (StatusCode::OK, json!({ "challenge": "c-123" }))
    );
    // 太大的 422（不管有没有写长度）。
    let big = "x".repeat(65 * 1024);
    let response = a
        .http
        .post(format!("{}{path}", a.base))
        .header("content-type", "text/plain")
        .body(big.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(response.headers()["connection"], "close");
    let chunked =
        reqwest::Body::wrap_stream(futures_util::stream::iter([Ok::<_, std::io::Error>(big)]));
    let response = a
        .http
        .post(format!("{}{path}", a.base))
        .header("content-type", "text/plain")
        .body(chunked)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(response.headers()["connection"], "close");
    // 计划的每日 token 上限到了：429。
    sqlx::query("UPDATE runs SET tokens_used = 100 WHERE id = $1::uuid")
        .bind(&run_id)
        .execute(a.t.db.pool())
        .await
        .unwrap();
    let set_limit = |limit: serde_json::Value| {
        sqlx::query("UPDATE plans SET policy = jsonb_set(policy, '{daily_token_limit}', $2) WHERE id = $1::uuid")
            .bind(plan["id"].as_str().unwrap().to_owned())
            .bind(limit)
            .execute(a.t.db.pool())
    };
    set_limit(json!(50)).await.unwrap();
    assert_eq!(
        send(path.clone(), "text/plain", "over the limit").await,
        StatusCode::TOO_MANY_REQUESTS
    );
    set_limit(json!(null)).await.unwrap();
    // 只收 JSON 和文本；JSON 要合法；令牌不对的 404。
    assert_eq!(
        send(path.clone(), "image/png", "x").await,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        send(path.clone(), "application/json", "{not json").await,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        send("/v1/webhooks/twh1_nope".into(), "text/plain", "hi").await,
        StatusCode::NOT_FOUND
    );
    // 排着的最多 5 个，再来的 429。
    for _ in 0..4 {
        assert_eq!(
            send(path.clone(), "text/plain; charset=utf-8", "another mail").await,
            StatusCode::ACCEPTED
        );
    }
    assert_eq!(
        send(path.clone(), "text/plain", "one too many").await,
        StatusCode::TOO_MANY_REQUESTS
    );
    // 停用了 404；换了令牌旧地址 404，新地址照样认（只是排满了）。
    let hook = format!("/v1/hooks/{hook_id}");
    let (st, off) = a
        .call(Method::PATCH, &hook, tok, Some(json!({ "enabled": false })))
        .await;
    assert_eq!(
        (st, off["enabled"].as_bool()),
        (StatusCode::OK, Some(false))
    );
    assert_eq!(
        send(path.clone(), "text/plain", "hi").await,
        StatusCode::NOT_FOUND
    );
    a.call(Method::PATCH, &hook, tok, Some(json!({ "enabled": true })))
        .await;
    let (st, rotated) = a
        .call(Method::POST, &format!("{hook}/rotate"), tok, None)
        .await;
    assert_eq!(st, StatusCode::OK, "{rotated}");
    let new_path = rotated["path"].as_str().unwrap().to_owned();
    assert_ne!(new_path, path);
    assert_eq!(
        send(path.clone(), "text/plain", "hi").await,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(new_path.clone(), "text/plain", "hi").await,
        StatusCode::TOO_MANY_REQUESTS
    );
    // 有 webhook 的计划不能加步骤；步骤不管怎么加上的，事件都不按单个 agent 跑（404）。
    let plan_path = format!("/v1/plans/{}", plan["id"].as_str().unwrap());
    let (st, _) = a
        .call(
            Method::PATCH,
            &plan_path,
            tok,
            Some(json!({ "steps": [{ "key": "a", "instance_id": inst, "prompt": "做" }] })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    sqlx::query(
        "INSERT INTO plan_steps (plan_id, key, user_id, instance_id, prompt) \
         SELECT id, 'a', user_id, instance_id, '做' FROM plans WHERE id = $1::uuid",
    )
    .bind(plan["id"].as_str().unwrap())
    .execute(a.t.db.pool())
    .await
    .unwrap();
    assert_eq!(
        send(new_path.clone(), "text/plain", "hi").await,
        StatusCode::NOT_FOUND
    );
    sqlx::query("DELETE FROM plan_steps WHERE plan_id = $1::uuid")
        .bind(plan["id"].as_str().unwrap())
        .execute(a.t.db.pool())
        .await
        .unwrap();
    // 别人删不了；删了就失效。
    let (st, _) = a
        .call(Method::DELETE, &hook, Some(other.access.as_str()), None)
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (st, _) = a.call(Method::DELETE, &hook, tok, None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert_eq!(
        send(new_path, "text/plain", "hi").await,
        StatusCode::NOT_FOUND
    );
    let audits: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action LIKE 'plan_hook.%' AND target = $1",
    )
    .bind(&hook_id)
    .fetch_one(a.t.db.pool())
    .await
    .unwrap();
    assert_eq!(audits, 5, "create, off, on, rotate, delete");
}

/// 受控出网通道（2.7）：默认只连模型；改档位和网站（整理写法、去重）；不合规的网站、没确认风险就开“全部公网”、
/// 空的自定义列表都拒绝；改了记审计；别人改不了。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn instance_egress_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138898").await;
    let other = a.login("13800138899").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let path = format!("/v1/instances/{inst}");
    let (_, body) = a.call(Method::GET, &path, tok, None).await;
    assert_eq!(
        (body["egress_mode"].as_str(), body["egress_hosts"].clone()),
        (Some("dev"), json!([]))
    );
    let patch = |egress: serde_json::Value| json!({ "egress": egress });
    let (st, body) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(patch(
                json!({ "mode": "dev", "hosts": ["Docs.Example.com.", "docs.example.com"] }),
            )),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(
        (body["egress_mode"].as_str(), body["egress_hosts"].clone()),
        (Some("dev"), json!(["docs.example.com"]))
    );
    for bad in [
        json!({ "mode": "custom", "hosts": ["10.0.0.1"] }),
        json!({ "mode": "custom", "hosts": ["*.example.com"] }),
        json!({ "mode": "custom", "hosts": [] }),
        json!({ "mode": "all" }),
        json!({ "mode": "everything" }),
    ] {
        let (st, body) = a
            .call(Method::PATCH, &path, tok, Some(patch(bad.clone())))
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{bad} -> {body}");
    }
    let (st, body) = a
        .call(
            Method::PATCH,
            &path,
            tok,
            Some(patch(json!({ "mode": "all", "accept_risk": true }))),
        )
        .await;
    assert_eq!(
        (st, body["egress_mode"].as_str()),
        (StatusCode::OK, Some("all"))
    );
    let (st, _) = a
        .call(
            Method::PATCH,
            &path,
            Some(other.access.as_str()),
            Some(patch(json!({ "mode": "model" }))),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let audits: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action = 'instance.egress' AND target = $1",
    )
    .bind(inst.to_string())
    .fetch_one(a.t.db.pool())
    .await
    .unwrap();
    assert_eq!(audits, 2, "dev, then all");

    // 出网情况：档位、今天的用量、最近被拒绝的（出口代理写的日志）。
    let user: UserId = {
        let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
        me["id"].as_str().unwrap().parse().unwrap()
    };
    let mut g = a.t.db.llmgw().await.unwrap();
    let today = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    g.egress_reserve(inst, user, today, 1234, 100 << 20)
        .await
        .unwrap();
    g.insert_egress_log(&[store::EgressLogEntry {
        user_id: user,
        instance_id: inst,
        at: chrono::Utc::now(),
        host: "blocked.example.com".into(),
        port: 443,
        address: None,
        allowed: false,
        reason: "not_allowed".into(),
        bytes_up: 0,
        bytes_down: 0,
        duration_ms: 0,
        count: 1,
        via: proto::egress::Via::Direct,
        kind: None,
        page_site: None,
    }])
    .await
    .unwrap();
    g.commit().await.unwrap();
    let (st, body) = a
        .call(Method::GET, &format!("{path}/egress"), tok, None)
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["mode"], "all");
    assert_eq!(body["used_today"], 1234);
    assert_eq!(body["daily_limit"], proto::egress::DAILY_BYTES);
    assert_eq!(body["recent_denied"][0]["host"], "blocked.example.com");
    assert!(
        body["dev_hosts"]
            .as_array()
            .unwrap()
            .contains(&json!("github.com"))
    );
    assert!(
        body["search_hosts"]
            .as_array()
            .unwrap()
            .contains(&json!("www.bing.com"))
    );
    assert_eq!(body["pending"], json!([]));
    let (st, _) = a
        .call(
            Method::GET,
            &format!("{path}/egress"),
            Some(other.access.as_str()),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

/// agent 想访问不在名单上的网站（2.7）：App 列出在等的，用户回答；“一直允许”记进实例；答过的不能再答；
/// 别人的看不到、答不了。
#[tokio::test]
async fn egress_requests_over_http() {
    let Some(a) = api().await else { return };
    let u = a.login("13800138896").await;
    let other = a.login("13800138897").await;
    let tok = Some(u.access.as_str());
    let inst = a.adopt(&u).await;
    let user: UserId = {
        let (_, me) = a.call(Method::GET, "/v1/me", tok, None).await;
        me["id"].as_str().unwrap().parse().unwrap()
    };
    let mut g = a.t.db.llmgw().await.unwrap();
    let mut ids = Vec::new();
    for host in ["one.example.com", "two.example.com"] {
        ids.push(
            g.egress_ask(user, inst, host, None, 5, 20)
                .await
                .unwrap()
                .id()
                .unwrap(),
        );
    }
    g.commit().await.unwrap();

    let (st, body) = a.call(Method::GET, "/v1/egress-requests", tok, None).await;
    assert_eq!(st, StatusCode::OK, "{body}");
    let hosts: Vec<_> = body["requests"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| (r["host"].as_str().unwrap(), r["status"].as_str().unwrap()))
        .collect();
    assert_eq!(
        hosts,
        [
            ("two.example.com", "pending"),
            ("one.example.com", "pending")
        ]
    );
    let (_, body) = a
        .call(
            Method::GET,
            &format!("/v1/instances/{inst}/egress"),
            tok,
            None,
        )
        .await;
    assert_eq!(body["pending"].as_array().unwrap().len(), 2);
    let (_, body) = a
        .call(
            Method::GET,
            "/v1/egress-requests",
            Some(other.access.as_str()),
            None,
        )
        .await;
    assert_eq!(body["requests"], json!([]));

    let decide = |id: &proto::domain::EgressRequestId, who: &str, decision: &str| {
        let path = format!("/v1/egress-requests/{id}/decide");
        let who = who.to_owned();
        let body = json!({ "decision": decision });
        let a = &a;
        async move { a.call(Method::POST, &path, Some(&who), Some(body)).await }
    };
    let (st, _) = decide(&ids[0], &other.access, "always").await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (st, body) = decide(&ids[0], &u.access, "sometimes").await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    let (st, body) = decide(&ids[0], &u.access, "always").await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["status"], "always");
    let (st, _) = decide(&ids[0], &u.access, "deny").await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (st, body) = decide(&ids[1], &u.access, "once").await;
    assert_eq!(st, StatusCode::OK, "{body}");
    let (_, body) = a
        .call(Method::GET, &format!("/v1/instances/{inst}"), tok, None)
        .await;
    assert_eq!(body["egress_hosts"], json!(["one.example.com"]));
    let (_, body) = a.call(Method::GET, "/v1/egress-requests", tok, None).await;
    assert_eq!(body["requests"], json!([]));
    let (_, body) = a
        .call(
            Method::GET,
            &format!("/v1/egress-requests?all=true&instance_id={inst}"),
            tok,
            None,
        )
        .await;
    assert_eq!(body["requests"].as_array().unwrap().len(), 2);
    let audits: i64 =
        sqlx::query_scalar("SELECT count(*) FROM audit_log WHERE action = 'egress.decide'")
            .fetch_one(a.t.db.pool())
            .await
            .unwrap();
    assert_eq!(audits, 2);

    // 设置里删掉一个一直允许的网站（只删这一个）。
    let (st, body) = a
        .call(
            Method::DELETE,
            &format!("/v1/instances/{inst}/egress/hosts/One.Example.com"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{body}");
    assert_eq!(body["egress_hosts"], json!([]));
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/instances/{inst}/egress/hosts/10.0.0.1"),
            tok,
            None,
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/instances/{inst}/egress/hosts/one.example.com"),
            Some(other.access.as_str()),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
}

// ---------- 跨用户项目（8.14） ----------

impl Api {
    async fn named(&self, phone: &str, name: &str) -> User {
        let u = self.login(phone).await;
        let (st, body) = self
            .call(
                Method::PATCH,
                "/v1/me",
                Some(&u.access),
                Some(json!({ "display_name": name })),
            )
            .await;
        assert_eq!(st, StatusCode::OK, "{body}");
        u
    }

    /// 建一个单人项目，负责人是 `lead`。
    async fn new_project(&self, u: &User, name: &str, lead: InstanceId) -> String {
        let (st, body) = self
            .call(
                Method::POST,
                "/v1/projects",
                Some(&u.access),
                Some(json!({
                    "name": name,
                    "goal": "ship the redesign",
                    "agents": [{ "instance_id": lead, "is_lead": true }]
                })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{body}");
        assert_eq!(body["role"], "creator");
        body["id"].as_str().unwrap().into()
    }

    async fn link_invite(&self, u: &User, project: &str) -> (Value, String) {
        let (st, body) = self
            .call(
                Method::POST,
                &format!("/v1/projects/{project}/invites"),
                Some(&u.access),
                Some(json!({ "link": true })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{body}");
        let token = body["token"].as_str().unwrap().to_string();
        assert_eq!(body["link"], format!("thinktin://join/{token}"));
        (body["invite"].clone(), token)
    }

    async fn join_link(&self, u: &User, token: &str, agents: &[InstanceId]) -> (StatusCode, Value) {
        let agents: Vec<Value> = agents.iter().map(|a| json!({ "instance_id": a })).collect();
        self.call(
            Method::POST,
            "/v1/project-invites/accept",
            Some(&u.access),
            Some(json!({
                "token": token,
                "agents": agents,
                "daily_token_limit": 200000,
                "total_token_limit": 5000000,
                "consent": true
            })),
        )
        .await
    }

    async fn inbox_subtypes(&self, u: &User) -> Vec<String> {
        let (st, body) = self
            .call(Method::GET, "/v1/inbox", Some(&u.access), None)
            .await;
        assert_eq!(st, StatusCode::OK, "{body}");
        body["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|i| i["subtype"].as_str().map(String::from))
            .collect()
    }
}

/// 按手机号邀请（8.14）：注册的、没注册的、拉黑了的、已经在项目里的号码，回的都是 201 和同样的字段；只有该通知的人
/// 收到通知，通知里没有项目名和邀请人的名字；预览里没有手机号，也没有别的成员的用户 id。
#[tokio::test]
async fn project_phone_invites_are_uniform_over_http() {
    let Some(a) = api().await else { return };
    let alice = a.named("13800130001", "Alice").await;
    let bob = a.login("13800130002").await;
    let carol = a.login("13800130003").await;
    let dave = a.login("13800130004").await;
    let a1 = a.adopt(&alice).await;
    let d1 = a.adopt(&dave).await;
    let p = a.new_project(&alice, "Moonshot", a1).await;
    // dave 先用链接加入（已经是成员）。
    let (_, token) = a.link_invite(&alice, &p).await;
    let (st, body) = a.join_link(&dave, &token, &[d1]).await;
    assert_eq!(st, StatusCode::CREATED, "{body}");
    // carol 拉黑 alice（alice 的 id 从 bob 将要看到的那种预览里来：先用 dave 的项目详情拿）。
    let (_, detail) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}"),
            Some(&dave.access),
            None,
        )
        .await;
    let alice_id = detail["creator"]["user_id"].as_str().unwrap().to_string();
    let (st, _) = a
        .call(
            Method::PUT,
            &format!("/v1/blocks/{alice_id}"),
            Some(&carol.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let mut shapes = vec![];
    let mut bob_invite = String::new();
    for phone in ["13800130002", "13800139999", "13800130003", "13800130004"] {
        let (st, body) = a
            .call(
                Method::POST,
                &format!("/v1/projects/{p}/invites"),
                Some(&alice.access),
                Some(json!({ "phone": phone })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{phone}: {body}");
        let inv = &body["invite"];
        assert_eq!(inv["status"], "pending");
        if phone == "13800130002" {
            bob_invite = inv["id"].as_str().unwrap().into();
        }
        // 去掉 id 和打码的号码，时间换成有效期的长度：剩下的每个号码都一样（整个响应也只有 invite 一项）。
        assert_eq!(body.as_object().unwrap().len(), 1, "{body}");
        let mut norm = inv.clone();
        let o = norm.as_object_mut().unwrap();
        o.remove("id");
        assert!(
            o.remove("phone_masked")
                .unwrap()
                .as_str()
                .unwrap()
                .contains("****")
        );
        let at = |k: &str| {
            chrono::DateTime::parse_from_rfc3339(o[k].as_str().unwrap())
                .unwrap()
                .timestamp()
        };
        let ttl = at("expires_at") - at("created_at");
        o.remove("created_at");
        o.remove("expires_at");
        o.insert("ttl".into(), json!(ttl));
        shapes.push(norm);
    }
    assert!(shapes.windows(2).all(|w| w[0] == w[1]), "{shapes:?}");
    assert_eq!(shapes[0]["ttl"], 7 * 24 * 3600);
    // 再邀请 bob：还是 201、同一个 id。
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/invites"),
            Some(&alice.access),
            Some(json!({ "phone": "138 0013 0002" })),
        )
        .await;
    assert_eq!(st, StatusCode::CREATED);
    assert_eq!(body["invite"]["id"], bob_invite.as_str());
    // 号码不对：422；邀请和链接都带、都不带：422。
    for bad in [
        json!({ "phone": "12" }),
        json!({ "phone": "13800130002", "link": true }),
        json!({}),
    ] {
        let (st, _) = a
            .call(
                Method::POST,
                &format!("/v1/projects/{p}/invites"),
                Some(&alice.access),
                Some(bad),
            )
            .await;
        assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    }
    // bob 的收件箱：一条邀请，不带项目名和 alice 的名字。
    let (_, inbox) = a
        .call(Method::GET, "/v1/inbox", Some(&bob.access), None)
        .await;
    let items = inbox["items"].as_array().unwrap();
    let item = items
        .iter()
        .find(|i| i["subtype"] == "project_invite")
        .expect("an invite notice");
    assert_eq!(item["project_invite_id"], bob_invite.as_str());
    let text = format!("{}{}", item["title"], item["body"]);
    assert!(
        !text.contains("Moonshot") && !text.contains("Alice"),
        "{text}"
    );
    // carol 没收到；dave 已经在项目里，也没收到。
    assert!(
        !a.inbox_subtypes(&carol)
            .await
            .contains(&"project_invite".into())
    );
    assert!(
        !a.inbox_subtypes(&dave)
            .await
            .contains(&"project_invite".into())
    );
    // bob 的预览：没有手机号，成员没有用户 id；创建者有 id（拉黑要用）。
    let (st, preview) = a
        .call(
            Method::GET,
            &format!("/v1/project-invites/{bob_invite}"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{preview}");
    assert!(!preview.to_string().contains("1380013"));
    assert_eq!(preview["creator"]["user_id"], alice_id.as_str());
    assert_eq!(preview["project"]["name"], "Moonshot");
    for m in preview["members"].as_array().unwrap() {
        assert!(m.get("user_id").is_none(), "{m}");
    }
    let (st, mine) = a
        .call(Method::GET, "/v1/project-invites", Some(&bob.access), None)
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(mine["invites"].as_array().unwrap().len(), 1);
    // carol 看 bob 的邀请：404。
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/project-invites/{bob_invite}"),
            Some(&carol.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    // 邀请人的列表：打码的号码。
    let (_, list) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}/invites"),
            Some(&alice.access),
            None,
        )
        .await;
    let masked: Vec<_> = list["invites"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|i| i["phone_masked"].as_str())
        .collect();
    assert!(masked.iter().all(|m| m.contains("****")), "{masked:?}");
    // bob 拒绝：204；之后看不到。
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/project-invites/{bob_invite}/decline"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, mine) = a
        .call(Method::GET, "/v1/project-invites", Some(&bob.access), None)
        .await;
    assert!(mine["invites"].as_array().unwrap().is_empty());
}

/// 链接邀请从发出到加入、撤回、退出、再加入、移出（8.14）。
#[tokio::test]
async fn project_link_invite_join_and_exit_over_http() {
    let Some(a) = api().await else { return };
    let alice = a.named("13800130011", "Alice").await;
    let bob = a.named("13800130012", "Bob").await;
    let carol = a.login("13800130013").await;
    let a1 = a.adopt(&alice).await;
    let b1 = a.adopt(&bob).await;
    let c1 = a.adopt(&carol).await;
    let p = a.new_project(&alice, "Design", a1).await;
    // 建项目时同一个 agent 写两遍：422。
    let (st, body) = a
        .call(
            Method::POST,
            "/v1/projects",
            Some(&alice.access),
            Some(
                json!({ "name": "dup", "agents": [{ "instance_id": a1 }, { "instance_id": a1 }] }),
            ),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    let (invite, token) = a.link_invite(&alice, &p).await;
    let invite_id = invite["id"].as_str().unwrap();
    // 令牌只在发出时返回一次。
    let (_, list) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}/invites"),
            Some(&alice.access),
            None,
        )
        .await;
    assert!(!list.to_string().contains(&token));
    // 格式不对的令牌、链接邀请的 id 走按 id 的接口：404。
    for bad in ["tpi1_nope", "garbage", ""] {
        let (st, _) = a
            .call(
                Method::POST,
                "/v1/project-invites/resolve",
                Some(&bob.access),
                Some(json!({ "token": bad })),
            )
            .await;
        assert_eq!(st, StatusCode::NOT_FOUND, "{bad}");
    }
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/project-invites/{invite_id}/accept"),
            Some(&bob.access),
            Some(json!({
                "agents": [{ "instance_id": b1 }],
                "daily_token_limit": 1000, "total_token_limit": 5000, "consent": true
            })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    // 预览。
    let (st, preview) = a
        .call(
            Method::POST,
            "/v1/project-invites/resolve",
            Some(&bob.access),
            Some(json!({ "token": token })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{preview}");
    assert_eq!(preview["project"]["goal"], "ship the redesign");
    assert_eq!(preview["creator"]["display_name"], "Alice");
    assert_eq!(preview["members"].as_array().unwrap().len(), 1);
    assert!(preview["shared_with_project"].as_array().unwrap().len() == 5);
    assert!(preview["kept_private"].as_array().unwrap().len() == 8);
    // 不确认：422；确认了：201；再来一次：200，内容一样；carol 拿同一个令牌：404。
    let (st, _) = a
        .call(
            Method::POST,
            "/v1/project-invites/accept",
            Some(&bob.access),
            Some(json!({
                "token": token, "agents": [{ "instance_id": b1 }],
                "daily_token_limit": 1000, "total_token_limit": 5000
            })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    // 选了别人的 agent：422（邀请还能用），不是“邀请找不到”。
    let (st, body) = a.join_link(&bob, &token, &[c1]).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    let (st, joined) = a.join_link(&bob, &token, &[b1]).await;
    assert_eq!(st, StatusCode::CREATED, "{joined}");
    assert_eq!(joined["role"], "member");
    let (st, again) = a.join_link(&bob, &token, &[b1]).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(again["id"], joined["id"]);
    assert_eq!(again["members"], joined["members"]);
    let (st, _) = a.join_link(&carol, &token, &[c1]).await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    // bob 的列表、详情。
    let (_, list) = a
        .call(Method::GET, "/v1/projects", Some(&bob.access), None)
        .await;
    let projects = list["projects"].as_array().unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0]["role"], "member");
    let (_, d) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}"),
            Some(&bob.access),
            None,
        )
        .await;
    let mine: Vec<(String, bool)> = d["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| {
            (
                x["instance_id"].as_str().unwrap().into(),
                x["mine"].as_bool().unwrap(),
            )
        })
        .collect();
    assert_eq!(mine, vec![(a1.to_string(), false), (b1.to_string(), true)]);
    assert_eq!(d["my_budget"]["daily_token_limit"], 200000);
    assert!(
        a.inbox_subtypes(&alice)
            .await
            .contains(&"project_joined".into())
    );
    // 预算。
    let (st, b) = a
        .call(
            Method::PUT,
            &format!("/v1/projects/{p}/budget"),
            Some(&bob.access),
            Some(json!({ "daily_token_limit": 10, "total_token_limit": 20 })),
        )
        .await;
    assert_eq!(
        (st, b["total_token_limit"].as_u64()),
        (StatusCode::OK, Some(20))
    );
    let (st, _) = a
        .call(
            Method::PUT,
            &format!("/v1/projects/{p}/budget"),
            Some(&bob.access),
            Some(json!({ "daily_token_limit": 30, "total_token_limit": 20 })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    // 撤回自己的 agent：204，alice 收到回执。
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/projects/{p}/agents/{b1}"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert!(
        a.inbox_subtypes(&alice)
            .await
            .contains(&"project_agent_left".into())
    );
    // 再加回来（要确认）。
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/agents"),
            Some(&bob.access),
            Some(json!({ "agents": [{ "instance_id": b1 }] })),
        )
        .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    let (st, d) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/agents"),
            Some(&bob.access),
            Some(json!({ "agents": [{ "instance_id": b1 }], "consent": true })),
        )
        .await;
    assert_eq!(st, StatusCode::OK, "{d}");
    assert_eq!(d["agent_count"], 2);
    // 退出：204；之后 404、列表里没有；alice 收到回执。
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/leave"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (_, list) = a
        .call(Method::GET, "/v1/projects", Some(&bob.access), None)
        .await;
    assert!(list["projects"].as_array().unwrap().is_empty());
    assert!(
        a.inbox_subtypes(&alice)
            .await
            .contains(&"project_left".into())
    );
    // 新链接再加入，然后被移出：bob 收到回执。
    let (_, token2) = a.link_invite(&alice, &p).await;
    let (st, _) = a.join_link(&bob, &token2, &[b1]).await;
    assert_eq!(st, StatusCode::CREATED);
    let bob_id = d["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["is_me"] == true)
        .unwrap()["user_id"]
        .as_str()
        .unwrap()
        .to_string();
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/projects/{p}/members/{bob_id}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert!(
        a.inbox_subtypes(&bob)
            .await
            .contains(&"project_removed".into())
    );
    // 创建者退不了：409；共享过的项目删不了：409。
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/leave"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/projects/{p}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    // 改名、目标：创建者能改。
    let (st, d) = a
        .call(
            Method::PATCH,
            &format!("/v1/projects/{p}"),
            Some(&alice.access),
            Some(json!({ "goal": "ship it" })),
        )
        .await;
    assert_eq!((st, d["goal"].as_str()), (StatusCode::OK, Some("ship it")));
}

/// 上限（8.14）：邀请人每天的数（429 带 Retry-After，0 不限）、10 个人、20 个待处理的邀请。
#[tokio::test]
async fn project_limits_and_invite_rate_limits_over_http() {
    let Some(a) = api_with(GatewayConfig {
        cross_user_projects: true,
        limits: gateway::LimitConfig {
            invites_per_day: 2,
            ..gateway::LimitConfig::default()
        },
        ..GatewayConfig::default()
    })
    .await
    else {
        return;
    };
    let alice = a.named("13800130021", "Alice").await;
    let a1 = a.adopt(&alice).await;
    let p = a.new_project(&alice, "Limits", a1).await;
    for n in 0..2 {
        let (st, _) = a
            .call(
                Method::POST,
                &format!("/v1/projects/{p}/invites"),
                Some(&alice.access),
                Some(json!({ "phone": format!("1380013110{n}") })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED);
    }
    let resp = a
        .http
        .post(format!("{}/v1/projects/{p}/invites", a.base))
        .bearer_auth(&alice.access)
        .json(&json!({ "link": true }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
    let retry: u64 = resp.headers()["retry-after"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=86_400).contains(&retry));
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["code"], "rate_limited");
}

#[tokio::test]
async fn project_member_and_pending_caps_over_http() {
    let Some(a) = api_with(GatewayConfig {
        cross_user_projects: true,
        limits: gateway::LimitConfig {
            invites_per_day: 0,
            ..gateway::LimitConfig::default()
        },
        ..GatewayConfig::default()
    })
    .await
    else {
        return;
    };
    let alice = a.named("13800130031", "Alice").await;
    let a1 = a.adopt(&alice).await;
    let p = a.new_project(&alice, "Crowd", a1).await;
    // 九个人用链接加入，第十个人的链接先发好；十个人满了以后再接受：409 project_member_limit。
    let (_, last_token) = a.link_invite(&alice, &p).await;
    for n in 0..9 {
        let u = a.login(&format!("1380013200{n}")).await;
        let i = a.adopt(&u).await;
        let (_, token) = a.link_invite(&alice, &p).await;
        let (st, body) = a.join_link(&u, &token, &[i]).await;
        assert_eq!(st, StatusCode::CREATED, "{n}: {body}");
    }
    let late = a.login("13800132099").await;
    let li = a.adopt(&late).await;
    let (st, body) = a.join_link(&late, &last_token, &[li]).await;
    assert_eq!(st, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["code"], "project_member_limit");
    // 满了也不能再邀请。
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/invites"),
            Some(&alice.access),
            Some(json!({ "link": true })),
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::CONFLICT, Some("project_member_limit"))
    );
    // 另一个项目：20 个待处理的邀请满了，第 21 个 409 project_invite_limit。
    let a2 = a.adopt(&alice).await;
    let p2 = a.new_project(&alice, "Pending", a2).await;
    for n in 0..20 {
        let (st, _) = a
            .call(
                Method::POST,
                &format!("/v1/projects/{p2}/invites"),
                Some(&alice.access),
                Some(json!({ "phone": format!("138001330{n:02}") })),
            )
            .await;
        assert_eq!(st, StatusCode::CREATED, "{n}");
    }
    let (st, body) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p2}/invites"),
            Some(&alice.access),
            Some(json!({ "link": true })),
        )
        .await;
    assert_eq!(
        (st, body["code"].as_str()),
        (StatusCode::CONFLICT, Some("project_invite_limit"))
    );
}

/// 外人对项目什么都看不到（一律 404，不是 403）；成员调只有创建者能用的接口 403。
#[tokio::test]
async fn outsiders_see_nothing_of_a_project() {
    let Some(a) = api().await else { return };
    let alice = a.named("13800130041", "Alice").await;
    let bob = a.login("13800130042").await;
    let carol = a.login("13800130043").await;
    let a1 = a.adopt(&alice).await;
    let b1 = a.adopt(&bob).await;
    let p = a.new_project(&alice, "Private", a1).await;
    let (invite, token) = a.link_invite(&alice, &p).await;
    let invite_id = invite["id"].as_str().unwrap().to_string();
    let (st, _) = a.join_link(&bob, &token, &[b1]).await;
    assert_eq!(st, StatusCode::CREATED);
    let (_, d) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}"),
            Some(&bob.access),
            None,
        )
        .await;
    let bob_id = d["members"][1]["user_id"].as_str().unwrap().to_string();
    let routes: Vec<(Method, String, Option<Value>)> = vec![
        (Method::GET, format!("/v1/projects/{p}"), None),
        (Method::GET, format!("/v1/projects/{p}/invites"), None),
        (
            Method::PATCH,
            format!("/v1/projects/{p}"),
            Some(json!({ "name": "x" })),
        ),
        (
            Method::DELETE,
            format!("/v1/projects/{p}/members/{bob_id}"),
            None,
        ),
        (
            Method::DELETE,
            format!("/v1/projects/{p}/agents/{b1}"),
            None,
        ),
        (
            Method::DELETE,
            format!("/v1/projects/{p}/invites/{invite_id}"),
            None,
        ),
        (Method::POST, format!("/v1/projects/{p}/leave"), None),
        (
            Method::POST,
            format!("/v1/projects/{p}/invites"),
            Some(json!({ "link": true })),
        ),
        (
            Method::POST,
            format!("/v1/project-invites/{invite_id}/accept"),
            Some(json!({
                "agents": [{ "instance_id": b1 }],
                "daily_token_limit": 1, "total_token_limit": 1, "consent": true
            })),
        ),
    ];
    for (m, path, body) in &routes {
        let (st, resp) = a
            .call(m.clone(), path, Some(&carol.access), body.clone())
            .await;
        assert_eq!(st, StatusCode::NOT_FOUND, "{m} {path}: {resp}");
    }
    // 成员调只有创建者能用的：403。
    for (m, path, body) in [
        (Method::GET, format!("/v1/projects/{p}/invites"), None),
        (Method::DELETE, format!("/v1/projects/{p}"), None),
        (
            Method::PATCH,
            format!("/v1/projects/{p}"),
            Some(json!({ "name": "x" })),
        ),
        (
            Method::POST,
            format!("/v1/projects/{p}/invites"),
            Some(json!({ "link": true })),
        ),
        (
            Method::DELETE,
            format!("/v1/projects/{p}/agents/{a1}"),
            None,
        ),
    ] {
        let (st, resp) = a.call(m.clone(), &path, Some(&bob.access), body).await;
        assert_eq!(st, StatusCode::FORBIDDEN, "{m} {path}: {resp}");
        assert_eq!(resp["code"], "forbidden");
    }
}

/// 旧的团队接口碰到共享了的项目：改、删 409；看只看得到自己的 agent；加入的人的团队列表里没有它。
#[tokio::test]
async fn old_team_api_on_a_shared_project() {
    let Some(a) = api().await else { return };
    let alice = a.named("13800130051", "Alice").await;
    let bob = a.login("13800130052").await;
    let a1 = a.adopt(&alice).await;
    let b1 = a.adopt(&bob).await;
    let p = a.new_project(&alice, "Team", a1).await;
    let (_, token) = a.link_invite(&alice, &p).await;
    let (st, _) = a.join_link(&bob, &token, &[b1]).await;
    assert_eq!(st, StatusCode::CREATED);
    let (st, _) = a
        .call(
            Method::PATCH,
            &format!("/v1/teams/{p}"),
            Some(&alice.access),
            Some(json!({ "name": "renamed" })),
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/teams/{p}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::CONFLICT);
    let (st, team) = a
        .call(
            Method::GET,
            &format!("/v1/teams/{p}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::OK);
    let members = team["members"].as_array().unwrap();
    assert_eq!(members.len(), 1);
    assert_eq!(members[0]["instance_id"], a1.to_string());
    let (_, teams) = a
        .call(Method::GET, "/v1/teams", Some(&bob.access), None)
        .await;
    assert!(teams["teams"].as_array().unwrap().is_empty());
}

/// 总开关关着（默认）：邀请、预览、接受都 404；单人项目照常。
#[tokio::test]
async fn cross_user_projects_are_off_by_default() {
    let Some(a) = api_with(GatewayConfig::default()).await else {
        return;
    };
    let alice = a.named("13800130061", "Alice").await;
    let a1 = a.adopt(&alice).await;
    let p = a.new_project(&alice, "Solo", a1).await;
    let (st, _) = a
        .call(
            Method::POST,
            &format!("/v1/projects/{p}/invites"),
            Some(&alice.access),
            Some(json!({ "link": true })),
        )
        .await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    // 令牌、正文都是对的格式，回的是开关的 404（不是“邀请找不到”）。
    let token = format!("tpi1_{}", "A".repeat(43));
    let join = json!({
        "token": token, "agents": [{ "instance_id": a1 }],
        "daily_token_limit": 1, "total_token_limit": 1, "consent": true
    });
    let some_invite = uuid::Uuid::now_v7();
    for (m, path, body) in [
        (
            Method::POST,
            "/v1/project-invites/resolve".to_string(),
            Some(json!({ "token": token })),
        ),
        (
            Method::POST,
            "/v1/project-invites/accept".into(),
            Some(join.clone()),
        ),
        (Method::GET, "/v1/project-invites".into(), None),
        (
            Method::GET,
            format!("/v1/project-invites/{some_invite}"),
            None,
        ),
        (
            Method::POST,
            format!("/v1/project-invites/{some_invite}/accept"),
            Some(join.clone()),
        ),
    ] {
        let (st, resp) = a.call(m.clone(), &path, Some(&alice.access), body).await;
        assert_eq!(st, StatusCode::NOT_FOUND, "{m} {path}");
        assert_eq!(resp["message"], "route not found", "{m} {path}: {resp}");
    }
    let (st, list) = a
        .call(Method::GET, "/v1/projects", Some(&alice.access), None)
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(list["projects"].as_array().unwrap().len(), 1);
}

/// 删了的实例离开共享项目（删实例的接口提交以后撤下）。
#[tokio::test]
async fn deleting_an_instance_leaves_shared_projects_over_http() {
    let Some(a) = api().await else { return };
    let alice = a.named("13800130071", "Alice").await;
    let bob = a.login("13800130072").await;
    let a1 = a.adopt(&alice).await;
    let b1 = a.adopt(&bob).await;
    let b2 = a.adopt(&bob).await;
    let p = a.new_project(&alice, "Shared", a1).await;
    let (_, token) = a.link_invite(&alice, &p).await;
    let (st, _) = a.join_link(&bob, &token, &[b1, b2]).await;
    assert_eq!(st, StatusCode::CREATED);
    let (st, _) = a
        .call(
            Method::DELETE,
            &format!("/v1/instances/{b2}"),
            Some(&bob.access),
            None,
        )
        .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (_, d) = a
        .call(
            Method::GET,
            &format!("/v1/projects/{p}"),
            Some(&alice.access),
            None,
        )
        .await;
    assert_eq!(d["agent_count"], 2);
    let live: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM project_agents WHERE instance_id = $1 AND left_at IS NULL",
    )
    .bind(b2.0)
    .fetch_one(a.t.db.pool())
    .await
    .unwrap();
    assert_eq!(live, 0);
}
