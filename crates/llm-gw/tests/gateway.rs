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
use keyvault::{KeyVault, LocalKms, MemoryKeyStore};
use llm_gw::limits::{Limiter, MemoryLedger};
use llm_gw::store::{Credential, Instance, Limits, MemoryDirectory, Route};
use llm_gw::usage::{MemorySink, Outcome, Usage};
use llm_gw::{Gateway, Options, build_client, router};
use serde_json::{Value, json};

const VENDOR_KEY: &str = "sk-vendor-secret-0001";

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

fn credential(
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
        responses,
        secret: vault
            .seal("user-1", id, &SecretString::from(VENDOR_KEY.to_owned()))
            .unwrap(),
        daily_token_limit,
        disabled: false,
    }
}

async fn start(setup: Setup) -> Env {
    let (upstream_addr, upstream) = start_upstream().await;
    let vault = KeyVault::new(LocalKms::new("test", &[7u8; 32]), MemoryKeyStore::default());
    vault.create_user_key("user-1").unwrap();
    let base = format!("http://{upstream_addr}/v");
    let creds = vec![
        credential(&vault, "cred-main", &base, true, setup.daily_token_limit),
        credential(&vault, "cred-nores", &base, false, None),
        credential(
            &vault,
            "cred-bad",
            &format!("http://{upstream_addr}/bad"),
            true,
            None,
        ),
        credential(
            &vault,
            "cred-slow",
            &format!("http://{upstream_addr}/slow"),
            true,
            None,
        ),
        // https 加域名能通过静态检查，要靠 DNS 解析这一步拦住。
        credential(
            &vault,
            "cred-local",
            &format!("https://localhost:{}/v", upstream_addr.port()),
            true,
            None,
        ),
    ];
    let route = |cred: &str, model: &str| Route {
        credential: cred.into(),
        model: model.into(),
    };
    let instance = Instance {
        id: "inst-1".into(),
        user_id: "user-1".into(),
        sandbox: Some("sbx-1".into()),
        active: true,
        routes: BTreeMap::from([
            ("main".into(), route("cred-main", "up-model")),
            ("nores".into(), route("cred-nores", "up-model")),
            ("bad".into(), route("cred-bad", "up-model")),
            ("slow".into(), route("cred-slow", "up-model")),
            ("local".into(), route("cred-local", "up-model")),
        ]),
        limits: setup.limits,
    };
    let directory = Arc::new(MemoryDirectory::new(vec![instance], creds, vec![]));
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
        usage: sink.clone(),
        ledger: ledger.clone(),
        limiter: Limiter::default(),
        client: build_client(&setup.options, None).unwrap(),
        options: setup.options,
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(
            listener,
            router(Arc::new(gw)).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap()
    });
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
        llm_gw::limits::BudgetLedger::used(env.ledger.as_ref(), "cred-main", day),
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

    // 吊销运行授权、实例停用，都立即生效。
    let token = env.token();
    env.directory.revoke_grant("grant-1");
    assert_eq!(env.anthropic(&token, body.clone()).await.status(), 401);
    let token2 = env.token_with(|r| r.grant = "grant-2".into());
    assert_eq!(env.anthropic(&token2, body.clone()).await.status(), 200);
    let mut inst =
        (*llm_gw::store::Directory::instance(env.directory.as_ref(), "inst-1").unwrap()).clone();
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
        1,
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
    assert_eq!(ids, ["bad", "local", "main", "nores", "slow"]);
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
    assert!(
        text.contains("does not resolve to a public address"),
        "{text}"
    );
    assert!(env.upstream.requests().is_empty());
}
