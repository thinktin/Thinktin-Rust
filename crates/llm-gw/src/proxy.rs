//! 鉴权、路由、换 key、流式透传（架构方案 5.2、5.5，WBS 9.2、9.3）。

use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use auth::sandbox_token::{SandboxClaims, SandboxTokenVerifier, redact};
use axum::Json;
use axum::body::Body;
use axum::extract::{ConnectInfo, Path, Request, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use bytes::Bytes;
use futures_util::{Stream, StreamExt};
use keyvault::SecretOpener;
use keyvault::secrecy::{ExposeSecret, SecretString};
use serde_json::{Value, json};
use tokio::sync::OwnedSemaphorePermit;
use url::{Host, Url};
use zeroize::Zeroizing;

use crate::body::JsonObject;
use crate::limits::{BudgetLedger, Limiter, Rejection};
use crate::ssrf::{self, PublicOnlyResolver, SsrfError};
use crate::store::{Credential, Directory, Instance};
use crate::usage::{
    MAX_PARSE_BYTES, Outcome, Protocol, SseParser, Usage, UsageMeter, UsageRecord, UsageSink,
    is_injected_usage_chunk,
};
use crate::vendors::{self, AnthropicAuth};

/// 上游错误响应最多读这么多。
const MAX_ERROR_BODY: usize = 1 << 20;

#[derive(Debug, Clone)]
pub struct Options {
    /// 只用于本地开发和测试：允许 http 和非公网上游。
    pub insecure_upstreams: bool,
    /// 允许不绑定来源地址的令牌（`net` 为空）。只用于本地开发。
    pub allow_unbound_tokens: bool,
    /// 出网走代理时为真：域名由代理解析，网关只做预检。
    pub via_proxy: bool,
    pub max_body_bytes: usize,
    /// 每日预算按哪个时区切天，单位秒。
    pub budget_utc_offset_secs: i64,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            insecure_upstreams: false,
            allow_unbound_tokens: false,
            via_proxy: false,
            max_body_bytes: 32 << 20,
            budget_utc_offset_secs: 8 * 3600,
        }
    }
}

pub struct Gateway {
    pub verifier: SandboxTokenVerifier,
    pub directory: Arc<dyn Directory>,
    pub secrets: Arc<dyn SecretOpener>,
    pub usage: Arc<dyn UsageSink>,
    pub ledger: Arc<dyn BudgetLedger>,
    pub limiter: Limiter,
    pub client: reqwest::Client,
    pub options: Options,
}

/// 网关访问厂商用的 HTTP 客户端：不跟随重定向；直连时 DNS 只解析出公网地址。
pub fn build_client(
    options: &Options,
    egress_proxy: Option<&str>,
) -> anyhow::Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(600))
        .pool_idle_timeout(Duration::from_secs(90));
    builder = match egress_proxy {
        Some(proxy) => builder.proxy(reqwest::Proxy::all(proxy)?),
        None => builder.no_proxy(),
    };
    if !options.insecure_upstreams {
        builder = builder.https_only(true);
        if egress_proxy.is_none() {
            builder = builder.dns_resolver(PublicOnlyResolver);
        }
    }
    Ok(builder.build()?)
}

pub fn router(gw: Arc<Gateway>) -> axum::Router {
    axum::Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/anthropic/v1/messages", post(anthropic_messages))
        .route(
            "/anthropic/v1/messages/count_tokens",
            post(anthropic_count_tokens),
        )
        .route("/anthropic/v1/models", get(anthropic_models))
        .route("/anthropic/v1/models/{id}", get(anthropic_model))
        .route("/openai/v1/chat/completions", post(chat_completions))
        .route("/openai/v1/responses", post(responses))
        .route("/openai/v1/models", get(openai_models))
        .route("/openai/v1/models/{id}", get(openai_model))
        .fallback(not_found)
        .with_state(gw)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Endpoint {
    Messages,
    CountTokens,
    Chat,
    Responses,
}

impl Endpoint {
    fn name(self) -> &'static str {
        match self {
            Self::Messages => "anthropic.messages",
            Self::CountTokens => "anthropic.count_tokens",
            Self::Chat => "openai.chat_completions",
            Self::Responses => "openai.responses",
        }
    }

    fn flavor(self) -> Flavor {
        match self {
            Self::Messages | Self::CountTokens => Flavor::Anthropic,
            Self::Chat | Self::Responses => Flavor::OpenAi,
        }
    }

    /// 拼在厂商 base URL 后面的路径。
    fn suffix(self) -> &'static str {
        match self {
            Self::Messages => "/v1/messages",
            Self::CountTokens => "/v1/messages/count_tokens",
            Self::Chat => "/chat/completions",
            Self::Responses => "/responses",
        }
    }

    fn meter(self) -> Option<Protocol> {
        match self {
            Self::Messages => Some(Protocol::Anthropic),
            Self::CountTokens => None,
            Self::Chat => Some(Protocol::Chat),
            Self::Responses => Some(Protocol::Responses),
        }
    }
}

