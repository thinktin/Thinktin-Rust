//! IM 渠道（10.5）：用户绑定飞书 / Lark、企业微信、钉钉的群机器人，运行完成、需要审批、运行失败时
//! 发到群里。
//!
//! webhook 地址只认各家官方的固定前缀（`proto::im::parse_webhook`），只存 token；token 和签名密钥用用户自己的
//! DEK 加密，库里只有密文，响应和审计里只有平台和提示（token 后 4 位）。测试消息也走出箱，
//! 和正式通知一样签名、限流、重试。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use keyvault::WebhookSecret;
use notify::{PushKind, PushMessage, PushTarget};
use proto::domain::{ImChannel, ImChannelId, ImEvent, ImVendor, UserId};
use proto::im::{ImUrlError, check_secret, hint, parse_webhook};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{ImChannelChange, ImWebhook, NewImChannel};
use zeroize::Zeroizing;

use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 每个用户最多绑这么多个群。
const MAX_CHANNELS: u64 = 20;

fn url_error(e: ImUrlError) -> ApiError {
    ApiError::invalid(match e {
        ImUrlError::UnknownAddress => {
            "webhook_url must be a Feishu, Lark, WeCom or DingTalk group bot webhook address, copied as is"
        }
        ImUrlError::BadToken => "webhook_url: the token after the address is missing or malformed",
        ImUrlError::SecretNotSupported => "secret: WeCom bots have no signing secret",
        ImUrlError::BadSecret => {
            "secret must be 8-128 visible characters (DingTalk secrets start with SEC)"
        }
    })
}

/// 解析地址和签名密钥，返回平台、token、密钥（空字符串表示没有）。
fn check_webhook(
    url: &str,
    secret: Option<&str>,
) -> ApiResult<(ImVendor, Zeroizing<String>, Zeroizing<String>)> {
    check_len("webhook_url", url, 1, 512)?;
    let (vendor, token) = parse_webhook(url).map_err(url_error)?;
    let secret = match secret.map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) => {
            check_secret(vendor, s).map_err(url_error)?;
            Zeroizing::new(s.to_owned())
        }
        None => Zeroizing::new(String::new()),
    };
    Ok((vendor, Zeroizing::new(token), secret))
}

fn check_label(label: &str) -> ApiResult<()> {
    check_len("label", label, 0, 64)?;
    if label.chars().any(char::is_control) {
        return Err(ApiError::invalid(
            "label must not contain control characters",
        ));
    }
    Ok(())
}

fn parse_events(events: &[String]) -> ApiResult<Vec<ImEvent>> {
    if events.is_empty() {
        return Err(ApiError::invalid(
            "events must name at least one of run_finished, run_failed, approval (turn the channel off with enabled = false)",
        ));
    }
    events
        .iter()
        .map(|e| {
            e.parse::<ImEvent>().map_err(|_| {
                ApiError::invalid(format!(
                    "unknown event {e:?}: use run_finished, run_failed or approval"
                ))
            })
        })
        .collect()
}

async fn seal(
    s: &AppState,
    user: UserId,
    id: ImChannelId,
    token: &str,
    secret: &str,
) -> ApiResult<Vec<u8>> {
    let vault = orchestrator::artifacts::user_vault(&s.db, s.kms.clone(), user, true)
        .await
        .map_err(ApiError::internal)?;
    let hook = WebhookSecret {
        token: token.to_owned(),
        secret: secret.to_owned(),
    };
    vault
        .seal_webhook(&user.to_string(), &id.to_string(), &hook)
        .await
        .map_err(ApiError::internal)
}

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let channels = t.im_channels().await?;
    t.rollback().await?;
    Ok(Json(json!({ "channels": channels })))
}

