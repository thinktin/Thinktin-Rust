//! 电脑端的工具服务（WBS 14.2）：跑在用户的电脑上（macOS App 的后台进程里），主动连设备中继，
//! 收平台转来的“我的电脑”工具调用（`proto::computer`），按手机给的权限把关后执行、回结果，
//! 每个调用记本地审计日志。手机经平台发来的能力令牌、吊销和审批决定也从中继收。
//!
//! - **普通操作**（看目录、读写文件、截图、键鼠、打开网页和应用）：要有手机签发、验过签、没过期没吊销的
//!   能力令牌覆盖（[`policy`]）。
//! - **高危操作**（删除、执行命令）：每次都给配对的手机发审批请求，等用户在手机上用私钥签名批准，
//!   电脑本地验签通过才做；拒绝、超时、签名不对都不做（架构方案 4.7、7）。
//! - 工具本身由 [`ToolBackend`] 实现：文件和命令用 [`files::FileTools`]，截图、键鼠、打开应用由 App 用系统接口实现。
//!
//! 连接协议见 `proto::relay`，消息正文见 `client_core::pairing`，部署和路由见 docs/relay.md。

pub mod audit;
pub mod files;
pub mod pairing;
pub mod policy;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use client_core::pairing::{
    ApprovalDecisionBody, ApprovalRequest, ApprovalRequestBody, CapabilityBody, CapabilityGrant,
    MAX_OFFER_TTL_SECS, PairConfirmBody, PairResponseBody, PairingOffer, RevocationBody,
    approval_message, arguments_digest, decode_signature, encode_public_key, encode_signature,
    pairing_confirmation_message, pairing_offer_uri, verify_approval, verify_capability,
    verify_pairing_response,
};
use futures_util::{SinkExt, StreamExt};
use proto::domain::{DeviceCallId, DeviceId, DeviceMessage, DeviceMessageKind, RunId};
use proto::relay::{ComputerFrame, RelayFrame, close};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tracing::{debug, info, warn};

use crate::audit::{Audit, Decision, Entry};
use crate::policy::{Need, State};

pub use pairing::{PairingKey, PairingStatus, SoftwareKey};
pub use policy::PairedPhone;

/// 工具的结果：MCP 的 content 数组；工具自己出错时 `is_error` 为真。
#[derive(Debug, Clone, PartialEq)]
pub struct ToolResult {
    pub content: Vec<Value>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![json!({ "type": "text", "text": text.into() })],
            is_error: false,
        }
    }

    pub fn error(text: impl Into<String>) -> Self {
        Self {
            content: vec![json!({ "type": "text", "text": text.into() })],
            is_error: true,
        }
    }
}

/// 工具的实现。权限在调用之前已经核对过。
#[async_trait]
pub trait ToolBackend: Send + Sync {
    /// 现在能用的工具（`computer_*` 的全名），随系统权限变化；连上中继时报给平台。
    fn available(&self) -> Vec<String>;
    /// 前台应用的 bundle id：键鼠操作只能对着手机授权过的应用。
    fn frontmost_app(&self) -> Option<String> {
        None
    }
    async fn call(&self, tool: &str, arguments: &Value) -> ToolResult;
}

/// 这台电脑的访问令牌（设备会话），由 App 用 client-core 管：保存、刷新。
#[async_trait]
pub trait TokenSource: Send + Sync {
    /// 现在的访问令牌；`refresh` 为真时先用刷新令牌换一个新的（快过期了、被中继以 4001 关了）。
    async fn access_token(&self, refresh: bool) -> Result<String, String>;
}

#[derive(Debug, Clone)]
pub struct DesktopConfig {
    /// 设备中继，比如 `wss://relay.example.com/v1/connect`。
    pub relay_url: String,
    /// 这台电脑的设备 id（登录时拿到的）：能力令牌、审批请求里的电脑 id。
    pub desktop_id: String,
    pub app_version: String,
    /// 本地状态（配对的手机、能力令牌、吊销列表）。
    pub state_path: PathBuf,
    /// 本地审计日志（JSON Lines）。
    pub audit_path: PathBuf,
    /// 高危操作等手机批准最多多久（还受平台给的调用期限约束）。
    pub approval_ttl: Duration,
    /// 多久换一次访问令牌（令牌 15 分钟过期）。
    pub token_refresh_every: Duration,
    /// 断线重连的退避上限。
    pub max_backoff: Duration,
}

