//! CubeSandbox 后端（WBS 6.2）：按 Cube 的 E2B 兼容接口实现 [`SandboxProvider`]。
//!
//! - 控制面：CubeAPI（`/sandboxes`、`/volumes`），开了鉴权时带 `Authorization: Bearer`；
//! - 数据面：沙箱里的 envd（端口 49983），经 CubeProxy 按 `49983-<沙箱 id>.<域名>` 路由。
//!   进程走 Connect 协议：`process.Process/Start` 流式返回输出，`SendInput` 写标准输入，
//!   `CloseStdin` 关标准输入，`SendSignal` 结束进程；文件走 envd 的 `/files`。
//!
//! 沙箱里的目录约定（模板负责建好，见 docs/sandbox-cube.md）：`<root>/home` 是 HOME，
//! `<root>/workspace` 挂工作区卷；进程以 `user` 运行。trait 里的相对路径都相对 `<root>`。
//!
//! 两处和本地后端不同：
//! - Cube 按模板分配 CPU、内存，[`CreateSpec::resources`] 由模板决定，这里不传；
//! - 沙箱出网经节点 SNAT，模型网关看不到单个沙箱的地址，[`SandboxInfo::address`] 用配置的
//!   `egress_address`（节点出网地址或 NAT 地址），沙箱令牌只能绑到这一级。

use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::net::IpAddr;
use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use bytes::{Bytes, BytesMut};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HOST};
use reqwest::{Method, StatusCode};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::sync::oneshot;

use crate::{
    CreateSpec, Error, ExecSpec, Process, ProcessControl, Result, SandboxId, SandboxInfo,
    SandboxProvider, SandboxState, SnapshotId, check_relative_path,
};

/// envd 在沙箱里监听的端口。
pub const ENVD_PORT: u16 = 49983;
const CONNECT_JSON: &str = "application/connect+json";
const FLAG_COMPRESSED: u8 = 0x01;
const FLAG_END_STREAM: u8 = 0x02;
/// 单个 Connect 消息的上限（输出分片很小，这只是防异常）。
const MAX_FRAME: usize = 16 << 20;
/// 标准输入一次最多发多少字节。
const STDIN_CHUNK: usize = 64 << 10;
/// 输出管道的缓冲：调用方读得慢时 envd 的流也跟着慢下来。
const PIPE_BUFFER: usize = 256 << 10;
/// 写标准输入、发信号这类小请求的超时。
const UNARY_TIMEOUT: Duration = Duration::from_secs(30);
/// 读写文件的超时。
const FILE_TIMEOUT: Duration = Duration::from_secs(120);
/// 发了 SIGKILL 以后等进程结束多久。
const KILL_WAIT: Duration = Duration::from_secs(10);
/// 沙箱正在暂停、恢复时（409、503）重试几次、隔多久。
const LIFECYCLE_RETRIES: u32 = 5;
const LIFECYCLE_RETRY_DELAY: Duration = Duration::from_secs(2);
/// 元数据里记原始模板和工作区：从快照恢复的沙箱，Cube 返回的模板 id 是快照 id。
const META_TEMPLATE: &str = "thinktin_template";
const META_WORKSPACE: &str = "thinktin_workspace";

#[derive(Clone)]
pub struct CubeConfig {
    /// CubeAPI 地址（E2B SDK 的 `E2B_API_URL`），如 `http://cube-api:3000`。
    pub api_url: String,
    /// CubeAPI 开了鉴权时的 key（`Authorization: Bearer`）。
    pub api_key: Option<String>,
    /// 沙箱域名。Cube 在创建、连接的响应里会返回，这里只是兜底。
    pub domain: Option<String>,
    /// 直接连 CubeProxy 的地址（如 `http://10.0.0.5`），按 Host 头路由；不填就按
    /// `<data_scheme>://49983-<沙箱 id>.<域名>` 解析（需要泛域名 DNS）。
    pub proxy_url: Option<String>,
    /// 不用 `proxy_url` 时数据面的 scheme。
    pub data_scheme: String,
    /// 沙箱里的根目录。
    pub root: String,
    /// 进程以哪个用户运行（envd 的 Basic 认证用户名）。
    pub user: String,
    /// 模型网关看到的沙箱来源地址（节点出网地址或 NAT 地址）。
    pub egress_address: Option<IpAddr>,
    /// 工作区放在 Cube 卷上（卷插件要先在 CubeMaster 里配好）。关掉时工作区在沙箱自己的磁盘上，
    /// 只随暂停和快照保留，重建沙箱会丢。
    pub use_volumes: bool,
    /// 卷插件名，不填用 CubeMaster 的默认插件。
    pub volume_driver: Option<String>,
    /// 控制面请求的超时（创建、暂停要做快照，可能要几十秒）。
    pub request_timeout: Duration,
}

impl Default for CubeConfig {
    fn default() -> Self {
        Self {
            api_url: "http://127.0.0.1:3000".into(),
            api_key: None,
            domain: None,
            proxy_url: None,
            data_scheme: "https".into(),
            root: "/sandbox".into(),
            user: "user".into(),
            egress_address: None,
            use_volumes: true,
            volume_driver: None,
            request_timeout: Duration::from_secs(120),
        }
    }
}

