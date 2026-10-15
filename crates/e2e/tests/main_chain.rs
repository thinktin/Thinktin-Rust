//! 主链路：用户登录 → 存 key → 领养 agent、配模型别名 → 下任务 → 控制面唤醒本地沙箱、
//! 换沙箱令牌、起 agent-shim 和 agent → agent 拿沙箱令牌调模型网关 → 网关从库里取出用户的 key
//! 换给模拟厂商 → 回答经事件流回到客户端 → 运行成功、用量记账、收件箱有结果。
//!
//! 同时检查密钥卫生（WBS 15.4）：厂商 key 不进沙箱（文件、环境）、不进日志；沙箱令牌不落盘。
//! 需要 DATABASE_URL（没有时跳过）。

use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier};
use auth::sms::RecordingSms;
use axum::extract::{Request, State};
use axum::response::IntoResponse;
use client_core::api::{Api, ApiConfig, MemorySessionStore, NewCredential};
use client_core::cache::Cache;
use client_core::client::Client;
use client_core::events::{EventSink, StreamConfig, StreamStatus};
use keyvault::{KeyVault, LocalKms, MemoryKeyStore};
use llm_gw::limits::Limiter;
use llm_gw::pg::{PgDirectory, PgLedger, PgUsageSink};
use llm_gw::{Gateway, Options, build_client, router};
use proto::domain::{DevicePlatform, InstanceEvent, ModelRoute, RunState};
use serde_json::{Value, json};
use server::{Config, Hooks};
use store::testing::TestDb;

const VENDOR_KEY: &str = "sk-e2e-vendor-key-7f3a9c";
const KMS_HEX: &str = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
const ANSWER: &str = "晴，25 度";

// ---------- 日志收集：检查 key 不进日志 ----------

#[derive(Clone, Default)]
struct Logs(Arc<Mutex<Vec<u8>>>);

impl Write for Logs {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Logs {
    type Writer = Logs;
    fn make_writer(&'a self) -> Logs {
        self.clone()
    }
}

// ---------- 模拟厂商 ----------

#[derive(Default)]
struct Vendor {
    seen: Mutex<Vec<(String, Value)>>,
}

async fn vendor(State(v): State<Arc<Vendor>>, req: Request) -> axum::response::Response {
    let auth = req
        .headers()
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    let body = axum::body::to_bytes(req.into_body(), 1 << 20)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    v.seen.lock().unwrap().push((auth, body));
    axum::Json(json!({
        "id": "c1", "object": "chat.completion",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": ANSWER}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 30, "completion_tokens": 12},
    }))
    .into_response()
}

async fn listen() -> (tokio::net::TcpListener, SocketAddr) {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let a = l.local_addr().unwrap();
    (l, a)
}

// ---------- 组件 ----------

fn binaries() -> (PathBuf, PathBuf) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let status = std::process::Command::new(env!("CARGO"))
        .args(["build", "-q", "-p", "agent-shim", "--bins"])
        .current_dir(&root)
        .status()
        .expect("run cargo build");
    assert!(status.success());
    let target = std::env::var("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("target"));
    let dir = target.join("debug").canonicalize().unwrap();
    (dir.join("agent-shim"), dir.join("fake-acp-agent"))
}

/// 假 agent 的清单：配置方式和 Pi 一样（shim 写 models.json，key 是沙箱令牌的环境变量引用）。
fn manifest(dir: &Path, agent: &Path) -> PathBuf {
    let path = dir.join("fake.toml");
    std::fs::write(
        &path,
        format!(
            r#"
            [agent]
            id = "fake"
            name = "Fake"
            upstream = "https://example.com/fake"
            version = "0.0.1"
            license = "MIT"
            sites = ["cn"]

            [runtime]
            template = "agents/fake:0.0.1"
            vcpu = 1
            memory_mb = 256
            state_dirs = [".fake-agent"]

            [[harness]]
            id = "acp"
            kind = "acp"
            command = ["{}"]
            session = {{ restore = true, per_session_mcp = true }}

            [llm]
            protocols = ["openai-completions"]
            config = "pi"
            "#,
            agent.display()
        ),
    )
    .unwrap();
    path
}

async fn start_llm_gw(db: store::Db, issuer: &SandboxTokenIssuer) -> String {
    let mut verifier = SandboxTokenVerifier::new();
    verifier
        .add_key_b64(issuer.kid(), &issuer.verifying_key_b64())
        .unwrap();
    let options = Options {
        // 本地沙箱没有独立的网络身份，模拟厂商是 http。
        insecure_upstreams: true,
        allow_unbound_tokens: true,
        ..Options::default()
    };
    let keys = Arc::new(MemoryKeyStore::default());
    let (sink, _writer) = PgUsageSink::spawn(db.clone());
    let ttl = Duration::from_secs(1);
    let gw = Gateway {
        verifier,
        directory: Arc::new(PgDirectory::new(db.clone(), keys.clone(), ttl)),
        secrets: Arc::new(KeyVault::new(
            LocalKms::from_hex("local-1", KMS_HEX).unwrap(),
            keys,
        )),
        usage: Arc::new(sink),
        ledger: Arc::new(PgLedger::new(db, options.budget_utc_offset_secs, ttl)),
        limiter: Limiter::default(),
        cooldowns: Default::default(),
        client: build_client(&options, None).unwrap(),
        options,
    };
    let (l, addr) = listen().await;
    tokio::spawn(llm_gw::serve(
        l,
        router(Arc::new(gw)),
        llm_gw::ServeOptions::default(),
        std::future::pending(),
    ));
    format!("http://{addr}")
}

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<InstanceEvent>>,
    statuses: Mutex<Vec<StreamStatus>>,
}

