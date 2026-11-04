//! 受控出网通道（WBS 2.7，[出口代理](../../../docs/egress.md)）：沙箱只能经这里上外网。
//!
//! 只做 HTTPS 的 `CONNECT host:443` 隧道，不解密。一条隧道要依次过这些关（便宜的在前）：
//!
//! 1. 沙箱令牌放在 `Proxy-Authorization: Basic`（代理地址里的密码），和模型网关一样核对签名、来源地址、实例在运行、
//!    沙箱和代数、运行授权没吊销；
//! 2. 每个实例每分钟开隧道的次数有上限；
//! 3. 目标网站名按 `proto::egress::normalize_host` 整理（不收 IP、数字变形、单段名字），端口只能是 443；
//! 4. 实例的档位放行这个网站（`EgressMode::allows`）；
//! 5. 每个实例同时最多几条隧道；
//! 6. 从今天的额度里先预留一段（[`EgressLedger::reserve`]），转发途中不够了再预留，用完就断；
//! 7. 由代理自己解析，任何一个地址不是公网地址、或者落在部署配置的禁段里就整体拒绝，直接连检查过的地址
//!    （没有“检查一次、连接时再解析一次”的窗口）。
//!
//! 隧道开着的时候每隔一会儿重新核对令牌和档位（实例停了、授权吊销、用户改了档位，最多这么久后断开），空闲太久、
//! 开得太久也断。每条隧道（放行的和拒绝的）记一行只有元数据的日志。

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use axum::body::Body;
use base64::Engine;
use chrono::{NaiveDate, Utc};
use hyper::body::Incoming;
use hyper::{Method, Request, Response, StatusCode, header};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;

use crate::proxy::{Caller, Gateway};
use crate::serve::PerIp;
use crate::ssrf;

/// 出口代理的设置。
#[derive(Debug, Clone)]
pub struct EgressOptions {
    /// 每个实例每天的双向流量上限（字节）。
    pub daily_bytes: u64,
    /// 每个实例同时最多几条隧道。
    pub max_tunnels: u32,
    /// 每个实例每分钟最多开几次隧道（含被拒绝的）。
    pub attempts_per_minute: u32,
    /// 每个实例每分钟最多记几条拒绝的日志（再多的只计数，防刷日志）。
    pub denials_logged_per_minute: u32,
    /// 每次从额度里预留多少。
    pub reserve_chunk: u64,
    pub connect_timeout: Duration,
    pub idle_timeout: Duration,
    pub max_duration: Duration,
    /// 隧道开着时多久重新核对一次令牌和档位。
    pub recheck_every: Duration,
    pub header_read_timeout: Duration,
    pub max_connections: usize,
    pub max_connections_per_ip: usize,
    /// 部署配置的禁段（比如服务机自己的公网地址），公网地址落在这里也拒绝。
    pub deny: Vec<Cidr>,
    /// 每天按哪个时区切（相对 UTC 的秒数）。
    pub utc_offset_secs: i64,
    /// 只用于本地开发和测试：允许非公网地址、任意端口、单段名字（`localhost`）。
    pub insecure: bool,
}

impl Default for EgressOptions {
    fn default() -> Self {
        Self {
            daily_bytes: proto::egress::DAILY_BYTES,
            max_tunnels: proto::egress::MAX_TUNNELS,
            attempts_per_minute: 120,
            denials_logged_per_minute: 30,
            reserve_chunk: 256 << 10,
            connect_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(300),
            max_duration: Duration::from_secs(3600),
            recheck_every: Duration::from_secs(30),
            header_read_timeout: Duration::from_secs(10),
            max_connections: 4096,
            max_connections_per_ip: 32,
            deny: Vec::new(),
            utc_offset_secs: proto::egress::DAY_UTC_OFFSET_SECS,
            insecure: false,
        }
    }
}

/// 一个 IP 网段（`10.0.0.0/8`、`2001:db8::/32`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    net: IpAddr,
    prefix: u8,
}

