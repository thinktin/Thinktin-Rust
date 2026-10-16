//! 模型网关流式吞吐：`concurrency` 个并发连接一共发 `requests` 个 Anthropic Messages 流式请求。
//!
//! 进程内模式：起一个假厂商（每个响应 `chunks` 个 `content_block_delta`，每块正文 `chunk_bytes` 字节，
//! 块之间停 `chunk_delay`），再起一个真实的网关（验沙箱令牌、限流、换 key、改模型名、透传、计量）接它。
//! 每个并发连接用自己的实例和令牌。核对每个响应和假厂商发的逐字节一致、每个请求都记了一条完整的用量。
//! `baseline` 时同样的负载再直连假厂商跑一遍，两者之差就是网关的开销。
//!
//! 外部模式（[`Target::External`]）：指向部署好的网关，令牌和模型别名由调用方给，不核对内容，只统计。

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, ensure};
use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};
use axum::body::{Body, Bytes};
use axum::extract::{Request, State};
use axum::response::Response;
use keyvault::secrecy::SecretString;
use keyvault::{KeyVault, LocalKms, MemoryKeyStore};
use llm_gw::limits::{Limiter, MemoryLedger};
use llm_gw::store::{Credential, Instance, Limits, MemoryDirectory, Route};
use llm_gw::usage::{Outcome, UsageRecord, UsageSink};
use llm_gw::{Gateway, Options, ServeOptions, build_client, router};
use serde::Serialize;
use serde_json::json;

use crate::stats::{Summary, rate};

const USER: &str = "loadtest-user";
const CREDENTIAL: &str = "loadtest-cred";
const ALIAS: &str = "main";

#[derive(Debug, Clone)]
pub struct Config {
    pub concurrency: usize,
    pub requests: usize,
    pub chunks: usize,
    pub chunk_bytes: usize,
    pub chunk_delay: Duration,
    /// 进程内模式下再直连假厂商跑一遍作为基线。
    pub baseline: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            concurrency: 256,
            requests: 5_000,
            chunks: 200,
            chunk_bytes: 64,
            chunk_delay: Duration::from_millis(5),
            baseline: true,
        }
    }
}

/// 压谁。
#[derive(Debug, Clone)]
pub enum Target {
    /// 进程内起假厂商和网关。
    InProcess,
    /// 部署好的网关：基地址（不带 `/anthropic`）、沙箱令牌、模型别名。
    External {
        base: String,
        token: String,
        model: String,
    },
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Pass {
    pub ok: usize,
    pub failed: usize,
    pub first_error: Option<String>,
    /// 内容和假厂商发的不一致的响应数（只在进程内模式核对）。
    pub mismatched: usize,
    pub wall_ms: f64,
    pub requests_per_sec: f64,
    pub bytes: u64,
    pub mib_per_sec: f64,
    /// 从发请求到收到第一块正文。
    pub ttfb: Summary,
    /// 从发请求到读完。
    pub total: Summary,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub concurrency: usize,
    pub requests: usize,
    pub chunks: usize,
    pub chunk_bytes: usize,
    pub chunk_delay_ms: f64,
    pub response_bytes: usize,
    pub gateway: Pass,
    /// 网关记下的完整用量条数（进程内模式，应等于成功数）。
    pub usage_complete: Option<u64>,
    pub usage_other: Option<u64>,
    pub baseline: Option<Pass>,
    /// 网关比直连多出来的首字节延迟中位数（毫秒）。
    pub overhead_ttfb_p50_ms: Option<f64>,
}

// ---------- 假厂商 ----------

/// 一个流式响应的全部分块（按块之间要停顿的位置切开）。
fn response_parts(chunks: usize, chunk_bytes: usize) -> Vec<Bytes> {
    let mut parts = Vec::with_capacity(chunks + 2);
    parts.push(Bytes::from(concat!(
        "event: message_start\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_lt\",\"model\":\"up-model\",",
        "\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n",
    )));
    let text = "x".repeat(chunk_bytes);
    let delta = format!(
        "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{text}\"}}}}\n\n"
    );
    let delta = Bytes::from(delta);
    for _ in 0..chunks {
        parts.push(delta.clone());
    }
    parts.push(Bytes::from(format!(
        "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":{}}}}}\n\n\
         event: message_stop\ndata: {{\"type\":\"message_stop\"}}\n\n",
        chunks.max(1)
    )));
    parts
}

