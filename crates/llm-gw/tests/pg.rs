//! 网关接控制面数据库（生产配置）：路由、用户 DEK、授权状态从库里读，用量写进用量表，
//! 每日预算按用量表汇总。需要 DATABASE_URL（没有时跳过）。

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};
use axum::extract::{Request, State};
use axum::response::IntoResponse;
use keyvault::secrecy::SecretString;
use keyvault::{KeyStore, KeyVault, LocalKms, MemoryKeyStore};
use llm_gw::limits::{BudgetLedger, Limiter};
use llm_gw::pg::{PgDirectory, PgLedger, PgUsageSink};
use llm_gw::{Gateway, Options, build_client, router};
use proto::domain::{
    CredentialId, GrantScope, InstanceLimits, InstanceState, ModelRoute, RunGrant, UserId,
};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{Db, NewCredential, NewInstance};

const VENDOR_KEY: &str = "sk-vendor-secret-0042";
const TTL: Duration = Duration::from_millis(300);

#[derive(Default)]
struct Upstream {
    auth: Mutex<Vec<String>>,
}

async fn upstream(State(up): State<Arc<Upstream>>, req: Request) -> axum::response::Response {
    let auth = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    up.auth.lock().unwrap().push(auth);
    axum::Json(json!({
        "id": "c1", "object": "chat.completion",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": "pong"}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 20, "completion_tokens": 5},
    }))
    .into_response()
}