impl std::str::FromStr for Cidr {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let (ip, prefix) = s.split_once('/').unwrap_or((s, ""));
        let net: IpAddr = ip.parse().map_err(|_| format!("bad address in {s:?}"))?;
        let max = if net.is_ipv4() { 32 } else { 128 };
        let prefix = if prefix.is_empty() {
            max
        } else {
            prefix
                .parse::<u8>()
                .ok()
                .filter(|p| *p <= max)
                .ok_or_else(|| format!("bad prefix in {s:?}"))?
        };
        Ok(Self {
            net: net.to_canonical(),
            prefix,
        })
    }
}

impl Cidr {
    pub fn contains(&self, ip: IpAddr) -> bool {
        let bits = |ip: IpAddr| -> (u128, u32) {
            match ip {
                IpAddr::V4(v4) => (u128::from(u32::from(v4)), 32),
                IpAddr::V6(v6) => (u128::from(v6), 128),
            }
        };
        let (a, len_a) = bits(self.net);
        let (b, len_b) = bits(ip.to_canonical());
        if len_a != len_b {
            return false;
        }
        if self.prefix == 0 {
            return true;
        }
        let shift = len_a - u32::from(self.prefix);
        (a >> shift) == (b >> shift)
    }
}

/// 一条隧道的日志（只有元数据）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EgressRecord {
    pub user: String,
    pub instance: String,
    pub host: String,
    pub port: u16,
    pub address: Option<SocketAddr>,
    pub allowed: bool,
    /// `ok`，或者拒绝、断开的原因。
    pub reason: &'static str,
    pub bytes_up: u64,
    pub bytes_down: u64,
    pub duration: Duration,
}

/// 额度和日志存在哪：生产是数据库（多副本共用），开发和测试用内存。
#[async_trait]
pub trait EgressLedger: Send + Sync {
    /// 从实例 `day` 这天的额度里预留最多 `want` 字节，返回实际预留到的；0 表示用完了。出错时调用方按用完处理。
    async fn reserve(
        &self,
        instance: &str,
        user: &str,
        day: NaiveDate,
        want: u64,
        limit: u64,
    ) -> anyhow::Result<u64>;
    /// 退回没用完的预留。
    async fn refund(&self, instance: &str, day: NaiveDate, bytes: u64) -> anyhow::Result<()>;
    /// 记一行日志。失败只记进程日志。
    async fn record(&self, record: EgressRecord);
}

/// 内存里的额度和日志（开发、测试）。
#[derive(Default)]
pub struct MemoryEgressLedger {
    usage: Mutex<HashMap<(String, NaiveDate), u64>>,
    records: Mutex<Vec<EgressRecord>>,
}

impl MemoryEgressLedger {
    pub fn records(&self) -> Vec<EgressRecord> {
        self.records
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn used(&self, instance: &str, day: NaiveDate) -> u64 {
        self.usage
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&(instance.to_owned(), day))
            .copied()
            .unwrap_or(0)
    }
}

#[async_trait]
impl EgressLedger for MemoryEgressLedger {
    async fn reserve(
        &self,
        instance: &str,
        _user: &str,
        day: NaiveDate,
        want: u64,
        limit: u64,
    ) -> anyhow::Result<u64> {
        let mut map = self.usage.lock().unwrap_or_else(|e| e.into_inner());
        let used = map.entry((instance.to_owned(), day)).or_default();
        let granted = want.min(limit.saturating_sub(*used));
        *used += granted;
        Ok(granted)
    }

    async fn refund(&self, instance: &str, day: NaiveDate, bytes: u64) -> anyhow::Result<()> {
        let mut map = self.usage.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(used) = map.get_mut(&(instance.to_owned(), day)) {
            *used = used.saturating_sub(bytes);
        }
        Ok(())
    }

    async fn record(&self, record: EgressRecord) {
        self.records
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(record);
    }
}

/// 每个实例的计数：开着的隧道、这一分钟开了几次、记了几条拒绝。
#[derive(Default)]
struct Counters {
    open: HashMap<String, u32>,
    minute: HashMap<String, (Instant, u32, u32)>,
}