impl std::fmt::Debug for CubeConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CubeConfig")
            .field("api_url", &self.api_url)
            .field("api_key", &self.api_key.is_some())
            .field("domain", &self.domain)
            .field("proxy_url", &self.proxy_url)
            .field("data_scheme", &self.data_scheme)
            .field("root", &self.root)
            .field("user", &self.user)
            .field("egress_address", &self.egress_address)
            .field("use_volumes", &self.use_volumes)
            .field("volume_driver", &self.volume_driver)
            .field("request_timeout", &self.request_timeout)
            .finish()
    }
}

/// 一个沙箱的数据面连接信息（令牌不进日志）。
#[derive(Clone)]
struct Conn {
    id: String,
    domain: String,
    envd_token: Option<String>,
    traffic_token: Option<String>,
}

/// 到某个沙箱 envd 的客户端。
#[derive(Clone)]
struct Envd {
    http: reqwest::Client,
    proxy_url: Option<String>,
    scheme: String,
    auth: String,
    conn: Conn,
}

impl Envd {
    fn request(&self, method: Method, path: &str) -> reqwest::RequestBuilder {
        let host = format!("{ENVD_PORT}-{}.{}", self.conn.id, self.conn.domain);
        let rb = match &self.proxy_url {
            Some(proxy) => self
                .http
                .request(method, format!("{}{path}", proxy.trim_end_matches('/')))
                .header(HOST, host),
            None => self
                .http
                .request(method, format!("{}://{host}{path}", self.scheme)),
        };
        let mut rb = rb.header(AUTHORIZATION, self.auth.as_str());
        if let Some(t) = &self.conn.envd_token {
            rb = rb.header("X-Access-Token", t.as_str());
        }
        if let Some(t) = &self.conn.traffic_token {
            rb = rb
                .header("e2b-traffic-access-token", t.as_str())
                .header("cube-traffic-access-token", t.as_str());
        }
        rb
    }

    /// Connect 协议的一元调用（JSON）。
    async fn unary(&self, rpc: &str, body: &Value) -> Result<(StatusCode, Bytes)> {
        let resp = self
            .request(Method::POST, &format!("/{rpc}"))
            .header(CONTENT_TYPE, "application/json")
            .header("Connect-Protocol-Version", "1")
            .timeout(UNARY_TIMEOUT)
            .body(body.to_string())
            .send()
            .await
            .map_err(provider_err)?;
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(provider_err)?;
        Ok((status, bytes))
    }
}

pub struct CubeProvider {
    cfg: CubeConfig,
    api: reqwest::Client,
    data: reqwest::Client,
    conns: Mutex<HashMap<String, Conn>>,
    /// 工作区名 → Cube 的卷 id。
    volumes: Mutex<HashMap<String, String>>,
}

#[derive(Deserialize)]
struct Created {
    #[serde(rename = "sandboxID")]
    sandbox_id: String,
    #[serde(default)]
    domain: Option<String>,
    #[serde(rename = "envdAccessToken", default)]
    envd_access_token: Option<String>,
    #[serde(rename = "trafficAccessToken", default)]
    traffic_access_token: Option<String>,
}

#[derive(Deserialize)]
struct Detail {
    #[serde(rename = "sandboxID")]
    sandbox_id: String,
    #[serde(rename = "templateID", default)]
    template_id: String,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    metadata: Option<BTreeMap<String, String>>,
}

impl Detail {
    fn running(&self) -> bool {
        self.state.as_deref() == Some("running")
    }
}

#[derive(Deserialize)]
struct VolumeEntry {
    #[serde(rename = "volumeID")]
    volume_id: String,
    #[serde(default)]
    name: String,
}

#[derive(Deserialize)]
struct SnapshotCreated {
    #[serde(rename = "snapshotID")]
    snapshot_id: String,
}

#[derive(Deserialize, Default)]
struct ApiErrorBody {
    #[serde(default)]
    message: String,
}

fn provider_err(e: impl std::fmt::Display) -> Error {
    Error::Provider(e.to_string())
}

fn api_error(what: &str, status: StatusCode, body: &[u8]) -> Error {
    let message = match serde_json::from_slice::<ApiErrorBody>(body) {
        Ok(b) if !b.message.is_empty() => b.message,
        _ => String::from_utf8_lossy(&body[..body.len().min(512)]).into_owned(),
    };
    if status == StatusCode::BAD_REQUEST {
        Error::Invalid(format!("{what}: {message}"))
    } else {
        Error::Provider(format!("{what}: HTTP {}: {message}", status.as_u16()))
    }
}

fn parse<T: serde::de::DeserializeOwned>(what: &str, body: &[u8]) -> Result<T> {
    serde_json::from_slice(body).map_err(|e| Error::Provider(format!("{what}: bad response: {e}")))
}

/// `host:port` → `host`：Cube 的出网白名单按地址或域名放行，不分端口。
pub fn allow_host(target: &str) -> &str {
    let t = target.trim();
    if let Some(rest) = t.strip_prefix('[') {
        return rest.split(']').next().unwrap_or(rest);
    }
    match t.rsplit_once(':') {
        Some((host, port))
            if !host.contains(':')
                && !port.is_empty()
                && port.bytes().all(|b| b.is_ascii_digit()) =>
        {
            host
        }
        _ => t,
    }
}