impl DesktopConfig {
    /// 状态和审计日志放在 `data_dir` 下，其余用默认值。
    pub fn new(
        relay_url: impl Into<String>,
        desktop_id: impl Into<String>,
        data_dir: &Path,
    ) -> Self {
        Self {
            relay_url: relay_url.into(),
            desktop_id: desktop_id.into(),
            app_version: String::new(),
            state_path: data_dir.join("desktop-state.json"),
            audit_path: data_dir.join("audit.jsonl"),
            approval_ttl: Duration::from_secs(10 * 60),
            token_refresh_every: Duration::from_secs(10 * 60),
            max_backoff: Duration::from_secs(60),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DesktopError {
    /// 中继拒绝了连接（403：账号被冻结，或者这台设备不是电脑）。
    #[error("the relay refused this computer ({0})")]
    Refused(String),
    /// 这台电脑在别处又连了一次（开了两个 App？）：这边停下，不互相顶。
    #[error("this computer connected again from elsewhere")]
    Replaced,
    #[error("local state: {0}")]
    State(String),
    /// 出不了配对二维码（电脑的密钥不对、设备 id 不对）。
    #[error("pairing: {0}")]
    Pairing(String),
}

/// 连接状态（给 App 显示“正在被控制”的提示用）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Offline,
    Connecting,
    Connected,
}

/// 一次连接为什么结束。
#[derive(Debug)]
enum SessionEnd {
    Stopped,
    Closed(Option<u16>),
    Refused(u16),
    Failed(String),
}

/// 等手机批准的高危操作：请求和回信的通道。
type Pending = HashMap<String, (ApprovalRequest, oneshot::Sender<(bool, Vec<u8>)>)>;

/// 正在显示的配对邀请和签确认用的密钥。
struct Offer {
    offer: PairingOffer,
    key: Arc<dyn PairingKey>,
}

struct Inner {
    cfg: DesktopConfig,
    tokens: Arc<dyn TokenSource>,
    backend: Arc<dyn ToolBackend>,
    audit: Audit,
    state: Mutex<State>,
    pending: Mutex<Pending>,
    offer: Mutex<Option<Offer>>,
    pairing: watch::Sender<PairingStatus>,
    status: watch::Sender<Status>,
    stop: watch::Sender<bool>,
}

/// 电脑端的工具服务。[`Desktop::run`] 一直连着中继（断了按退避重连），直到 [`Desktop::stop`]。
#[derive(Clone)]
pub struct Desktop {
    inner: Arc<Inner>,
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

/// 等 `stop` 变成真。不把 `watch::Ref` 带出来（它不能跨线程）。
async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|s| *s).await;
}

impl Desktop {
    pub fn new(
        cfg: DesktopConfig,
        tokens: Arc<dyn TokenSource>,
        backend: Arc<dyn ToolBackend>,
    ) -> Result<Self, DesktopError> {
        let state = match std::fs::read(&cfg.state_path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| DesktopError::State(format!("{}: {e}", cfg.state_path.display())))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => State::default(),
            Err(e) => {
                return Err(DesktopError::State(format!(
                    "{}: {e}",
                    cfg.state_path.display()
                )));
            }
        };
        let audit = Audit::open(&cfg.audit_path)
            .map_err(|e| DesktopError::State(format!("{}: {e}", cfg.audit_path.display())))?;
        Ok(Self {
            inner: Arc::new(Inner {
                cfg,
                tokens,
                backend,
                audit,
                state: Mutex::new(state),
                pending: Mutex::new(HashMap::new()),
                offer: Mutex::new(None),
                pairing: watch::channel(PairingStatus::Idle).0,
                status: watch::channel(Status::Offline).0,
                stop: watch::channel(false).0,
            }),
        })
    }

    /// 配对完成（App 用 client-core 的配对流程验过手机的签名）：记下手机，审批请求发给它，
    /// 能力令牌和审批决定用它的公钥验。换了手机，之前的令牌作废。
    pub fn pair(&self, phone: PairedPhone) -> Result<(), DesktopError> {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        if st.phone.as_ref() != Some(&phone) {
            st.grants.clear();
        }
        st.phone = Some(phone);
        self.inner.save(&st)
    }