/// 出口代理。
pub struct Egress {
    gw: Arc<Gateway>,
    ledger: Arc<dyn EgressLedger>,
    options: EgressOptions,
    counters: Mutex<Counters>,
}

/// 占着的一条隧道名额，放掉时减一。
struct TunnelSlot {
    egress: Arc<Egress>,
    instance: String,
}

impl Drop for TunnelSlot {
    fn drop(&mut self) {
        let mut c = self
            .egress
            .counters
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(n) = c.open.get_mut(&self.instance) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                c.open.remove(&self.instance);
            }
        }
        metrics::gauge!("thinktin_egress_open_tunnels").decrement(1.0);
    }
}

/// 一条隧道的来龙去脉：谁、去哪、哪一天的额度。
struct Target {
    token: String,
    peer: SocketAddr,
    user: String,
    instance: String,
    host: String,
    port: u16,
    day: NaiveDate,
}

/// 隧道的额度：本地还剩多少预留，不够了再找账本要。
struct Budget {
    available: tokio::sync::Mutex<u64>,
}

/// 拒绝：状态码、原因（进日志）、给 agent 看的说明。
struct Denied {
    status: StatusCode,
    reason: &'static str,
    message: String,
}

fn denied(status: StatusCode, reason: &'static str, message: impl Into<String>) -> Denied {
    Denied {
        status,
        reason,
        message: message.into(),
    }
}

fn respond(d: &Denied) -> Response<Body> {
    let mut resp = Response::new(Body::from(format!(
        "thinktin egress: {}: {}\n",
        d.reason, d.message
    )));
    *resp.status_mut() = d.status;
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    if d.status == StatusCode::PROXY_AUTHENTICATION_REQUIRED {
        resp.headers_mut().insert(
            header::PROXY_AUTHENTICATE,
            header::HeaderValue::from_static("Basic realm=\"thinktin-egress\""),
        );
    }
    resp
}

