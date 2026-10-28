//! 沙箱里 E2B envd（端口 49983）的客户端，Cube 和 ACS 两个后端共用。
//!
//! 进程走 Connect 协议：`process.Process/Start` 流式返回输出，`SendInput` 写标准输入，
//! `CloseStdin` 关标准输入，`SendSignal` 结束进程；文件走 envd 的 `/files`。两个后端只在
//! 请求怎么路由到某个沙箱（[`Route`]）、上传用什么格式（[`Upload`]）上不同。

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;
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

use crate::{Error, ExecSpec, Process, ProcessControl, Result, check_relative_path};

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

/// 数据面请求怎么到达某个沙箱的 envd。
#[derive(Clone, Debug)]
pub(crate) enum Route {
    /// 直接连代理（如 CubeProxy），按 Host 头 `49983-<沙箱 id>.<域名>` 路由。
    HostHeader { proxy_url: String, domain: String },
    /// 按泛域名解析 `<scheme>://49983-<沙箱 id>.<域名>`。
    Wildcard { scheme: String, domain: String },
    /// OpenKruise sandbox-manager 的路径路由：`<base>/kruise/<沙箱 id>/49983/<路径>`。
    KruisePath { base: String },
}

/// `/files` 上传用什么格式。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Upload {
    /// 先发 `application/octet-stream`，envd 报 400 或 415 再改 multipart（老版本只收 multipart）。
    OctetStreamThenMultipart,
    /// 只发 multipart：ACS 镜像里的 envd 收到别的格式报 500，没法据此回退。
    MultipartOnly,
}

/// 到某个沙箱 envd 的客户端（令牌不进日志）。
#[derive(Clone)]
pub(crate) struct Envd {
    pub http: reqwest::Client,
    pub route: Route,
    /// 进程以哪个用户运行（Basic 认证的用户名，也是 `/files` 的 `username`）。
    pub user: String,
    pub sandbox_id: String,
    pub envd_token: Option<String>,
    /// Cube 的流量令牌，ACS 没有。
    pub traffic_token: Option<String>,
    pub upload: Upload,
}

impl Envd {
    fn request(&self, method: Method, path: &str) -> reqwest::RequestBuilder {
        let rb = match &self.route {
            Route::HostHeader { proxy_url, domain } => self
                .http
                .request(method, format!("{}{path}", proxy_url.trim_end_matches('/')))
                .header(HOST, format!("{ENVD_PORT}-{}.{domain}", self.sandbox_id)),
            Route::Wildcard { scheme, domain } => self.http.request(
                method,
                format!("{scheme}://{ENVD_PORT}-{}.{domain}{path}", self.sandbox_id),
            ),
            Route::KruisePath { base } => self.http.request(
                method,
                format!(
                    "{}/kruise/{}/{ENVD_PORT}{path}",
                    base.trim_end_matches('/'),
                    self.sandbox_id
                ),
            ),
        };
        let basic = STANDARD.encode(format!("{}:", self.user));
        let mut rb = rb.header(AUTHORIZATION, format!("Basic {basic}"));
        if let Some(t) = &self.envd_token {
            rb = rb.header("X-Access-Token", t.as_str());
        }
        if let Some(t) = &self.traffic_token {
            rb = rb
                .header("e2b-traffic-access-token", t.as_str())
                .header("cube-traffic-access-token", t.as_str());
        }
        rb
    }

    /// Connect 协议的一元调用（JSON）。
    pub async fn unary(&self, rpc: &str, body: &Value) -> Result<(StatusCode, Bytes)> {
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

    /// 启动 [`start_request`] 做好的进程请求。
    pub async fn start(&self, request: Value) -> Result<Process> {
        let resp = self
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
        tokio::spawn(pump_stdin(self.clone(), pid, stdin_r));
        Ok(Process {
            stdin: Box::new(stdin),
            stdout: Box::new(stdout),
            stderr: Box::new(stderr),
            control: Box::new(EnvdControl {
                envd: self.clone(),
                pid,
                exit: Some(exit_rx),
                status: None,
            }),
        })
    }

    fn files_target(&self, full: &str) -> String {
        format!(
            "/files?path={}&username={}",
            query_escape(full),
            query_escape(&self.user)
        )
    }

    /// 写沙箱里的文件，`full` 是绝对路径。
    pub async fn write(&self, full: &str, data: &[u8]) -> Result<()> {
        if let Some((parent, _)) = full.rsplit_once('/')
            && !parent.is_empty()
        {
            // 先建上级目录。已经存在时 envd 报错，忽略；真有问题下面写文件时会报出来。
            let _ = self
                .unary("filesystem.Filesystem/MakeDir", &json!({ "path": parent }))
                .await;
        }
        let target = self.files_target(full);
        let multipart_upload = || async {
            let boundary = random_boundary();
            let filename = full.rsplit('/').next().unwrap_or("file");
            let resp = self
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
            let status = resp.status();
            Ok::<_, Error>((status, resp.bytes().await.unwrap_or_default()))
        };
        let (status, bytes) = match self.upload {
            Upload::MultipartOnly => multipart_upload().await?,
            Upload::OctetStreamThenMultipart => {
                let resp = self
                    .request(Method::POST, &target)
                    .header(CONTENT_TYPE, "application/octet-stream")
                    .timeout(FILE_TIMEOUT)
                    .body(data.to_vec())
                    .send()
                    .await
                    .map_err(provider_err)?;
                let status = resp.status();
                let bytes = resp.bytes().await.unwrap_or_default();
                if status == StatusCode::BAD_REQUEST || status == StatusCode::UNSUPPORTED_MEDIA_TYPE
                {
                    multipart_upload().await?
                } else {
                    (status, bytes)
                }
            }
        };
        if status.is_success() {
            return Ok(());
        }
        Err(api_error("write file", status, &bytes))
    }

    /// 读沙箱里的文件，`full` 是绝对路径，`shown` 是报错里用的相对路径。
    pub async fn read(&self, full: &str, shown: &str, max: u64) -> Result<Vec<u8>> {
        let mut resp = self
            .request(Method::GET, &self.files_target(full))
            .timeout(FILE_TIMEOUT)
            .send()
            .await
            .map_err(provider_err)?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Err(Error::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("{shown} not found in sandbox {}", self.sandbox_id),
            )));
        }
        if !status.is_success() {
            let bytes = resp.bytes().await.unwrap_or_default();
            return Err(api_error("read file", status, &bytes));
        }
        let too_large = || Error::Invalid(format!("{shown:?} is larger than {max} bytes"));
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