    /// 开始配对（App 的“配对手机”）：出一个新的邀请，返回二维码的内容（`thinktin-pair:v1?…`）。邀请 [`ttl`](Duration)
    /// 后过期（最长 10 分钟）；之前的邀请作废。手机扫码回复后，这边验签、用 `key` 签确认发回，记下手机
    /// （[`Desktop::watch_pairing`] 变成 [`PairingStatus::Paired`]）。要连着中继才收得到回复。
    pub fn start_pairing(
        &self,
        key: Arc<dyn PairingKey>,
        ttl: Duration,
    ) -> Result<String, DesktopError> {
        let inner = &self.inner;
        let mut nonce = [0u8; 32];
        getrandom::fill(&mut nonce).map_err(|e| DesktopError::Pairing(e.to_string()))?;
        let desktop_key = encode_public_key(key.public_key())
            .map_err(|e| DesktopError::Pairing(e.to_string()))?;
        let expires_at = unix_now() + ttl.as_secs().clamp(1, MAX_OFFER_TTL_SECS);
        let offer = PairingOffer {
            desktop_id: inner.cfg.desktop_id.clone(),
            desktop_key,
            nonce: encode_signature(&nonce),
            expires_at,
        };
        let uri =
            pairing_offer_uri(offer.clone()).map_err(|e| DesktopError::Pairing(e.to_string()))?;
        *inner.offer.lock().unwrap_or_else(|e| e.into_inner()) = Some(Offer { offer, key });
        inner.pairing.send_replace(PairingStatus::Waiting {
            uri: uri.clone(),
            expires_at,
        });
        info!("showing a pairing code");
        Ok(uri)
    }

    /// 不配了（关掉二维码）：邀请作废。
    pub fn cancel_pairing(&self) {
        self.inner
            .offer
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        self.inner.pairing.send_replace(PairingStatus::Idle);
    }

    /// 配对进行到哪了（App 的配对界面跟着它变）。
    pub fn watch_pairing(&self) -> watch::Receiver<PairingStatus> {
        self.inner.pairing.subscribe()
    }

    /// 配对的手机（没配对时为 `None`）。
    pub fn paired_phone(&self) -> Option<PairedPhone> {
        let st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        st.phone.clone()
    }

    /// 解除配对：之后普通操作、高危操作都不做。
    pub fn unpair(&self) -> Result<(), DesktopError> {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        st.phone = None;
        st.grants.clear();
        self.inner.save(&st)
    }

    /// 现在有效的能力令牌（给 App 显示）。
    pub fn grants(&self) -> Vec<CapabilityGrant> {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        st.valid(unix_now())
    }

    pub fn status(&self) -> Status {
        *self.inner.status.borrow()
    }

    /// 状态变化（App 显示“正在被控制”、断线提示）。
    pub fn watch_status(&self) -> watch::Receiver<Status> {
        self.inner.status.subscribe()
    }

    /// 让 [`Desktop::run`] 断开连接、返回。
    pub fn stop(&self) {
        self.inner.stop.send_replace(true);
    }

    /// 连着中继，断了按退避重连，直到 [`Desktop::stop`]。账号被冻结、这台电脑在别处又连了一次时
    /// 返回错误（App 提示用户，不要自动重启）。
    pub async fn run(&self) -> Result<(), DesktopError> {
        client_core::install_crypto();
        let inner = &self.inner;
        let mut stop = inner.stop.subscribe();
        let mut backoff = Duration::from_secs(1);
        let mut refresh = false;
        loop {
            if *stop.borrow() {
                break;
            }
            inner.status.send_replace(Status::Connecting);
            let end = match inner.tokens.access_token(refresh).await {
                Ok(token) => {
                    refresh = false;
                    let started = Instant::now();
                    let end = self.session(&token, &mut stop).await;
                    if started.elapsed() > Duration::from_secs(60) {
                        backoff = Duration::from_secs(1);
                    }
                    end
                }
                Err(e) => SessionEnd::Failed(format!("no access token: {e}")),
            };
            inner.status.send_replace(Status::Offline);
            match end {
                SessionEnd::Stopped => break,
                SessionEnd::Closed(Some(close::UNAUTHENTICATED)) | SessionEnd::Refused(401) => {
                    info!("the relay wants a fresh access token");
                    refresh = true;
                }
                SessionEnd::Closed(Some(close::ACCOUNT_FROZEN)) => {
                    return Err(DesktopError::Refused("account frozen".into()));
                }
                SessionEnd::Refused(403) => {
                    return Err(DesktopError::Refused(
                        "account frozen or not a computer".into(),
                    ));
                }
                SessionEnd::Closed(Some(close::REPLACED)) => return Err(DesktopError::Replaced),
                SessionEnd::Failed(reason) => warn!(%reason, "the relay connection failed"),
                other => debug!(?other, "relay connection ended"),
            }
            tokio::select! {
                () = stopped(&mut stop) => break,
                () = tokio::time::sleep(backoff) => {}
            }
            backoff = (backoff * 2).min(inner.cfg.max_backoff);
        }
        inner.status.send_replace(Status::Offline);
        Ok(())
    }

