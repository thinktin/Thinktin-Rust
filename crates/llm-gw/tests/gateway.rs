//! 网关端到端测试：agent 侧 HTTP 客户端 → 网关 → 假厂商。

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};
use axum::body::{Body, Bytes};
use axum::extract::{Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use keyvault::secrecy::SecretString;
use keyvault::{KeyVault, LocalKms, MemoryKeyStore, VaultSecret};
use llm_gw::limits::{Limiter, MemoryLedger};
use llm_gw::store::{Credential, Fallback, Instance, Limits, MemoryDirectory, Route, SealedVault};
use llm_gw::usage::{MemorySink, Outcome, Usage};
use llm_gw::{Gateway, Options, build_client, router};
use serde_json::{Value, json};

const VENDOR_KEY: &str = "sk-vendor-secret-0001";
const VAULT_SECRET: &str = "gh-vault-secret-42";

// ---------- 假厂商 ----------

#[derive(Debug, Clone)]
struct Seen {
    path: String,
    headers: HeaderMap,
    body: Vec<u8>,
}

#[derive(Default)]
struct Upstream {
    seen: Mutex<Vec<Seen>>,
}

impl Upstream {
    fn requests(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

const ANTHROPIC_SSE: &str = concat!(
    "event: message_start\n",
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"model\":\"up-model\",\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":30,\"output_tokens\":1}}}\n\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"pong\"}}\n\n",
    "event: message_delta\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":6}}\n\n",
    "event: message_stop\n",
    "data: {\"type\":\"message_stop\"}\n\n",
);

const CHAT_CONTENT: &str =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"pong\"}}]}\n\n";
const CHAT_USAGE: &str = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":8}}}\n\n";
const CHAT_DONE: &str = "data: [DONE]\n\n";

fn sse(body: String) -> Response {
    // 按很小的块发，检验网关的增量解析。
    let chunks: Vec<Result<Bytes, std::io::Error>> = body
        .into_bytes()
        .chunks(7)
        .map(|c| Ok(Bytes::copy_from_slice(c)))
        .collect();
    Response::builder()
        .header("content-type", "text/event-stream")
        .header("request-id", "req-123")
        .header("set-cookie", "upstream=1")
        .body(Body::from_stream(futures_util::stream::iter(chunks)))
        .unwrap()
}

async fn upstream_handler(State(up): State<Arc<Upstream>>, req: Request) -> Response {
    let path = req
        .uri()
        .path_and_query()
        .map(|p| p.to_string())
        .unwrap_or_default();
    let headers = req.headers().clone();
    let body = axum::body::to_bytes(req.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec();
    up.seen.lock().unwrap().push(Seen {
        path: path.clone(),
        headers,
        body: body.clone(),
    });
    let json: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let route = path.split('?').next().unwrap();
    match route {
        "/v/anthropic/v1/messages" => sse(ANTHROPIC_SSE.to_owned()),
        "/v/openai/v1/chat/completions" => {
            let mut out = CHAT_CONTENT.to_owned();
            if json["stream_options"]["include_usage"] == json!(true) {
                out.push_str(CHAT_USAGE);
            }
            out.push_str(CHAT_DONE);
            sse(out)
        }
        "/v/openai/v1/responses" => axum::Json(json!({
            "id": "resp_1", "object": "response", "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "pong"}]}],
            "usage": {"input_tokens": 50, "input_tokens_details": {"cached_tokens": 40}, "output_tokens": 9},
        }))
        .into_response(),
        "/bad/anthropic/v1/messages" => (
            StatusCode::UNAUTHORIZED,
            axum::Json(json!({"type": "error", "error": {"type": "authentication_error", "message": format!("invalid x-api-key {VENDOR_KEY}")}})),
        )
            .into_response(),
        "/slow/anthropic/v1/messages" => {
            let head = ANTHROPIC_SSE.split("event: content_block_delta").next().unwrap().to_owned();
            let stream = futures_util::stream::once(async move { Ok::<_, std::io::Error>(Bytes::from(head)) })
                .chain(futures_util::stream::pending());
            Response::builder()
                .header("content-type", "text/event-stream")
                .body(Body::from_stream(stream))
                .unwrap()
        }
        // 被限流：降级链换下一把 key，这把按 Retry-After 冷却。
        "/busy/anthropic/v1/messages" => (
            StatusCode::TOO_MANY_REQUESTS,
            [("retry-after", "7")],
            axum::Json(json!({"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}})),
        )
            .into_response(),
        // 请求本身有问题：换 key 也没用，不降级。
        "/broke/anthropic/v1/messages" => (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({"type": "error", "error": {"type": "invalid_request_error", "message": "bad request"}})),
        )
            .into_response(),
        // 迟迟不回响应头。
        "/hang/anthropic/v1/messages" => {
            tokio::time::sleep(Duration::from_secs(30)).await;
            (StatusCode::OK, "late").into_response()
        }
        // 2xx 但不带用量。
        "/nousage/openai/v1/chat/completions" => {
            axum::Json(json!({"choices": [{"message": {"content": "pong"}}]})).into_response()
        }
        _ => (StatusCode::NOT_FOUND, "no such upstream route").into_response(),
    }
}

use futures_util::StreamExt;

async fn start_upstream() -> (SocketAddr, Arc<Upstream>) {
    let up = Arc::new(Upstream::default());
    let app = axum::Router::new()
        .fallback(upstream_handler)
        .with_state(up.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (addr, up)
}

// ---------- 网关 ----------

struct Env {
    gw: String,
    upstream: Arc<Upstream>,
    sink: Arc<MemorySink>,
    ledger: Arc<MemoryLedger>,
    directory: Arc<MemoryDirectory>,
    issuer: SandboxTokenIssuer,
    http: reqwest::Client,
}

struct Setup {
    options: Options,
    limits: Limits,
    daily_token_limit: Option<u64>,
}

impl Default for Setup {
    fn default() -> Self {
        Self {
            options: Options {
                insecure_upstreams: true,
                ..Options::default()
            },
            limits: Limits::default(),
            daily_token_limit: None,
        }
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

async fn credential(
    vault: &KeyVault<LocalKms, MemoryKeyStore>,
    id: &str,
    base: &str,
    responses: bool,
    daily_token_limit: Option<u64>,
) -> Credential {
    Credential {
        id: id.into(),
        user_id: "user-1".into(),
        vendor: "custom".into(),
        anthropic_base: Some(format!("{base}/anthropic")),
        openai_base: Some(format!("{base}/openai/v1")),
        responses_base: responses.then(|| format!("{base}/openai/v1")),
        secret: vault
            .seal("user-1", id, &SecretString::from(VENDOR_KEY.to_owned()))
            .await
            .unwrap(),
        daily_token_limit,
        disabled: false,
    }
}

async fn start(setup: Setup) -> Env {
    let (upstream_addr, upstream) = start_upstream().await;
    let vault = KeyVault::new(LocalKms::new("test", &[7u8; 32]), MemoryKeyStore::default());
    vault.create_user_key("user-1").await.unwrap();
    let base = format!("http://{upstream_addr}/v");
    let creds = vec![
        credential(&vault, "cred-main", &base, true, setup.daily_token_limit).await,
        credential(&vault, "cred-nores", &base, false, None).await,
        credential(
            &vault,
            "cred-bad",
            &format!("http://{upstream_addr}/bad"),
            true,
            None,
        )
        .await,
        credential(
            &vault,
            "cred-slow",
            &format!("http://{upstream_addr}/slow"),
            true,
            None,
        )
        .await,
        credential(
            &vault,
            "cred-hang",
            &format!("http://{upstream_addr}/hang"),
            true,
            None,
        )
        .await,
        credential(
            &vault,
            "cred-nousage",
            &format!("http://{upstream_addr}/nousage"),
            true,
            None,
        )
        .await,
        credential(
            &vault,
            "cred-busy",
            &format!("http://{upstream_addr}/busy"),
            true,
            None,
        )
        .await,
        credential(
            &vault,
            "cred-broke",
            &format!("http://{upstream_addr}/broke"),
            true,
            None,
        )
        .await,
        // 没有人监听的端口：连不上。
        credential(&vault, "cred-down", "http://127.0.0.1:1/v", true, None).await,
        // https 加域名能通过静态检查，要靠 DNS 解析这一步拦住。
        credential(
            &vault,
            "cred-local",
            &format!("https://localhost:{}/v", upstream_addr.port()),
            true,
            None,
        )
        .await,
    ];
    let route = |cred: &str, model: &str| Route {
        credential: cred.into(),
        model: model.into(),
        fallbacks: vec![],
    };
    let chain = |cred: &str, model: &str, fallbacks: &[(&str, &str)]| Route {
        fallbacks: fallbacks
            .iter()
            .map(|(c, m)| Fallback {
                credential: (*c).into(),
                model: (*m).into(),
            })
            .collect(),
        ..route(cred, model)
    };
    let instance = Instance {
        id: "inst-1".into(),
        user_id: "user-1".into(),
        sandbox: Some("sbx-1".into()),
        epoch: 0,
        active: true,
        routes: BTreeMap::from([
            ("main".into(), route("cred-main", "up-model")),
            ("nores".into(), route("cred-nores", "up-model")),
            ("bad".into(), route("cred-bad", "up-model")),
            ("slow".into(), route("cred-slow", "up-model")),
            ("local".into(), route("cred-local", "up-model")),
            ("hang".into(), route("cred-hang", "up-model")),
            ("nousage".into(), route("cred-nousage", "up-model")),
            (
                "chain".into(),
                chain(
                    "cred-busy",
                    "m-busy",
                    &[("cred-bad", "m-bad"), ("cred-main", "m-main")],
                ),
            ),
            (
                "allbad".into(),
                chain("cred-busy", "m-busy", &[("cred-bad", "m-bad")]),
            ),
            (
                "broke".into(),
                chain("cred-broke", "m-broke", &[("cred-main", "m-main")]),
            ),
            (
                "down".into(),
                chain("cred-down", "m-down", &[("cred-main", "m-main")]),
            ),
            // cred-nores 没有 Responses 接口：调 Responses 时跳过它。
            (
                "codex".into(),
                chain("cred-nores", "m-nores", &[("cred-main", "m-main")]),
            ),
            // cred-main 的当日预算用完后跳到 cred-nores。
            (
                "budgeted".into(),
                chain("cred-main", "m-main", &[("cred-nores", "m-nores")]),
            ),
        ]),
        limits: setup.limits,
    };
    let directory = Arc::new(MemoryDirectory::new(vec![instance], creds, vec![]));
    // 用户保险箱里的一个条目（9.11）：转发前从请求里抹掉。
    directory.set_vault(
        "user-1",
        vec![SealedVault {
            id: "item-1".into(),
            name: "github".into(),
            sealed: vault
                .seal_vault(
                    "user-1",
                    "item-1",
                    &VaultSecret {
                        username: "octocat".into(),
                        password: VAULT_SECRET.into(),
                    },
                )
                .await
                .unwrap(),
        }],
    );
    let issuer = SandboxTokenIssuer::generate("k1").unwrap();
    let mut verifier = SandboxTokenVerifier::new();
    verifier
        .add_key_b64("k1", &issuer.verifying_key_b64())
        .unwrap();
    let sink = Arc::new(MemorySink::default());
    let ledger = Arc::new(MemoryLedger::default());
    let gw = Gateway {
        verifier,
        directory: directory.clone(),
        secrets: Arc::new(vault),
        vault: Default::default(),
        usage: sink.clone(),
        ledger: ledger.clone(),
        limiter: Limiter::default(),
        cooldowns: Default::default(),
        client: build_client(&setup.options, None).unwrap(),
        options: setup.options,
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(llm_gw::serve(
        listener,
        router(Arc::new(gw)),
        llm_gw::ServeOptions::default(),
        std::future::pending(),
    ));
    Env {
        gw: format!("http://{addr}"),
        upstream,
        sink,
        ledger,
        directory,
        issuer,
        http: reqwest::Client::builder().no_proxy().build().unwrap(),
    }
}

impl Env {
    fn token_with(&self, f: impl FnOnce(&mut TokenRequest)) -> String {
        let mut req = TokenRequest {
            ep: 0,
            iid: "inst-1".into(),
            uid: "user-1".into(),
            grant: "grant-1".into(),
            sbx: "sbx-1".into(),
            net: Some("127.0.0.1".into()),
        };
        f(&mut req);
        self.issuer.issue(req, 600, now()).unwrap()
    }

    fn token(&self) -> String {
        self.token_with(|_| {})
    }

    async fn anthropic(&self, token: &str, body: Value) -> reqwest::Response {
        self.http
            .post(format!("{}/anthropic/v1/messages", self.gw))
            .header("x-api-key", token)
            .header("anthropic-version", "2023-06-01")
            .header("cookie", "session=leak")
            .json(&body)
            .send()
            .await
            .unwrap()
    }

    async fn openai(&self, path: &str, token: &str, body: Value) -> reqwest::Response {
        self.http
            .post(format!("{}/openai/v1/{path}", self.gw))
            .bearer_auth(token)
            .json(&body)
            .send()
            .await
            .unwrap()
    }

    async fn records(&self, n: usize) -> Vec<llm_gw::usage::UsageRecord> {
        for _ in 0..100 {
            let got = self.sink.0.lock().unwrap().clone();
            if got.len() >= n {
                return got;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.sink.0.lock().unwrap().clone()
    }
}

/// 沙箱令牌绝不能出现在发给厂商的请求里。
fn assert_no_token_leak(seen: &Seen, token: &str) {
    for (name, value) in &seen.headers {
        let v = value.to_str().unwrap_or("");
        assert!(
            !v.contains(token) && !v.contains("tts1."),
            "sandbox token leaked in header {name}"
        );
    }
    assert!(
        !String::from_utf8_lossy(&seen.body).contains("tts1."),
        "sandbox token leaked in body"
    );
}

// ---------- 用例 ----------

#[tokio::test]
async fn anthropic_stream_swaps_key_rewrites_model_and_meters() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .anthropic(&token, json!({"model": "main", "max_tokens": 64, "stream": true, "messages": [{"role": "user", "content": "ping"}]}))
        .await;
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.headers()["content-type"], "text/event-stream");
    assert_eq!(resp.headers()["request-id"], "req-123");
    assert!(resp.headers().get("set-cookie").is_none());
    let text = resp.text().await.unwrap();
    assert_eq!(
        text, ANTHROPIC_SSE,
        "stream must pass through byte for byte"
    );

    let seen = env.upstream.requests();
    assert_eq!(seen.len(), 1);
    let req = &seen[0];
    assert_eq!(req.path, "/v/anthropic/v1/messages");
    assert_eq!(req.headers["x-api-key"], VENDOR_KEY);
    assert_eq!(req.headers["authorization"], format!("Bearer {VENDOR_KEY}"));
    assert_eq!(req.headers["anthropic-version"], "2023-06-01");
    assert!(req.headers.get("cookie").is_none());
    assert_no_token_leak(req, &token);
    let body: Value = serde_json::from_slice(&req.body).unwrap();
    assert_eq!(body["model"], "up-model");
    assert_eq!(body["messages"][0]["content"], "ping");

    let records = env.records(1).await;
    let r = &records[0];
    assert_eq!(
        (
            r.instance.as_str(),
            r.alias.as_str(),
            r.upstream_model.as_str()
        ),
        ("inst-1", "main", "up-model")
    );
    assert_eq!(
        (r.status, r.outcome, r.stream),
        (200, Outcome::Complete, true)
    );
    assert_eq!(
        r.usage,
        Some(Usage {
            input_tokens: 12,
            cache_read_tokens: 30,
            cache_write_tokens: 0,
            output_tokens: 6
        })
    );
    let day = (now() as i64 + 8 * 3600) as u64 / 86_400;
    assert_eq!(
        llm_gw::limits::BudgetLedger::used(env.ledger.as_ref(), "cred-main", day).await,
        48
    );
}

#[tokio::test]
async fn beta_query_is_forwarded_other_queries_are_not() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let body = json!({"model": "main", "max_tokens": 8, "messages": []});
    for (query, expected) in [
        ("?beta=true", "/v/anthropic/v1/messages?beta=true"),
        ("?x=1", "/v/anthropic/v1/messages"),
    ] {
        let resp = env
            .http
            .post(format!("{}/anthropic/v1/messages{query}", env.gw))
            .header("x-api-key", &token)
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        resp.text().await.unwrap();
        assert_eq!(env.upstream.requests().last().unwrap().path, expected);
    }
}

#[tokio::test]
async fn chat_stream_gets_usage_injected_and_stripped() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .openai("chat/completions", &token, json!({"model": "main", "stream": true, "messages": [{"role": "user", "content": "ping"}]}))
        .await;
    assert_eq!(resp.status(), 200);
    let text = resp.text().await.unwrap();
    // agent 没要用量分片，网关替它要了，转发时再去掉。
    assert_eq!(text, format!("{CHAT_CONTENT}{CHAT_DONE}"));
    let seen = env.upstream.requests();
    assert_eq!(
        seen[0].headers["authorization"],
        format!("Bearer {VENDOR_KEY}")
    );
    assert!(seen[0].headers.get("x-api-key").is_none());
    assert_no_token_leak(&seen[0], &token);
    let body: Value = serde_json::from_slice(&seen[0].body).unwrap();
    assert_eq!(body["stream_options"]["include_usage"], true);
    assert_eq!(body["model"], "up-model");
    let r = &env.records(1).await[0];
    assert_eq!(
        r.usage,
        Some(Usage {
            input_tokens: 12,
            cache_read_tokens: 8,
            cache_write_tokens: 0,
            output_tokens: 5
        })
    );

    // agent 自己要了用量分片，就原样给它。
    let resp = env
        .openai(
            "chat/completions",
            &token,
            json!({"model": "main", "stream": true, "stream_options": {"include_usage": true}, "messages": []}),
        )
        .await;
    assert_eq!(
        resp.text().await.unwrap(),
        format!("{CHAT_CONTENT}{CHAT_USAGE}{CHAT_DONE}")
    );
    assert_eq!(env.records(2).await[1].usage.unwrap().output_tokens, 5);
}

#[tokio::test]
async fn responses_non_stream_and_protocol_support() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .openai(
            "responses",
            &token,
            json!({"model": "main", "input": "ping"}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["usage"]["output_tokens"], 9);
    let r = &env.records(1).await[0];
    assert_eq!((r.endpoint, r.stream), ("openai.responses", false));
    assert_eq!(
        r.usage,
        Some(Usage {
            input_tokens: 10,
            cache_read_tokens: 40,
            cache_write_tokens: 0,
            output_tokens: 9
        })
    );

    // 厂商不提供 Responses API：直接 400，不访问上游。
    let resp = env
        .openai(
            "responses",
            &token,
            json!({"model": "nores", "input": "ping"}),
        )
        .await;
    assert_eq!(resp.status(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Responses API")
    );
    assert_eq!(env.upstream.requests().len(), 1);
}

#[tokio::test]
async fn token_and_instance_checks() {
    let env = start(Setup::default()).await;
    let body = json!({"model": "main", "max_tokens": 8, "messages": []});
    let cases = [
        ("missing", String::new()),
        ("garbage", "tts1.k1.x.y".to_owned()),
        (
            "other sandbox",
            env.token_with(|r| r.sbx = "sbx-old".into()),
        ),
        ("other user", env.token_with(|r| r.uid = "user-2".into())),
        (
            "unknown instance",
            env.token_with(|r| r.iid = "inst-9".into()),
        ),
        (
            "other source",
            env.token_with(|r| r.net = Some("10.0.0.7".into())),
        ),
        ("unbound", env.token_with(|r| r.net = None)),
        (
            "unparsable source",
            env.token_with(|r| r.net = Some("not-an-ip".into())),
        ),
    ];
    for (name, token) in cases {
        let mut req = env
            .http
            .post(format!("{}/anthropic/v1/messages", env.gw))
            .json(&body);
        if !token.is_empty() {
            req = req.header("x-api-key", &token);
        }
        let resp = req.send().await.unwrap();
        assert_eq!(resp.status(), 401, "{name}");
        let err: Value = resp.json().await.unwrap();
        assert_eq!(err["type"], "error", "{name}");
        assert_eq!(err["error"]["type"], "authentication_error", "{name}");
    }

    // 绑定地址写成 IPv4 映射的 IPv6 也算同一个来源。
    let mapped = env.token_with(|r| r.net = Some("::ffff:127.0.0.1".into()));
    assert_eq!(env.anthropic(&mapped, body.clone()).await.status(), 200);

    // 吊销运行授权、实例停用，都立即生效。
    let token = env.token();
    env.directory.revoke_grant("grant-1");
    assert_eq!(env.anthropic(&token, body.clone()).await.status(), 401);
    let token2 = env.token_with(|r| r.grant = "grant-2".into());
    assert_eq!(env.anthropic(&token2, body.clone()).await.status(), 200);
    let mut inst = (*llm_gw::store::Directory::instance(env.directory.as_ref(), "inst-1", false)
        .await
        .unwrap())
    .clone();
    inst.active = false;
    env.directory.upsert_instance(inst);
    assert_eq!(env.anthropic(&token2, body.clone()).await.status(), 401);

    // OpenAI 风格的错误格式。
    let resp = env
        .openai("chat/completions", "nope", json!({"model": "main"}))
        .await;
    assert_eq!(resp.status(), 401);
    let err: Value = resp.json().await.unwrap();
    assert_eq!(err["error"]["code"], "invalid_api_key");
    assert_eq!(
        env.upstream.requests().len(),
        2,
        "rejected requests never reach the vendor"
    );
}

#[tokio::test]
async fn bad_requests_and_unknown_models() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .anthropic(&token, json!({"model": "gpt-9", "messages": []}))
        .await;
    assert_eq!(resp.status(), 404);
    assert_eq!(
        resp.json::<Value>().await.unwrap()["error"]["type"],
        "not_found_error"
    );
    assert_eq!(
        env.anthropic(&token, json!({"messages": []}))
            .await
            .status(),
        400
    );
    let resp = env
        .http
        .post(format!("{}/anthropic/v1/messages", env.gw))
        .header("x-api-key", &token)
        .header("content-type", "application/json")
        .body(r#"{"model":"main","model":"other"}"#)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 400);
    assert!(resp.text().await.unwrap().contains("duplicate"));
    let resp = env
        .http
        .get(format!("{}/nope", env.gw))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
    assert!(env.upstream.requests().is_empty());
}

#[tokio::test]
async fn model_listing_shows_aliases_only() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .http
        .get(format!("{}/openai/v1/models", env.gw))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let ids: Vec<&str> = body["data"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap())
        .collect();
    // 只列别名，降级链里的上游模型不出现。
    assert_eq!(
        ids,
        [
            "allbad", "bad", "broke", "budgeted", "chain", "codex", "down", "hang", "local",
            "main", "nores", "nousage", "slow"
        ]
    );
    let resp = env
        .http
        .get(format!("{}/anthropic/v1/models/main", env.gw))
        .header("x-api-key", &token)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.json::<Value>().await.unwrap()["id"], "main");
    let resp = env
        .http
        .get(format!("{}/openai/v1/models/up-model", env.gw))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
    let resp = env
        .http
        .get(format!("{}/openai/v1/models", env.gw))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 401);
}

#[tokio::test]
async fn upstream_errors_pass_through_without_the_key() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .anthropic(
            &token,
            json!({"model": "bad", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 401);
    let text = resp.text().await.unwrap();
    assert!(
        !text.contains(VENDOR_KEY),
        "vendor key leaked to the agent: {text}"
    );
    assert!(text.contains("[redacted]"));
    let r = &env.records(1).await[0];
    assert_eq!((r.status, r.outcome), (401, Outcome::UpstreamStatus));
}

#[tokio::test]
async fn daily_budget_stops_the_key() {
    let env = start(Setup {
        daily_token_limit: Some(40),
        ..Setup::default()
    })
    .await;
    let token = env.token();
    let body = json!({"model": "main", "max_tokens": 8, "messages": []});
    let resp = env.anthropic(&token, body.clone()).await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    env.records(1).await;
    let resp = env.anthropic(&token, body).await;
    assert_eq!(resp.status(), 402);
    assert_eq!(
        resp.json::<Value>().await.unwrap()["error"]["type"],
        "billing_error"
    );
    assert_eq!(env.upstream.requests().len(), 1);
    // 请求没发出去，也记一条（不计费）：执行器据此让运行等 key（7.11）。
    let r = &env.records(2).await[1];
    assert_eq!(
        (r.outcome, r.status, r.charged_tokens, r.credential.as_str()),
        (Outcome::Unavailable, 402, 0, "cred-main")
    );
    assert_eq!(r.instance, "inst-1");
}

#[tokio::test]
async fn rate_limit_returns_retry_after() {
    let env = start(Setup {
        limits: Limits {
            requests_per_minute: 2,
            max_concurrent: 8,
        },
        ..Setup::default()
    })
    .await;
    let token = env.token();
    let body = json!({"model": "main", "max_tokens": 8, "messages": []});
    for _ in 0..2 {
        let resp = env.anthropic(&token, body.clone()).await;
        assert_eq!(resp.status(), 200);
        resp.text().await.unwrap();
    }
    let resp = env.anthropic(&token, body).await;
    assert_eq!(resp.status(), 429);
    assert!(resp.headers().contains_key("retry-after"));
    assert_eq!(
        resp.json::<Value>().await.unwrap()["error"]["type"],
        "rate_limit_error"
    );
}

#[tokio::test]
async fn client_disconnect_is_recorded() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let mut resp = env
        .anthropic(
            &token,
            json!({"model": "slow", "max_tokens": 8, "stream": true, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    let first = resp.chunk().await.unwrap().unwrap();
    assert!(String::from_utf8_lossy(&first).contains("message_start"));
    drop(resp);
    let records = env.records(1).await;
    assert_eq!(
        records.len(),
        1,
        "a record must be written when the agent hangs up"
    );
    assert_eq!(records[0].outcome, Outcome::ClientClosed);
    assert_eq!(records[0].usage.unwrap().input_tokens, 12);
}

#[tokio::test]
async fn private_upstreams_are_blocked_in_secure_mode() {
    let env = start(Setup {
        options: Options::default(),
        ..Setup::default()
    })
    .await;
    let token = env.token();
    let resp = env
        .anthropic(
            &token,
            json!({"model": "main", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 502);
    let text = resp.text().await.unwrap();
    assert!(text.contains("must use https"), "{text}");
    let resp = env
        .anthropic(
            &token,
            json!({"model": "local", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 502);
    let text = resp.text().await.unwrap();
    // 解析结果不告诉调用方（否则能拿来探测内网域名是否存在）。
    assert!(text.contains("is not allowed"), "{text}");
    assert!(
        !text.contains("resolve") && !text.contains("localhost"),
        "{text}"
    );
    assert!(env.upstream.requests().is_empty());
}

#[tokio::test]
async fn disconnect_before_vendor_answers_is_still_charged() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let impatient = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(300))
        .build()
        .unwrap();
    let body = json!({"model": "hang", "max_tokens": 1000, "messages": [{"role": "user", "content": "x".repeat(4000)}]});
    let res = impatient
        .post(format!("{}/anthropic/v1/messages", env.gw))
        .header("x-api-key", &token)
        .json(&body)
        .send()
        .await;
    assert!(
        res.is_err(),
        "the client gives up before the vendor answers"
    );
    let records = env.records(1).await;
    assert_eq!(
        records.len(),
        1,
        "a record is written even though no response came back"
    );
    let r = &records[0];
    assert_eq!(
        (r.outcome, r.usage, r.estimated),
        (Outcome::ClientClosed, None, true)
    );
    // 输入按请求体字节数 / 4，输出按 max_tokens。
    assert!(
        r.charged_tokens >= 1000 + 1000,
        "charged {}",
        r.charged_tokens
    );
    let day = (now() as i64 + 8 * 3600) as u64 / 86_400;
    assert_eq!(
        llm_gw::limits::BudgetLedger::used(env.ledger.as_ref(), "cred-hang", day).await,
        r.charged_tokens
    );
}

#[tokio::test]
async fn missing_usage_is_charged_conservatively() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .openai(
            "chat/completions",
            &token,
            json!({"model": "nousage", "max_tokens": 500, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    let r = &env.records(1).await[0];
    assert_eq!(
        (r.outcome, r.usage, r.estimated),
        (Outcome::Complete, None, true)
    );
    assert!(r.charged_tokens >= 500, "charged {}", r.charged_tokens);
}

#[tokio::test]
async fn background_and_case_variant_keys_are_rejected() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .openai(
            "responses",
            &token,
            json!({"model": "main", "input": "x", "background": true}),
        )
        .await;
    assert_eq!(resp.status(), 400);
    assert!(resp.text().await.unwrap().contains("background"));
    for body in [
        r#"{"model":"main","Stream":true}"#,
        r#"{"model":"main","MODEL":"other"}"#,
    ] {
        let resp = env
            .http
            .post(format!("{}/openai/v1/chat/completions", env.gw))
            .bearer_auth(&token)
            .header("content-type", "application/json")
            .body(body)
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 400, "{body}");
    }
    assert!(env.upstream.requests().is_empty());
}

// ---------- 降级链（9.9） ----------

fn models_seen(env: &Env) -> Vec<(String, String)> {
    env.upstream
        .requests()
        .iter()
        .map(|s| {
            let body: Value = serde_json::from_slice(&s.body).unwrap_or(Value::Null);
            (
                s.path.split('/').nth(1).unwrap_or_default().to_owned(),
                body["model"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

#[tokio::test]
async fn fallback_chain_moves_on_after_rate_limits_and_bad_keys() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let body = json!({"model": "chain", "max_tokens": 8, "stream": true, "messages": []});
    let resp = env.anthropic(&token, body.clone()).await;
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.text().await.unwrap(), ANTHROPIC_SSE);
    // 按顺序试：被限流的、key 失效的，最后成功；每把 key 用它自己的上游模型。
    let pair = |a: &str, b: &str| (a.to_owned(), b.to_owned());
    assert_eq!(
        models_seen(&env),
        [
            pair("busy", "m-busy"),
            pair("bad", "m-bad"),
            pair("v", "m-main")
        ]
    );
    for seen in env.upstream.requests() {
        assert_eq!(seen.headers["x-api-key"], VENDOR_KEY);
        assert_no_token_leak(&seen, &token);
    }
    // 每次尝试各记一条用量，别名不变，key 和上游模型按实际的记。
    let records = env.records(3).await;
    let got: Vec<_> = records
        .iter()
        .map(|r| {
            (
                r.alias.as_str(),
                r.credential.as_str(),
                r.upstream_model.as_str(),
                r.status,
                r.outcome,
            )
        })
        .collect();
    assert_eq!(
        got,
        [
            ("chain", "cred-busy", "m-busy", 429, Outcome::UpstreamStatus),
            ("chain", "cred-bad", "m-bad", 401, Outcome::UpstreamStatus),
            ("chain", "cred-main", "m-main", 200, Outcome::Complete),
        ]
    );
    // 两把失败的 key 在冷却：下一个请求直接从能用的开始。
    let resp = env.anthropic(&token, body).await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    assert_eq!(models_seen(&env).len(), 4);
    assert_eq!(models_seen(&env)[3], pair("v", "m-main"));
}

#[tokio::test]
async fn fallback_chain_returns_the_last_failure_when_every_key_fails() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .anthropic(
            &token,
            json!({"model": "allbad", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 401);
    let text = resp.text().await.unwrap();
    assert!(!text.contains(VENDOR_KEY), "vendor key leaked: {text}");
    assert_eq!(env.upstream.requests().len(), 2);
    // 冷却只调整顺序，不拒绝：都在冷却时照样按顺序再试一遍。
    let resp = env
        .anthropic(
            &token,
            json!({"model": "allbad", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 401);
    assert_eq!(env.upstream.requests().len(), 4);
}

#[tokio::test]
async fn request_errors_and_timeouts_do_not_fall_back() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .anthropic(
            &token,
            json!({"model": "broke", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 400);
    assert_eq!(
        models_seen(&env),
        [("broke".to_owned(), "m-broke".to_owned())]
    );
}

#[tokio::test]
async fn fallback_chain_covers_unreachable_vendors() {
    let env = start(Setup::default()).await;
    let token = env.token();
    let resp = env
        .anthropic(
            &token,
            json!({"model": "down", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    assert_eq!(models_seen(&env), [("v".to_owned(), "m-main".to_owned())]);
    let records = env.records(2).await;
    assert_eq!(
        (records[0].credential.as_str(), records[0].outcome),
        ("cred-down", Outcome::ConnectFailed)
    );
    assert_eq!(records[0].charged_tokens, 0);
    assert_eq!(records[1].credential, "cred-main");
}

#[tokio::test]
async fn fallback_chain_skips_keys_without_the_protocol_or_budget() {
    let env = start(Setup {
        daily_token_limit: Some(40),
        ..Setup::default()
    })
    .await;
    let token = env.token();
    // cred-nores 没有 Responses：直接跳过，不发请求、不记用量。
    let resp = env
        .openai(
            "responses",
            &token,
            json!({"model": "codex", "input": "ping"}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    assert_eq!(models_seen(&env), [("v".to_owned(), "m-main".to_owned())]);
    assert_eq!(env.records(1).await[0].credential, "cred-main");
    // cred-main 的当日预算这时已经用完（59 > 40）：跳到备用的 key。
    let resp = env
        .anthropic(
            &token,
            json!({"model": "budgeted", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    assert_eq!(models_seen(&env)[1], ("v".to_owned(), "m-nores".to_owned()));
    assert_eq!(env.records(2).await[1].credential, "cred-nores");
    // 只有一把 key 而且预算用完：还是原来的 402。
    let resp = env
        .anthropic(
            &token,
            json!({"model": "main", "max_tokens": 8, "messages": []}),
        )
        .await;
    assert_eq!(resp.status(), 402);
}

/// 保险箱里的值（9.11）转发前从请求里抹掉，模型看不到；不管 agent 的 SDK 怎么转义都认得出来。
#[tokio::test]
async fn vault_values_never_reach_the_model() {
    let env = start(Setup::default()).await;
    let token = env.token();
    // Python 的 json.dumps 会把字符转成 \u 转义。
    let raw = concat!(
        r#"{"model":"main","max_tokens":8,"messages":["#,
        r#"{"role":"user","content":"token gh-vault-secret-42"},"#,
        r#"{"role":"assistant","content":"ok"},"#,
        r#"{"role":"user","content":[{"type":"tool_result","content":"again: gh-vault-secret-\u0034\u0032"}]}]}"#
    );
    let resp = env
        .http
        .post(format!("{}/anthropic/v1/messages", env.gw))
        .header("x-api-key", &token)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .body(raw)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    let seen = env.upstream.requests();
    let body = String::from_utf8(seen.last().unwrap().body.clone()).unwrap();
    assert!(!body.contains(VAULT_SECRET), "{body}");
    assert!(!body.contains(r"\u0034\u0032"), "{body}");
    assert_eq!(body.matches("[vault:github]").count(), 2, "{body}");
    // 其余内容原样转发（账号不算秘密）。
    let v: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["messages"][1]["content"], "ok");
    assert_eq!(v["model"], "up-model");

    // 没有保险箱值的请求一个字节都不改（除了换掉 model）。
    let resp = env
        .openai(
            "chat/completions",
            &token,
            json!({"model": "main", "messages": [{"role": "user", "content": "octocat says hi"}]}),
        )
        .await;
    assert_eq!(resp.status(), 200);
    resp.text().await.unwrap();
    let seen = env.upstream.requests();
    let body = String::from_utf8(seen.last().unwrap().body.clone()).unwrap();
    assert!(body.contains("octocat says hi"), "{body}");
}