// ---------- 错误 ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Flavor {
    Anthropic,
    OpenAi,
}

#[derive(Debug, Clone, Copy)]
enum Kind {
    Auth,
    Permission,
    NotFound,
    Invalid,
    TooLarge,
    RateLimit,
    Budget,
    Upstream,
    Timeout,
    Internal,
}

#[derive(Debug)]
struct ApiError {
    kind: Kind,
    message: String,
    retry_after: Option<u64>,
}

fn err(kind: Kind, message: impl Into<String>) -> ApiError {
    ApiError {
        kind,
        message: message.into(),
        retry_after: None,
    }
}

impl ApiError {
    fn status(&self) -> StatusCode {
        match self.kind {
            Kind::Auth => StatusCode::UNAUTHORIZED,
            Kind::Permission => StatusCode::FORBIDDEN,
            Kind::NotFound => StatusCode::NOT_FOUND,
            Kind::Invalid => StatusCode::BAD_REQUEST,
            Kind::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Kind::RateLimit => StatusCode::TOO_MANY_REQUESTS,
            // 预算用完不是暂时性错误，用 402 让 agent 停下来，而不是按 429 反复重试。
            Kind::Budget => StatusCode::PAYMENT_REQUIRED,
            Kind::Upstream => StatusCode::BAD_GATEWAY,
            Kind::Timeout => StatusCode::GATEWAY_TIMEOUT,
            Kind::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    fn into_response(self, flavor: Flavor) -> Response {
        let status = self.status();
        let body = match flavor {
            Flavor::Anthropic => {
                let ty = match self.kind {
                    Kind::Auth => "authentication_error",
                    Kind::Permission => "permission_error",
                    Kind::NotFound => "not_found_error",
                    Kind::Invalid => "invalid_request_error",
                    Kind::TooLarge => "request_too_large",
                    Kind::RateLimit => "rate_limit_error",
                    Kind::Budget => "billing_error",
                    Kind::Upstream | Kind::Timeout | Kind::Internal => "api_error",
                };
                json!({"type": "error", "error": {"type": ty, "message": self.message}})
            }
            Flavor::OpenAi => {
                let (ty, code) = match self.kind {
                    Kind::Auth => ("invalid_request_error", "invalid_api_key"),
                    Kind::Permission => ("invalid_request_error", "permission_denied"),
                    Kind::NotFound => ("invalid_request_error", "model_not_found"),
                    Kind::Invalid => ("invalid_request_error", "invalid_request"),
                    Kind::TooLarge => ("invalid_request_error", "request_too_large"),
                    Kind::RateLimit => ("requests", "rate_limit_exceeded"),
                    Kind::Budget => ("insufficient_quota", "insufficient_quota"),
                    Kind::Upstream | Kind::Timeout | Kind::Internal => {
                        ("server_error", "upstream_error")
                    }
                };
                json!({"error": {"message": self.message, "type": ty, "code": code, "param": null}})
            }
        };
        let mut resp = (status, Json(body)).into_response();
        if let Some(secs) = self.retry_after {
            resp.headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(secs));
        }
        resp
    }
}

impl From<Rejection> for ApiError {
    fn from(r: Rejection) -> Self {
        let (message, retry_after) = match r {
            Rejection::RateLimited { retry_after } => (
                "request rate limit exceeded for this agent",
                Some(retry_after),
            ),
            Rejection::TooManyConcurrent => {
                ("too many concurrent requests for this agent", Some(1))
            }
            Rejection::CircuitOpen { retry_after } => (
                "this agent sent requests too fast and is paused for a while",
                Some(retry_after),
            ),
        };
        ApiError {
            kind: Kind::RateLimit,
            message: message.into(),
            retry_after,
        }
    }
}

// ---------- 鉴权 ----------

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// 沙箱令牌可以放在 `Authorization: Bearer`、`x-api-key` 或 `api-key` 里，取决于 agent 用的 SDK。
fn presented_token(headers: &HeaderMap) -> Option<&str> {
    if let Some(v) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    {
        let v = v.trim();
        if v.len() > 7 && v[..7].eq_ignore_ascii_case("bearer ") {
            return Some(v[7..].trim());
        }
    }
    ["x-api-key", "api-key"]
        .into_iter()
        .find_map(|h| headers.get(h).and_then(|v| v.to_str().ok()))
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

struct Caller {
    claims: SandboxClaims,
    instance: Arc<Instance>,
}

impl Gateway {
    /// 校验令牌，并核对实例、沙箱、运行授权和来源地址。所有失败对外都是同一句话，具体原因只进日志。
    fn authenticate(&self, headers: &HeaderMap, peer: SocketAddr) -> Result<Caller, ApiError> {
        let rejected = || err(Kind::Auth, "sandbox token rejected");
        let token =
            presented_token(headers).ok_or_else(|| err(Kind::Auth, "missing sandbox token"))?;
        let claims = self.verifier.verify(token, now_secs()).map_err(|e| {
            tracing::info!(token = %redact(token), %peer, reason = %e, "sandbox token rejected");
            rejected()
        })?;
        let deny = |reason: &str| {
            tracing::info!(instance = %claims.iid, jti = %claims.jti, %peer, reason, "sandbox token rejected");
            rejected()
        };
        match &claims.net {
            Some(net) => {
                let bound = net.parse::<IpAddr>().ok().map(|ip| ip.to_canonical());
                if bound != Some(peer.ip().to_canonical()) {
                    return Err(deny("source address does not match token"));
                }
            }
            None if !self.options.allow_unbound_tokens => {
                return Err(deny("token is not bound to a source address"));
            }
            None => {}
        }
        let instance = self
            .directory
            .instance(&claims.iid)
            .ok_or_else(|| deny("unknown instance"))?;
        if instance.user_id != claims.uid {
            return Err(deny("instance belongs to another user"));
        }
        if !instance.active {
            return Err(deny("instance is not active"));
        }
        if instance.sandbox.as_deref() != Some(claims.sbx.as_str()) {
            return Err(deny("sandbox is not the instance's current sandbox"));
        }
        if self.directory.grant_revoked(&claims.grant) {
            return Err(deny("run grant revoked"));
        }
        Ok(Caller { claims, instance })
    }

    fn budget_day(&self) -> u64 {
        let secs = now_secs() as i64 + self.options.budget_utc_offset_secs;
        (secs.max(0) / 86_400) as u64
    }
}

// ---------- 上游地址 ----------

struct Target {
    url: Url,
    vendor: String,
    anthropic_auth: AnthropicAuth,
    chat_stream_usage: bool,
}

fn target(cred: &Credential, endpoint: Endpoint, alias: &str) -> Result<Target, ApiError> {
    let (anthropic_base, openai_base, responses, anthropic_auth, chat_stream_usage) =
        if cred.vendor == vendors::CUSTOM {
            (
                cred.anthropic_base.as_deref(),
                cred.openai_base.as_deref(),
                cred.responses,
                AnthropicAuth::Both,
                true,
            )
        } else {
            let v = vendors::vendor(&cred.vendor).ok_or_else(|| {
                err(
                    Kind::Permission,
                    format!("model `{alias}` points to an unknown vendor"),
                )
            })?;
            (
                v.anthropic_base,
                v.openai_base,
                v.responses,
                v.anthropic_auth,
                v.chat_stream_usage,
            )
        };
    let base = match endpoint {
        Endpoint::Messages | Endpoint::CountTokens => anthropic_base,
        Endpoint::Chat => openai_base,
        Endpoint::Responses => openai_base.filter(|_| responses),
    };
    let base = base.ok_or_else(|| {
        let protocol = match endpoint {
            Endpoint::Messages | Endpoint::CountTokens => "the Anthropic Messages API",
            Endpoint::Chat => "the OpenAI Chat Completions API",
            Endpoint::Responses => "the OpenAI Responses API",
        };
        err(
            Kind::Invalid,
            format!("the vendor behind model `{alias}` does not offer {protocol}"),
        )
    })?;
    let url = Url::parse(&format!(
        "{}{}",
        base.trim_end_matches('/'),
        endpoint.suffix()
    ))
    .map_err(|_| {
        err(
            Kind::Upstream,
            format!("the vendor URL for model `{alias}` is invalid"),
        )
    })?;
    Ok(Target {
        url,
        vendor: cred.vendor.clone(),
        anthropic_auth,
        chat_stream_usage,
    })
}

fn blocked(alias: &str, e: &SsrfError) -> ApiError {
    tracing::warn!(alias, reason = %e, "upstream blocked by SSRF policy");
    err(
        Kind::Upstream,
        format!("the vendor URL for model `{alias}` is not allowed: {e}"),
    )
}

// ---------- 请求头 ----------

/// 转发给厂商的请求头：只放行协议需要的几个，鉴权头换成用户的 key。
fn upstream_headers(
    client: &HeaderMap,
    endpoint: Endpoint,
    auth: AnthropicAuth,
    key: &SecretString,
) -> Result<HeaderMap, ApiError> {
    let mut out = HeaderMap::new();
    let pass: &[&str] = match endpoint.flavor() {
        Flavor::Anthropic => &[
            "anthropic-version",
            "anthropic-beta",
            "accept",
            "user-agent",
        ],
        Flavor::OpenAi => &["openai-beta", "accept", "user-agent"],
    };
    for name in pass {
        for v in client.get_all(*name) {
            out.append(HeaderName::from_static(name), v.clone());
        }
    }
    out.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    if endpoint.flavor() == Flavor::Anthropic && !out.contains_key("anthropic-version") {
        out.insert("anthropic-version", HeaderValue::from_static("2023-06-01"));
    }
    let bad_key = || {
        err(
            Kind::Permission,
            "the stored API key contains invalid characters",
        )
    };
    let bearer = || -> Result<HeaderValue, ApiError> {
        let text = Zeroizing::new(format!("Bearer {}", key.expose_secret()));
        let mut v = HeaderValue::from_str(&text).map_err(|_| bad_key())?;
        v.set_sensitive(true);
        Ok(v)
    };
    let x_api_key = || -> Result<HeaderValue, ApiError> {
        let mut v = HeaderValue::from_str(key.expose_secret()).map_err(|_| bad_key())?;
        v.set_sensitive(true);
        Ok(v)
    };
    match (endpoint.flavor(), auth) {
        (Flavor::OpenAi, _) | (Flavor::Anthropic, AnthropicAuth::Bearer) => {
            out.insert(header::AUTHORIZATION, bearer()?);
        }
        (Flavor::Anthropic, AnthropicAuth::XApiKey) => {
            out.insert("x-api-key", x_api_key()?);
        }
        (Flavor::Anthropic, AnthropicAuth::Both) => {
            out.insert(header::AUTHORIZATION, bearer()?);
            out.insert("x-api-key", x_api_key()?);
        }
    }
    Ok(out)
}

/// 回给 agent 的响应头：内容类型、重试提示、请求 id、限流信息。
fn downstream_headers(upstream: &HeaderMap) -> HeaderMap {
    let mut out = HeaderMap::new();
    for (name, value) in upstream {
        let n = name.as_str();
        if matches!(
            n,
            "content-type" | "retry-after" | "request-id" | "x-request-id"
        ) || n.starts_with("anthropic-ratelimit-")
            || n.starts_with("x-ratelimit-")
        {
            out.append(name.clone(), value.clone());
        }
    }
    out
}

fn is_event_stream(headers: &HeaderMap) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| {
            v.trim_start()
                .to_ascii_lowercase()
                .starts_with("text/event-stream")
        })
}