#[derive(Clone)]
struct Upstream {
    parts: Arc<Vec<Bytes>>,
    delay: Duration,
}

async fn upstream_handler(State(up): State<Upstream>, req: Request) -> Response {
    // 把请求体读完再回，和真实厂商一样。
    let _ = axum::body::to_bytes(req.into_body(), usize::MAX).await;
    let parts = up.parts.clone();
    let delay = up.delay;
    let stream = futures_util::stream::unfold(0usize, move |i| {
        let parts = parts.clone();
        async move {
            let Some(part) = parts.get(i).cloned() else {
                return None;
            };
            if i > 0 && !delay.is_zero() {
                tokio::time::sleep(delay).await;
            }
            Some((Ok::<Bytes, std::io::Error>(part), i + 1))
        }
    });
    Response::builder()
        .header("content-type", "text/event-stream")
        .body(Body::from_stream(stream))
        .unwrap_or_default()
}

async fn start_upstream(parts: Arc<Vec<Bytes>>, delay: Duration) -> anyhow::Result<SocketAddr> {
    let app = axum::Router::new()
        .fallback(upstream_handler)
        .with_state(Upstream { parts, delay });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Ok(addr)
}

// ---------- 网关 ----------

/// 只计数的用量记录（压测时不攒记录，免得内存一直涨）。
#[derive(Default)]
pub struct CountingSink {
    pub complete: AtomicU64,
    pub other: AtomicU64,
}

impl UsageSink for CountingSink {
    fn record(&self, record: UsageRecord) {
        if record.outcome == Outcome::Complete {
            self.complete.fetch_add(1, Ordering::Relaxed);
        } else {
            self.other.fetch_add(1, Ordering::Relaxed);
        }
    }
}

