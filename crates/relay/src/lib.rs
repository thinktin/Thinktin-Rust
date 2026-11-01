//! 设备中继（WBS 14.1）：用户的电脑（macOS App 里的守护进程）主动连出到这里、保持 wss 长连接，
//! 不用在电脑上开入站端口。平台经它用电脑上的工具（`orchestrator::computer` 写调用，这里转给电脑、回填结果），
//! 手机和电脑之间的配对、审批、能力令牌消息也经它投递（收件方不在线时排队）。连接协议见 [`proto::relay`]。
//!
//! 和控制面分开部署（维持大量长连接，扩容方式不同），可以多副本：一台电脑同时只连一个副本，
//! 在线状态和要转给它的东西都在数据库里，副本之间不直接通信——平台写库并发通知，
//! 连着那台电脑的副本收到通知去库里取。副本挂了，它连着的电脑重连到别的副本；
//! 它留下的在线状态没人刷新，过 [`store::LINK_FRESH`] 就算离线。
//!
//! TLS 在负载均衡上终结，这里只说 HTTP / WebSocket。

mod conn;
mod hub;
mod listen;

use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use auth::access_token::AccessTokenVerifier;
use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::extract::ws::WebSocketUpgrade;
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use proto::api::{ErrorBody, ErrorCode};
use proto::domain::{DeviceId, SessionId, UserId, UserStatus};
use proto::relay::MAX_FRAME_BYTES;
use store::Db;
use tokio::net::TcpListener;
use tokio::sync::{Semaphore, watch};
use tracing::{info, warn};

pub use hub::DeviceHub;

#[derive(Debug, Clone)]
pub struct RelayConfig {
    /// 这个副本的名字：记进电脑的在线状态，排查用。
    pub node: String,
    /// 心跳间隔：每隔这么久 ping 电脑、刷新在线状态、核对会话；三个周期没收到电脑的任何帧就断开。
    /// 要明显短于 [`store::LINK_FRESH`]（平台据它判断电脑在不在线）。
    pub heartbeat: Duration,
    /// 同时保持的电脑连接数上限。
    pub max_connections: usize,
    /// 读完 HTTP 请求头的时限。
    pub header_read_timeout: Duration,
    /// 停机时等连接收尾（关连接、去掉在线状态）最多多久。
    pub grace: Duration,
}

impl Default for RelayConfig {
    fn default() -> Self {
        Self {
            node: "relay-1".into(),
            heartbeat: Duration::from_secs(20),
            max_connections: 50_000,
            header_read_timeout: Duration::from_secs(10),
            grace: Duration::from_secs(10),
        }
    }
}

/// 核对过的电脑。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Computer {
    pub user: UserId,
    pub device: DeviceId,
    pub session: SessionId,
    /// 访问令牌什么时候过期（Unix 秒）。
    pub token_exp: u64,
}

/// 没能通过核对的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AuthFail {
    /// 令牌不对或过期：刷新令牌后重连。
    Unauthenticated,
    /// 会话被吊销、设备被下线、账号注销：回到登录页。
    SessionRevoked,
    /// 账号被冻结（4.6）。
    Frozen,
    /// 不是电脑：只有 macOS、Windows 设备能连中继。
    NotComputer,
    /// 数据库暂时不可用。
    Unavailable,
}

impl AuthFail {
    fn code(self) -> ErrorCode {
        match self {
            Self::Unauthenticated => ErrorCode::Unauthenticated,
            Self::SessionRevoked => ErrorCode::SessionRevoked,
            Self::Frozen => ErrorCode::AccountFrozen,
            Self::NotComputer => ErrorCode::Forbidden,
            Self::Unavailable => ErrorCode::Unavailable,
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::Unauthenticated => "unauthenticated",
            Self::SessionRevoked => "session revoked",
            Self::Frozen => "account frozen",
            Self::NotComputer => "only computers connect to the relay",
            Self::Unavailable => "temporarily unavailable",
        }
    }
}

impl IntoResponse for AuthFail {
    fn into_response(self) -> Response {
        refuse(self.code(), self.message())
    }
}

fn refuse(code: ErrorCode, message: &str) -> Response {
    let status =
        StatusCode::from_u16(code.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(ErrorBody::new(code, message))).into_response()
}

pub(crate) fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

pub struct Relay {
    db: Db,
    verifier: AccessTokenVerifier,
    cfg: RelayConfig,
    hub: DeviceHub,
    /// 电脑连接的名额。
    slots: Arc<Semaphore>,
    stopping: watch::Sender<bool>,
    /// 每个电脑连接持有一份：只剩这一份时连接都收尾了。
    live: Arc<()>,
}

impl Relay {
    /// `verifier` 里放控制面签访问令牌用的公钥（轮换时新旧都放）。
    pub fn new(db: Db, verifier: AccessTokenVerifier, cfg: RelayConfig) -> Arc<Self> {
        let (stopping, _) = watch::channel(false);
        Arc::new(Self {
            slots: Arc::new(Semaphore::new(cfg.max_connections)),
            db,
            verifier,
            cfg,
            hub: DeviceHub::default(),
            stopping,
            live: Arc::new(()),
        })
    }