impl EventSink for Sink {
    fn on_event(&self, event: &InstanceEvent) {
        self.events.lock().unwrap().push(event.clone());
    }
    fn on_reset(&self, _: u64, _: Option<u64>) {}
    fn on_status(&self, status: StreamStatus) {
        self.statuses.lock().unwrap().push(status);
    }
}

/// 目录下所有文件里有没有 `needle`。
fn files_containing(dir: &Path, needle: &[u8]) -> Vec<PathBuf> {
    let mut hits = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.flatten() {
            let p = e.path();
            let Ok(meta) = std::fs::symlink_metadata(&p) else {
                continue;
            };
            if meta.is_dir() {
                stack.push(p);
            } else if meta.is_file()
                && let Ok(bytes) = std::fs::read(&p)
                && bytes.windows(needle.len()).any(|w| w == needle)
            {
                hits.push(p);
            }
        }
    }
    hits
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_task_runs_through_the_whole_platform() {
    let logs = Logs::default();
    let _ = tracing_subscriber::fmt()
        .with_env_filter("debug,hyper=info,hyper_util=info,h2=info,sqlx=warn,reqwest=info,rustls=info,tungstenite=info,tokio_tungstenite=info")
        .with_writer(logs.clone())
        .try_init();
    let Some(t) = TestDb::new().await else { return };
    let (shim, agent) = binaries();
    let dir = tempfile::tempdir().unwrap();

    // 模拟厂商和模型网关。
    let up = Arc::new(Vendor::default());
    let (l, vendor_addr) = listen().await;
    let app = axum::Router::new().fallback(vendor).with_state(up.clone());
    tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
    let issuer = SandboxTokenIssuer::generate("k1").unwrap();
    let gw_url = start_llm_gw(t.db.clone(), &issuer).await;

    // 控制面：接口 + 后台任务，本地沙箱后端，沙箱里跑假 agent。
    let mut cfg = Config::parse(&format!(
        r#"
        [shutdown]
        drain_secs = 0
        grace_secs = 10
        [api]
        enabled = true
        dev_sms = true
        [worker]
        enabled = true
        sweep_every_secs = 3600
        [sandbox]
        local_root = "{}"
        shim_path = "{}"
        gateway_url = "{gw_url}"
        manifest_override = "{}"
        token_kid = "k1"
        [storage]
        local_root = "{}"
        "#,
        dir.path().join("sandboxes").display(),
        shim.display(),
        manifest(dir.path(), &agent).display(),
        dir.path().join("blobs").display(),
    ))
    .unwrap();
    cfg.sandbox_token_seed = Some(issuer.seed_b64().to_string());
    cfg.api_secrets = server::config::ApiSecrets {
        access_token_seed: Some(
            auth::signed::Signer25519::generate("a1")
                .unwrap()
                .seed_b64()
                .to_string(),
        ),
        code_pepper: Some("ab".repeat(32)),
        kms_key: Some(KMS_HEX.into()),
    };
    let sms = Arc::new(RecordingSms::default());
    let (l, server_addr) = listen().await;
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let db = t.db.clone();
    let hooks = Hooks {
        sms: Some(sms_for_server(&sms)),
    };
    let server = tokio::spawn(async move {
        server::serve_with(
            &cfg,
            db,
            l,
            async {
                stop_rx.await.ok();
            },
            hooks,
        )
        .await
    });

    // 客户端：登录、存 key、领养、配别名。
    let store = Arc::new(MemorySessionStore::default());
    let client = Client::new(
        Api::new(
            ApiConfig {
                base_url: format!("http://{server_addr}"),
                platform: DevicePlatform::Ios,
                device_name: "iPhone".into(),
                timeout: Duration::from_secs(10),
            },
            store,
        )
        .unwrap(),
        Some(Cache::open(dir.path().join("client.db")).unwrap()),
    )
    .unwrap();
    client.api.send_code("13800138600").await.unwrap();
    let code = sms.last_code("+8613800138600").unwrap();
    client.login("13800138600", &code, None).await.unwrap();
    let cred = client
        .api
        .add_credential(&NewCredential {
            vendor: "custom".into(),
            label: "测试厂商".into(),
            api_key: VENDOR_KEY.into(),
            openai_base: Some("https://vendor.example/v1".into()),
            ..NewCredential::default()
        })
        .await
        .unwrap();
    assert_eq!(cred.last4, "3a9c", "only the last 4 characters come back");
    // 接口只收 https 的自定义地址；模拟厂商是本机的 http，测试里直接改库。
    sqlx::query("UPDATE credentials SET openai_base = $1 WHERE id = $2")
        .bind(format!("http://{vendor_addr}/v1"))
        .bind(cred.id.0)
        .execute(t.db.pool())
        .await
        .unwrap();
    let inst = client.api.adopt("claude", "助手", None).await.unwrap();
    client
        .api
        .set_model_routes(
            inst.id,
            &[ModelRoute {
                alias: "main".into(),
                credential_id: cred.id,
                upstream_model: "vendor-model".into(),
                fallbacks: vec![],
            }],
        )
        .await
        .unwrap();

    // 下任务，看着事件流。
    let sink = Arc::new(Sink::default());
    let _sub = client.subscribe(
        &tokio::runtime::Handle::current(),
        inst.id,
        sink.clone(),
        StreamConfig::default(),
    );
    let run = client
        .api
        .create_run(inst.id, "llm 今天天气怎么样")
        .await
        .unwrap();
    let mut done = None;
    for _ in 0..240 {
        let r = client.api.run(run.id).await.unwrap();
        if r.state.is_terminal() {
            done = Some(r);
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let done = done.expect("the run did not finish");
    assert_eq!(done.state, RunState::Succeeded, "{done:?}");
    assert_eq!(done.summary.as_deref(), Some(&*format!("llm: {ANSWER}")));

    // 厂商收到的是用户的 key 和真实模型名，不是别名、不是沙箱令牌。
    let seen = up.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].0, format!("Bearer {VENDOR_KEY}"));
    assert_eq!(seen[0].1["model"], "vendor-model");
    assert_eq!(seen[0].1["messages"][0]["content"], "今天天气怎么样");

    // 事件流把回答和运行状态推给了客户端。
    for _ in 0..100 {
        let got = sink.events.lock().unwrap().iter().any(|e| {
            e.kind == "run.state" && e.run_id == Some(run.id) && e.payload["state"] == "succeeded"
        });
        if got {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let events = sink.events.lock().unwrap().clone();
    assert!(
        events.iter().any(|e| e.kind == "agent.message"
            && e.payload["text"]
                .as_str()
                .is_some_and(|t| t.contains(ANSWER))),
        "{events:#?}"
    );
    assert!(
        events
            .iter()
            .any(|e| e.kind == "run.state" && e.payload["state"] == "succeeded")
    );

    // 用量按运行授权记账。
    let mut usage: Vec<(i64, String)> = Vec::new();
    for _ in 0..40 {
        usage = sqlx::query_as(
            "SELECT charged_tokens, upstream_model FROM usage_records WHERE instance_id = $1 AND run_grant_id IS NOT NULL",
        )
        .bind(inst.id.0)
        .fetch_all(t.db.pool())
        .await
        .unwrap();
        if !usage.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(usage, [(42, "vendor-model".to_string())]);

    // 收件箱里有结果（推送可能丢，收件箱不会）。
    let inbox = client.sync_inbox(20).await.unwrap();
    assert!(
        inbox
            .items
            .iter()
            .any(|i| i.kind == "run_finished" && i.run_id == Some(run.id)),
        "{inbox:?}"
    );

    // 密钥卫生：厂商 key 不在沙箱里（文件），沙箱令牌不落盘，日志里都没有。
    let sandboxes = dir.path().join("sandboxes");
    assert!(
        files_containing(&sandboxes, VENDOR_KEY.as_bytes()).is_empty(),
        "the vendor key reached the sandbox"
    );
    assert!(
        files_containing(&sandboxes, b"tts1.").is_empty(),
        "a sandbox token was written to disk"
    );
    stop_tx.send(()).unwrap();
    server.await.unwrap().unwrap();
    let logs = String::from_utf8_lossy(&logs.0.lock().unwrap()).into_owned();
    assert!(!logs.is_empty(), "logs were captured");
    assert!(
        !logs.contains(VENDOR_KEY),
        "the vendor key appeared in logs"
    );
    // 日志里的令牌只能是打码后的样子（前缀.kid.***）。
    for (i, _) in logs.match_indices("tts1.") {
        assert!(
            logs[i..].starts_with("tts1.k1.***"),
            "an unredacted sandbox token appeared in logs: {}",
            &logs[i..(i + 40).min(logs.len())]
        );
    }
}

fn sms_for_server(sms: &Arc<RecordingSms>) -> Arc<dyn auth::sms::SmsSender> {
    sms.clone()
}