/// Cube 的卷名只能是字母、数字、`-`、`_`。
fn check_volume_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(Error::Invalid(format!("bad workspace name {name:?}")));
    }
    Ok(())
}

/// 查询参数里的值（路径）按 RFC 3986 转义。
fn query_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

fn envelope(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(0);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn multipart(boundary: &str, filename: &str, data: &[u8]) -> Vec<u8> {
    let filename: String = filename
        .chars()
        .map(|c| if c == '"' || c.is_control() { '_' } else { c })
        .collect();
    let mut body = Vec::with_capacity(data.len() + 256);
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n\
             Content-Type: application/octet-stream\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(data);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

fn random_boundary() -> String {
    let mut b = [0u8; 12];
    let _ = getrandom::fill(&mut b);
    let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("thinktin-{hex}")
}

// ---------- 进程事件（envd 的 process.proto，JSON 编码） ----------

#[derive(Deserialize, Default)]
struct StartResponse {
    #[serde(default)]
    event: Option<ProcessEvent>,
}

#[derive(Deserialize, Default)]
struct ProcessEvent {
    #[serde(default)]
    start: Option<StartEvent>,
    #[serde(default)]
    data: Option<DataEvent>,
    #[serde(default)]
    end: Option<EndEvent>,
}

#[derive(Deserialize)]
struct StartEvent {
    #[serde(default)]
    pid: u32,
}

#[derive(Deserialize, Default)]
struct DataEvent {
    #[serde(default)]
    stdout: Option<String>,
    #[serde(default)]
    stderr: Option<String>,
}

#[derive(Deserialize, Default)]
struct EndEvent {
    /// proto3 的 JSON 不输出默认值：退出码 0 时这个字段可能没有。
    #[serde(rename = "exitCode", alias = "exit_code", default)]
    exit_code: Option<i32>,
    #[serde(default)]
    exited: bool,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Deserialize, Default)]
struct EndStream {
    #[serde(default)]
    error: Option<ConnectError>,
}

#[derive(Deserialize, Default)]
struct ConnectError {
    #[serde(default)]
    code: String,
    #[serde(default)]
    message: String,
}

fn parse_event(payload: &[u8]) -> Result<ProcessEvent> {
    let msg: StartResponse = serde_json::from_slice(payload)
        .map_err(|e| Error::Provider(format!("bad envd event: {e}")))?;
    Ok(msg.event.unwrap_or_default())
}

/// 流结束的消息：带 error 就是出错了。
fn end_stream(payload: &[u8]) -> Result<()> {
    if payload.is_empty() {
        return Ok(());
    }
    let v: EndStream = serde_json::from_slice(payload).unwrap_or_default();
    match v.error {
        Some(e) => Err(Error::Provider(format!("envd: {}: {}", e.code, e.message))),
        None => Ok(()),
    }
}

/// Go 的 `os.ProcessState` 文字：`signal: killed`、`signal: terminated` ……
fn signal_of(status: &str) -> Option<i32> {
    let name = status.strip_prefix("signal: ")?;
    Some(match name.trim() {
        "hangup" => libc::SIGHUP,
        "interrupt" => libc::SIGINT,
        "quit" => libc::SIGQUIT,
        "aborted" => libc::SIGABRT,
        "segmentation fault" => libc::SIGSEGV,
        "broken pipe" => libc::SIGPIPE,
        "terminated" => libc::SIGTERM,
        _ => libc::SIGKILL,
    })
}

fn exit_code_of(status: &str) -> Option<i32> {
    status.strip_prefix("exit status ")?.trim().parse().ok()
}

fn exit_status(end: &EndEvent) -> ExitStatus {
    if let Some(sig) = end.status.as_deref().and_then(signal_of) {
        return ExitStatus::from_raw(sig);
    }
    let code = match end.exit_code {
        Some(c) if c >= 0 => c,
        // 被信号结束时 envd 报 -1。
        Some(_) => return ExitStatus::from_raw(libc::SIGKILL),
        None => match end.status.as_deref().and_then(exit_code_of) {
            Some(c) => c,
            None if end.exited && end.error.is_none() => 0,
            None => 1,
        },
    };
    ExitStatus::from_raw((code & 0xff) << 8)
}

/// 按 Connect 的信封格式（1 字节标志 + 4 字节大端长度 + 内容）切分响应流。
struct Frames {
    resp: reqwest::Response,
    buf: BytesMut,
}

impl Frames {
    fn new(resp: reqwest::Response) -> Self {
        Self {
            resp,
            buf: BytesMut::new(),
        }
    }

    async fn next(&mut self) -> Result<Option<(u8, Bytes)>> {
        loop {
            if self.buf.len() >= 5 {
                let flags = self.buf[0];
                let len = u32::from_be_bytes([self.buf[1], self.buf[2], self.buf[3], self.buf[4]])
                    as usize;
                if len > MAX_FRAME {
                    return Err(Error::Provider(format!(
                        "envd message too large ({len} bytes)"
                    )));
                }
                if self.buf.len() >= 5 + len {
                    let frame = self.buf.split_to(5 + len).freeze();
                    return Ok(Some((flags, frame.slice(5..))));
                }
            }
            match self.resp.chunk().await.map_err(provider_err)? {
                Some(chunk) => self.buf.extend_from_slice(&chunk),
                None if self.buf.is_empty() => return Ok(None),
                None => {
                    return Err(Error::Provider(
                        "envd stream ended in the middle of a message".into(),
                    ));
                }
            }
        }
    }
}

fn decode(b64: &str) -> Result<Vec<u8>> {
    STANDARD
        .decode(b64)
        .map_err(|e| Error::Provider(format!("bad envd output: {e}")))
}

/// 把进程输出写进管道，直到进程结束。读的一方关掉了就丢弃那一路输出，接着等退出。
async fn pump_output(
    frames: &mut Frames,
    out: &mut DuplexStream,
    err: &mut DuplexStream,
) -> Result<ExitStatus> {
    let mut out_open = true;
    let mut err_open = true;
    while let Some((flags, payload)) = frames.next().await? {
        if flags & FLAG_COMPRESSED != 0 {
            return Err(Error::Provider(
                "compressed envd messages are not supported".into(),
            ));
        }
        if flags & FLAG_END_STREAM != 0 {
            end_stream(&payload)?;
            break;
        }
        let ev = parse_event(&payload)?;
        if let Some(data) = ev.data {
            if let Some(b) = data.stdout
                && out_open
            {
                out_open = out.write_all(&decode(&b)?).await.is_ok();
            }
            if let Some(b) = data.stderr
                && err_open
            {
                err_open = err.write_all(&decode(&b)?).await.is_ok();
            }
        }
        if let Some(end) = ev.end {
            return Ok(exit_status(&end));
        }
    }
    Err(Error::Provider(
        "envd stream ended before the process exited".into(),
    ))
}

/// 把写进管道的标准输入转发给 envd；写的一方关掉后关掉进程的标准输入。
async fn pump_stdin(envd: Envd, pid: u32, mut input: DuplexStream) {
    let mut buf = vec![0u8; STDIN_CHUNK];
    loop {
        let n = match input.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let body = json!({
            "process": { "pid": pid },
            "input": { "stdin": STANDARD.encode(&buf[..n]) },
        });
        match envd.unary("process.Process/SendInput", &body).await {
            Ok((status, _)) if status.is_success() => {}
            // 进程已经结束或 envd 不可达：不再转发。
            _ => return,
        }
    }
    // 老版本 envd 没有 CloseStdin，忽略错误。
    let _ = envd
        .unary(
            "process.Process/CloseStdin",
            &json!({ "process": { "pid": pid } }),
        )
        .await;
}

struct CubeControl {
    envd: Envd,
    pid: u32,
    exit: Option<oneshot::Receiver<Result<ExitStatus>>>,
    status: Option<ExitStatus>,
}

#[async_trait]
impl ProcessControl for CubeControl {
    async fn wait(&mut self) -> Result<ExitStatus> {
        if let Some(s) = self.status {
            return Ok(s);
        }
        let rx = self
            .exit
            .as_mut()
            .ok_or_else(|| Error::Provider("the process stream is gone".into()))?;
        let res = rx.await;
        self.exit = None;
        let status = res.map_err(|_| Error::Provider("the process stream task ended".into()))??;
        self.status = Some(status);
        Ok(status)
    }

    async fn kill(&mut self) -> Result<()> {
        if self.status.is_some() {
            return Ok(());
        }
        let body = json!({ "process": { "pid": self.pid }, "signal": "SIGNAL_SIGKILL" });
        // 进程已经结束时 envd 报 not_found，忽略。
        let _ = self.envd.unary("process.Process/SendSignal", &body).await;
        let _ = tokio::time::timeout(KILL_WAIT, self.wait()).await;
        Ok(())
    }
}

impl CubeProvider {
    pub fn new(cfg: CubeConfig) -> Result<Self> {
        let api = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(cfg.request_timeout)
            .build()
            .map_err(provider_err)?;
        // 进程的输出流可能持续几个小时，不设总超时；小请求各自设超时。
        let data = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(provider_err)?;
        Ok(Self {
            cfg,
            api,
            data,
            conns: Mutex::default(),
            volumes: Mutex::default(),
        })
    }

    /// 沙箱里的绝对路径。
    fn abs(&self, rel: &str) -> String {
        format!("{}/{rel}", self.cfg.root.trim_end_matches('/'))
    }

    fn api(&self, method: Method, path: &str) -> reqwest::RequestBuilder {
        let rb = self.api.request(
            method,
            format!("{}{path}", self.cfg.api_url.trim_end_matches('/')),
        );
        match &self.cfg.api_key {
            Some(key) => rb.bearer_auth(key),
            None => rb,
        }
    }

    async fn call(&self, rb: reqwest::RequestBuilder) -> Result<(StatusCode, Bytes)> {
        let resp = rb.send().await.map_err(provider_err)?;
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(provider_err)?;
        Ok((status, bytes))
    }

    fn conns(&self) -> std::sync::MutexGuard<'_, HashMap<String, Conn>> {
        self.conns.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn volume_ids(&self) -> std::sync::MutexGuard<'_, HashMap<String, String>> {
        self.volumes.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cached_conn(&self, id: &str) -> Option<Conn> {
        self.conns().get(id).cloned()
    }

    fn forget(&self, id: &str) {
        self.conns().remove(id);
    }

    fn remember(&self, c: Created) {
        let conn = Conn {
            id: c.sandbox_id.clone(),
            domain: c
                .domain
                .filter(|d| !d.is_empty())
                .or_else(|| self.cfg.domain.clone())
                .unwrap_or_else(|| "cube.app".into()),
            envd_token: c.envd_access_token.filter(|t| !t.is_empty()),
            traffic_token: c.traffic_access_token.filter(|t| !t.is_empty()),
        };
        self.conns().insert(c.sandbox_id, conn);
    }

    fn envd(&self, conn: Conn) -> Envd {
        let basic = STANDARD.encode(format!("{}:", self.cfg.user));
        Envd {
            http: self.data.clone(),
            proxy_url: self.cfg.proxy_url.clone(),
            scheme: self.cfg.data_scheme.clone(),
            auth: format!("Basic {basic}"),
            conn,
        }
    }

    async fn detail(&self, id: &SandboxId) -> Result<Option<Detail>> {
        let (status, bytes) = self
            .call(self.api(Method::GET, &format!("/sandboxes/{}", id.0)))
            .await?;
        if status == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !status.is_success() {
            return Err(api_error("get sandbox", status, &bytes));
        }
        Ok(Some(parse("get sandbox", &bytes)?))
    }

    fn info(&self, d: Detail) -> SandboxInfo {
        let running = d.running();
        let mut metadata = d.metadata.unwrap_or_default();
        let template = metadata.remove(META_TEMPLATE).unwrap_or(d.template_id);
        let workspace = metadata.remove(META_WORKSPACE);
        SandboxInfo {
            id: SandboxId(d.sandbox_id),
            template,
            workspace,
            // pausing、unknown 都按暂停处理：控制服务会去恢复，恢复是幂等的。
            state: if running {
                SandboxState::Running
            } else {
                SandboxState::Paused
            },
            address: self.cfg.egress_address,
            metadata,
        }
    }

    /// `POST /sandboxes/{id}/connect`：暂停的会恢复，顺便取回数据面的令牌。
    /// `timeout` 为 None 时不改沙箱的空闲超时。
    async fn connect(&self, id: &SandboxId, timeout: Option<i64>) -> Result<()> {
        let body = match timeout {
            Some(t) => json!({ "timeout": t }),
            None => json!({}),
        };
        let mut attempt = 0;
        loop {
            let (status, bytes) = self
                .call(
                    self.api(Method::POST, &format!("/sandboxes/{}/connect", id.0))
                        .json(&body),
                )
                .await?;
            if status == StatusCode::NOT_FOUND {
                return Err(Error::NotFound(id.clone()));
            }
            // 正在暂停之类的生命周期操作进行中：稍后再试。
            if (status == StatusCode::CONFLICT || status == StatusCode::SERVICE_UNAVAILABLE)
                && attempt < LIFECYCLE_RETRIES
            {
                attempt += 1;
                tokio::time::sleep(LIFECYCLE_RETRY_DELAY).await;
                continue;
            }
            if !status.is_success() {
                return Err(api_error("connect sandbox", status, &bytes));
            }
            let created: Created = parse("connect sandbox", &bytes)?;
            self.remember(created);
            return Ok(());
        }
    }

    /// 运行中沙箱的数据面连接。控制服务重启后缓存是空的：先确认在运行，再用 connect 取令牌
    /// （不改超时，运行中的沙箱不受影响）。
    async fn running_conn(&self, id: &SandboxId) -> Result<Conn> {
        if let Some(c) = self.cached_conn(&id.0) {
            return Ok(c);
        }
        let detail = self
            .detail(id)
            .await?
            .ok_or_else(|| Error::NotFound(id.clone()))?;
        if !detail.running() {
            return Err(Error::InvalidState {
                id: id.clone(),
                expected: SandboxState::Running,
                actual: SandboxState::Paused,
            });
        }
        self.connect(id, None).await?;
        self.cached_conn(&id.0)
            .ok_or_else(|| Error::Provider(format!("no connection info for sandbox {id}")))
    }

    async fn find_volume(&self, name: &str) -> Result<Option<String>> {
        let cached = self.volume_ids().get(name).cloned();
        if let Some(id) = cached {
            return Ok(Some(id));
        }
        let (status, bytes) = self.call(self.api(Method::GET, "/volumes")).await?;
        if !status.is_success() {
            return Err(api_error("list volumes", status, &bytes));
        }
        let list: Vec<VolumeEntry> = parse("list volumes", &bytes)?;
        let found = list
            .into_iter()
            .find(|v| v.name == name)
            .map(|v| v.volume_id);
        if let Some(id) = &found {
            self.volume_ids().insert(name.to_owned(), id.clone());
        }
        Ok(found)
    }

    async fn ensure_volume(&self, name: &str) -> Result<String> {
        check_volume_name(name)?;
        if let Some(id) = self.find_volume(name).await? {
            return Ok(id);
        }
        let mut body = json!({ "name": name });
        if let Some(driver) = &self.cfg.volume_driver {
            body["driver"] = json!(driver);
        }
        let (status, bytes) = self
            .call(self.api(Method::POST, "/volumes").json(&body))
            .await?;
        if status.is_success() {
            let v: VolumeEntry = parse("create volume", &bytes)?;
            self.volume_ids()
                .insert(name.to_owned(), v.volume_id.clone());
            return Ok(v.volume_id);
        }
        // 并发创建时别的副本可能已经建好了。
        if let Some(id) = self.find_volume(name).await? {
            return Ok(id);
        }
        Err(api_error("create volume", status, &bytes))
    }

    async fn sandbox_body(&self, template_id: &str, spec: &CreateSpec) -> Result<Value> {
        let mut metadata = spec.metadata.clone();
        metadata.insert(META_TEMPLATE.into(), spec.template.clone());
        if let Some(ws) = &spec.workspace {
            metadata.insert(META_WORKSPACE.into(), ws.clone());
        }
        let hosts: Vec<&str> = spec
            .network
            .allow
            .iter()
            .map(|t| allow_host(t))
            .filter(|h| !h.is_empty())
            .collect();
        let mut network = json!({ "allowPublicTraffic": false });
        if !hosts.is_empty() {
            network["allowOut"] = json!(hosts);
        }
        let mut body = json!({
            "templateID": template_id,
            // 不按空闲时间回收：暂停、归档由控制服务的巡检决定。
            "timeout": -1,
            "secure": true,
            // 默认拒绝全部出网，只放行白名单（通常只有模型网关）。
            "allow_internet_access": false,
            "network": network,
            "metadata": metadata,
        });
        if self.cfg.use_volumes
            && let Some(ws) = &spec.workspace
        {
            let volume = self.ensure_volume(ws).await?;
            body["volumeMounts"] = json!([{ "name": volume, "path": self.abs("workspace") }]);
        }
        Ok(body)
    }

    async fn create_from(
        &self,
        template_id: &str,
        spec: CreateSpec,
        missing: Error,
    ) -> Result<SandboxInfo> {
        let body = self.sandbox_body(template_id, &spec).await?;
        let (status, bytes) = self
            .call(self.api(Method::POST, "/sandboxes").json(&body))
            .await?;
        if status == StatusCode::NOT_FOUND {
            return Err(missing);
        }
        if !status.is_success() {
            return Err(api_error("create sandbox", status, &bytes));
        }
        let created: Created = parse("create sandbox", &bytes)?;
        let id = SandboxId(created.sandbox_id.clone());
        self.remember(created);
        Ok(SandboxInfo {
            id,
            template: spec.template,
            workspace: spec.workspace,
            state: SandboxState::Running,
            address: self.cfg.egress_address,
            metadata: spec.metadata,
        })
    }
}

#[async_trait]
impl SandboxProvider for CubeProvider {
    fn name(&self) -> &'static str {
        "cube"
    }

    async fn create(&self, spec: CreateSpec) -> Result<SandboxInfo> {
        if spec.template.is_empty() {
            return Err(Error::Invalid("template is required".into()));
        }
        let missing = Error::Invalid(format!("template {:?} not found", spec.template));
        let template = spec.template.clone();
        self.create_from(&template, spec, missing).await
    }

    async fn get(&self, id: &SandboxId) -> Result<Option<SandboxInfo>> {
        Ok(self.detail(id).await?.map(|d| self.info(d)))
    }

    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> Result<Process> {
        let (program, args) = spec
            .argv
            .split_first()
            .ok_or_else(|| Error::Invalid("argv is empty".into()))?;
        let cwd = match &spec.cwd {
            Some(rel) => {
                check_relative_path(rel)?;
                self.abs(rel)
            }
            None => self.abs("workspace"),
        };
        let mut envs: BTreeMap<String, String> = spec
            .env
            .iter()
            .map(|(k, v)| (k.clone(), v.expose().to_owned()))
            .collect();
        envs.entry("HOME".into())
            .or_insert_with(|| self.abs("home"));
        let envd = self.envd(self.running_conn(id).await?);
        let request = json!({
            "process": { "cmd": program, "args": args, "envs": envs, "cwd": cwd },
            "stdin": true,
        });
        let resp = envd
            .request(Method::POST, "/process.Process/Start")
            .header(CONTENT_TYPE, CONNECT_JSON)
            .header("Connect-Protocol-Version", "1")
            .header("Connect-Content-Encoding", "identity")
            // envd 定期发 keepalive 事件：长时间没有输出时，中间的代理也不会断开连接。
            .header("Keepalive-Ping-Interval", "30")
            .body(envelope(request.to_string().as_bytes()))
            .send()
            .await
            .map_err(provider_err)?;
        let status = resp.status();
        if !status.is_success() {
            let bytes = resp.bytes().await.unwrap_or_default();
            return Err(api_error("start process", status, &bytes));
        }
        let mut frames = Frames::new(resp);
        let pid = loop {
            let Some((flags, payload)) = frames.next().await? else {
                return Err(Error::Provider(
                    "envd closed the stream before the process started".into(),
                ));
            };
            if flags & FLAG_END_STREAM != 0 {
                end_stream(&payload)?;
                return Err(Error::Provider(
                    "envd ended the stream before the process started".into(),
                ));
            }
            if let Some(start) = parse_event(&payload)?.start {
                break start.pid;
            }
        };

        let (stdout, mut stdout_w) = tokio::io::duplex(PIPE_BUFFER);
        let (stderr, mut stderr_w) = tokio::io::duplex(PIPE_BUFFER);
        let (exit_tx, exit_rx) = oneshot::channel();
        tokio::spawn(async move {
            let result = pump_output(&mut frames, &mut stdout_w, &mut stderr_w).await;
            // 关掉输出管道，读的一方读到 EOF。
            drop(stdout_w);
            drop(stderr_w);
            let _ = exit_tx.send(result);
        });
        let (stdin, stdin_r) = tokio::io::duplex(STDIN_CHUNK);
        tokio::spawn(pump_stdin(envd.clone(), pid, stdin_r));
        Ok(Process {
            stdin: Box::new(stdin),
            stdout: Box::new(stdout),
            stderr: Box::new(stderr),
            control: Box::new(CubeControl {
                envd,
                pid,
                exit: Some(exit_rx),
                status: None,
            }),
        })
    }

    async fn pause(&self, id: &SandboxId) -> Result<()> {
        // 暂停后数据面不可用；下次用时重新确认状态、取令牌。
        self.forget(&id.0);
        let (status, bytes) = self
            .call(self.api(Method::POST, &format!("/sandboxes/{}/pause", id.0)))
            .await?;
        if status.is_success() {
            return Ok(());
        }
        if status == StatusCode::NOT_FOUND {
            return Err(Error::NotFound(id.clone()));
        }
        if status == StatusCode::CONFLICT {
            // 已经暂停（或正在暂停）时 Cube 报 409。
            return match self.detail(id).await? {
                Some(d) if !d.running() => Ok(()),
                Some(_) => Err(api_error("pause sandbox", status, &bytes)),
                None => Err(Error::NotFound(id.clone())),
            };
        }
        Err(api_error("pause sandbox", status, &bytes))
    }

    async fn resume(&self, id: &SandboxId) -> Result<SandboxInfo> {
        self.connect(id, Some(-1)).await?;
        let detail = self
            .detail(id)
            .await?
            .ok_or_else(|| Error::NotFound(id.clone()))?;
        let mut info = self.info(detail);
        info.state = SandboxState::Running;
        Ok(info)
    }

    async fn snapshot(&self, id: &SandboxId) -> Result<SnapshotId> {
        let (status, bytes) = self
            .call(
                self.api(Method::POST, &format!("/sandboxes/{}/snapshots", id.0))
                    .json(&json!({})),
            )
            .await?;
        if status == StatusCode::NOT_FOUND {
            return Err(Error::NotFound(id.clone()));
        }
        if !status.is_success() {
            return Err(api_error("snapshot sandbox", status, &bytes));
        }
        let s: SnapshotCreated = parse("snapshot sandbox", &bytes)?;
        Ok(SnapshotId(s.snapshot_id))
    }

    async fn restore(&self, snapshot: &SnapshotId, spec: CreateSpec) -> Result<SandboxInfo> {
        // 快照 id 可以直接当模板用来建沙箱。
        self.create_from(&snapshot.0, spec, Error::SnapshotNotFound(snapshot.clone()))
            .await
    }

    async fn destroy(&self, id: &SandboxId) -> Result<()> {
        self.forget(&id.0);
        let mut attempt = 0;
        loop {
            let resp = self
                .api(Method::DELETE, &format!("/sandboxes/{}", id.0))
                .send()
                .await
                .map_err(provider_err)?;
            let status = resp.status();
            let retry_after = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok());
            let bytes = resp.bytes().await.map_err(provider_err)?;
            if status.is_success() || status == StatusCode::NOT_FOUND {
                return Ok(());
            }
            // 正在暂停或别的生命周期操作占着锁：按 Retry-After 再试。
            if (status == StatusCode::SERVICE_UNAVAILABLE || status == StatusCode::CONFLICT)
                && attempt < LIFECYCLE_RETRIES
            {
                attempt += 1;
                let wait = retry_after
                    .map(|s| Duration::from_secs(s.clamp(1, 10)))
                    .unwrap_or(LIFECYCLE_RETRY_DELAY);
                tokio::time::sleep(wait).await;
                continue;
            }
            return Err(api_error("delete sandbox", status, &bytes));
        }
    }

    async fn delete_workspace(&self, workspace: &str) -> Result<()> {
        if !self.cfg.use_volumes {
            return Ok(());
        }
        check_volume_name(workspace)?;
        let Some(volume) = self.find_volume(workspace).await? else {
            return Ok(());
        };
        let (status, bytes) = self
            .call(self.api(Method::DELETE, &format!("/volumes/{volume}")))
            .await?;
        self.volume_ids().remove(workspace);
        if status.is_success() || status == StatusCode::NOT_FOUND {
            return Ok(());
        }
        Err(api_error("delete volume", status, &bytes))
    }

    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> Result<()> {
        check_relative_path(path)?;
        let envd = self.envd(self.running_conn(id).await?);
        let full = self.abs(path);
        if let Some((parent, _)) = full.rsplit_once('/')
            && !parent.is_empty()
        {
            // 先建上级目录。已经存在时 envd 报错，忽略；真有问题下面写文件时会报出来。
            let _ = envd
                .unary("filesystem.Filesystem/MakeDir", &json!({ "path": parent }))
                .await;
        }
        let target = format!(
            "/files?path={}&username={}",
            query_escape(&full),
            query_escape(&self.cfg.user)
        );
        let resp = envd
            .request(Method::POST, &target)
            .header(CONTENT_TYPE, "application/octet-stream")
            .timeout(FILE_TIMEOUT)
            .body(data.to_vec())
            .send()
            .await
            .map_err(provider_err)?;
        let mut status = resp.status();
        let mut bytes = resp.bytes().await.unwrap_or_default();
        if status == StatusCode::BAD_REQUEST || status == StatusCode::UNSUPPORTED_MEDIA_TYPE {
            // 老版本 envd 只收 multipart。
            let boundary = random_boundary();
            let filename = full.rsplit('/').next().unwrap_or("file");
            let resp = envd
                .request(Method::POST, &target)
                .header(
                    CONTENT_TYPE,
                    format!("multipart/form-data; boundary={boundary}"),
                )
                .timeout(FILE_TIMEOUT)
                .body(multipart(&boundary, filename, data))
                .send()
                .await
                .map_err(provider_err)?;
            status = resp.status();
            bytes = resp.bytes().await.unwrap_or_default();
        }
        if status.is_success() {
            return Ok(());
        }
        Err(api_error("write file", status, &bytes))
    }

    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> Result<Vec<u8>> {
        check_relative_path(path)?;
        let envd = self.envd(self.running_conn(id).await?);
        let full = self.abs(path);
        let target = format!(
            "/files?path={}&username={}",
            query_escape(&full),
            query_escape(&self.cfg.user)
        );
        let mut resp = envd
            .request(Method::GET, &target)
            .timeout(FILE_TIMEOUT)
            .send()
            .await
            .map_err(provider_err)?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Err(Error::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("{path} not found in sandbox {id}"),
            )));
        }
        if !status.is_success() {
            let bytes = resp.bytes().await.unwrap_or_default();
            return Err(api_error("read file", status, &bytes));
        }
        let too_large = || Error::Invalid(format!("{path:?} is larger than {max} bytes"));
        if resp.content_length().is_some_and(|n| n > max) {
            return Err(too_large());
        }
        let mut out = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(provider_err)? {
            if (out.len() + chunk.len()) as u64 > max {
                return Err(too_large());
            }
            out.extend_from_slice(&chunk);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allow_targets_drop_the_port() {
        assert_eq!(allow_host("gw.internal:8790"), "gw.internal");
        assert_eq!(allow_host("10.1.2.3:443"), "10.1.2.3");
        assert_eq!(allow_host("10.1.2.3"), "10.1.2.3");
        assert_eq!(allow_host("*.example.com"), "*.example.com");
        assert_eq!(allow_host("[2001:db8::1]:443"), "2001:db8::1");
        assert_eq!(allow_host("10.0.0.0/8"), "10.0.0.0/8");
    }

    #[test]
    fn exit_statuses() {
        let end = |code: Option<i32>, exited: bool, status: &str| EndEvent {
            exit_code: code,
            exited,
            status: Some(status.to_owned()),
            error: None,
        };
        assert_eq!(
            exit_status(&end(Some(3), true, "exit status 3")).code(),
            Some(3)
        );
        // 退出码 0 时 JSON 里没有 exitCode。
        assert_eq!(
            exit_status(&end(None, true, "exit status 0")).code(),
            Some(0)
        );
        assert_eq!(exit_status(&end(None, true, "exited")).code(), Some(0));
        assert_eq!(
            exit_status(&end(Some(-1), false, "signal: killed")).signal(),
            Some(libc::SIGKILL)
        );
        assert_eq!(
            exit_status(&end(Some(-1), false, "signal: terminated")).signal(),
            Some(libc::SIGTERM)
        );
        let failed = EndEvent {
            error: Some("boom".into()),
            ..EndEvent::default()
        };
        assert_eq!(exit_status(&failed).code(), Some(1));
    }

    #[test]
    fn query_values_are_escaped() {
        assert_eq!(
            query_escape("/sandbox/workspace/a b&c.txt"),
            "/sandbox/workspace/a%20b%26c.txt"
        );
        assert_eq!(query_escape("文"), "%E6%96%87");
    }

    #[test]
    fn multipart_body_quotes_the_filename() {
        let body = multipart("b", "a\"b.txt", b"hi");
        let text = String::from_utf8(body).unwrap();
        assert!(text.contains("filename=\"a_b.txt\""), "{text}");
        assert!(text.ends_with("\r\n\r\nhi\r\n--b--\r\n"), "{text:?}");
    }

    #[test]
    fn workspace_names_follow_cube_rules() {
        assert!(check_volume_name("ws-0123abcd").is_ok());
        for bad in ["", "ws.1", "ws/1", "../x"] {
            assert!(check_volume_name(bad).is_err(), "{bad}");
        }
    }
}
