//! 一台电脑的连接：连上时记在线状态、唤醒等电脑的运行；被叫醒时把等着的调用和消息转过去；
//! 心跳时 ping、刷新在线状态、核对会话；收下电脑回的结果和发给手机的消息；断开时去掉在线状态，
//! 转出去没回的调用判失败。

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use proto::domain::DeviceMessageId;
use proto::relay::{
    ComputerFrame, MAX_CALL_RESULT_BYTES, MAX_MESSAGE_BODY_BYTES, MAX_TOOLS, RelayFrame, close,
};
use proto::shim::PlatformTool;
use serde_json::json;
use store::NewLink;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, watch};
use tokio::time::{Instant, MissedTickBehavior};
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::{AuthFail, Computer, Relay, unix_now};

/// 发一帧最长等多久（电脑那边太慢就断开，它重连后接着收）。
const SEND_TIMEOUT: Duration = Duration::from_secs(30);
/// 一次领多少个调用。
const CLAIM_BATCH: i64 = 32;
/// 一次取多少条消息。
const MESSAGE_BATCH: i64 = 200;
/// App 版本号最长多少个字符。
const MAX_APP_VERSION_CHARS: usize = 64;

/// 连接为什么结束。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum End {
    /// 电脑断开了。
    Closed,
    /// 这台电脑在别处又连了一次。
    Replaced,
    Unauthenticated,
    Frozen,
    /// 三个心跳周期没收到电脑的任何帧。
    Silent,
    /// 中继停机。
    Restarting,
    Protocol(&'static str),
    /// 帧发不出去。
    SendFailed,
    Internal,
}

impl End {
    fn label(self) -> &'static str {
        match self {
            Self::Closed => "closed",
            Self::Replaced => "replaced",
            Self::Unauthenticated => "unauthenticated",
            Self::Frozen => "frozen",
            Self::Silent => "silent",
            Self::Restarting => "restarting",
            Self::Protocol(_) => "protocol",
            Self::SendFailed => "send_failed",
            Self::Internal => "internal",
        }
    }

    /// 关闭码和原因；`None`：对面已经走了，不用发。
    fn close_frame(self) -> Option<(u16, &'static str)> {
        match self {
            Self::Closed | Self::SendFailed => None,
            Self::Replaced => Some((close::REPLACED, "connected elsewhere")),
            Self::Unauthenticated => Some((close::UNAUTHENTICATED, "unauthenticated")),
            Self::Frozen => Some((close::ACCOUNT_FROZEN, "account frozen")),
            Self::Silent => Some((1001, "heartbeat timeout")),
            Self::Restarting => Some((close::RESTARTING, "relay restarting")),
            Self::Protocol(reason) => Some((close::PROTOCOL, reason)),
            Self::Internal => Some((1011, "internal error")),
        }
    }
}

impl From<store::Error> for End {
    fn from(e: store::Error) -> Self {
        warn!(error = %e, "relay database error");
        End::Internal
    }
}

struct Conn {
    relay: Arc<Relay>,
    who: Computer,
    connection: Uuid,
    socket: WebSocket,
    /// 这次连接里已经投递、电脑还没确认的消息：不重复投（下次连上再投）。
    in_flight: HashSet<DeviceMessageId>,
    last_heard: Instant,
}

/// 中继开始停机。不把 `watch::Ref`（读锁）带出来：select! 的结果要跨 await 留着，读锁不能跨线程。
async fn stopped(stopping: &mut watch::Receiver<bool>) {
    let _ = stopping.wait_for(|s| *s).await;
}