    pub fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route("/v1/connect", get(connect))
            .route("/healthz", get(|| async { "ok" }))
            .route("/readyz", get(ready))
            .with_state(self.clone())
    }

    /// 现在连着的电脑数。
    pub fn connections(&self) -> usize {
        Arc::strong_count(&self.live) - 1
    }

    /// 一直运行到 `stop`：监听库里的通知、接受电脑的连接；之后让电脑都重连到别的副本。
    pub async fn serve(
        self: Arc<Self>,
        listener: TcpListener,
        stop: impl Future<Output = ()>,
    ) -> anyhow::Result<()> {
        let mut hub_stop = self.stopping.subscribe();
        let hub = tokio::spawn(self.hub.clone().listen(self.db.pool().clone(), async move {
            let _ = hub_stop.wait_for(|s| *s).await;
        }));
        info!(addr = %listener.local_addr()?, node = %self.cfg.node, "relay listening");
        listen::serve(listener, self.router(), self.cfg.header_read_timeout, stop).await?;
        self.shutdown().await;
        let _ = hub.await;
        info!("relay stopped");
        Ok(())
    }

    /// 停机：所有电脑连接以 1012 关闭（电脑马上重连，会连到别的副本）、去掉在线状态，最多等 `grace`。
    pub async fn shutdown(&self) {
        self.stopping.send_replace(true);
        let deadline = Instant::now() + self.cfg.grace;
        while self.connections() > 0 && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        if self.connections() > 0 {
            warn!(
                connections = self.connections(),
                "computer connections still open after the grace period"
            );
        }
    }

    /// 核对访问令牌：验签、有效期，再查会话、账号、设备。
    pub(crate) async fn authenticate(&self, token: &str) -> Result<Computer, AuthFail> {
        let claims = self
            .verifier
            .verify(token, unix_now())
            .map_err(|_| AuthFail::Unauthenticated)?;
        fn parse<T: std::str::FromStr>(s: &str) -> Result<T, AuthFail> {
            s.parse().map_err(|_| AuthFail::Unauthenticated)
        }
        let who = Computer {
            user: parse(&claims.uid)?,
            device: parse(&claims.did)?,
            session: parse(&claims.sid)?,
            token_exp: claims.exp,
        };
        self.check(&who).await?;
        Ok(who)
    }

    /// 会话还有效、账号可用、设备是这个用户没下线的电脑。
    pub(crate) async fn check(&self, who: &Computer) -> Result<(), AuthFail> {
        let lookup = async {
            let mut r = self.db.relay().await?;
            let state = r.session_state(who.session).await?;
            let platform = r.device_platform(who.device).await?;
            r.rollback().await?;
            Ok::<_, store::Error>((state, platform))
        };
        let (state, platform) = lookup.await.map_err(|e| {
            warn!(error = %e, "cannot check a device session");
            AuthFail::Unavailable
        })?;
        let Some(state) = state else {
            return Err(AuthFail::Unauthenticated);
        };
        if state.user_id != who.user || state.device_id != who.device {
            return Err(AuthFail::Unauthenticated);
        }
        match state.user_status {
            UserStatus::Frozen => return Err(AuthFail::Frozen),
            UserStatus::Deleted => return Err(AuthFail::SessionRevoked),
            UserStatus::Active => {}
        }
        if !state.live {
            return Err(AuthFail::SessionRevoked);
        }
        match platform {
            Some((owner, platform, false)) if owner == who.user && platform.is_computer() => Ok(()),
            Some((_, _, true)) => Err(AuthFail::SessionRevoked),
            _ => Err(AuthFail::NotComputer),
        }
    }
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

/// `GET /v1/connect`：电脑带着访问令牌升级成 WebSocket。
async fn connect(
    State(relay): State<Arc<Relay>>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    if *relay.stopping.borrow() {
        return refuse(ErrorCode::Unavailable, "the relay is restarting");
    }
    let Some(token) = bearer(&headers) else {
        return refuse(ErrorCode::Unauthenticated, "missing bearer token");
    };
    let who = match relay.authenticate(token).await {
        Ok(who) => who,
        Err(fail) => return fail.into_response(),
    };
    let Ok(slot) = relay.slots.clone().try_acquire_owned() else {
        warn!("computer connection limit reached");
        return refuse(ErrorCode::Unavailable, "too many connections");
    };
    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| async move {
            let _slot = slot;
            conn::run(relay, who, socket).await;
        })
}

/// 就绪检查：停机中或者数据库不通时 503，负载均衡据此摘掉这个副本。
async fn ready(State(relay): State<Arc<Relay>>) -> Response {
    if *relay.stopping.borrow() {
        return (StatusCode::SERVICE_UNAVAILABLE, "stopping").into_response();
    }
    match tokio::time::timeout(Duration::from_secs(2), relay.db.ping()).await {
        Ok(Ok(())) => (StatusCode::OK, "ready").into_response(),
        _ => (StatusCode::SERVICE_UNAVAILABLE, "database unavailable").into_response(),
    }
}
