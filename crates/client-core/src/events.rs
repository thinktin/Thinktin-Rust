//! 事件流（WBS 11.3）：连实例的 WebSocket，带上最后收到的序号续传；断线按指数退避重连；
//! 按序号去重（重连时服务端可能补发已经收到的）；服务端以 4001 关闭（令牌过期、会话失效）时
//! 刷新令牌再连，刷新失败说明已经退出登录，停下来。账号被冻结（4.6：握手被拒、以 4003 关闭、
//! 刷新被拒）也停下来。
//!
//! 收到的事件先写进缓存（推进续传位置），再交给 [`EventSink`]，界面从缓存读也不会漏。

use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{FutureExt, StreamExt};
use proto::api::{API_VERSION, VERSION_HEADER};
use proto::domain::{InstanceEvent, InstanceId};
use serde::Deserialize;
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tracing::{debug, warn};

use crate::api::Api;
use crate::cache::Cache;
use crate::error::ClientError;

/// 服务端会话失效时的关闭码。
const CLOSE_UNAUTHENTICATED: u16 = 4001;
/// 账号被冻结时的关闭码。
const CLOSE_ACCOUNT_FROZEN: u16 = 4003;

/// 连接状态，给界面显示“连接中 / 已连接 / 重连中”。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum StreamStatus {
    Connecting,
    Live,
    /// 断开了，`retry_in_ms` 毫秒后重连。
    Reconnecting {
        retry_in_ms: u64,
    },
    /// 登录失效，事件流停止；回到登录页。
    SignedOut,
    /// 实例不存在或不属于当前用户，事件流停止。
    NotFound,
    /// 账号被冻结（4.6），事件流停止；提示联系客服。
    AccountFrozen,
    /// 这个版本太老了，服务端不再接受（握手或别的请求回了 426），事件流停止；界面进升级页
    /// （`ThinktinClient::upgrade_required()` 也是 true）。
    UpgradeRequired,
    /// 调用方停的。
    Stopped,
}

pub trait EventSink: Send + Sync {
    fn on_event(&self, event: &InstanceEvent);
    /// 续传位置已经过了服务端的保留期：本地的旧事件作废，界面整体重新加载。
    fn on_reset(&self, oldest_seq: u64, latest_seq: Option<u64>);
    fn on_status(&self, status: StreamStatus);
}