/// 厂商的错误信息偶尔会带上 key 本身，转发前抹掉。
fn redact_secret(body: &[u8], secret: &str) -> Vec<u8> {
    let needle = secret.as_bytes();
    if needle.len() < 8 {
        return body.to_vec();
    }
    let mut out = Vec::with_capacity(body.len());
    let mut i = 0;
    while i < body.len() {
        if body[i..].starts_with(needle) {
            out.extend_from_slice(b"[redacted]");
            i += needle.len();
        } else {
            out.push(body[i]);
            i += 1;
        }
    }
    out
}

// ---------- 转发 ----------

async fn anthropic_messages(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
) -> Response {
    forward(gw, peer, Endpoint::Messages, req).await
}

async fn anthropic_count_tokens(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
) -> Response {
    forward(gw, peer, Endpoint::CountTokens, req).await
}

async fn chat_completions(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
) -> Response {
    forward(gw, peer, Endpoint::Chat, req).await
}

async fn responses(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
) -> Response {
    forward(gw, peer, Endpoint::Responses, req).await
}

async fn forward(gw: Arc<Gateway>, peer: SocketAddr, endpoint: Endpoint, req: Request) -> Response {
    match forward_inner(gw, peer, endpoint, req).await {
        Ok(resp) => resp,
        Err(e) => e.into_response(endpoint.flavor()),
    }
}