struct InProcess {
    gateway: String,
    upstream: String,
    tokens: Vec<String>,
    sink: Arc<CountingSink>,
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

async fn start_in_process(cfg: &Config, parts: Arc<Vec<Bytes>>) -> anyhow::Result<InProcess> {
    let upstream_addr = start_upstream(parts, cfg.chunk_delay).await?;
    let upstream = format!("http://{upstream_addr}");

    let vault = KeyVault::new(
        LocalKms::new("loadtest", &[7u8; 32]),
        MemoryKeyStore::default(),
    );
    vault.create_user_key(USER).await?;
    let credential = Credential {
        id: CREDENTIAL.into(),
        user_id: USER.into(),
        vendor: "custom".into(),
        anthropic_base: Some(format!("{upstream}/anthropic")),
        openai_base: Some(format!("{upstream}/openai/v1")),
        responses_base: None,
        secret: vault
            .seal(
                USER,
                CREDENTIAL,
                &SecretString::from("sk-loadtest-0000".to_owned()),
            )
            .await?,
        daily_token_limit: None,
        disabled: false,
    };
    // 每个并发连接一个实例，限流放到测不到的高度：这里测的是网关本身，不是限流。
    let workers = cfg.concurrency.max(1);
    let limits = Limits {
        requests_per_minute: u32::MAX / 2,
        max_concurrent: 1 << 20,
    };
    let instances: Vec<Instance> = (0..workers)
        .map(|i| Instance {
            id: format!("lt-inst-{i}"),
            user_id: USER.into(),
            sandbox: Some(format!("lt-sbx-{i}")),
            epoch: 0,
            active: true,
            routes: BTreeMap::from([(
                ALIAS.to_owned(),
                Route {
                    credential: CREDENTIAL.into(),
                    model: "up-model".into(),
                    fallbacks: vec![],
                },
            )]),
            limits,
        })
        .collect();
    let directory = Arc::new(MemoryDirectory::new(instances, vec![credential], vec![]));

    let issuer = SandboxTokenIssuer::generate("lt")?;
    let mut verifier = SandboxTokenVerifier::new();
    verifier.add_key_b64("lt", &issuer.verifying_key_b64())?;
    let now = unix_now();
    let tokens = (0..workers)
        .map(|i| {
            issuer.issue(
                TokenRequest {
                    ep: 0,
                    iid: format!("lt-inst-{i}"),
                    uid: USER.into(),
                    grant: "lt-grant".into(),
                    sbx: format!("lt-sbx-{i}"),
                    net: Some("127.0.0.1".into()),
                },
                24 * 3600,
                now,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;

    let options = Options {
        insecure_upstreams: true,
        ..Options::default()
    };
    let sink = Arc::new(CountingSink::default());
    let gw = Gateway {
        verifier,
        directory,
        secrets: Arc::new(vault),
        vault: Default::default(),
        usage: sink.clone(),
        ledger: Arc::new(MemoryLedger::default()),
        limiter: Limiter::default(),
        cooldowns: Default::default(),
        client: build_client(&options, None)?,
        options,
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    // 所有连接都从 127.0.0.1 来：按来源地址的连接上限放到并发数之上。
    let serve_options = ServeOptions {
        max_connections_per_ip: workers * 2 + 64,
        max_connections: (workers * 2 + 64).max(ServeOptions::default().max_connections),
        ..ServeOptions::default()
    };
    tokio::spawn(llm_gw::serve(
        listener,
        router(Arc::new(gw)),
        serve_options,
        std::future::pending(),
    ));
    Ok(InProcess {
        gateway: format!("http://{addr}"),
        upstream,
        tokens,
        sink,
    })
}

// ---------- 负载 ----------

struct Sample {
    ttfb: Duration,
    total: Duration,
    bytes: u64,
    matched: bool,
}

async fn one_request(
    http: &reqwest::Client,
    url: &str,
    token: &str,
    model: &str,
    expected: Option<&[u8]>,
) -> Result<Sample, String> {
    let start = Instant::now();
    let mut resp = http
        .post(url)
        .header("x-api-key", token)
        .header("anthropic-version", "2023-06-01")
        .json(&json!({
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "messages": [{"role": "user", "content": "ping"}],
        }))
        .send()
        .await
        .map_err(|e| format!("send: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        let body: String = body.chars().take(200).collect();
        return Err(format!("status {status}: {body}"));
    }
    let mut ttfb = None;
    let mut bytes = 0u64;
    // 核对内容：逐块和期望的字节比，不攒整个响应。
    let mut matched = true;
    while let Some(chunk) = resp.chunk().await.map_err(|e| format!("read: {e}"))? {
        ttfb.get_or_insert_with(|| start.elapsed());
        if let Some(exp) = expected {
            let at = bytes as usize;
            let end = at + chunk.len();
            matched &= end <= exp.len() && exp[at..end] == chunk[..];
        }
        bytes += chunk.len() as u64;
    }
    let total = start.elapsed();
    if let Some(exp) = expected {
        matched &= bytes as usize == exp.len();
    }
    Ok(Sample {
        ttfb: ttfb.unwrap_or(total),
        total,
        bytes,
        matched,
    })
}

/// 一轮负载：`concurrency` 个任务从同一个计数器领请求，直到发满 `requests` 个。
/// `tokens` 按任务分（任务 i 用 `tokens[i % len]`）。
async fn pass(
    url: &str,
    tokens: &[String],
    model: &str,
    cfg: &Config,
    expected: Option<Arc<Vec<u8>>>,
) -> anyhow::Result<Pass> {
    ensure!(!tokens.is_empty(), "need at least one token");
    let workers = cfg.concurrency.max(1);
    let http = reqwest::Client::builder()
        .no_proxy()
        .pool_max_idle_per_host(workers)
        .timeout(Duration::from_secs(600))
        .build()?;
    let next = Arc::new(AtomicUsize::new(0));
    let start = Instant::now();
    let mut tasks = Vec::with_capacity(workers);
    for w in 0..workers {
        let http = http.clone();
        let url = url.to_owned();
        let token = tokens[w % tokens.len()].clone();
        let model = model.to_owned();
        let expected = expected.clone();
        let next = next.clone();
        let total = cfg.requests;
        tasks.push(tokio::spawn(async move {
            let mut out = Vec::new();
            while next.fetch_add(1, Ordering::Relaxed) < total {
                out.push(
                    one_request(
                        &http,
                        &url,
                        &token,
                        &model,
                        expected.as_deref().map(Vec::as_slice),
                    )
                    .await,
                );
            }
            out
        }));
    }
    let mut ttfb = Vec::with_capacity(cfg.requests);
    let mut totals = Vec::with_capacity(cfg.requests);
    let (mut ok, mut failed, mut mismatched, mut bytes) = (0, 0, 0, 0u64);
    let mut first_error = None;
    for task in tasks {
        for r in task.await.context("load task panicked")? {
            match r {
                Ok(s) => {
                    ok += 1;
                    if !s.matched {
                        mismatched += 1;
                    }
                    bytes += s.bytes;
                    ttfb.push(s.ttfb);
                    totals.push(s.total);
                }
                Err(e) => {
                    failed += 1;
                    first_error.get_or_insert(e);
                }
            }
        }
    }
    let wall = start.elapsed();
    Ok(Pass {
        ok,
        failed,
        first_error,
        mismatched,
        wall_ms: wall.as_secs_f64() * 1000.0,
        requests_per_sec: rate(ok, wall),
        bytes,
        mib_per_sec: bytes as f64 / (1024.0 * 1024.0) / wall.as_secs_f64().max(0.001),
        ttfb: Summary::of(&ttfb),
        total: Summary::of(&totals),
    })
}

pub async fn run(target: &Target, cfg: &Config) -> anyhow::Result<Report> {
    let parts = Arc::new(response_parts(cfg.chunks, cfg.chunk_bytes));
    let expected: Arc<Vec<u8>> = Arc::new(parts.iter().flat_map(|p| p.iter().copied()).collect());
    let mut report = Report {
        concurrency: cfg.concurrency,
        requests: cfg.requests,
        chunks: cfg.chunks,
        chunk_bytes: cfg.chunk_bytes,
        chunk_delay_ms: cfg.chunk_delay.as_secs_f64() * 1000.0,
        response_bytes: expected.len(),
        gateway: Pass::default(),
        usage_complete: None,
        usage_other: None,
        baseline: None,
        overhead_ttfb_p50_ms: None,
    };
    match target {
        Target::External { base, token, model } => {
            let url = format!("{}/anthropic/v1/messages", base.trim_end_matches('/'));
            report.gateway = pass(&url, std::slice::from_ref(token), model, cfg, None).await?;
            report.response_bytes = 0;
        }
        Target::InProcess => {
            let env = start_in_process(cfg, parts).await?;
            let url = format!("{}/anthropic/v1/messages", env.gateway);
            report.gateway = pass(&url, &env.tokens, ALIAS, cfg, Some(expected.clone())).await?;
            // 用量在响应读完后异步记下，稍等一下。
            for _ in 0..200 {
                let seen = env.sink.complete.load(Ordering::Relaxed)
                    + env.sink.other.load(Ordering::Relaxed);
                if seen >= (report.gateway.ok + report.gateway.failed) as u64 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            report.usage_complete = Some(env.sink.complete.load(Ordering::Relaxed));
            report.usage_other = Some(env.sink.other.load(Ordering::Relaxed));
            if cfg.baseline {
                let url = format!("{}/anthropic/v1/messages", env.upstream);
                let base = pass(&url, &env.tokens, ALIAS, cfg, Some(expected)).await?;
                report.overhead_ttfb_p50_ms = Some(report.gateway.ttfb.p50_ms - base.ttfb.p50_ms);
                report.baseline = Some(base);
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_is_valid_sse() {
        let parts = response_parts(3, 5);
        assert_eq!(parts.len(), 5);
        let all: Vec<u8> = parts.iter().flat_map(|p| p.iter().copied()).collect();
        let text = String::from_utf8(all).unwrap();
        let events: Vec<&str> = text.split("\n\n").filter(|e| !e.is_empty()).collect();
        assert_eq!(events.len(), 1 + 3 + 2);
        for e in &events {
            let data = e.lines().find_map(|l| l.strip_prefix("data: ")).unwrap();
            serde_json::from_str::<serde_json::Value>(data).unwrap();
        }
        assert!(text.contains("\"text\":\"xxxxx\""));
        assert!(text.ends_with("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"));
    }
}
