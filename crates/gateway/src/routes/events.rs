//! 实例事件流（5.2、5.3）：客户端带上最后收到的序号，先补发之后的事件，再实时推送。
//!
//! WebSocket 上服务端发的消息（JSON 文本）：
//! - `{"type":"event", "seq":…, "run_id":…, "kind":…, "payload":…, "created_at":…}`
//! - `{"type":"reset", "oldest_seq":…, "latest_seq":…}`：要续传的位置已经过了保留期，客户端整体重新加载后从 oldest_seq 接着收。
//!
//! 心跳时重新核对访问令牌和会话：令牌过期或会话被吊销就以 4001 关闭，客户端刷新令牌后重连；
//! 账号被冻结（4.6）以 4003 关闭，客户端不再重连。

use std::time::Duration;

use auth::service::{AuthError, Principal};
use axum::Json;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use proto::api::ErrorCode;
use proto::domain::{InstanceEvent, InstanceId};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;
use tracing::debug;

use super::parse_id;
use crate::{ApiError, ApiResult, AppState};

/// 发一条消息最长等多久（客户端太慢就断开，它重连后按序号续传）。
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
/// 会话失效时的关闭码。
const CLOSE_UNAUTHENTICATED: u16 = 4001;
/// 账号被冻结（4.6）时的关闭码：客户端不再重连，提示联系客服。
const CLOSE_ACCOUNT_FROZEN: u16 = 4003;

#[derive(Deserialize)]
pub struct PageQuery {
    #[serde(default)]
    after: u64,
    limit: Option<i64>,
}

async fn fetch(
    s: &AppState,
    who: &Principal,
    instance: InstanceId,
    after: u64,
    limit: i64,
) -> ApiResult<Vec<InstanceEvent>> {
    let mut t = s.db.tenant(who.user).await?;
    let events = t.events_after(instance, after, limit).await?;
    t.rollback().await?;
    Ok(events)
}

/// 补发用的分页接口（不方便用 WebSocket 时）。
pub async fn page(
    State(s): State<AppState>,
    crate::Authed(who): crate::Authed,
    Path(id): Path<String>,
    Query(q): Query<PageQuery>,
) -> ApiResult<Json<Value>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let limit = q.limit.unwrap_or(s.cfg.events_page).clamp(1, 1000);
    let mut t = s.db.tenant(who.user).await?;
    t.instance(id).await?;
    let (oldest, latest) = t.event_range(id).await?;
    let events = t.events_after(id, q.after, limit).await?;
    t.rollback().await?;
    Ok(Json(json!({
        "events": events,
        "oldest_seq": oldest,
        "latest_seq": latest,
    })))
}

#[derive(Deserialize)]
pub struct StreamQuery {
    #[serde(default)]
    after: u64,
}

pub async fn stream(
    State(s): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<StreamQuery>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> ApiResult<Response> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let token = crate::extract::bearer(&headers)
        .map(str::to_owned)
        .ok_or_else(|| ApiError::new(ErrorCode::Unauthenticated, "missing bearer token"))?;
    let who = s.auth.authenticate(&token).await?;
    s.limits().authed(who.user, who.device)?;
    let mut t = s.db.tenant(who.user).await?;
    t.instance(id).await?;
    t.rollback().await?;
    // 每个用户同时打开的事件流有上限（5.4），连接断开时归还。
    let slot = s.limits().open_stream(who.user)?;
    Ok(ws
        .max_message_size(64 << 10)
        .max_frame_size(64 << 10)
        .on_upgrade(move |socket| async move {
            let _slot = slot;
            run_stream(s, who, token, id, q.after, socket).await
        }))
}

async fn send(socket: &mut WebSocket, msg: Message) -> bool {
    matches!(
        tokio::time::timeout(SEND_TIMEOUT, socket.send(msg)).await,
        Ok(Ok(()))
    )
}

async fn close(socket: &mut WebSocket, code: u16, reason: &str) {
    let _ = send(
        socket,
        Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        })),
    )
    .await;
}

async fn run_stream(
    s: AppState,
    who: Principal,
    token: String,
    instance: InstanceId,
    after: u64,
    mut socket: WebSocket,
) {
    let mut wake = s.hub.subscribe(instance);
    let mut last = after;

    // 续传位置早于保留的最早事件：告诉客户端整体重新加载。
    let range = async {
        let mut t = s.db.tenant(who.user).await?;
        let r = t.event_range(instance).await?;
        t.rollback().await?;
        Ok::<_, store::Error>(r)
    }
    .await;
    match range {
        Ok((oldest, latest)) if oldest > last.saturating_add(1) => {
            let msg = json!({ "type": "reset", "oldest_seq": oldest, "latest_seq": latest });
            if !send(&mut socket, Message::Text(msg.to_string().into())).await {
                return;
            }
            last = oldest - 1;
        }
        Ok(_) => {}
        Err(e) => {
            debug!(error = %e, "event stream setup failed");
            close(&mut socket, 1011, "internal error").await;
            return;
        }
    }

    let mut heartbeat = tokio::time::interval(s.cfg.ws_heartbeat);
    heartbeat.tick().await;
    loop {
        // 把库里 last 之后的事件都发出去。
        loop {
            let page = match fetch(&s, &who, instance, last, s.cfg.events_page).await {
                Ok(p) => p,
                Err(_) => {
                    close(&mut socket, 1011, "internal error").await;
                    return;
                }
            };
            for ev in &page {
                let mut v = serde_json::to_value(ev).unwrap_or_default();
                v["type"] = json!("event");
                if !send(&mut socket, Message::Text(v.to_string().into())).await {
                    return;
                }
                last = ev.seq;
            }
            if (page.len() as i64) < s.cfg.events_page {
                break;
            }
        }
        // 等到有新事件（或心跳）再查库。客户端发来的消息（pong、文本）不处理，也不触发查库：
        // 否则一个连接狂发小帧就能让服务端不停开数据库事务。
        loop {
            tokio::select! {
                r = wake.recv() => match r {
                    Ok(()) | Err(RecvError::Lagged(_)) => break,
                    Err(RecvError::Closed) => return,
                },
                _ = heartbeat.tick() => {
                    match s.auth.authenticate(&token).await {
                        Ok(_) => {}
                        Err(AuthError::AccountFrozen) => {
                            close(&mut socket, CLOSE_ACCOUNT_FROZEN, "account frozen").await;
                            return;
                        }
                        Err(_) => {
                            close(&mut socket, CLOSE_UNAUTHENTICATED, "unauthenticated").await;
                            return;
                        }
                    }
                    if !send(&mut socket, Message::Ping(Default::default())).await {
                        return;
                    }
                    break;
                }
                msg = socket.recv() => match msg {
                    None | Some(Err(_)) | Some(Ok(Message::Close(_))) => return,
                    Some(Ok(_)) => {}
                },
            }
        }
    }
}
