//! 手机和电脑之间转发的消息（14.1）：配对应答和确认、高危操作的审批请求和决定、能力令牌、吊销
//! （内容和签名见 docs/pairing.md）。平台只转发，内容由两端签名。这里是手机一侧；
//! 电脑一侧走设备中继（`relay`），收件方不在线时排队。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use proto::domain::{DeviceId, DeviceMessage, DeviceMessageId, DeviceMessageKind};
use proto::relay::MAX_MESSAGE_BODY_BYTES;
use serde::Deserialize;
use serde_json::{Value, json};

use super::parse_id;
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 一次最多确认多少条。
const MAX_ACK: usize = 200;

#[derive(Deserialize)]
pub struct SendReq {
    kind: DeviceMessageKind,
    body: Value,
}

/// `POST /v1/devices/{id}/messages`：从当前设备发给自己的另一台设备（手机发给电脑）。
pub async fn send(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<SendReq>,
) -> ApiResult<(StatusCode, Json<DeviceMessage>)> {
    let to: DeviceId = parse_id(&id, "device")?;
    let size = serde_json::to_string(&req.body).map_or(usize::MAX, |t| t.len());
    if size > MAX_MESSAGE_BODY_BYTES {
        return Err(ApiError::invalid(format!(
            "body is larger than {MAX_MESSAGE_BODY_BYTES} bytes"
        )));
    }
    let mut t = s.db.tenant(who.user).await?;
    let message = t
        .send_device_message(who.device, to, req.kind, &req.body)
        .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(message)))
}

#[derive(Deserialize)]
pub struct PendingQuery {
    limit: Option<i64>,
}

/// `GET /v1/devices/current/messages`：发给当前设备、还没收的消息，按发出的顺序。
pub async fn pending(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<PendingQuery>,
) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(100).clamp(1, 200);
    let mut t = s.db.tenant(who.user).await?;
    let messages = t.pending_device_messages(who.device, limit).await?;
    t.rollback().await?;
    Ok(Json(json!({ "messages": messages })))
}

#[derive(Deserialize)]
pub struct AckReq {
    ids: Vec<DeviceMessageId>,
}

/// `POST /v1/devices/current/messages/ack`：收下了这些消息，之后不再返回。
pub async fn ack(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<AckReq>,
) -> ApiResult<Json<Value>> {
    if req.ids.is_empty() || req.ids.len() > MAX_ACK {
        return Err(ApiError::invalid(format!("give 1 to {MAX_ACK} ids")));
    }
    let mut t = s.db.tenant(who.user).await?;
    let n = t.ack_device_messages(who.device, &req.ids).await?;
    t.commit().await?;
    Ok(Json(json!({ "acknowledged": n })))
}