pub(crate) async fn run(relay: Arc<Relay>, who: Computer, socket: WebSocket) {
    let _live = relay.live.clone();
    // 先订阅再记在线状态：平台看到电脑在线后写的调用，通知一定收得到。
    let mut wake = relay.hub.subscribe(who.device);
    let mut stopping = relay.stopping.subscribe();
    let mut c = Conn {
        relay,
        who,
        connection: Uuid::now_v7(),
        socket,
        in_flight: HashSet::new(),
        last_heard: Instant::now(),
    };
    metrics::gauge!("thinktin_relay_connections").increment(1.0);
    info!(device = %who.device, connection = %c.connection, "computer connected");
    let end = c.serve(&mut wake, &mut stopping).await;
    if let Some((code, reason)) = end.close_frame() {
        c.close(code, reason).await;
    }
    c.finish().await;
    metrics::gauge!("thinktin_relay_connections").decrement(1.0);
    metrics::counter!("thinktin_relay_disconnects_total", "reason" => end.label()).increment(1);
    info!(device = %who.device, connection = %c.connection, reason = end.label(), "computer disconnected");
}

impl Conn {
    async fn serve(
        &mut self,
        wake: &mut broadcast::Receiver<()>,
        stopping: &mut watch::Receiver<bool>,
    ) -> End {
        if let Err(end) = self.start().await {
            return end;
        }
        let mut beat = tokio::time::interval(self.relay.cfg.heartbeat);
        beat.set_missed_tick_behavior(MissedTickBehavior::Delay);
        beat.tick().await;
        loop {
            let step = tokio::select! {
                r = wake.recv() => match r {
                    Ok(()) | Err(RecvError::Lagged(_)) => self.sync().await,
                    Err(RecvError::Closed) => Err(End::Internal),
                },
                _ = beat.tick() => self.heartbeat().await,
                () = stopped(stopping) => Err(End::Restarting),
                msg = self.socket.recv() => {
                    self.last_heard = Instant::now();
                    match msg {
                        None | Some(Err(_)) | Some(Ok(Message::Close(_))) => Err(End::Closed),
                        Some(Ok(Message::Text(text))) => self.on_text(text.as_str()).await,
                        Some(Ok(Message::Binary(_))) => {
                            Err(End::Protocol("binary frames are not supported"))
                        }
                        Some(Ok(Message::Ping(_) | Message::Pong(_))) => Ok(()),
                    }
                }
            };
            if let Err(end) = step {
                return end;
            }
        }
    }

    async fn send(&mut self, frame: &RelayFrame) -> Result<(), End> {
        let text = serde_json::to_string(frame).map_err(|_| End::Internal)?;
        match tokio::time::timeout(SEND_TIMEOUT, self.socket.send(Message::Text(text.into()))).await
        {
            Ok(Ok(())) => Ok(()),
            _ => Err(End::SendFailed),
        }
    }