    /// 一次连接：从握手到断开。
    async fn session(&self, token: &str, stop: &mut watch::Receiver<bool>) -> SessionEnd {
        let inner = &self.inner;
        let mut req = match inner.cfg.relay_url.as_str().into_client_request() {
            Ok(r) => r,
            Err(e) => return SessionEnd::Failed(e.to_string()),
        };
        match format!("Bearer {token}").parse() {
            Ok(v) => {
                req.headers_mut().insert("authorization", v);
            }
            Err(_) => return SessionEnd::Failed("the access token is not a valid header".into()),
        }
        let ws = match tokio_tungstenite::connect_async(req).await {
            Ok((ws, _)) => ws,
            Err(tungstenite::Error::Http(resp)) => {
                return SessionEnd::Refused(resp.status().as_u16());
            }
            Err(e) => return SessionEnd::Failed(e.to_string()),
        };
        let (mut sink, mut stream) = ws.split();
        let (out, mut outgoing) = mpsc::unbounded_channel::<ComputerFrame>();
        // 中继说心跳间隔之前，先按一分钟算。
        let mut heartbeat = Duration::from_secs(60);
        let mut last_heard = Instant::now();
        let mut refresh = tokio::time::interval(inner.cfg.token_refresh_every);
        refresh.tick().await;
        let mut watchdog = tokio::time::interval(Duration::from_secs(5));
        loop {
            tokio::select! {
                () = stopped(stop) => {
                    let _ = sink.send(tungstenite::Message::Close(None)).await;
                    return SessionEnd::Stopped;
                }
                msg = stream.next() => {
                    last_heard = Instant::now();
                    match msg {
                        Some(Ok(tungstenite::Message::Text(text))) => {
                            match serde_json::from_str::<RelayFrame>(&text) {
                                Ok(frame) => self.on_frame(frame, &out, &mut heartbeat),
                                Err(e) => warn!(error = %e, "an unknown frame from the relay"),
                            }
                        }
                        Some(Ok(tungstenite::Message::Close(frame))) => {
                            return SessionEnd::Closed(frame.map(|f| u16::from(f.code)));
                        }
                        Some(Ok(_)) => {}
                        Some(Err(e)) => return SessionEnd::Failed(e.to_string()),
                        None => return SessionEnd::Closed(None),
                    }
                }
                Some(frame) = outgoing.recv() => {
                    let Ok(text) = serde_json::to_string(&frame) else { continue };
                    if let Err(e) = sink.send(tungstenite::Message::Text(text.into())).await {
                        return SessionEnd::Failed(e.to_string());
                    }
                }
                _ = refresh.tick() => {
                    // 访问令牌 15 分钟过期：提前换新的告诉中继，连接不断。
                    match inner.tokens.access_token(true).await {
                        Ok(token) => {
                            let _ = out.send(ComputerFrame::Auth { token });
                        }
                        Err(e) => warn!(error = %e, "cannot refresh the access token"),
                    }
                }
                _ = watchdog.tick() => {
                    if last_heard.elapsed() > heartbeat * 3 {
                        return SessionEnd::Failed("the relay went quiet".into());
                    }
                }
            }
        }
    }