/// `Proxy-Authorization: Basic base64(用户名:令牌)` 里的令牌（用户名随便写）。
fn proxy_token(req: &Request<Incoming>) -> Option<String> {
    let v = req
        .headers()
        .get(header::PROXY_AUTHORIZATION)?
        .to_str()
        .ok()?
        .trim();
    let (scheme, rest) = v.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("basic") {
        return None;
    }
    let raw = base64::engine::general_purpose::STANDARD
        .decode(rest.trim())
        .ok()?;
    let text = String::from_utf8(raw).ok()?;
    let (_, token) = text.split_once(':')?;
    let token = token.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

impl Egress {
    pub fn new(gw: Arc<Gateway>, ledger: Arc<dyn EgressLedger>, options: EgressOptions) -> Self {
        Self {
            gw,
            ledger,
            options,
            counters: Mutex::default(),
        }
    }

    fn today(&self) -> NaiveDate {
        (Utc::now() + chrono::Duration::seconds(self.options.utc_offset_secs)).date_naive()
    }

    /// 这一分钟又开了一次隧道：没超过上限返回 true。
    fn attempt(&self, instance: &str) -> bool {
        let mut c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        let e = c.minute.entry(instance.to_owned()).or_insert((now, 0, 0));
        if now.duration_since(e.0) >= Duration::from_secs(60) {
            *e = (now, 0, 0);
        }
        e.1 += 1;
        let ok = e.1 <= self.options.attempts_per_minute;
        if c.minute.len() > 100_000 {
            c.minute
                .retain(|_, (at, _, _)| now.duration_since(*at) < Duration::from_secs(60));
        }
        ok
    }

    /// 这一分钟还能再记一条拒绝的日志吗。
    fn may_log_denial(&self, instance: &str) -> bool {
        let mut c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let Some(e) = c.minute.get_mut(instance) else {
            return true;
        };
        e.2 += 1;
        e.2 <= self.options.denials_logged_per_minute
    }

    fn take_slot(self: &Arc<Self>, instance: &str) -> Option<TunnelSlot> {
        let mut c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let n = c.open.entry(instance.to_owned()).or_default();
        if *n >= self.options.max_tunnels {
            return None;
        }
        *n += 1;
        metrics::gauge!("thinktin_egress_open_tunnels").increment(1.0);
        Some(TunnelSlot {
            egress: self.clone(),
            instance: instance.to_owned(),
        })
    }

    fn record_denial(&self, caller: &Caller, host: &str, port: u16, d: &Denied) {
        metrics::counter!("thinktin_egress_tunnels_total", "result" => d.reason).increment(1);
        if !self.may_log_denial(&caller.instance.id) {
            return;
        }
        let record = EgressRecord {
            user: caller.instance.user_id.clone(),
            instance: caller.instance.id.clone(),
            host: host.chars().take(253).collect(),
            port,
            address: None,
            allowed: false,
            reason: d.reason,
            bytes_up: 0,
            bytes_down: 0,
            duration: Duration::ZERO,
        };
        let ledger = self.ledger.clone();
        tokio::spawn(async move { ledger.record(record).await });
    }

    /// 解析目标，所有地址都要是公网地址且不在禁段里。
    async fn resolve(&self, host: &str, port: u16) -> Result<Vec<SocketAddr>, Denied> {
        let addrs: Vec<SocketAddr> = if self.options.insecure {
            tokio::net::lookup_host((host, port))
                .await
                .map(|a| a.collect())
                .unwrap_or_default()
        } else {
            match ssrf::resolve_public(host).await {
                Ok(a) => a
                    .into_iter()
                    .map(|a| SocketAddr::new(a.ip(), port))
                    .collect(),
                Err(ssrf::SsrfError::NotPublic(_)) => {
                    return Err(denied(
                        StatusCode::FORBIDDEN,
                        "private_address",
                        format!("{host} resolves to an address that is not on the public internet"),
                    ));
                }
                Err(_) => Vec::new(),
            }
        };
        if addrs.is_empty() {
            return Err(denied(
                StatusCode::BAD_GATEWAY,
                "dns",
                format!("{host} did not resolve"),
            ));
        }
        if addrs
            .iter()
            .any(|a| self.options.deny.iter().any(|c| c.contains(a.ip())))
        {
            return Err(denied(
                StatusCode::FORBIDDEN,
                "private_address",
                format!("{host} resolves to a blocked address"),
            ));
        }
        Ok(addrs)
    }

    async fn connect(&self, addrs: &[SocketAddr]) -> Option<(TcpStream, SocketAddr)> {
        for addr in addrs {
            if let Ok(Ok(s)) =
                tokio::time::timeout(self.options.connect_timeout, TcpStream::connect(addr)).await
            {
                let _ = s.set_nodelay(true);
                return Some((s, *addr));
            }
        }
        None
    }

    /// 处理一个 CONNECT：过关就回 200 并把隧道交给后台任务。
    async fn handle(self: Arc<Self>, req: Request<Incoming>, peer: SocketAddr) -> Response<Body> {
        if req.method() != Method::CONNECT {
            return respond(&denied(
                StatusCode::METHOD_NOT_ALLOWED,
                "method",
                "only CONNECT host:443 is supported (set https_proxy, not a plain HTTP request)",
            ));
        }
        let Some(token) = proxy_token(&req) else {
            metrics::counter!("thinktin_egress_tunnels_total", "result" => "auth").increment(1);
            return respond(&denied(
                StatusCode::PROXY_AUTHENTICATION_REQUIRED,
                "auth",
                "missing proxy credentials (the sandbox token goes in the proxy URL)",
            ));
        };
        let Ok(caller) = self.gw.verify_token(&token, peer).await else {
            metrics::counter!("thinktin_egress_tunnels_total", "result" => "auth").increment(1);
            return respond(&denied(
                StatusCode::PROXY_AUTHENTICATION_REQUIRED,
                "auth",
                "sandbox token rejected",
            ));
        };
        if !self.attempt(&caller.instance.id) {
            metrics::counter!("thinktin_egress_tunnels_total", "result" => "rate").increment(1);
            return respond(&denied(
                StatusCode::TOO_MANY_REQUESTS,
                "rate",
                "too many connections this minute, slow down",
            ));
        }
        let authority = req.uri().authority().cloned();
        let raw_host = authority.as_ref().map(|a| a.host()).unwrap_or_default();
        let port = authority.as_ref().and_then(|a| a.port_u16()).unwrap_or(0);
        let host = match proto::egress::normalize_host(raw_host, self.options.insecure) {
            Ok(h) => h,
            Err(e) => {
                let d = denied(StatusCode::BAD_REQUEST, "bad_host", e.to_string());
                self.record_denial(&caller, raw_host, port, &d);
                return respond(&d);
            }
        };
        if port != 443 && !(self.options.insecure && port != 0) {
            let d = denied(
                StatusCode::FORBIDDEN,
                "port",
                "only port 443 (HTTPS) is allowed",
            );
            self.record_denial(&caller, &host, port, &d);
            return respond(&d);
        }
        if !caller
            .instance
            .egress_mode
            .allows(&host, &caller.instance.egress_hosts)
        {
            let d = denied(
                StatusCode::FORBIDDEN,
                "not_allowed",
                format!(
                    "this agent may not reach {host}; the user can allow it in the agent's internet settings"
                ),
            );
            self.record_denial(&caller, &host, port, &d);
            return respond(&d);
        }
        let Some(slot) = self.take_slot(&caller.instance.id) else {
            let d = denied(
                StatusCode::TOO_MANY_REQUESTS,
                "too_many_tunnels",
                format!("at most {} connections at a time", self.options.max_tunnels),
            );
            self.record_denial(&caller, &host, port, &d);
            return respond(&d);
        };
        let target = Target {
            token,
            peer,
            user: caller.instance.user_id.clone(),
            instance: caller.instance.id.clone(),
            host,
            port,
            day: self.today(),
        };
        // 先预留一段：今天用完了就不开。
        let first = match self
            .ledger
            .reserve(
                &target.instance,
                &target.user,
                target.day,
                self.options.reserve_chunk,
                self.options.daily_bytes,
            )
            .await
        {
            Ok(0) => {
                let d = denied(
                    StatusCode::TOO_MANY_REQUESTS,
                    "quota",
                    "today's internet allowance for this agent is used up",
                );
                self.record_denial(&caller, &target.host, port, &d);
                return respond(&d);
            }
            Ok(n) => n,
            Err(e) => {
                tracing::error!(error = %e, "reserving egress bytes failed");
                let d = denied(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "store",
                    "the egress service is unavailable, try again later",
                );
                self.record_denial(&caller, &target.host, port, &d);
                return respond(&d);
            }
        };
        let refund = |bytes: u64| {
            let ledger = self.ledger.clone();
            let (instance, day) = (target.instance.clone(), target.day);
            async move {
                if let Err(e) = ledger.refund(&instance, day, bytes).await {
                    tracing::warn!(error = %e, "refunding egress bytes failed");
                }
            }
        };
        let addrs = match self.resolve(&target.host, port).await {
            Ok(a) => a,
            Err(d) => {
                refund(first).await;
                self.record_denial(&caller, &target.host, port, &d);
                return respond(&d);
            }
        };
        let Some((upstream, address)) = self.connect(&addrs).await else {
            refund(first).await;
            let d = denied(
                StatusCode::BAD_GATEWAY,
                "connect_failed",
                format!("could not connect to {}", target.host),
            );
            self.record_denial(&caller, &target.host, port, &d);
            return respond(&d);
        };
        let this = self.clone();
        tokio::spawn(async move {
            this.tunnel(req, upstream, address, target, first, slot)
                .await
        });
        Response::new(Body::empty())
    }

    /// 隧道开着的时候还放不放行：令牌还有效、档位还放行这个网站。
    async fn still_allowed(&self, t: &Target) -> bool {
        match self.gw.verify_token(&t.token, t.peer).await {
            Ok(c) => c
                .instance
                .egress_mode
                .allows(&t.host, &c.instance.egress_hosts),
            Err(_) => false,
        }
    }

    async fn tunnel(
        self: Arc<Self>,
        req: Request<Incoming>,
        upstream: TcpStream,
        address: SocketAddr,
        target: Target,
        first: u64,
        _slot: TunnelSlot,
    ) {
        let started = Instant::now();
        let budget = Arc::new(Budget {
            available: tokio::sync::Mutex::new(first),
        });
        let up = Arc::new(AtomicU64::new(0));
        let down = Arc::new(AtomicU64::new(0));
        let last = Arc::new(AtomicU64::new(0));
        let reason = match hyper::upgrade::on(req).await {
            Ok(upgraded) => {
                let (cr, cw) = tokio::io::split(TokioIo::new(upgraded));
                let (ur, uw) = upstream.into_split();
                let mut a = tokio::spawn(copy(
                    cr,
                    uw,
                    self.clone(),
                    budget.clone(),
                    target.clone_ids(),
                    up.clone(),
                    last.clone(),
                    started,
                ));
                let mut b = tokio::spawn(copy(
                    ur,
                    cw,
                    self.clone(),
                    budget.clone(),
                    target.clone_ids(),
                    down.clone(),
                    last.clone(),
                    started,
                ));
                let mut recheck = tokio::time::interval(self.options.recheck_every);
                recheck.tick().await;
                let mut idle = tokio::time::interval(Duration::from_secs(1));
                let deadline = tokio::time::sleep(self.options.max_duration);
                tokio::pin!(deadline);
                let (mut a_done, mut b_done) = (false, false);
                let reason = loop {
                    tokio::select! {
                        r = &mut a, if !a_done => {
                            a_done = true;
                            if let Ok(Err(r)) = r { break r; }
                            if b_done { break "ok"; }
                        }
                        r = &mut b, if !b_done => {
                            b_done = true;
                            if let Ok(Err(r)) = r { break r; }
                            if a_done { break "ok"; }
                        }
                        _ = recheck.tick() => {
                            if !self.still_allowed(&target).await { break "revoked"; }
                        }
                        _ = idle.tick() => {
                            let quiet = started.elapsed()
                                .saturating_sub(Duration::from_millis(last.load(Ordering::Relaxed)));
                            if quiet >= self.options.idle_timeout { break "idle"; }
                        }
                        () = &mut deadline => break "max_duration",
                    }
                };
                a.abort();
                b.abort();
                reason
            }
            Err(e) => {
                tracing::debug!(error = %e, "egress upgrade failed");
                "upgrade_failed"
            }
        };
        let left = *budget.available.lock().await;
        if left > 0
            && let Err(e) = self.ledger.refund(&target.instance, target.day, left).await
        {
            tracing::warn!(error = %e, "refunding egress bytes failed");
        }
        let (bytes_up, bytes_down) = (up.load(Ordering::Relaxed), down.load(Ordering::Relaxed));
        metrics::counter!("thinktin_egress_tunnels_total", "result" => reason).increment(1);
        metrics::counter!("thinktin_egress_bytes_total", "direction" => "up").increment(bytes_up);
        metrics::counter!("thinktin_egress_bytes_total", "direction" => "down")
            .increment(bytes_down);
        self.ledger
            .record(EgressRecord {
                user: target.user,
                instance: target.instance,
                host: target.host,
                port: target.port,
                address: Some(address),
                allowed: true,
                reason,
                bytes_up,
                bytes_down,
                duration: started.elapsed(),
            })
            .await;
    }

    /// 从额度里扣 `n` 字节：本地预留不够就再找账本要，今天用完了（或者账本出错）返回原因。
    async fn charge(&self, budget: &Budget, ids: &Ids, n: u64) -> Result<(), &'static str> {
        let mut available = budget.available.lock().await;
        while *available < n {
            let want = self.options.reserve_chunk.max(n - *available);
            match self
                .ledger
                .reserve(
                    &ids.instance,
                    &ids.user,
                    ids.day,
                    want,
                    self.options.daily_bytes,
                )
                .await
            {
                Ok(0) => return Err("quota"),
                Ok(got) => *available += got,
                Err(e) => {
                    tracing::error!(error = %e, "reserving egress bytes failed");
                    return Err("store");
                }
            }
        }
        *available -= n;
        Ok(())
    }
}