#[derive(Debug, Clone)]
pub struct StreamConfig {
    pub min_backoff: Duration,
    pub max_backoff: Duration,
    /// 这么久没收到任何消息（服务端心跳间隔的几倍）就当连接已死，重连。
    pub idle_timeout: Duration,
    pub connect_timeout: Duration,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            min_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(30),
            idle_timeout: Duration::from_secs(80),
            connect_timeout: Duration::from_secs(15),
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Frame {
    Event(InstanceEvent),
    Reset {
        oldest_seq: u64,
        latest_seq: Option<u64>,
    },
}

/// 停止事件流。丢掉句柄也会停。
pub struct StreamHandle {
    stop: watch::Sender<bool>,
}

impl StreamHandle {
    pub fn stop(&self) {
        let _ = self.stop.send(true);
    }
}

impl Drop for StreamHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 在 `rt` 上开始收 `instance` 的事件。`after` 不给就从缓存里的续传位置开始（没有缓存从头）。
pub fn spawn(
    rt: &tokio::runtime::Handle,
    api: Arc<Api>,
    cache: Option<Arc<Cache>>,
    instance: InstanceId,
    after: Option<u64>,
    sink: Arc<dyn EventSink>,
    cfg: StreamConfig,
) -> StreamHandle {
    let (stop, rx) = watch::channel(false);
    rt.spawn(async move {
        // 任务里 panic 了也要给界面一个结束的状态，不然一直显示“连接中”。
        let status = AssertUnwindSafe(run(api, cache, instance, after, sink.clone(), cfg, rx))
            .catch_unwind()
            .await
            .unwrap_or_else(|_| {
                warn!("event stream task panicked");
                StreamStatus::Stopped
            });
        sink.on_status(status);
    });
    StreamHandle { stop }
}

fn ws_url(base: &str, instance: InstanceId, after: u64) -> Result<url::Url, String> {
    let mut url = url::Url::parse(base).map_err(|e| e.to_string())?;
    let scheme = match url.scheme() {
        "https" => "wss",
        "http" => "ws",
        s => return Err(format!("unsupported scheme {s}")),
    };
    url.set_scheme(scheme)
        .map_err(|()| "cannot set scheme".to_string())?;
    url.set_path(&format!(
        "{}/v1/instances/{instance}/events/ws",
        url.path().trim_end_matches('/')
    ));
    url.set_query(Some(&format!("after={after}")));
    Ok(url)
}

/// 一次连接怎么结束的。
enum Ended {
    Stopped,
    /// 令牌过期：刷新后马上重连。
    Unauthenticated,
    NotFound,
    /// 账号被冻结。
    AccountFrozen,
    /// 握手被拒（403），原因要问接口。
    Forbidden,
    /// 这个版本太老了（426）。
    UpgradeRequired,
    /// 网络问题：退避后重连。`progressed` 表示这次连上后收到过消息（退避重新从头算）。
    Dropped {
        progressed: bool,
    },
}

async fn run(
    api: Arc<Api>,
    cache: Option<Arc<Cache>>,
    instance: InstanceId,
    after: Option<u64>,
    sink: Arc<dyn EventSink>,
    cfg: StreamConfig,
    mut stop: watch::Receiver<bool>,
) -> StreamStatus {
    let mut last = match after {
        Some(a) => a,
        None => cache
            .as_ref()
            .and_then(|c| c.cursor(instance).ok().flatten())
            .unwrap_or(0),
    };
    let mut backoff = cfg.min_backoff;
    let mut refreshed_in_a_row = 0;
    loop {
        // 这个版本太老了（别的请求、别的事件流发现的）：不再连。
        if *stop.borrow() {
            return StreamStatus::Stopped;
        }
        if api.upgrade_required() {
            return StreamStatus::UpgradeRequired;
        }
        sink.on_status(StreamStatus::Connecting);
        let ended = connect_once(
            &api,
            cache.as_deref(),
            instance,
            &mut last,
            sink.as_ref(),
            &cfg,
            &mut stop,
        )
        .await;
        match ended {
            Ended::Stopped => return StreamStatus::Stopped,
            Ended::NotFound => return StreamStatus::NotFound,
            Ended::AccountFrozen => return StreamStatus::AccountFrozen,
            Ended::UpgradeRequired => {
                api.mark_upgrade_required();
                return StreamStatus::UpgradeRequired;
            }
            Ended::Unauthenticated => {
                refreshed_in_a_row += 1;
                match api.refresh().await {
                    // 刚刷新过还被拒（时钟、服务端问题）：别打转，按网络问题退避。
                    Ok(()) if refreshed_in_a_row <= 2 => continue,
                    Ok(()) => {}
                    Err(ClientError::SignedOut) => return StreamStatus::SignedOut,
                    Err(ClientError::AccountFrozen) => return StreamStatus::AccountFrozen,
                    Err(ClientError::UpgradeRequired) => return StreamStatus::UpgradeRequired,
                    Err(e) => debug!(error = %e, "token refresh failed"),
                }
            }
            Ended::Forbidden => {
                // 握手被拒（403）：问一下接口是不是账号被冻结了，别的情况按网络问题退避。
                match api.me().await {
                    Err(ClientError::AccountFrozen) => return StreamStatus::AccountFrozen,
                    Err(ClientError::SignedOut) => return StreamStatus::SignedOut,
                    Err(ClientError::UpgradeRequired) => return StreamStatus::UpgradeRequired,
                    Ok(_) => {}
                    Err(e) => debug!(error = %e, "checking the account failed"),
                }
            }
            Ended::Dropped { progressed } => {
                if progressed {
                    backoff = cfg.min_backoff;
                    refreshed_in_a_row = 0;
                }
            }
        }
        let wait = jitter(backoff);
        sink.on_status(StreamStatus::Reconnecting {
            retry_in_ms: wait.as_millis() as u64,
        });
        tokio::select! {
            () = stopped(&mut stop) => return StreamStatus::Stopped,
            () = tokio::time::sleep(wait) => {}
        }
        backoff = (backoff * 2).min(cfg.max_backoff);
    }
}

/// 等到要求停止（不把 watch 的读锁带过 await）。
async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|s| *s).await;
}

/// 在 `base` 的 75%–125% 之间取一个值，避免大量客户端同时重连。
fn jitter(base: Duration) -> Duration {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let factor = 0.75 + f64::from(nanos % 1000) / 2000.0;
    base.mul_f64(factor)
}