    fn on_frame(
        &self,
        frame: RelayFrame,
        out: &mpsc::UnboundedSender<ComputerFrame>,
        heartbeat: &mut Duration,
    ) {
        let inner = &self.inner;
        match frame {
            RelayFrame::Welcome {
                device,
                heartbeat_secs,
            } => {
                *heartbeat = Duration::from_secs(heartbeat_secs.max(1));
                if device.to_string() != inner.cfg.desktop_id {
                    warn!(%device, configured = %inner.cfg.desktop_id, "the relay knows this computer by another id");
                }
                inner.status.send_replace(Status::Connected);
                info!("connected to the relay");
                let _ = out.send(ComputerFrame::Hello {
                    tools: inner.backend.available(),
                    app_version: inner.cfg.app_version.clone(),
                });
            }
            RelayFrame::Call {
                id,
                tool,
                arguments,
                run,
                expires_at,
            } => {
                let me = self.clone();
                let out = out.clone();
                tokio::spawn(async move {
                    let deadline = expires_at.timestamp().max(0) as u64;
                    let result = me.call(id, &tool, arguments, run, deadline, &out).await;
                    let _ = out.send(ComputerFrame::CallResult {
                        call: id,
                        content: result.content,
                        is_error: result.is_error,
                    });
                });
            }
            RelayFrame::Message { message } => {
                self.on_message(&message, out);
                let _ = out.send(ComputerFrame::Ack {
                    message: message.id,
                });
            }
            RelayFrame::Sent { .. } => {}
            RelayFrame::Error {
                reference,
                code,
                message,
            } => warn!(?reference, %code, %message, "the relay could not handle a frame"),
        }
    }

    /// 一个工具调用：核对权限（或者等手机批准）、执行、记审计日志。
    async fn call(
        &self,
        id: DeviceCallId,
        tool: &str,
        arguments: Value,
        run: Option<RunId>,
        deadline: u64,
        out: &mpsc::UnboundedSender<ComputerFrame>,
    ) -> ToolResult {
        let inner = &self.inner;
        let entry = |decision: Decision, ok: Option<bool>, detail: Option<String>| Entry {
            at: unix_now(),
            call: id.to_string(),
            run: run.map(|r| r.to_string()),
            tool: tool.to_owned(),
            arguments_digest: arguments_digest(arguments.to_string()).unwrap_or_default(),
            decision,
            ok,
            detail,
        };
        let need = match policy::need(tool, &arguments, inner.backend.frontmost_app()) {
            Ok(n) => n,
            Err(msg) => {
                inner
                    .audit
                    .record(&entry(Decision::Denied, None, Some(msg.clone())));
                return ToolResult::error(msg);
            }
        };
        let decision = match need {
            Need::Approval => match self.approve(tool, &arguments, deadline, out).await {
                Ok(()) => Decision::Approved,
                Err(msg) => {
                    inner
                        .audit
                        .record(&entry(Decision::Declined, None, Some(msg.clone())));
                    return ToolResult::error(msg);
                }
            },
            need => {
                let grants = {
                    let mut st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
                    st.valid(unix_now())
                };
                if !policy::allows(&grants, &need) {
                    let msg = policy::denied(&need);
                    inner
                        .audit
                        .record(&entry(Decision::Denied, None, Some(msg.clone())));
                    return ToolResult::error(msg);
                }
                Decision::Allowed
            }
        };
        info!(call = %id, tool, ?decision, "running a tool on this computer");
        let result = inner.backend.call(tool, &arguments).await;
        let detail = result.is_error.then(|| {
            result
                .content
                .first()
                .and_then(|c| c["text"].as_str())
                .unwrap_or_default()
                .to_owned()
        });
        inner
            .audit
            .record(&entry(decision, Some(!result.is_error), detail));
        result
    }

