//! 登录、刷新、退出、本人信息、设备（4.1、4.2），全部停止、下线其他设备（4.6）。

use auth::service::NewDevice;
use auth::sms::CodePurpose;
use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use orchestrator::account::{self, Stopped};
use proto::domain::{Device, DeviceId, DevicePlatform, PushChannelKind, User};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed, ClientIp};

#[derive(Deserialize)]
pub struct CodeReq {
    phone: String,
}

pub async fn send_code(
    State(s): State<AppState>,
    ClientIp(ip): ClientIp,
    ApiJson(req): ApiJson<CodeReq>,
) -> ApiResult<StatusCode> {
    // 同一个来源地址发码限频（防短信轰炸）；同一手机号的限制在 auth 里。
    s.limits().anonymous(ip)?;
    s.limits().codes(ip)?;
    s.auth.send_code(&req.phone, CodePurpose::Login).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct DeviceInfo {
    platform: DevicePlatform,
    #[serde(default)]
    name: String,
    push_channel: Option<PushChannelKind>,
    push_token: Option<String>,
}

#[derive(Deserialize)]
pub struct LoginReq {
    phone: String,
    code: String,
    device: DeviceInfo,
}

#[derive(Serialize)]
pub struct TokensResp {
    access_token: String,
    access_expires_in: u64,
    refresh_token: String,
}

impl From<auth::service::Tokens> for TokensResp {
    fn from(t: auth::service::Tokens) -> Self {
        Self {
            access_token: t.access_token,
            access_expires_in: t.access_expires_in,
            refresh_token: t.refresh_token.to_string(),
        }
    }
}

#[derive(Serialize)]
pub struct LoginResp {
    user: User,
    new_user: bool,
    device_id: DeviceId,
    #[serde(flatten)]
    tokens: TokensResp,
}

fn push_of(
    channel: Option<PushChannelKind>,
    token: Option<String>,
) -> ApiResult<Option<(PushChannelKind, String)>> {
    match (channel, token) {
        (Some(c), Some(t)) => {
            check_len("push_token", &t, 1, 512)?;
            Ok(Some((c, t)))
        }
        (None, None) => Ok(None),
        _ => Err(ApiError::invalid("push_channel and push_token go together")),
    }
}

pub async fn login(
    State(s): State<AppState>,
    ClientIp(ip): ClientIp,
    ApiJson(req): ApiJson<LoginReq>,
) -> ApiResult<Json<LoginResp>> {
    s.limits().anonymous(ip)?;
    check_len("device.name", &req.device.name, 0, 64)?;
    let device = NewDevice {
        platform: req.device.platform,
        name: req.device.name,
        push: push_of(req.device.push_channel, req.device.push_token)?,
    };
    // 注册风控（5.4）：手机号没注册过时，按来源地址和全站的新注册上限放行。
    let limits = s.limits().clone();
    let l = s
        .auth
        .login_gated(&req.phone, &req.code, &device, move || {
            limits.signup(ip).map_err(|l| l.0)
        })
        .await?;
    Ok(Json(LoginResp {
        user: l.user,
        new_user: l.new_user,
        device_id: l.device_id,
        tokens: l.tokens.into(),
    }))
}

#[derive(Deserialize)]
pub struct RefreshReq {
    refresh_token: String,
}

pub async fn refresh(
    State(s): State<AppState>,
    ClientIp(ip): ClientIp,
    ApiJson(req): ApiJson<RefreshReq>,
) -> ApiResult<Json<TokensResp>> {
    s.limits().anonymous(ip)?;
    Ok(Json(s.auth.refresh(&req.refresh_token).await?.into()))
}

pub async fn logout(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<StatusCode> {
    s.auth.logout(&who).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn me(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<User>> {
    let mut t = s.db.tenant(who.user).await?;
    let me = t.me().await?;
    t.rollback().await?;
    Ok(Json(me))
}

#[derive(Deserialize)]
pub struct UpdateMe {
    display_name: Option<String>,
}

pub async fn update_me(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<UpdateMe>,
) -> ApiResult<Json<User>> {
    if let Some(name) = &req.display_name {
        check_len("display_name", name, 1, 64)?;
    }
    let mut t = s.db.tenant(who.user).await?;
    t.set_display_name(req.display_name.as_deref()).await?;
    let me = t.me().await?;
    t.commit().await?;
    Ok(Json(me))
}

#[derive(Deserialize)]
pub struct SelfCodeReq {
    purpose: String,
}

pub async fn send_self_code(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<SelfCodeReq>,
) -> ApiResult<StatusCode> {
    let purpose = match req.purpose.as_str() {
        "delete_account" => CodePurpose::DeleteAccount,
        "change_phone" => CodePurpose::ChangePhone,
        _ => {
            return Err(ApiError::invalid(
                "purpose must be delete_account or change_phone",
            ));
        }
    };
    s.auth.send_code_to_self(&who, purpose).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct DeleteReq {
    code: String,
}

pub async fn delete_account(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<DeleteReq>,
) -> ApiResult<StatusCode> {
    s.auth.delete_account(&who, &req.code).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn devices(
    State(s): State<AppState>,
    Authed(who): Authed,
) -> ApiResult<Json<serde_json::Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let devices: Vec<Device> = t.devices().await?;
    t.rollback().await?;
    let list: Vec<_> = devices
        .into_iter()
        .map(|d| {
            let current = d.id == who.device;
            let mut v = serde_json::to_value(d).unwrap_or_default();
            v["current"] = json!(current);
            v
        })
        .collect();
    Ok(Json(json!({ "devices": list })))
}

#[derive(Deserialize)]
pub struct PushReq {
    channel: PushChannelKind,
    token: String,
}

pub async fn set_push(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<PushReq>,
) -> ApiResult<StatusCode> {
    check_len("token", &req.token, 1, 512)?;
    let mut t = s.db.tenant(who.user).await?;
    t.set_push_token(who.device, req.channel, &req.token)
        .await?;
    t.commit().await?;
    // 同一个令牌之前登记在别的设备（可能是别的账号）上的，清掉：推送只发给现在用这台手机的人。
    let mut w = s.db.worker().await?;
    w.release_push_token(who.device, req.channel, &req.token)
        .await?;
    w.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn revoke_device(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let device: DeviceId = parse_id(&id, "device")?;
    s.auth.revoke_device(&who, device).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 全部停止（4.6）：取消所有运行、吊销全部运行授权、暂停全部计划。
/// 之后在实例上发起运行、恢复计划时重新签发授权。
pub async fn stop_all(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Stopped>> {
    Ok(Json(
        account::stop_all(&s.db, who.user, &who.actor()).await?,
    ))
}

#[derive(Deserialize)]
pub struct SignOutOthersReq {
    /// 同时停止全部 agent（怀疑账号被盗时）。
    #[serde(default)]
    stop_agents: bool,
}

/// 下线其他设备（4.6），只留当前这台；可以顺带“全部停止”。
pub async fn sign_out_others(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<SignOutOthersReq>,
) -> ApiResult<Json<serde_json::Value>> {
    let devices = s.auth.revoke_other_devices(&who).await?;
    let stopped = if req.stop_agents {
        Some(account::stop_all(&s.db, who.user, &who.actor()).await?)
    } else {
        None
    };
    Ok(Json(
        json!({ "devices_signed_out": devices, "stopped": stopped }),
    ))
}