/// 检查 [`ExecSpec`]、拼好 `process.Process/Start` 的请求。`root` 是沙箱里的根目录：
/// 工作目录默认 `<root>/workspace`，HOME 默认 `<root>/home`。
pub(crate) fn start_request(root: &str, spec: &ExecSpec) -> Result<Value> {
    let abs = |rel: &str| format!("{}/{rel}", root.trim_end_matches('/'));
    let (program, args) = spec
        .argv
        .split_first()
        .ok_or_else(|| Error::Invalid("argv is empty".into()))?;
    let cwd = match &spec.cwd {
        Some(rel) => {
            check_relative_path(rel)?;
            abs(rel)
        }
        None => abs("workspace"),
    };
    let mut envs: BTreeMap<String, String> = spec
        .env
        .iter()
        .map(|(k, v)| (k.clone(), v.expose().to_owned()))
        .collect();
    envs.entry("HOME".into()).or_insert_with(|| abs("home"));
    Ok(json!({
        "process": { "cmd": program, "args": args, "envs": envs, "cwd": cwd },
        "stdin": true,
    }))
}

// ---------- E2B 风格接口的通用处理（控制面也用） ----------

#[derive(Deserialize, Default)]
struct ApiErrorBody {
    #[serde(default)]
    message: String,
}

pub(crate) fn provider_err(e: impl std::fmt::Display) -> Error {
    Error::Provider(e.to_string())
}

pub(crate) fn api_error(what: &str, status: StatusCode, body: &[u8]) -> Error {
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

pub(crate) fn parse<T: serde::de::DeserializeOwned>(what: &str, body: &[u8]) -> Result<T> {
    serde_json::from_slice(body).map_err(|e| Error::Provider(format!("{what}: bad response: {e}")))
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

struct EnvdControl {
    envd: Envd,
    pid: u32,
    exit: Option<oneshot::Receiver<Result<ExitStatus>>>,
    status: Option<ExitStatus>,
}

#[async_trait]
impl ProcessControl for EnvdControl {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn envd(route: Route) -> Envd {
        Envd {
            http: reqwest::Client::new(),
            route,
            user: "user".into(),
            sandbox_id: "sbx-1".into(),
            envd_token: Some("tok".into()),
            traffic_token: None,
            upload: Upload::MultipartOnly,
        }
    }

    #[test]
    fn routes() {
        let url = |route: Route| {
            let e = envd(route);
            let req = e
                .request(Method::GET, &e.files_target("/sandbox/a"))
                .build()
                .unwrap();
            let host = req
                .headers()
                .get(HOST)
                .map(|h| h.to_str().unwrap().to_owned());
            (req.url().to_string(), host)
        };
        assert_eq!(
            url(Route::KruisePath {
                base: "http://h/".into()
            }),
            (
                "http://h/kruise/sbx-1/49983/files?path=/sandbox/a&username=user".into(),
                None
            )
        );
        assert_eq!(
            url(Route::Wildcard {
                scheme: "https".into(),
                domain: "cube.app".into()
            })
            .0,
            "https://49983-sbx-1.cube.app/files?path=/sandbox/a&username=user"
        );
        assert_eq!(
            url(Route::HostHeader {
                proxy_url: "http://10.0.0.5/".into(),
                domain: "cube.app".into()
            }),
            (
                "http://10.0.0.5/files?path=/sandbox/a&username=user".into(),
                Some("49983-sbx-1.cube.app".into())
            )
        );
    }

    #[test]
    fn start_requests_default_to_the_workspace() {
        let spec = ExecSpec {
            argv: vec!["sh".into(), "-c".into(), "true".into()],
            ..ExecSpec::default()
        };
        let req = start_request("/sandbox/", &spec).unwrap();
        assert_eq!(req["process"]["cwd"], "/sandbox/workspace");
        assert_eq!(req["process"]["envs"]["HOME"], "/sandbox/home");
        assert_eq!(req["process"]["args"], json!(["-c", "true"]));
        assert!(start_request("/sandbox", &ExecSpec::default()).is_err());
        let escape = ExecSpec {
            cwd: Some("../etc".into()),
            ..spec
        };
        assert!(start_request("/sandbox", &escape).is_err());
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
}