    /// 高危操作：给配对的手机发审批请求，等用户签名批准，本地验签。
    async fn approve(
        &self,
        tool: &str,
        arguments: &Value,
        deadline: u64,
        out: &mpsc::UnboundedSender<ComputerFrame>,
    ) -> Result<(), String> {
        let inner = &self.inner;
        let phone = {
            let st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
            st.phone.clone()
        }
        .ok_or_else(|| {
            "No phone is paired with this computer, so actions that need the user's approval cannot run. \
             Ask the user to pair their phone in the ThinkTin app."
                .to_owned()
        })?;
        let to: DeviceId = phone
            .device_id
            .parse()
            .map_err(|_| "the paired phone has a bad device id".to_owned())?;
        let now = unix_now();
        let ttl = inner
            .cfg
            .approval_ttl
            .as_secs()
            .min(deadline.saturating_sub(now))
            .max(1);
        let request = ApprovalRequest {
            desktop_id: inner.cfg.desktop_id.clone(),
            request_id: uuid::Uuid::now_v7().to_string(),
            tool: tool.to_owned(),
            arguments_json: arguments.to_string(),
            summary: summary(tool, arguments),
            issued_at: now,
            expires_at: now + ttl,
        };
        approval_message(request.clone(), true).map_err(|e| e.to_string())?;
        let (tx, rx) = oneshot::channel();
        inner
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(request.request_id.clone(), (request.clone(), tx));
        let body = serde_json::to_value(ApprovalRequestBody {
            request: request.clone(),
        })
        .unwrap_or_default();
        let _ = out.send(ComputerFrame::Send {
            to,
            kind: DeviceMessageKind::ApprovalRequest,
            body,
            reference: Some(request.request_id.clone()),
        });
        info!(request = %request.request_id, tool, "asked the phone for approval");
        let decided = tokio::time::timeout(Duration::from_secs(ttl), rx).await;
        inner
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&request.request_id);
        let Ok(Ok((approve, signature))) = decided else {
            return Err(
                "The user did not approve this on their phone in time; nothing was done.".into(),
            );
        };
        verify_approval(request, approve, signature, phone.public_key).map_err(|e| {
            warn!(error = %e, "an approval with a bad signature");
            "The approval from the phone could not be verified; nothing was done.".to_owned()
        })?;
        if !approve {
            return Err("The user declined this on their phone; do not try another way.".into());
        }
        Ok(())
    }

    /// 手机发来的消息：配对回复、能力令牌、吊销、审批决定。
    fn on_message(&self, m: &DeviceMessage, out: &mpsc::UnboundedSender<ComputerFrame>) {
        let inner = &self.inner;
        let phone = {
            let st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
            st.phone.clone()
        };
        let from_phone = phone
            .as_ref()
            .is_some_and(|p| p.device_id == m.from_device.to_string());
        match m.kind {
            DeviceMessageKind::PairResponse => self.on_pair_response(m, out),
            DeviceMessageKind::Capability => {
                let (Some(phone), true) = (phone, from_phone) else {
                    warn!(from = %m.from_device, "a capability not from the paired phone was dropped");
                    return;
                };
                let Ok(body) = serde_json::from_value::<CapabilityBody>(m.body.clone()) else {
                    warn!("a malformed capability was dropped");
                    return;
                };
                if body.grant.desktop_id != inner.cfg.desktop_id {
                    warn!("a capability for another computer was dropped");
                    return;
                }
                let checked = decode_signature(&body.signature).and_then(|sig| {
                    verify_capability(body.grant.clone(), sig, phone.public_key.clone())
                });
                if let Err(e) = checked {
                    warn!(error = %e, "a capability with a bad signature was dropped");
                    return;
                }
                let mut st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
                if st.add_grant(body.grant) {
                    if let Err(e) = inner.save(&st) {
                        warn!(error = %e, "cannot save a capability");
                    }
                    info!("got a capability from the phone");
                }
            }
            DeviceMessageKind::Revocation => {
                if !from_phone {
                    warn!(from = %m.from_device, "a revocation not from the paired phone was dropped");
                    return;
                }
                let Ok(body) = serde_json::from_value::<RevocationBody>(m.body.clone()) else {
                    warn!("a malformed revocation was dropped");
                    return;
                };
                let mut st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
                st.revoke(&body.token_id);
                if let Err(e) = inner.save(&st) {
                    warn!(error = %e, "cannot save a revocation");
                }
                info!(token = %body.token_id, "a capability was revoked");
            }
            DeviceMessageKind::ApprovalDecision => {
                let Ok(body) = serde_json::from_value::<ApprovalDecisionBody>(m.body.clone())
                else {
                    warn!("a malformed approval decision was dropped");
                    return;
                };
                let Ok(signature) = decode_signature(&body.signature) else {
                    warn!("an approval decision with a malformed signature was dropped");
                    return;
                };
                let waiting = inner
                    .pending
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&body.request_id);
                match waiting {
                    // 验签在等的那一边做。
                    Some((_, tx)) => {
                        let _ = tx.send((body.approve, signature));
                    }
                    None => {
                        debug!(request = %body.request_id, "a decision for a request nobody waits for")
                    }
                }
            }
            other => debug!(kind = %other, "a message the tool service does not handle"),
        }
    }

    /// 手机扫码后的配对回复：对上正在显示的邀请、验手机的签名，签确认发回，记下手机。
    /// 验不过时邀请作废（一个二维码只认一次回复），要重新出二维码。
    fn on_pair_response(&self, m: &DeviceMessage, out: &mpsc::UnboundedSender<ComputerFrame>) {
        let inner = &self.inner;
        let Ok(body) = serde_json::from_value::<PairResponseBody>(m.body.clone()) else {
            warn!("a malformed pairing response was dropped");
            return;
        };
        let current = {
            let mut offer = inner.offer.lock().unwrap_or_else(|e| e.into_inner());
            match offer.as_ref() {
                Some(o) if o.offer.nonce == body.nonce => offer.take(),
                _ => None,
            }
        };
        let Some(Offer { offer, key }) = current else {
            debug!(from = %m.from_device, "a pairing response for no current pairing code");
            return;
        };
        let phone_id = m.from_device.to_string();
        let fail = |reason: String| {
            warn!(from = %phone_id, %reason, "a pairing response was refused");
            inner.pairing.send_replace(PairingStatus::Failed { reason });
        };
        let verified = decode_signature(&body.signature).and_then(|signature| {
            verify_pairing_response(
                offer.clone(),
                phone_id.clone(),
                body.phone_key.clone(),
                signature,
            )
        });
        if let Err(e) = verified {
            return fail(e.to_string());
        }
        let confirmation =
            match pairing_confirmation_message(offer, phone_id.clone(), body.phone_key.clone()) {
                Ok(message) => key.sign(&message),
                Err(e) => Err(e.to_string()),
            };
        let signature = match confirmation {
            Ok(signature) => signature,
            Err(e) => return fail(format!("cannot sign the confirmation: {e}")),
        };
        if let Err(e) = self.pair(PairedPhone {
            device_id: phone_id.clone(),
            public_key: body.phone_key,
        }) {
            return fail(e.to_string());
        }
        let confirm = serde_json::to_value(PairConfirmBody {
            nonce: body.nonce.clone(),
            signature: encode_signature(&signature),
        })
        .unwrap_or_default();
        let _ = out.send(ComputerFrame::Send {
            to: m.from_device,
            kind: DeviceMessageKind::PairConfirm,
            body: confirm,
            reference: Some(body.nonce),
        });
        info!(phone = %phone_id, "paired with a phone");
        inner
            .pairing
            .send_replace(PairingStatus::Paired { phone_id });
    }
}