/// 扣额度要的几个 id。
#[derive(Clone)]
struct Ids {
    user: String,
    instance: String,
    day: NaiveDate,
}

impl Target {
    fn clone_ids(&self) -> Ids {
        Ids {
            user: self.user.clone(),
            instance: self.instance.clone(),
            day: self.day,
        }
    }
}

/// 一个方向的转发：读到的先扣额度再写；读完了就关掉对面的写方向。返回 Err(原因) 表示要断开整条隧道。
#[allow(clippy::too_many_arguments)]
async fn copy<R, W>(
    mut from: R,
    mut to: W,
    egress: Arc<Egress>,
    budget: Arc<Budget>,
    ids: Ids,
    counter: Arc<AtomicU64>,
    last: Arc<AtomicU64>,
    started: Instant,
) -> Result<(), &'static str>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buf = vec![0u8; 16 << 10];
    loop {
        let n = match from.read(&mut buf).await {
            Ok(0) => {
                let _ = to.shutdown().await;
                return Ok(());
            }
            Ok(n) => n,
            Err(_) => return Err("reset"),
        };
        egress.charge(&budget, &ids, n as u64).await?;
        if to.write_all(&buf[..n]).await.is_err() {
            return Err("reset");
        }
        counter.fetch_add(n as u64, Ordering::Relaxed);
        let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        last.store(ms, Ordering::Relaxed);
    }
}