async fn forward_inner(
    gw: Arc<Gateway>,
    peer: SocketAddr,
    endpoint: Endpoint,
    req: Request,
) -> Result<Response, ApiError> {
    let started = Instant::now();
    let (parts, body) = req.into_parts();
    let caller = gw.authenticate(&parts.headers, peer)?;
    let permit = gw
        .limiter
        .acquire(&caller.instance.id, caller.instance.limits)?;

    let bytes = axum::body::to_bytes(body, gw.options.max_body_bytes)
        .await
        .map_err(|_| err(Kind::TooLarge, "request body is too large"))?;
    let mut body = JsonObject::parse(&bytes).map_err(|m| err(Kind::Invalid, m))?;
    drop(bytes);
    let alias = body
        .get_str("model")
        .map_err(|m| err(Kind::Invalid, m))?
        .ok_or_else(|| err(Kind::Invalid, "`model` is required"))?;
    let route = caller.instance.routes.get(&alias).ok_or_else(|| {
        err(
            Kind::NotFound,
            format!("model `{alias}` is not configured for this agent"),
        )
    })?;
    let cred = gw
        .directory
        .credential(&route.credential)
        .filter(|c| c.user_id == caller.instance.user_id && !c.disabled)
        .ok_or_else(|| {
            err(
                Kind::Permission,
                format!("the API key behind model `{alias}` is unavailable"),
            )
        })?;
    let day = gw.budget_day();
    if let Some(limit) = cred.daily_token_limit
        && gw.ledger.used(&cred.id, day) >= limit
    {
        return Err(err(
            Kind::Budget,
            format!("the daily token budget of the API key behind model `{alias}` is used up"),
        ));
    }

    let target = target(&cred, endpoint, &alias)?;
    let mut url = target.url;
    ssrf::check_upstream_url(&url, gw.options.insecure_upstreams)
        .map_err(|e| blocked(&alias, &e))?;
    if gw.options.via_proxy
        && !gw.options.insecure_upstreams
        && let Some(Host::Domain(domain)) = url.host()
    {
        ssrf::resolve_public(domain)
            .await
            .map_err(|e| blocked(&alias, &e))?;
    }
    // Claude Code 的 SDK 调 beta 接口时带 `?beta=true`，其余查询参数一律不转发。
    if endpoint.flavor() == Flavor::Anthropic && parts.uri.query() == Some("beta=true") {
        url.set_query(Some("beta=true"));
    }

    let stream = body
        .get_bool("stream")
        .map_err(|m| err(Kind::Invalid, m))?
        .unwrap_or(false);
    body.set("model", &route.model);
    let strip_usage_chunk = if endpoint == Endpoint::Chat && stream && target.chat_stream_usage {
        body.ensure_include_usage()
            .map_err(|m| err(Kind::Invalid, m))?
    } else {
        false
    };
    let payload = body.to_vec();
    drop(body);

    let key = gw
        .secrets
        .open_secret(&cred.user_id, &cred.id, &cred.secret)
        .map_err(|e| {
            tracing::error!(credential = %cred.id, error = %e, "failed to open API key");
            err(Kind::Internal, "failed to load the API key")
        })?;
    let headers = upstream_headers(&parts.headers, endpoint, target.anthropic_auth, &key)?;

    let mut finisher = Finisher {
        gw: gw.clone(),
        credential: cred.id.clone(),
        day,
        started,
        record: UsageRecord {
            ts_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
            instance: caller.instance.id.clone(),
            user: caller.claims.uid.clone(),
            grant: caller.claims.grant.clone(),
            sandbox: caller.claims.sbx.clone(),
            token_id: caller.claims.jti.clone(),
            alias: alias.clone(),
            credential: cred.id.clone(),
            vendor: target.vendor.clone(),
            upstream_model: route.model.clone(),
            endpoint: endpoint.name(),
            stream,
            status: 0,
            outcome: Outcome::UpstreamError,
            usage: None,
            duration_ms: 0,
        },
    };

    let resp = match gw
        .client
        .post(url)
        .headers(headers)
        .body(payload)
        .send()
        .await
    {
        Ok(resp) => resp,
        Err(e) => {
            finisher.finish(Outcome::UpstreamError, None);
            if let Some(ssrf) = ssrf::find_ssrf_error(&e) {
                return Err(blocked(&alias, ssrf));
            }
            tracing::warn!(alias, vendor = %target.vendor, error = %e, "upstream request failed");
            return Err(if e.is_timeout() {
                err(Kind::Timeout, "the vendor did not respond in time")
            } else {
                err(Kind::Upstream, "could not reach the vendor")
            });
        }
    };

    let status = resp.status();
    finisher.record.status = status.as_u16();
    let headers = downstream_headers(resp.headers());

    if !status.is_success() {
        // 错误响应很小：读完、抹掉 key，再整体返回。
        let mut buf = Vec::new();
        let mut upstream = resp.bytes_stream();
        while let Some(Ok(chunk)) = upstream.next().await {
            let room = MAX_ERROR_BODY.saturating_sub(buf.len());
            buf.extend_from_slice(&chunk[..chunk.len().min(room)]);
            if buf.len() >= MAX_ERROR_BODY {
                break;
            }
        }
        let body = redact_secret(&buf, key.expose_secret());
        tracing::info!(alias, vendor = %target.vendor, status = status.as_u16(), "upstream returned an error");
        finisher.finish(Outcome::UpstreamStatus, None);
        return Ok((status, headers, body).into_response());
    }
    drop(key);

    let sse = is_event_stream(resp.headers());
    let tapped = Tapped {
        inner: Box::pin(resp.bytes_stream()),
        meter: endpoint.meter().map(UsageMeter::new),
        sse: sse.then(SseParser::default),
        json: (!sse && endpoint.meter().is_some()).then(Vec::new),
        strip_usage_chunk: strip_usage_chunk && sse,
        finisher: Some(finisher),
        tail: None,
        done: false,
        _permit: permit,
    };
    let mut response = Response::new(Body::from_stream(tapped));
    *response.status_mut() = status;
    *response.headers_mut() = headers;
    if sse {
        response
            .headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
        response
            .headers_mut()
            .insert("x-accel-buffering", HeaderValue::from_static("no"));
    }
    Ok(response)
}

