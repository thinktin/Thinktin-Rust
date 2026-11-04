//! 受控出网通道（WBS 2.7，[出口代理](../../../docs/egress.md)）：沙箱只能经这里上外网。
//!
//! 只做 HTTPS 的 `CONNECT host:443` 隧道，不解密。一条隧道要依次过这些关（便宜的在前）：
//!
//! 1. 沙箱令牌放在 `Proxy-Authorization: Basic`（代理地址里的密码），和模型网关一样核对签名、来源地址、实例在运行、
//!    沙箱和代数、运行授权没吊销；
//! 2. 每个实例每分钟开隧道的次数有上限；
//! 3. 目标网站名按 `proto::egress::normalize_host` 整理（不收 IP、数字变形、单段名字），端口只能是 443；
//! 4. 实例的档位直接放行这个网站（`EgressMode::allows`：默认是搜索、开发网站和用户一直允许的）；不直接放行的问用户
//!    （[`Egress::ask`]：这次任务里答过就按答的，没答过就登记一条请求、最多等一分钟看用户答不答，没答就告诉 agent
//!    先做别的）；
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
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
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
use tokio::sync::{Notify, Semaphore, watch};

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
    /// 每个来源地址每分钟最多发几次 CONNECT（核对令牌之前就数，过期令牌反复来也不会每次都查库）。
    pub attempts_per_ip_per_minute: u32,
    /// 每个实例每分钟最多记几行日志（放行的和拒绝的一起数）。再多的按“网站、结果”合并，每分钟记一行带次数的。
    pub logs_per_minute: u32,
    /// 每次从额度里预留多少。
    pub reserve_chunk: u64,
    pub connect_timeout: Duration,
    pub idle_timeout: Duration,
    pub max_duration: Duration,
    /// 隧道开着时多久重新核对一次令牌和档位。
    pub recheck_every: Duration,
    /// 同时开着的隧道满了时，新的等多久空出名额（npm 这类工具会同时开很多连接，马上拒绝它们就装不上包）。
    pub slot_wait: Duration,
    /// 停机时等开着的隧道收尾（退回额度、写日志）多久。
    pub shutdown_grace: Duration,
    pub header_read_timeout: Duration,
    pub max_connections: usize,
    pub max_connections_per_ip: usize,
    /// 部署配置的禁段（比如服务机自己的公网地址），公网地址落在这里也拒绝。
    pub deny: Vec<Cidr>,
    /// 每天按哪个时区切（相对 UTC 的秒数）。
    pub utc_offset_secs: i64,
    /// 问用户的时候最多等多久（用户 2026-11-04 定：一分钟）。
    pub ask_wait: Duration,
    /// 等用户回答时多久查一次。
    pub ask_poll: Duration,
    /// 一次任务里最多几个网站同时在等用户回答（再多的不问，直接拒绝）。
    pub max_pending_asks: u32,
    /// 每个实例一小时里最多登记几条新请求。
    pub max_asks_per_hour: u32,
    /// 每个实例最多几个连接同时等用户回答（再多的照样登记、马上告诉 agent 用户还没答）。
    pub max_waiting: u32,
    /// 只用于本地开发和测试：允许非公网地址、任意端口、单段名字（`localhost`）。
    pub insecure: bool,
}