/// 在 `listener` 上跑出口代理，直到 `shutdown` 完成（之后不再接新连接，开着的隧道照常跑完）。
pub async fn serve_egress(
    listener: TcpListener,
    egress: Arc<Egress>,
    shutdown: impl std::future::Future<Output = ()>,
) -> std::io::Result<()> {
    let total = Arc::new(Semaphore::new(egress.options.max_connections));
    let per_ip = Arc::new(PerIp::default());
    tokio::pin!(shutdown);
    loop {
        let (stream, peer) = tokio::select! {
            _ = &mut shutdown => return Ok(()),
            accepted = listener.accept() => match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    tracing::warn!(error = %e, "egress accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            },
        };
        let Ok(permit) = total.clone().try_acquire_owned() else {
            continue;
        };
        let Some(slot) = per_ip.take(
            peer.ip().to_canonical(),
            egress.options.max_connections_per_ip,
        ) else {
            continue;
        };
        let _ = stream.set_nodelay(true);
        let egress = egress.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _slot = slot;
            let timeout = egress.options.header_read_timeout;
            let service = hyper::service::service_fn(move |req: Request<Incoming>| {
                let egress = egress.clone();
                async move { Ok::<_, Infallible>(egress.handle(req, peer).await) }
            });
            let mut builder = hyper::server::conn::http1::Builder::new();
            builder
                .timer(TokioTimer::new())
                .header_read_timeout(timeout)
                .keep_alive(false);
            if let Err(e) = builder
                .serve_connection(TokioIo::new(stream), service)
                .with_upgrades()
                .await
            {
                tracing::debug!(%peer, error = %e, "egress connection ended with an error");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cidrs_match_by_prefix() {
        let c: Cidr = "10.0.0.0/8".parse().unwrap();
        assert!(c.contains("10.1.2.3".parse().unwrap()));
        assert!(c.contains("::ffff:10.1.2.3".parse().unwrap()));
        assert!(!c.contains("11.0.0.1".parse().unwrap()));
        let one: Cidr = "47.74.56.251".parse().unwrap();
        assert!(one.contains("47.74.56.251".parse().unwrap()));
        assert!(!one.contains("47.74.56.250".parse().unwrap()));
        let v6: Cidr = "2001:db8::/32".parse().unwrap();
        assert!(v6.contains("2001:db8:1::1".parse().unwrap()));
        assert!(!v6.contains("10.0.0.1".parse().unwrap()));
        assert!("10.0.0.0/33".parse::<Cidr>().is_err());
        assert!("nope/8".parse::<Cidr>().is_err());
    }
}