/// 记一次调用的用量，并给 key 的每日预算记账。
struct Finisher {
    gw: Arc<Gateway>,
    credential: String,
    day: u64,
    started: Instant,
    record: UsageRecord,
}

impl Finisher {
    fn finish(mut self, outcome: Outcome, usage: Option<Usage>) {
        self.record.outcome = outcome;
        self.record.usage = usage;
        self.record.duration_ms = self.started.elapsed().as_millis() as u64;
        if let Some(u) = usage {
            self.gw.ledger.add(&self.credential, self.day, u.total());
        }
        self.gw.usage.record(self.record);
    }
}

/// 把厂商的响应原样流给 agent，同时取出用量。客户端中途断开时在 Drop 里记账。
struct Tapped {
    inner: Pin<Box<dyn Stream<Item = reqwest::Result<Bytes>> + Send>>,
    meter: Option<UsageMeter>,
    sse: Option<SseParser>,
    /// 非流式响应：攒下响应体（有上限）用来取用量。
    json: Option<Vec<u8>>,
    strip_usage_chunk: bool,
    finisher: Option<Finisher>,
    tail: Option<Bytes>,
    done: bool,
    _permit: OwnedSemaphorePermit,
}

impl Tapped {
    fn process(&mut self, chunk: Bytes) -> Bytes {
        if let Some(parser) = self.sse.as_mut() {
            if parser.broken {
                return chunk;
            }
            let keep_raw = self.strip_usage_chunk;
            let events = parser.push(&chunk, keep_raw);
            let mut out = Vec::new();
            for event in events {
                let parsed = event
                    .data
                    .as_deref()
                    .and_then(|d| serde_json::from_slice::<Value>(d).ok());
                if let (Some(v), Some(meter)) = (&parsed, self.meter.as_mut()) {
                    meter.on_event(v);
                }
                if keep_raw && !parsed.as_ref().is_some_and(is_injected_usage_chunk) {
                    out.extend_from_slice(&event.raw);
                }
            }
            if !keep_raw {
                return chunk;
            }
            if parser.broken {
                out.extend_from_slice(&parser.take_rest());
            }
            return Bytes::from(out);
        }
        if let Some(buf) = self.json.as_mut() {
            if buf.len() + chunk.len() <= MAX_PARSE_BYTES {
                buf.extend_from_slice(&chunk);
            } else {
                self.json = None;
            }
        }
        chunk
    }