impl Default for EgressOptions {
    fn default() -> Self {
        Self {
            daily_bytes: proto::egress::DAILY_BYTES,
            max_tunnels: proto::egress::MAX_TUNNELS,
            attempts_per_minute: 120,
            attempts_per_ip_per_minute: 240,
            logs_per_minute: 30,
            reserve_chunk: 256 << 10,
            connect_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(300),
            max_duration: Duration::from_secs(3600),
            recheck_every: Duration::from_secs(30),
            slot_wait: Duration::from_secs(30),
            shutdown_grace: Duration::from_secs(10),
            header_read_timeout: Duration::from_secs(10),
            max_connections: 4096,
            max_connections_per_ip: 32,
            deny: Vec::new(),
            utc_offset_secs: proto::egress::DAY_UTC_OFFSET_SECS,
            ask_wait: Duration::from_secs(proto::egress::ASK_WAIT_SECS),
            ask_poll: Duration::from_secs(1),
            max_pending_asks: proto::egress::MAX_PENDING_ASKS,
            max_asks_per_hour: proto::egress::MAX_ASKS_PER_HOUR,
            max_waiting: 2 * proto::egress::MAX_TUNNELS,
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
    /// 合并了几条隧道（超过每分钟的日志上限时按网站和结果合并），平常是 1。
    pub count: u32,
}

/// 用户对 agent 想访问的一个网站怎么答的（出口代理看到的）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    /// 还在等。
    Pending,
    /// 访问一次（这次任务）或者一直允许。
    Allowed,
    /// 拒绝（这次任务里不再问）。
    Denied,
    /// 太久没人答、已经过期，或者这条没了。
    Gone,
}

impl Answer {
    pub(crate) fn from_status(status: Option<&str>) -> Self {
        match status {
            Some("pending") => Answer::Pending,
            Some("once" | "always") => Answer::Allowed,
            Some("denied") => Answer::Denied,
            _ => Answer::Gone,
        }
    }
}

/// 登记“想访问一个网站”的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Asked {
    /// 请求 id：新登记的、接着等的，或者用户刚答过的那条。
    Request(String),
    /// 这次任务已经有好几个网站在等用户回答。
    TooManyPending,
    /// 这个实例这一小时问用户问得太多了。
    HourlyLimit,
}

/// 额度、日志和要问用户的网站存在哪：生产是数据库（多副本共用），开发和测试用内存。
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
    /// 实例现在在做的任务，和这次任务里用户对 `host` 答过的（访问一次、拒绝；没答过为空）。
    async fn decision(
        &self,
        instance: &str,
        host: &str,
    ) -> anyhow::Result<(Option<String>, Option<Answer>)>;
    /// 登记“想访问 `host`”（同一个网站已经有一条在等就接着等那条，用户刚答过就是答过的那条）；这次任务已经有
    /// `max_pending` 个网站在等、或者这个实例一小时里已经有 `max_per_hour` 条用户没答应的时不登记。
    async fn ask(
        &self,
        user: &str,
        instance: &str,
        host: &str,
        run: Option<&str>,
        max_pending: u32,
        max_per_hour: u32,
    ) -> anyhow::Result<Asked>;
    /// 实例 `day` 这天用掉（含预留中）的字节。
    async fn used_on(&self, instance: &str, day: NaiveDate) -> anyhow::Result<u64>;
    /// 一条请求现在怎么样了。
    async fn answer(&self, request: &str) -> anyhow::Result<Answer>;
}

/// 内存里的一条请求（开发、测试）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryAsk {
    pub id: String,
    pub instance: String,
    pub host: String,
    pub run: Option<String>,
    /// pending、once、always、denied、expired。
    pub status: String,
    pub created: Instant,
}

/// 内存里的额度和日志（开发、测试）。
#[derive(Default)]
pub struct MemoryEgressLedger {
    usage: Mutex<HashMap<(String, NaiveDate), u64>>,
    records: Mutex<Vec<EgressRecord>>,
    asks: Mutex<Vec<MemoryAsk>>,
    runs: Mutex<HashMap<String, String>>,
}