impl Inner {
    /// 保存本地状态：先写临时文件再改名，不会留下写了一半的文件。
    fn save(&self, st: &State) -> Result<(), DesktopError> {
        let path = &self.cfg.state_path;
        let bytes =
            serde_json::to_vec_pretty(st).map_err(|e| DesktopError::State(e.to_string()))?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| DesktopError::State(e.to_string()))?;
        }
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, bytes)
            .and_then(|()| std::fs::rename(&tmp, path))
            .map_err(|e| DesktopError::State(format!("{}: {e}", path.display())))
    }
}

/// 审批界面给用户看的说明（签名覆盖它的摘要，手机显示的和电脑要做的对得上）。
fn summary(tool: &str, arguments: &Value) -> String {
    let what = match tool {
        "computer_run" => {
            let cwd = arguments["cwd"]
                .as_str()
                .map(|c| format!(" (in {c})"))
                .unwrap_or_default();
            format!(
                "Run a command on your computer{cwd}: {}",
                arguments["command"].as_str().unwrap_or_default()
            )
        }
        "computer_delete" => format!(
            "Move to the Trash on your computer: {}",
            arguments["path"].as_str().unwrap_or_default()
        ),
        other => format!("{other}: {arguments}"),
    };
    match arguments["reason"].as_str() {
        Some(reason) if !reason.is_empty() => format!("{what}\nWhy: {reason}"),
        _ => what,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summaries_show_what_will_happen() {
        assert_eq!(
            summary(
                "computer_run",
                &json!({ "command": "rm -rf build", "cwd": "/Users/a/app", "reason": "clean" })
            ),
            "Run a command on your computer (in /Users/a/app): rm -rf build\nWhy: clean"
        );
        assert_eq!(
            summary("computer_delete", &json!({ "path": "/Users/a/x.zip" })),
            "Move to the Trash on your computer: /Users/a/x.zip"
        );
    }
}