    /// 流正常结束：补发没凑成事件的尾巴，算出最终用量。
    fn complete(&mut self) -> Option<Bytes> {
        let mut tail = None;
        if let Some(parser) = self.sse.as_mut()
            && self.strip_usage_chunk
            && !parser.broken
        {
            let rest = parser.take_rest();
            if !rest.is_empty() {
                tail = Some(Bytes::from(rest));
            }
        }
        if let (Some(buf), Some(meter)) = (self.json.take(), self.meter.as_mut())
            && let Ok(v) = serde_json::from_slice::<Value>(&buf)
        {
            meter.on_body(&v);
        }
        self.finish(Outcome::Complete);
        tail
    }

    fn finish(&mut self, outcome: Outcome) {
        if let Some(f) = self.finisher.take() {
            f.finish(outcome, self.meter.as_ref().and_then(UsageMeter::usage));
        }
    }
}

impl Stream for Tapped {
    type Item = Result<Bytes, std::io::Error>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = &mut *self;
        if this.done {
            return Poll::Ready(this.tail.take().map(Ok));
        }
        loop {
            match this.inner.poll_next_unpin(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Some(Ok(chunk))) => {
                    let out = this.process(chunk);
                    if !out.is_empty() {
                        return Poll::Ready(Some(Ok(out)));
                    }
                }
                Poll::Ready(Some(Err(e))) => {
                    tracing::warn!(error = %e, "upstream stream failed");
                    this.done = true;
                    this.finish(Outcome::UpstreamError);
                    return Poll::Ready(Some(Err(std::io::Error::other("upstream stream failed"))));
                }
                Poll::Ready(None) => {
                    this.done = true;
                    this.tail = this.complete();
                    return Poll::Ready(this.tail.take().map(Ok));
                }
            }
        }
    }
}