impl MemoryEgressLedger {
    pub fn records(&self) -> Vec<EgressRecord> {
        self.records
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn asks(&self) -> Vec<MemoryAsk> {
        self.asks.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// 用户回答一条请求（`once`、`always`、`denied`、`expired`）。
    pub fn decide(&self, id: &str, status: &str) {
        for a in self
            .asks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter_mut()
        {
            if a.id == id {
                a.status = status.to_owned();
            }
        }
    }

    /// 实例现在在做的任务（空表示没有）。
    pub fn set_run(&self, instance: &str, run: Option<&str>) {
        let mut runs = self.runs.lock().unwrap_or_else(|e| e.into_inner());
        match run {
            Some(r) => runs.insert(instance.to_owned(), r.to_owned()),
            None => runs.remove(instance),
        };
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

    async fn decision(
        &self,
        instance: &str,
        host: &str,
    ) -> anyhow::Result<(Option<String>, Option<Answer>)> {
        let run = self
            .runs
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(instance)
            .cloned();
        let answer = self
            .asks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .rev()
            .find(|a| {
                a.instance == instance
                    && a.host == host
                    && a.run == run
                    && matches!(a.status.as_str(), "once" | "denied")
            })
            .map(|a| Answer::from_status(Some(&a.status)));
        Ok((run, answer))
    }

    async fn ask(
        &self,
        _user: &str,
        instance: &str,
        host: &str,
        run: Option<&str>,
        max_pending: u32,
        max_per_hour: u32,
    ) -> anyhow::Result<Asked> {
        let mut asks = self.asks.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(a) = asks
            .iter_mut()
            .find(|a| a.instance == instance && a.host == host && a.status == "pending")
        {
            a.run = run.map(str::to_owned);
            return Ok(Asked::Request(a.id.clone()));
        }
        let pending = asks
            .iter()
            .filter(|a| a.instance == instance && a.status == "pending" && a.run.as_deref() == run)
            .count();
        let hour = asks
            .iter()
            .filter(|a| {
                a.instance == instance
                    && a.created.elapsed() < Duration::from_secs(3600)
                    && !matches!(a.status.as_str(), "once" | "always")
            })
            .count();
        if pending >= max_pending as usize {
            return Ok(Asked::TooManyPending);
        }
        if hour >= max_per_hour as usize {
            return Ok(Asked::HourlyLimit);
        }
        let id = proto::domain::EgressRequestId::new().to_string();
        asks.push(MemoryAsk {
            id: id.clone(),
            instance: instance.to_owned(),
            host: host.to_owned(),
            run: run.map(str::to_owned),
            status: "pending".into(),
            created: Instant::now(),
        });
        Ok(Asked::Request(id))
    }

    async fn used_on(&self, instance: &str, day: NaiveDate) -> anyhow::Result<u64> {
        Ok(self.used(instance, day))
    }

    async fn answer(&self, request: &str) -> anyhow::Result<Answer> {
        let asks = self.asks.lock().unwrap_or_else(|e| e.into_inner());
        Ok(Answer::from_status(
            asks.iter()
                .find(|a| a.id == request)
                .map(|a| a.status.as_str()),
        ))
    }
}

/// 每个实例的计数：开着的隧道、这一分钟开了几次、记了几行日志；每个来源地址这一分钟发了几次。
#[derive(Default)]
struct Counters {
    open: HashMap<String, u32>,
    /// 在等用户回答的连接。
    waiting: HashMap<String, u32>,
    minute: HashMap<String, (Instant, u32, u32)>,
    peers: HashMap<IpAddr, (Instant, u32)>,
}

/// 超过日志上限时合并的键：同一个实例、网站、端口、结果。
type SummaryKey = (String, String, String, u16, bool, &'static str);

/// 预留了还没交给隧道的额度：中途出错、客户端断开（请求被丢弃）时退回。
struct Reserved {
    ledger: Arc<dyn EgressLedger>,
    instance: String,
    day: NaiveDate,
    bytes: u64,
}

impl Reserved {
    /// 交给隧道：之后由隧道结束时退回剩下的。
    fn take(mut self) -> u64 {
        std::mem::take(&mut self.bytes)
    }
}

impl Drop for Reserved {
    fn drop(&mut self) {
        if self.bytes == 0 {
            return;
        }
        let (ledger, instance, day, bytes) = (
            self.ledger.clone(),
            std::mem::take(&mut self.instance),
            self.day,
            self.bytes,
        );
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            rt.spawn(async move {
                if let Err(e) = ledger.refund(&instance, day, bytes).await {
                    tracing::warn!(error = %e, "refunding egress bytes failed");
                }
            });
        }
    }
}

/// 出口代理。
pub struct Egress {
    gw: Arc<Gateway>,
    ledger: Arc<dyn EgressLedger>,
    options: EgressOptions,
    counters: Mutex<Counters>,
    /// 超过日志上限、等着合并写的：键 → (次数, 上行, 下行, 时长)。
    summaries: Mutex<HashMap<SummaryKey, (u32, u64, u64, Duration)>>,
    /// 有隧道名额空出来了。
    slot_freed: Notify,
    /// 停机：开着的隧道收尾退出。
    stopping: watch::Sender<bool>,
    /// 开着的隧道任务数，和它降到 0 的通知。
    running: AtomicUsize,
    drained: Notify,
}

/// 一个开着的隧道任务：结束时计数减一。
struct Running(Arc<Egress>);

impl Drop for Running {
    fn drop(&mut self) {
        if self.0.running.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.0.drained.notify_waiters();
        }
    }
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
        drop(c);
        metrics::gauge!("thinktin_egress_open_tunnels").decrement(1.0);
        self.egress.slot_freed.notify_waiters();
    }
}

/// 今天的流量用完了。
fn quota_denied() -> Denied {
    denied(
        StatusCode::TOO_MANY_REQUESTS,
        "quota",
        "today's internet allowance for this agent is used up",
    )
}

/// 一条拒绝的日志。
fn denial_record(caller: &Caller, host: &str, port: u16, reason: &'static str) -> EgressRecord {
    EgressRecord {
        user: caller.instance.user_id.clone(),
        instance: caller.instance.id.clone(),
        host: host.chars().take(253).collect(),
        port,
        address: None,
        allowed: false,
        reason,
        bytes_up: 0,
        bytes_down: 0,
        duration: Duration::ZERO,
        count: 1,
    }
}

/// 等用户回答、等名额的时候客户端断开了（这个请求被丢弃）：照样记一行日志。正常走完前 [`Abandoned::disarm`]。
struct Abandoned {
    egress: Arc<Egress>,
    record: Option<EgressRecord>,
}

impl Abandoned {
    fn disarm(mut self) {
        self.record = None;
    }
}

impl Drop for Abandoned {
    fn drop(&mut self) {
        let Some(record) = self.record.take() else {
            return;
        };
        metrics::counter!("thinktin_egress_tunnels_total", "result" => record.reason).increment(1);
        let egress = self.egress.clone();
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            rt.spawn(async move { egress.log(record).await });
        }
    }
}