struct Env {
    t: TestDb,
    user: UserId,
    instance: proto::domain::InstanceId,
    credential: CredentialId,
    grant: RunGrant,
    issuer: SandboxTokenIssuer,
    gw: String,
    up: Arc<Upstream>,
    ledger: Arc<PgLedger>,
    http: reqwest::Client,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let up = Arc::new(Upstream::default());
    let app = axum::Router::new()
        .fallback(upstream)
        .with_state(up.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let up_addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    // 控制面那边：用户、DEK、加密保存的 key、实例、路由、运行授权、沙箱。
    let kms = Arc::new(LocalKms::new("local-1", &[4u8; 32]));
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    let uid = user.id.to_string();
    let vault = KeyVault::new(kms.clone(), MemoryKeyStore::default());
    vault.create_user_key(&uid).unwrap();
    let wrapped = vault.store().get(&uid).unwrap();
    w.insert_user_key(user.id, &wrapped.kms_key_id, &wrapped.ciphertext)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let credential = CredentialId::new();
    let sealed = vault
        .seal(
            &uid,
            &credential.to_string(),
            &SecretString::from(VENDOR_KEY.to_owned()),
        )
        .unwrap();
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let instance = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "vol-1".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    tx.create_credential(&NewCredential {
        id: credential,
        vendor: "custom".into(),
        label: String::new(),
        anthropic_base: None,
        openai_base: Some(format!("http://{up_addr}/v1")),
        responses_base: None,
        sealed: sealed.ciphertext,
        last4: sealed.last4,
        daily_token_limit: Some(60),
    })
    .await
    .unwrap();
    tx.set_model_routes(
        instance.id,
        &[ModelRoute {
            alias: "main".into(),
            credential_id: credential,
            upstream_model: "up-model".into(),
            fallbacks: vec![],
        }],
    )
    .await
    .unwrap();
    let grant = tx
        .create_run_grant(
            instance.id,
            None,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    tx.commit().await.unwrap();
    set_sandbox(&t.db, instance.id, "sbx-1").await;

    // 网关这边：同一把主密钥，DEK 从库里读。
    let keys = Arc::new(MemoryKeyStore::default());
    let issuer = SandboxTokenIssuer::generate("k1").unwrap();
    let mut verifier = SandboxTokenVerifier::new();
    verifier
        .add_key_b64("k1", &issuer.verifying_key_b64())
        .unwrap();
    let options = Options {
        insecure_upstreams: true,
        allow_unbound_tokens: true,
        ..Options::default()
    };
    let (sink, _writer) = PgUsageSink::spawn(t.db.clone());
    let ledger = Arc::new(PgLedger::new(
        t.db.clone(),
        options.budget_utc_offset_secs,
        TTL,
    ));
    let gw = Gateway {
        verifier,
        directory: Arc::new(PgDirectory::new(t.db.clone(), keys.clone(), TTL)),
        secrets: Arc::new(KeyVault::new(kms, keys)),
        vault: Default::default(),
        usage: Arc::new(sink),
        ledger: ledger.clone(),
        limiter: Limiter::default(),
        cooldowns: Default::default(),
        client: build_client(&options, None).unwrap(),
        options,
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(llm_gw::serve(
        listener,
        router(Arc::new(gw)),
        llm_gw::ServeOptions::default(),
        std::future::pending(),
    ));
    Some(Env {
        t,
        user: user.id,
        instance: instance.id,
        credential,
        grant,
        issuer,
        gw: format!("http://{addr}"),
        up,
        ledger,
        http: reqwest::Client::builder().no_proxy().build().unwrap(),
    })
}

async fn set_sandbox(db: &Db, instance: proto::domain::InstanceId, sbx: &str) {
    let mut w = db.worker().await.unwrap();
    w.set_instance_runtime(instance, InstanceState::Running, Some(sbx), None, None)
        .await
        .unwrap();
    w.commit().await.unwrap();
}

impl Env {
    fn token(&self, sbx: &str) -> String {
        self.token_at(sbx, 0)
    }

    fn token_at(&self, sbx: &str, ep: u64) -> String {
        self.issuer
            .issue(
                TokenRequest {
                    ep,
                    iid: self.instance.to_string(),
                    uid: self.user.to_string(),
                    grant: self.grant.id.to_string(),
                    sbx: sbx.into(),
                    net: None,
                },
                600,
                now(),
            )
            .unwrap()
    }

    async fn chat(&self, token: &str) -> (u16, Value) {
        let r = self
            .http
            .post(format!("{}/openai/v1/chat/completions", self.gw))
            .bearer_auth(token)
            .json(&json!({ "model": "main", "messages": [{ "role": "user", "content": "ping" }] }))
            .send()
            .await
            .unwrap();
        let status = r.status().as_u16();
        (status, r.json().await.unwrap_or(Value::Null))
    }

    async fn usage_rows(&self) -> Vec<(Option<uuid::Uuid>, i64, String)> {
        sqlx::query_as(
            "SELECT run_grant_id, charged_tokens, alias FROM usage_records WHERE instance_id = $1 ORDER BY created_at",
        )
        .bind(self.instance.0)
        .fetch_all(self.t.db.pool())
        .await
        .unwrap()
    }
}

async fn eventually<F, Fut>(what: &str, f: F)
where
    F: Fn() -> Fut,
    Fut: Future<Output = bool>,
{
    for _ in 0..100 {
        if f().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn routes_keys_usage_and_budget_come_from_the_database() {
    let Some(e) = env().await else { return };
    let token = e.token("sbx-1");
    let (st, body) = e.chat(&token).await;
    assert_eq!(st, 200, "{body}");
    assert_eq!(body["choices"][0]["message"]["content"], "pong");
    assert_eq!(
        e.up.auth.lock().unwrap().last().unwrap(),
        &format!("Bearer {VENDOR_KEY}"),
        "the user's key was decrypted with the DEK from the database"
    );
    // 用量写进用量表，带着运行授权（执行器按它算这次运行的 token）。
    eventually("usage row", || async { e.usage_rows().await.len() == 1 }).await;
    let rows = e.usage_rows().await;
    assert_eq!(rows[0], (Some(e.grant.id.0), 25, "main".to_string()));

    // 每日预算按用量表汇总：60 的额度，用了 25、50 之后第三次被拒。
    let (st, _) = e.chat(&token).await;
    assert_eq!(st, 200);
    eventually("second usage row", || async {
        e.usage_rows().await.len() == 2
    })
    .await;
    tokio::time::sleep(TTL).await;
    let day = (now() as i64 + 8 * 3600) as u64 / 86_400;
    assert_eq!(e.ledger.used(&e.credential.to_string(), day).await, 50);
    let (st, _) = e.chat(&token).await;
    assert_eq!(st, 200, "50 < 60 still passes");
    eventually("third usage row", || async {
        e.usage_rows().await.len() == 3
    })
    .await;
    tokio::time::sleep(TTL).await;
    let (st, body) = e.chat(&token).await;
    assert_eq!(st, 402, "{body}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sandbox_changes_and_revocations_take_effect() {
    let Some(e) = env().await else { return };
    let old = e.token("sbx-1");
    assert_eq!(e.chat(&old).await.0, 200);

    // 实例唤醒换了沙箱：新令牌立刻能用（不等缓存过期），旧令牌不行。
    set_sandbox(&e.t.db, e.instance, "sbx-2").await;
    let new = e.token("sbx-2");
    assert_eq!(e.chat(&new).await.0, 200);
    assert_eq!(e.chat(&old).await.0, 401);

    // 运行结束（令牌代数加一）：沙箱 id 没变，之前签的令牌也作废；新签的立刻能用。
    let mut w = e.t.db.worker().await.unwrap();
    w.bump_token_epoch(e.instance).await.unwrap();
    w.commit().await.unwrap();
    let next = e.token_at("sbx-2", 1);
    assert_eq!(e.chat(&next).await.0, 200);
    assert_eq!(e.chat(&new).await.0, 401);

    // 吊销运行授权：缓存过期后拒绝。
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.revoke_run_grant(e.grant.id, "test").await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::sleep(TTL + Duration::from_millis(50)).await;
    assert_eq!(e.chat(&next).await.0, 401);

    // 不认识的授权 id 一律拒绝。
    let bogus = e
        .issuer
        .issue(
            TokenRequest {
                ep: 0,
                iid: e.instance.to_string(),
                uid: e.user.to_string(),
                grant: "not-a-grant".into(),
                sbx: "sbx-2".into(),
                net: None,
            },
            600,
            now(),
        )
        .unwrap();
    assert_eq!(e.chat(&bogus).await.0, 401);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn erased_accounts_cannot_use_their_keys() {
    let Some(e) = env().await else { return };
    let token = e.token("sbx-1");
    assert_eq!(e.chat(&token).await.0, 200);
    // 注销：DEK 销毁、数据删除。缓存过期后网关拿不到 key 和实例。
    let mut w = e.t.db.worker().await.unwrap();
    w.erase_account(e.user).await.unwrap();
    w.commit().await.unwrap();
    tokio::time::sleep(TTL + Duration::from_millis(50)).await;
    let (st, _) = e.chat(&token).await;
    assert!(st == 401 || st == 403, "{st}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn narrowed_grants_only_reach_their_aliases() {
    let Some(e) = env().await else { return };
    let mut w = e.t.db.worker().await.unwrap();
    let narrow = |aliases: &[&str]| GrantScope {
        aliases: aliases.iter().map(|a| a.to_string()).collect(),
        ..GrantScope::default()
    };
    let only_other = w
        .create_child_grant(
            e.grant.id,
            e.instance,
            &narrow(&["other"]),
            Duration::from_secs(600),
        )
        .await
        .unwrap();
    let only_main = w
        .create_child_grant(
            e.grant.id,
            e.instance,
            &narrow(&["main"]),
            Duration::from_secs(600),
        )
        .await
        .unwrap();
    w.commit().await.unwrap();
    let token = |grant: &RunGrant| {
        e.issuer
            .issue(
                TokenRequest {
                    ep: 0,
                    iid: e.instance.to_string(),
                    uid: e.user.to_string(),
                    grant: grant.id.to_string(),
                    sbx: "sbx-1".into(),
                    net: None,
                },
                600,
                now(),
            )
            .unwrap()
    };
    let (st, body) = e.chat(&token(&only_other)).await;
    assert_eq!(st, 403, "{body}");
    assert_eq!(e.chat(&token(&only_main)).await.0, 200);
}

/// 保险箱条目（9.11）：网关用 `thinktin_llmgw` 角色读得到密文、用库里的 DEK 解得开，用来抹值。
#[tokio::test]
async fn vault_items_are_loaded_for_scrubbing() {
    use llm_gw::store::Directory;

    let Some(t) = TestDb::new().await else { return };
    let kms = Arc::new(LocalKms::new("local-1", &[4u8; 32]));
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000009").await.unwrap();
    let uid = user.id.to_string();
    let vault = KeyVault::new(kms.clone(), MemoryKeyStore::default());
    vault.create_user_key(&uid).unwrap();
    let wrapped = vault.store().get(&uid).unwrap();
    w.insert_user_key(user.id, &wrapped.kms_key_id, &wrapped.ciphertext)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &uid,
            &id.to_string(),
            &keyvault::VaultSecret {
                username: String::new(),
                password: "pg-vault-pass".into(),
            },
        )
        .unwrap();
    let mut tx = t.db.tenant(user.id).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "db".into(),
        purpose: String::new(),
        sealed,
        has_username: false,
        instance_ids: vec![],
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();

    let keys = Arc::new(MemoryKeyStore::default());
    let dir = PgDirectory::new(t.db.clone(), keys.clone(), TTL);
    let items = dir.vault_items(&uid).await.unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(
        (items[0].id.as_str(), items[0].name.as_str()),
        (id.to_string().as_str(), "db")
    );
    // 读条目时顺手把用户的 DEK 放进了共享的密钥库。
    let gw_vault = KeyVault::new(kms, keys);
    let secret = gw_vault
        .open_vault(&uid, &items[0].id, &items[0].sealed)
        .unwrap();
    assert_eq!(secret.password, "pg-vault-pass");
    assert!(
        dir.vault_items(&UserId::new().to_string())
            .await
            .unwrap()
            .is_empty()
    );
    assert!(dir.vault_items("not-a-uuid").await.unwrap().is_empty());
}