async fn connect_once(
    api: &Api,
    cache: Option<&Cache>,
    instance: InstanceId,
    last: &mut u64,
    sink: &dyn EventSink,
    cfg: &StreamConfig,
    stop: &mut watch::Receiver<bool>,
) -> Ended {
    let token = match api.bearer() {
        Ok(t) => t,
        Err(_) => return Ended::Unauthenticated,
    };
    let url = match ws_url(api.base_url(), instance, *last) {
        Ok(u) => u,
        Err(e) => {
            warn!(error = %e, "bad base url for the event stream");
            return Ended::Dropped { progressed: false };
        }
    };
    let mut req = match url.as_str().into_client_request() {
        Ok(r) => r,
        Err(e) => {
            warn!(error = %e, "bad event stream request");
            return Ended::Dropped { progressed: false };
        }
    };
    let headers = req.headers_mut();
    if let Ok(v) = HeaderValue::from_str(&format!("Bearer {token}")) {
        headers.insert("authorization", v);
    }
    if let Ok(v) = HeaderValue::from_str(&API_VERSION.to_string()) {
        headers.insert(VERSION_HEADER, v);
    }
    if let Some(lang) = api.accept_language()
        && let Ok(v) = HeaderValue::from_bytes(lang.as_bytes())
    {
        headers.insert("accept-language", v);
    }
    // wss 用系统证书校验（和接口请求一样），ws（本地开发）不加密。
    let connect = tokio::time::timeout(
        cfg.connect_timeout,
        tokio_tungstenite::connect_async_tls_with_config(
            req,
            None,
            false,
            Some(tokio_tungstenite::Connector::Rustls(api.ws_tls())),
        ),
    );
    let mut ws = tokio::select! {
        () = stopped(stop) => return Ended::Stopped,
        r = connect => match r {
            Ok(Ok((ws, _))) => ws,
            Ok(Err(WsError::Http(resp))) => {
                return match resp.status().as_u16() {
                    401 => Ended::Unauthenticated,
                    403 => Ended::Forbidden,
                    404 => Ended::NotFound,
                    426 => {
                        warn!("event stream refused: this app version is too old (426)");
                        Ended::UpgradeRequired
                    }
                    s => {
                        debug!(status = s, "event stream refused");
                        Ended::Dropped { progressed: false }
                    }
                };
            }
            Ok(Err(e)) => {
                debug!(error = %e, "event stream connect failed");
                return Ended::Dropped { progressed: false };
            }
            Err(_) => return Ended::Dropped { progressed: false },
        },
    };
    sink.on_status(StreamStatus::Live);
    let mut progressed = false;
    loop {
        let next = tokio::select! {
            () = stopped(stop) => {
                let _ = ws.close(None).await;
                return Ended::Stopped;
            }
            n = tokio::time::timeout(cfg.idle_timeout, ws.next()) => n,
        };
        let msg = match next {
            Err(_) => {
                debug!("event stream idle, reconnecting");
                return Ended::Dropped { progressed };
            }
            Ok(None) => return Ended::Dropped { progressed },
            Ok(Some(Err(e))) => {
                debug!(error = %e, "event stream broke");
                return Ended::Dropped { progressed };
            }
            Ok(Some(Ok(m))) => m,
        };
        progressed = true;
        match msg {
            Message::Text(text) => match serde_json::from_str::<Frame>(&text) {
                Ok(Frame::Event(e)) => {
                    if e.seq <= *last {
                        continue;
                    }
                    if let Some(c) = cache
                        && let Err(err) = c.put_events(instance, std::slice::from_ref(&e))
                    {
                        warn!(error = %err, "caching event failed");
                    }
                    *last = e.seq;
                    sink.on_event(&e);
                }
                Ok(Frame::Reset {
                    oldest_seq,
                    latest_seq,
                }) => {
                    if let Some(c) = cache
                        && let Err(err) = c.reset_events(instance, oldest_seq)
                    {
                        warn!(error = %err, "resetting cached events failed");
                    }
                    *last = oldest_seq.saturating_sub(1);
                    sink.on_reset(oldest_seq, latest_seq);
                }
                Err(e) => debug!(error = %e, "ignoring unknown event frame"),
            },
            Message::Close(frame) => {
                let code = frame.map(|f| f.code);
                return match code {
                    Some(CloseCode::Library(CLOSE_UNAUTHENTICATED)) => Ended::Unauthenticated,
                    Some(CloseCode::Library(CLOSE_ACCOUNT_FROZEN)) => Ended::AccountFrozen,
                    _ => Ended::Dropped { progressed },
                };
            }
            // Ping 由库自动回 Pong。
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls() {
        let i = InstanceId::new();
        assert_eq!(
            ws_url("https://api.thinktin.cn", i, 7).unwrap().as_str(),
            format!("wss://api.thinktin.cn/v1/instances/{i}/events/ws?after=7")
        );
        assert_eq!(
            ws_url("http://127.0.0.1:8080/base/", i, 0)
                .unwrap()
                .as_str(),
            format!("ws://127.0.0.1:8080/base/v1/instances/{i}/events/ws?after=0")
        );
        assert!(ws_url("ftp://x", i, 0).is_err());
    }

    #[test]
    fn jitter_stays_in_range() {
        for _ in 0..100 {
            let j = jitter(Duration::from_secs(4));
            assert!(j >= Duration::from_secs(3) && j <= Duration::from_secs(5));
        }
    }
}