/// 一个在等用户回答的连接，放下时还回名额。
struct WaitingSlot {
    egress: Arc<Egress>,
    instance: String,
}

impl Drop for WaitingSlot {
    fn drop(&mut self) {
        let mut c = self
            .egress
            .counters
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(n) = c.waiting.get_mut(&self.instance) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                c.waiting.remove(&self.instance);
            }
        }
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
    /// 用户答应了（访问一次、一直允许）才开的：档位本身不直接放行，重新核对时只要档位还问用户就接着开。
    approved: bool,
}

/// 隧道的额度：本地还剩多少预留、是哪一天的，不够了再找账本要。过了零点就退回前一天剩下的，改从当天扣。
struct Budget {
    inner: tokio::sync::Mutex<(u64, NaiveDate)>,
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
            summaries: Mutex::default(),
            slot_freed: Notify::new(),
            stopping: watch::channel(false).0,
            running: AtomicUsize::new(0),
            drained: Notify::new(),
        }
    }

    /// 停机：开着的隧道断开（退回额度、写日志），最多等 `shutdown_grace`，再把合并的日志写掉。
    pub async fn stop(&self) {
        self.stopping.send_replace(true);
        let wait = async {
            loop {
                let drained = self.drained.notified();
                tokio::pin!(drained);
                drained.as_mut().enable();
                if self.running.load(Ordering::Acquire) == 0 {
                    return;
                }
                drained.await;
            }
        };
        if tokio::time::timeout(self.options.shutdown_grace, wait)
            .await
            .is_err()
        {
            tracing::warn!("egress tunnels did not close in time");
        }
        self.flush_summaries().await;
    }

    /// 等一个隧道名额，最多等 `slot_wait`。
    async fn wait_slot(self: &Arc<Self>, instance: &str) -> Option<TunnelSlot> {
        let deadline = tokio::time::Instant::now() + self.options.slot_wait;
        loop {
            let freed = self.slot_freed.notified();
            tokio::pin!(freed);
            freed.as_mut().enable();
            if let Some(slot) = self.take_slot(instance) {
                return Some(slot);
            }
            if tokio::time::timeout_at(deadline, freed).await.is_err() {
                return None;
            }
        }
    }

    /// 这个来源地址这一分钟又发了一次 CONNECT：没超过上限返回 true。
    fn peer_attempt(&self, ip: IpAddr) -> bool {
        let mut c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        let e = c.peers.entry(ip.to_canonical()).or_insert((now, 0));
        if now.duration_since(e.0) >= Duration::from_secs(60) {
            *e = (now, 0);
        }
        e.1 += 1;
        let ok = e.1 <= self.options.attempts_per_ip_per_minute;
        if c.peers.len() > 100_000 {
            c.peers
                .retain(|_, (at, _)| now.duration_since(*at) < Duration::from_secs(60));
        }
        ok
    }

    /// 记一行日志：这一分钟没超过上限就直接写，超了就并进合并表，由 [`Egress::flush_summaries`] 每分钟写一行。
    async fn log(&self, record: EgressRecord) {
        if self.may_log(&record.instance) {
            self.ledger.record(record).await;
            return;
        }
        let key = (
            record.user,
            record.instance,
            record.host,
            record.port,
            record.allowed,
            record.reason,
        );
        let mut s = self.summaries.lock().unwrap_or_else(|e| e.into_inner());
        if s.len() >= 100_000 && !s.contains_key(&key) {
            metrics::counter!("thinktin_egress_log_dropped_total").increment(1);
            return;
        }
        let e = s.entry(key).or_insert((0, 0, 0, Duration::ZERO));
        e.0 += record.count;
        e.1 += record.bytes_up;
        e.2 += record.bytes_down;
        e.3 += record.duration;
    }

    /// 把合并表写成带次数的日志行（每分钟一次，停机前一次）。
    pub async fn flush_summaries(&self) {
        let drained: Vec<_> = {
            let mut s = self.summaries.lock().unwrap_or_else(|e| e.into_inner());
            s.drain().collect()
        };
        for ((user, instance, host, port, allowed, reason), (count, up, down, duration)) in drained
        {
            self.ledger
                .record(EgressRecord {
                    user,
                    instance,
                    host,
                    port,
                    address: None,
                    allowed,
                    reason,
                    bytes_up: up,
                    bytes_down: down,
                    duration,
                    count,
                })
                .await;
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

    /// 这一分钟还能再单独记一行日志吗。
    fn may_log(&self, instance: &str) -> bool {
        let mut c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let Some(e) = c.minute.get_mut(instance) else {
            return true;
        };
        e.2 += 1;
        e.2 <= self.options.logs_per_minute
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

    fn record_denial(self: &Arc<Self>, caller: &Caller, host: &str, port: u16, d: &Denied) {
        metrics::counter!("thinktin_egress_tunnels_total", "result" => d.reason).increment(1);
        let record = denial_record(caller, host, port, d.reason);
        let this = self.clone();
        tokio::spawn(async move { this.log(record).await });
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
        if !self.peer_attempt(peer.ip()) {
            metrics::counter!("thinktin_egress_tunnels_total", "result" => "rate").increment(1);
            return respond(&denied(
                StatusCode::TOO_MANY_REQUESTS,
                "rate",
                "too many connections from this sandbox this minute, slow down",
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
        // 档位不直接放行、要问用户的（问了、用户答应了才往下走）。
        let mut ask_user = false;
        if !caller
            .instance
            .egress_mode
            .allows(&host, &caller.instance.egress_hosts)
        {
            // 目录有缓存：用户刚点了“一直允许”时缓存里还没有，重新读一次再判断。
            let fresh = self.gw.directory.instance(&caller.instance.id, true).await;
            let (mode, allowed) = match &fresh {
                Some(i) => (i.egress_mode, i.egress_mode.allows(&host, &i.egress_hosts)),
                None => (caller.instance.egress_mode, false),
            };
            if !allowed {
                if !mode.asks() {
                    let d = denied(
                        StatusCode::FORBIDDEN,
                        "not_allowed",
                        format!("this agent may not reach {host}"),
                    );
                    self.record_denial(&caller, &host, port, &d);
                    return respond(&d);
                }
                // 今天的流量用完了：答应了也连不上，不用问。
                if self
                    .ledger
                    .used_on(&caller.instance.id, self.today())
                    .await
                    .is_ok_and(|used| used >= self.options.daily_bytes)
                {
                    let d = quota_denied();
                    self.record_denial(&caller, &host, port, &d);
                    return respond(&d);
                }
                ask_user = true;
            }
        }
        // 下面可能要等一会儿（问用户最多一分钟、等名额最多半分钟）：客户端等不及断开时，这个请求被丢弃，守卫记一行日志。
        let started = Instant::now();
        let gone = Abandoned {
            egress: self.clone(),
            record: Some(denial_record(&caller, &host, port, "client_gone")),
        };
        if ask_user && let Err(d) = self.ask(&caller, &host).await {
            gone.disarm();
            self.record_denial(&caller, &host, port, &d);
            return respond(&d);
        }
        let Some(slot) = self.wait_slot(&caller.instance.id).await else {
            gone.disarm();
            let d = denied(
                StatusCode::TOO_MANY_REQUESTS,
                "too_many_tunnels",
                format!("at most {} connections at a time", self.options.max_tunnels),
            );
            self.record_denial(&caller, &host, port, &d);
            return respond(&d);
        };
        gone.disarm();
        // 等的这段时间里任务可能结束了（令牌代数变了）、授权可能吊销了：重新读一次实例，再核对一遍令牌。
        if ask_user || started.elapsed() >= Duration::from_secs(1) {
            let _ = self.gw.directory.instance(&caller.instance.id, true).await;
            if self.gw.verify_token(&token, peer).await.is_err() {
                let d = denied(
                    StatusCode::PROXY_AUTHENTICATION_REQUIRED,
                    "auth",
                    "sandbox token rejected",
                );
                self.record_denial(&caller, &host, port, &d);
                return respond(&d);
            }
        }
        let target = Target {
            token,
            peer,
            user: caller.instance.user_id.clone(),
            instance: caller.instance.id.clone(),
            host,
            port,
            day: self.today(),
            approved: ask_user,
        };
        // 先预留一段：今天用完了就不开。预留由 `Reserved` 拿着：解析、连接时出错或者客户端断开（这个请求被丢弃）
        // 都会退回。
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
                let d = quota_denied();
                self.record_denial(&caller, &target.host, port, &d);
                return respond(&d);
            }
            Ok(n) => Reserved {
                ledger: self.ledger.clone(),
                instance: target.instance.clone(),
                day: target.day,
                bytes: n,
            },
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
        let addrs = match self.resolve(&target.host, port).await {
            Ok(a) => a,
            Err(d) => {
                drop(first);
                self.record_denial(&caller, &target.host, port, &d);
                return respond(&d);
            }
        };
        let Some((upstream, address)) = self.connect(&addrs).await else {
            drop(first);
            let d = denied(
                StatusCode::BAD_GATEWAY,
                "connect_failed",
                format!("could not connect to {}", target.host),
            );
            self.record_denial(&caller, &target.host, port, &d);
            return respond(&d);
        };
        let this = self.clone();
        let first = first.take();
        tokio::spawn(async move {
            this.tunnel(req, upstream, address, target, first, slot)
                .await
        });
        Response::new(Body::empty())
    }

    /// 隧道开着的时候还放不放行：令牌还有效（任务结束、实例停了、授权吊销都会失效）、档位还放行这个网站（用户答应过的，
    /// 档位还问用户就行）。
    async fn still_allowed(&self, t: &Target) -> bool {
        match self.gw.verify_token(&t.token, t.peer).await {
            Ok(c) => {
                let mode = c.instance.egress_mode;
                (t.approved && mode.asks()) || mode.allows(&t.host, &c.instance.egress_hosts)
            }
            Err(_) => false,
        }
    }

    /// 不直接放行的网站问用户（2.7）。这次任务里答过就按答的；没答过就登记一条请求（同一个网站只有一条在等，后台给
    /// 用户发提醒），最多等 `ask_wait` 看用户答不答。用户答应了返回 Ok，否则是给 agent 看的拒绝。
    async fn ask(self: &Arc<Self>, caller: &Caller, host: &str) -> Result<(), Denied> {
        let instance = caller.instance.id.as_str();
        let unavailable = |e: anyhow::Error| {
            tracing::error!(error = %e, "egress approval lookup failed");
            denied(
                StatusCode::SERVICE_UNAVAILABLE,
                "store",
                "the egress service is unavailable, try again later",
            )
        };
        let user_denied = || {
            denied(
                StatusCode::FORBIDDEN,
                "user_denied",
                format!("the user declined {host} for this task; do it another way"),
            )
        };
        let pending = || {
            denied(
                StatusCode::FORBIDDEN,
                "pending_approval",
                format!(
                    "{host} needs the user's approval; they have been asked in the Thinktin app and have not \
                     answered yet. Do other work first and try {host} again later, or find another way"
                ),
            )
        };
        let (run, answer) = self
            .ledger
            .decision(instance, host)
            .await
            .map_err(unavailable)?;
        match answer {
            Some(Answer::Allowed) => return Ok(()),
            Some(Answer::Denied) => return Err(user_denied()),
            _ => {}
        }
        let id = match self
            .ledger
            .ask(
                &caller.instance.user_id,
                instance,
                host,
                run.as_deref(),
                self.options.max_pending_asks,
                self.options.max_asks_per_hour,
            )
            .await
            .map_err(unavailable)?
        {
            Asked::Request(id) => id,
            Asked::TooManyPending => {
                return Err(denied(
                    StatusCode::FORBIDDEN,
                    "too_many_asks",
                    "too many sites are already waiting for the user's approval; wait for those or do it another way",
                ));
            }
            Asked::HourlyLimit => {
                return Err(denied(
                    StatusCode::FORBIDDEN,
                    "ask_rate",
                    format!(
                        "the user was asked about too many new sites this hour, so {host} was not asked; try again later or do it another way"
                    ),
                ));
            }
        };
        metrics::counter!("thinktin_egress_asks_total").increment(1);
        let Some(_waiting) = self.take_waiting(instance) else {
            return Err(pending());
        };
        let deadline = tokio::time::Instant::now() + self.options.ask_wait;
        let mut stop = self.stopping.subscribe();
        loop {
            match self.ledger.answer(&id).await {
                Ok(Answer::Allowed) => return Ok(()),
                Ok(Answer::Denied) => return Err(user_denied()),
                Ok(Answer::Gone) => return Err(pending()),
                Ok(Answer::Pending) => {}
                Err(e) => tracing::warn!(error = %e, "checking an egress approval failed"),
            }
            let now = tokio::time::Instant::now();
            if now >= deadline || *stop.borrow_and_update() {
                return Err(pending());
            }
            tokio::select! {
                () = tokio::time::sleep(self.options.ask_poll.min(deadline - now)) => {}
                _ = stop.changed() => {}
            }
        }
    }

    /// 占一个“等用户回答”的名额。
    fn take_waiting(self: &Arc<Self>, instance: &str) -> Option<WaitingSlot> {
        let mut c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let n = c.waiting.entry(instance.to_owned()).or_default();
        if *n >= self.options.max_waiting {
            return None;
        }
        *n += 1;
        Some(WaitingSlot {
            egress: self.clone(),
            instance: instance.to_owned(),
        })
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
        let _running = {
            self.running.fetch_add(1, Ordering::AcqRel);
            Running(self.clone())
        };
        let mut stop = self.stopping.subscribe();
        let budget = Arc::new(Budget {
            inner: tokio::sync::Mutex::new((first, target.day)),
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
                    if *stop.borrow_and_update() {
                        break "shutdown";
                    }
                    tokio::select! {
                        _ = stop.changed() => {}
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
        let (left, day) = *budget.inner.lock().await;
        if left > 0
            && let Err(e) = self.ledger.refund(&target.instance, day, left).await
        {
            tracing::warn!(error = %e, "refunding egress bytes failed");
        }
        let (bytes_up, bytes_down) = (up.load(Ordering::Relaxed), down.load(Ordering::Relaxed));
        metrics::counter!("thinktin_egress_tunnels_total", "result" => reason).increment(1);
        metrics::counter!("thinktin_egress_bytes_total", "direction" => "up").increment(bytes_up);
        metrics::counter!("thinktin_egress_bytes_total", "direction" => "down")
            .increment(bytes_down);
        self.log(EgressRecord {
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
            count: 1,
        })
        .await;
    }

    /// 从额度里扣 `n` 字节：本地预留不够就再找账本要，今天用完了（或者账本出错）返回原因。
    async fn charge(&self, budget: &Budget, ids: &Ids, n: u64) -> Result<(), &'static str> {
        let mut guard = budget.inner.lock().await;
        let (available, day) = &mut *guard;
        let today = self.today();
        if *day != today {
            if *available > 0
                && let Err(e) = self.ledger.refund(&ids.instance, *day, *available).await
            {
                tracing::warn!(error = %e, "refunding egress bytes failed");
            }
            *available = 0;
            *day = today;
        }
        while *available < n {
            let want = self.options.reserve_chunk.max(n - *available);
            match self
                .ledger
                .reserve(
                    &ids.instance,
                    &ids.user,
                    *day,
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
}

impl Target {
    fn clone_ids(&self) -> Ids {
        Ids {
            user: self.user.clone(),
            instance: self.instance.clone(),
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

/// 任务句柄丢了就停掉任务。
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// 在 `listener` 上跑出口代理，直到 `shutdown` 完成：之后不再接新连接，开着的隧道收尾断开（[`Egress::stop`]）。
pub async fn serve_egress(
    listener: TcpListener,
    egress: Arc<Egress>,
    shutdown: impl std::future::Future<Output = ()>,
) -> std::io::Result<()> {
    let total = Arc::new(Semaphore::new(egress.options.max_connections));
    let per_ip = Arc::new(PerIp::default());
    let flusher = {
        let egress = egress.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(60));
            loop {
                tick.tick().await;
                egress.flush_summaries().await;
            }
        })
    };
    let _flusher = AbortOnDrop(flusher);
    tokio::pin!(shutdown);
    loop {
        let (stream, peer) = tokio::select! {
            _ = &mut shutdown => {
                egress.stop().await;
                return Ok(());
            }
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