    async fn close(&mut self, code: u16, reason: &str) {
        let frame = Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        }));
        let _ = tokio::time::timeout(Duration::from_secs(5), self.socket.send(frame)).await;
    }

    /// 某一帧没处理成：告诉电脑，连接不断。
    async fn error(
        &mut self,
        reference: Option<String>,
        code: &str,
        message: impl Into<String>,
    ) -> Result<(), End> {
        self.send(&RelayFrame::Error {
            reference,
            code: code.into(),
            message: message.into(),
        })
        .await
    }

    /// 连上之后：记下在线状态（顶掉这台电脑之前的连接）、唤醒等电脑的运行、打招呼，再转等着的东西。
    async fn start(&mut self) -> Result<(), End> {
        let mut r = self.relay.db.relay().await?;
        r.link_device(&NewLink {
            device: self.who.device,
            user: self.who.user,
            node: self.relay.cfg.node.clone(),
            connection: self.connection,
        })
        .await?;
        let woken = r.wake_device_waiters(self.who.user).await?;
        r.commit().await?;
        if woken > 0 {
            info!(device = %self.who.device, runs = woken, "computer online, waiting runs resume");
        }
        self.send(&RelayFrame::Welcome {
            device: self.who.device,
            heartbeat_secs: self.relay.cfg.heartbeat.as_secs().max(1),
        })
        .await?;
        self.sync().await
    }

    /// 被叫醒：还是这台电脑现在的连接的话，把等着的调用和消息转过去。
    async fn sync(&mut self) -> Result<(), End> {
        loop {
            let mut r = self.relay.db.relay().await?;
            if !r.touch_link(self.who.device, self.connection).await? {
                r.rollback().await?;
                return Err(End::Replaced);
            }
            let calls = r
                .claim_device_calls(self.who.device, self.connection, CLAIM_BATCH)
                .await?;
            r.commit().await?;
            let more = calls.len() as i64 == CLAIM_BATCH;
            for call in calls {
                debug!(call = %call.id, tool = %call.tool, "forwarding a call to the computer");
                metrics::counter!("thinktin_relay_calls_total", "outcome" => "forwarded")
                    .increment(1);
                self.send(&RelayFrame::Call {
                    id: call.id,
                    tool: call.tool,
                    arguments: call.arguments,
                    run: call.run,
                    expires_at: call.expires_at,
                })
                .await?;
            }
            if !more {
                break;
            }
        }
        let mut r = self.relay.db.relay().await?;
        let messages = r
            .pending_device_messages(self.who.user, self.who.device, MESSAGE_BATCH)
            .await?;
        r.rollback().await?;
        for message in messages {
            if !self.in_flight.insert(message.id) {
                continue;
            }
            metrics::counter!("thinktin_relay_messages_total", "direction" => "to_computer")
                .increment(1);
            self.send(&RelayFrame::Message { message }).await?;
        }
        Ok(())
    }

    /// 心跳：电脑还在说话、令牌没过期、会话还有效、还是现在的连接，然后 ping。
    async fn heartbeat(&mut self) -> Result<(), End> {
        if self.last_heard.elapsed() > self.relay.cfg.heartbeat * 3 {
            return Err(End::Silent);
        }
        if unix_now() >= self.who.token_exp {
            return Err(End::Unauthenticated);
        }
        match self.relay.check(&self.who).await {
            Ok(()) => {}
            Err(AuthFail::Frozen) => return Err(End::Frozen),
            // 数据库一时不通：这一轮先不管，别把所有电脑都踢下线。
            Err(AuthFail::Unavailable) => {}
            Err(_) => return Err(End::Unauthenticated),
        }
        match self.touch().await {
            Ok(true) => {}
            Ok(false) => return Err(End::Replaced),
            Err(e) => warn!(error = %e, "cannot refresh a computer's link"),
        }
        match tokio::time::timeout(
            SEND_TIMEOUT,
            self.socket.send(Message::Ping(Default::default())),
        )
        .await
        {
            Ok(Ok(())) => Ok(()),
            _ => Err(End::SendFailed),
        }
    }

    async fn touch(&mut self) -> store::Result<bool> {
        let mut r = self.relay.db.relay().await?;
        let alive = r.touch_link(self.who.device, self.connection).await?;
        r.commit().await?;
        Ok(alive)
    }

    async fn on_text(&mut self, text: &str) -> Result<(), End> {
        let frame: ComputerFrame = match serde_json::from_str(text) {
            Ok(f) => f,
            Err(e) => return self.error(None, "invalid", format!("bad frame: {e}")).await,
        };
        match frame {
            ComputerFrame::Hello { tools, app_version } => self.hello(tools, app_version).await,
            ComputerFrame::Auth { token } => self.reauth(&token).await,
            ComputerFrame::CallResult {
                call,
                content,
                is_error,
            } => {
                // 太大的结果不收，换成一个错误告诉 agent（帧本身的上限更大，留了余量）。
                let result = if text.len() > MAX_CALL_RESULT_BYTES {
                    json!({
                        "content": [{ "type": "text", "text": "the result from the computer is too large" }],
                        "is_error": true,
                    })
                } else {
                    json!({ "content": content, "is_error": is_error })
                };
                let mut r = self.relay.db.relay().await?;
                let accepted = r
                    .finish_device_call(call, self.who.device, self.connection, &result)
                    .await?;
                r.commit().await?;
                if !accepted {
                    return self
                        .error(
                            None,
                            "not_found",
                            format!("call {call} is not waiting for a result"),
                        )
                        .await;
                }
                metrics::counter!("thinktin_relay_calls_total", "outcome" => "answered")
                    .increment(1);
                Ok(())
            }
            ComputerFrame::Ack { message } => {
                let mut r = self.relay.db.relay().await?;
                r.ack_device_messages(self.who.user, self.who.device, &[message])
                    .await?;
                r.commit().await?;
                self.in_flight.remove(&message);
                Ok(())
            }
            ComputerFrame::Send {
                to,
                kind,
                body,
                reference,
            } => {
                let size = serde_json::to_string(&body).map_or(usize::MAX, |s| s.len());
                if size > MAX_MESSAGE_BODY_BYTES {
                    return self
                        .error(reference, "too_large", "the message body is too large")
                        .await;
                }
                let mut r = self.relay.db.relay().await?;
                let sent = r
                    .send_device_message(self.who.user, self.who.device, to, kind, &body)
                    .await;
                match sent {
                    Ok(m) => {
                        r.commit().await?;
                        metrics::counter!("thinktin_relay_messages_total", "direction" => "from_computer")
                            .increment(1);
                        self.send(&RelayFrame::Sent {
                            id: m.id,
                            reference,
                        })
                        .await
                    }
                    Err(e) => {
                        r.rollback().await?;
                        match e {
                            store::Error::NotFound => {
                                self.error(reference, "not_found", "no such device").await
                            }
                            store::Error::Invalid(m) => self.error(reference, "invalid", m).await,
                            other => {
                                warn!(error = %other, "cannot store a message from a computer");
                                self.error(reference, "internal", "internal error").await
                            }
                        }
                    }
                }
            }
        }
    }

    /// 电脑报上来的工具和 App 版本。
    async fn hello(&mut self, tools: Vec<String>, app_version: String) -> Result<(), End> {
        if tools.len() > MAX_TOOLS
            || tools.iter().any(|t| !PlatformTool::valid_name(t))
            || app_version.chars().count() > MAX_APP_VERSION_CHARS
        {
            return self
                .error(
                    None,
                    "invalid",
                    "too many tools, a bad tool name or a long version",
                )
                .await;
        }
        let mut r = self.relay.db.relay().await?;
        let alive = r
            .set_link_info(self.who.device, self.connection, &tools, &app_version)
            .await?;
        r.commit().await?;
        if !alive {
            return Err(End::Replaced);
        }
        debug!(device = %self.who.device, tools = tools.len(), %app_version, "computer hello");
        Ok(())
    }

    /// 换上新的访问令牌：必须是同一个用户的同一台电脑。
    async fn reauth(&mut self, token: &str) -> Result<(), End> {
        match self.relay.authenticate(token).await {
            Ok(who) if who.user == self.who.user && who.device == self.who.device => {
                self.who = who;
                Ok(())
            }
            Ok(_) => Err(End::Protocol("the token belongs to another device")),
            Err(AuthFail::Frozen) => Err(End::Frozen),
            Err(AuthFail::Unavailable) => {
                self.error(
                    None,
                    "unavailable",
                    "cannot check the token right now, retry",
                )
                .await
            }
            Err(_) => Err(End::Unauthenticated),
        }
    }

    /// 连接结束：去掉在线状态（还是这次连接的话），转出去没回的调用判失败。
    async fn finish(&mut self) {
        let unlink = async {
            let mut r = self.relay.db.relay().await?;
            let failed = r.unlink_device(self.who.device, self.connection).await?;
            r.commit().await?;
            Ok::<_, store::Error>(failed)
        };
        match unlink.await {
            Ok(failed) if !failed.is_empty() => {
                info!(device = %self.who.device, calls = failed.len(), "unanswered calls failed");
            }
            Ok(_) => {}
            Err(e) => warn!(error = %e, device = %self.who.device, "cannot unlink a computer"),
        }
    }
}