impl Drop for Tapped {
    fn drop(&mut self) {
        self.finish(Outcome::ClientClosed);
    }
}

// ---------- 模型列表 ----------

/// 模型列表只列实例配置的别名，不访问厂商。
async fn list_models(
    gw: &Gateway,
    headers: &HeaderMap,
    peer: SocketAddr,
) -> Result<Vec<String>, ApiError> {
    let caller = gw.authenticate(headers, peer)?;
    Ok(caller.instance.routes.keys().cloned().collect())
}

fn anthropic_model_json(id: &str) -> Value {
    json!({"type": "model", "id": id, "display_name": id, "created_at": "2026-01-01T00:00:00Z"})
}

fn openai_model_json(id: &str) -> Value {
    json!({"id": id, "object": "model", "created": 0, "owned_by": "thinktin"})
}

async fn anthropic_models(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> Response {
    match list_models(&gw, &headers, peer).await {
        Ok(ids) => Json(json!({
            "data": ids.iter().map(|id| anthropic_model_json(id)).collect::<Vec<_>>(),
            "has_more": false,
            "first_id": ids.first(),
            "last_id": ids.last(),
        }))
        .into_response(),
        Err(e) => e.into_response(Flavor::Anthropic),
    }
}

async fn anthropic_model(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    match list_models(&gw, &headers, peer).await {
        Ok(ids) if ids.contains(&id) => Json(anthropic_model_json(&id)).into_response(),
        Ok(_) => err(
            Kind::NotFound,
            format!("model `{id}` is not configured for this agent"),
        )
        .into_response(Flavor::Anthropic),
        Err(e) => e.into_response(Flavor::Anthropic),
    }
}

async fn openai_models(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> Response {
    match list_models(&gw, &headers, peer).await {
        Ok(ids) => Json(json!({
            "object": "list",
            "data": ids.iter().map(|id| openai_model_json(id)).collect::<Vec<_>>(),
        }))
        .into_response(),
        Err(e) => e.into_response(Flavor::OpenAi),
    }
}

async fn openai_model(
    State(gw): State<Arc<Gateway>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    match list_models(&gw, &headers, peer).await {
        Ok(ids) if ids.contains(&id) => Json(openai_model_json(&id)).into_response(),
        Ok(_) => err(
            Kind::NotFound,
            format!("model `{id}` is not configured for this agent"),
        )
        .into_response(Flavor::OpenAi),
        Err(e) => e.into_response(Flavor::OpenAi),
    }
}

async fn not_found(req: Request) -> Response {
    let flavor = if req.uri().path().starts_with("/anthropic/") {
        Flavor::Anthropic
    } else {
        Flavor::OpenAi
    };
    err(
        Kind::NotFound,
        format!("no route for {} {}", req.method(), req.uri().path()),
    )
    .into_response(flavor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_header_forms() {
        let mut h = HeaderMap::new();
        assert_eq!(presented_token(&h), None);
        h.insert("x-api-key", HeaderValue::from_static("tts1.a"));
        assert_eq!(presented_token(&h), Some("tts1.a"));
        h.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("bearer  tts1.b "),
        );
        assert_eq!(presented_token(&h), Some("tts1.b"));
        let mut h = HeaderMap::new();
        h.insert("api-key", HeaderValue::from_static("tts1.c"));
        assert_eq!(presented_token(&h), Some("tts1.c"));
        h.insert(header::AUTHORIZATION, HeaderValue::from_static("Basic abc"));
        assert_eq!(presented_token(&h), Some("tts1.c"));
    }

    #[test]
    fn redacts_key_in_error_bodies() {
        let body = br#"{"error":"invalid key sk-abcdef123456 for sk-abcdef123456"}"#;
        assert_eq!(
            redact_secret(body, "sk-abcdef123456"),
            br#"{"error":"invalid key [redacted] for [redacted]"}"#.to_vec()
        );
        assert_eq!(redact_secret(b"short", "abc"), b"short".to_vec());
    }

    #[test]
    fn client_auth_is_never_forwarded() {
        let mut client = HeaderMap::new();
        client.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer tts1.sandbox"),
        );
        client.insert("x-api-key", HeaderValue::from_static("tts1.sandbox"));
        client.insert("cookie", HeaderValue::from_static("a=b"));
        client.insert("anthropic-beta", HeaderValue::from_static("x"));
        let key = SecretString::from("sk-user-key-123".to_owned());
        let out =
            upstream_headers(&client, Endpoint::Messages, AnthropicAuth::XApiKey, &key).unwrap();
        assert_eq!(out.get("x-api-key").unwrap(), "sk-user-key-123");
        assert!(out.get(header::AUTHORIZATION).is_none());
        assert!(out.get("cookie").is_none());
        assert_eq!(out.get("anthropic-beta").unwrap(), "x");
        assert_eq!(out.get("anthropic-version").unwrap(), "2023-06-01");
        let out = upstream_headers(&client, Endpoint::Chat, AnthropicAuth::XApiKey, &key).unwrap();
        assert_eq!(
            out.get(header::AUTHORIZATION).unwrap(),
            "Bearer sk-user-key-123"
        );
        assert!(out.get("x-api-key").is_none());
        assert!(out.get("anthropic-beta").is_none());
    }
}