#[derive(Deserialize)]
pub struct CreateReq {
    webhook_url: String,
    secret: Option<String>,
    #[serde(default)]
    label: String,
    events: Option<Vec<String>>,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<ImChannel>)> {
    let url = Zeroizing::new(req.webhook_url);
    let secret = req.secret.map(Zeroizing::new);
    let (vendor, token, secret) = check_webhook(&url, secret.as_deref().map(String::as_str))?;
    check_label(&req.label)?;
    let events = match &req.events {
        Some(e) => parse_events(e)?,
        None => ImEvent::ALL.to_vec(),
    };
    // 先粗查一次，省得满了还去封密钥；真正的上限在插入的事务里按用户加锁再数（并发的请求不能一起超过）。
    let mut t = s.db.tenant(who.user).await?;
    let n = t.im_channel_count().await?;
    t.rollback().await?;
    if n >= MAX_CHANNELS {
        return Err(ApiError::invalid(format!(
            "at most {MAX_CHANNELS} IM channels per account"
        )));
    }
    let id = ImChannelId::new();
    let sealed = seal(&s, who.user, id, &token, &secret).await?;
    let mut t = s.db.tenant(who.user).await?;
    let channel = t
        .create_im_channel(
            &NewImChannel {
                id,
                vendor,
                label: req.label,
                sealed,
                hint: hint(&token),
                has_secret: !secret.is_empty(),
                bot_tag: keyvault::webhook_fingerprint(vendor.as_str(), &token),
                events,
            },
            MAX_CHANNELS,
        )
        .await?;
    t.audit(
        &who.actor(),
        "im_channel.create",
        Some(&id.to_string()),
        &json!({ "vendor": vendor, "hint": channel.hint }),
    )
    .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(channel)))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    label: Option<String>,
    events: Option<Vec<String>>,
    enabled: Option<bool>,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<ImChannel>> {
    let id: ImChannelId = parse_id(&id, "im channel")?;
    if let Some(label) = &req.label {
        check_label(label)?;
    }
    let events = req.events.as_deref().map(parse_events).transpose()?;
    let mut t = s.db.tenant(who.user).await?;
    let channel = t
        .update_im_channel(
            id,
            &ImChannelChange {
                label: req.label,
                events,
                enabled: req.enabled,
                webhook: None,
            },
        )
        .await?;
    t.audit(
        &who.actor(),
        "im_channel.update",
        Some(&id.to_string()),
        &json!({ "enabled": channel.enabled, "events": channel.events }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(channel))
}

#[derive(Deserialize)]
pub struct WebhookReq {
    webhook_url: String,
    secret: Option<String>,
}

/// 换地址或签名密钥（群机器人重建了、密钥重置了）。要是同一家的；之前记下的错误清掉，机器人失效被后台停用的
/// 渠道重新打开，换上新地址就能接着发（用户自己关掉的还是关着）。
pub async fn replace_webhook(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<WebhookReq>,
) -> ApiResult<Json<ImChannel>> {
    let id: ImChannelId = parse_id(&id, "im channel")?;
    let url = Zeroizing::new(req.webhook_url);
    let secret = req.secret.map(Zeroizing::new);
    let (vendor, token, secret) = check_webhook(&url, secret.as_deref().map(String::as_str))?;
    let mut t = s.db.tenant(who.user).await?;
    t.im_channel(id).await?;
    t.rollback().await?;
    let sealed = seal(&s, who.user, id, &token, &secret).await?;
    let mut t = s.db.tenant(who.user).await?;
    let channel = t
        .update_im_channel(
            id,
            &ImChannelChange {
                webhook: Some(ImWebhook {
                    vendor,
                    sealed,
                    hint: hint(&token),
                    has_secret: !secret.is_empty(),
                    bot_tag: keyvault::webhook_fingerprint(vendor.as_str(), &token),
                }),
                ..Default::default()
            },
        )
        .await?;
    t.audit(
        &who.actor(),
        "im_channel.rotate",
        Some(&id.to_string()),
        &json!({ "vendor": vendor, "hint": channel.hint }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(channel))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: ImChannelId = parse_id(&id, "im channel")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_im_channel(id).await?;
    t.audit(
        &who.actor(),
        "im_channel.delete",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 发一条测试消息（经出箱，和正式通知一样）。结果写回渠道的 `last_sent_at` / `last_error`。
pub async fn test(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let id: ImChannelId = parse_id(&id, "im channel")?;
    let mut t = s.db.tenant(who.user).await?;
    let channel = t.im_channel(id).await?;
    if !channel.enabled {
        return Err(ApiError::invalid(
            "the channel is turned off; turn it on first",
        ));
    }
    s.limits().im_tests(who.user)?;
    let locale = t.user_locale(who.user).await?;
    let (title, body) = orchestrator::texts::im_test(locale);
    let message = PushMessage {
        kind: PushKind::Info,
        title: title.into(),
        body: body.into(),
        thread_id: None,
        collapse_id: None,
        target: PushTarget::default(),
        ttl: Some(std::time::Duration::from_secs(3600)),
        ai_generated: false,
        locale,
        subtype: None,
    };
    t.enqueue_outbox(&orchestrator::outbox::im_item(id, &message, None))
        .await?;
    t.audit(
        &who.actor(),
        "im_channel.test",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok((StatusCode::ACCEPTED, Json(json!({ "queued": true }))))
}
