//! 模型 key 管理（9.8）：保存时用用户自己的 DEK 加密，库里只有密文；对外只显示后 4 位；
//! 增删改都记审计。解密只在模型网关里发生。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use keyvault::SealedSecret;
use keyvault::secrecy::SecretString;
use proto::domain::{Credential, CredentialId, RunState, UserId};
use proto::vendors;
use serde::Deserialize;
use serde_json::{Value, json};
use store::NewCredential;
use zeroize::Zeroizing;

use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 用用户的 DEK 加密一把 key。用户还没有 DEK 就生成一个（并发生成时以先写进库的为准）。
async fn seal(
    s: &AppState,
    user: UserId,
    record: CredentialId,
    secret: &SecretString,
) -> ApiResult<SealedSecret> {
    let vault = orchestrator::artifacts::user_vault(&s.db, s.kms.clone(), user, true)
        .await
        .map_err(ApiError::internal)?;
    vault
        .seal(&user.to_string(), &record.to_string(), secret)
        .map_err(ApiError::internal)
}

fn check_key(vendor: &str, api_key: &str) -> ApiResult<()> {
    if api_key.len() < 8 || api_key.len() > 4096 {
        return Err(ApiError::invalid("api_key must be 8-4096 bytes"));
    }
    if api_key.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(ApiError::invalid(
            "api_key must not contain spaces or control characters",
        ));
    }
    // 订阅类 key（编程套餐等）按厂商条款只能在官方工具里用，平台不能中转（9.12）。
    vendors::check_key(vendor, api_key).map_err(ApiError::invalid)
}

fn check_base(field: &str, url: &Option<String>) -> ApiResult<()> {
    if let Some(u) = url {
        check_len(field, u, 9, 512)?;
        if !u.starts_with("https://") {
            return Err(ApiError::invalid(format!("{field} must be an https URL")));
        }
        if let Some(plan) = vendors::plan_only_base(u) {
            return Err(ApiError::invalid(format!(
                "{field}: {plan} is a coding or subscription plan address, which only works in the vendor's own tools; use the pay-as-you-go address"
            )));
        }
    }
    Ok(())
}

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let creds = t.credentials().await?;
    t.rollback().await?;
    Ok(Json(json!({ "credentials": creds })))
}

#[derive(Deserialize)]
pub struct CreateReq {
    vendor: String,
    #[serde(default)]
    label: String,
    api_key: String,
    anthropic_base: Option<String>,
    openai_base: Option<String>,
    responses_base: Option<String>,
    daily_token_limit: Option<u64>,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<Credential>)> {
    check_len("vendor", &req.vendor, 1, 64)?;
    if !vendors::is_known(&req.vendor) {
        return Err(ApiError::invalid(
            "unknown vendor: use an id from GET /v1/vendors, or custom with your own base URLs",
        ));
    }
    check_len("label", &req.label, 0, 64)?;
    let api_key = Zeroizing::new(req.api_key);
    check_key(&req.vendor, &api_key)?;
    check_base("anthropic_base", &req.anthropic_base)?;
    check_base("openai_base", &req.openai_base)?;
    check_base("responses_base", &req.responses_base)?;
    let custom = req.vendor == "custom";
    let has_base =
        req.anthropic_base.is_some() || req.openai_base.is_some() || req.responses_base.is_some();
    if custom != has_base {
        return Err(ApiError::invalid(
            "base URLs are required for, and only allowed with, vendor custom",
        ));
    }
    if req.daily_token_limit == Some(0) {
        return Err(ApiError::invalid("daily_token_limit must be positive"));
    }
    let id = CredentialId::new();
    let secret = SecretString::from(api_key.to_string());
    let sealed = seal(&s, who.user, id, &secret).await?;
    let mut t = s.db.tenant(who.user).await?;
    let cred = t
        .create_credential(&NewCredential {
            id,
            vendor: req.vendor,
            label: req.label,
            anthropic_base: req.anthropic_base,
            openai_base: req.openai_base,
            responses_base: req.responses_base,
            sealed: sealed.ciphertext,
            last4: sealed.last4,
            daily_token_limit: req.daily_token_limit,
        })
        .await?;
    t.audit(
        &who.actor(),
        "credential.create",
        Some(&id.to_string()),
        &json!({ "vendor": cred.vendor, "last4": cred.last4 }),
    )
    .await?;
    // 等 key 的运行（7.11）马上接着跑：还用不了的话执行器会让它接着等。
    t.wake_waiting_runs(RunState::WaitingQuota).await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(cred)))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    label: Option<String>,
    disabled: Option<bool>,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<Credential>> {
    let id: CredentialId = parse_id(&id, "credential")?;
    let mut t = s.db.tenant(who.user).await?;
    if let Some(label) = &req.label {
        check_len("label", label, 0, 64)?;
        t.rename_credential(id, label).await?;
    }
    if let Some(disabled) = req.disabled {
        t.set_credential_disabled(id, disabled).await?;
        t.audit(
            &who.actor(),
            if disabled {
                "credential.disable"
            } else {
                "credential.enable"
            },
            Some(&id.to_string()),
            &json!({}),
        )
        .await?;
        if !disabled {
            t.wake_waiting_runs(RunState::WaitingQuota).await?;
        }
    }
    let cred = t.credential(id).await?;
    t.commit().await?;
    Ok(Json(cred))
}

#[derive(Deserialize)]
pub struct SecretReq {
    api_key: String,
}

/// 换 key（同一个厂商、同一条记录）：模型别名不用改。
pub async fn replace_secret(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<SecretReq>,
) -> ApiResult<Json<Credential>> {
    let id: CredentialId = parse_id(&id, "credential")?;
    let api_key = Zeroizing::new(req.api_key);
    // 先确认记录存在、属于自己（按它的厂商检查新 key），再加密。
    let mut t = s.db.tenant(who.user).await?;
    let current = t.credential(id).await?;
    t.rollback().await?;
    check_key(&current.vendor, &api_key)?;
    let sealed = seal(&s, who.user, id, &SecretString::from(api_key.to_string())).await?;
    let mut t = s.db.tenant(who.user).await?;
    t.replace_credential_secret(id, &sealed.ciphertext, &sealed.last4)
        .await?;
    t.audit(
        &who.actor(),
        "credential.rotate",
        Some(&id.to_string()),
        &json!({ "last4": sealed.last4 }),
    )
    .await?;
    t.wake_waiting_runs(RunState::WaitingQuota).await?;
    let cred = t.credential(id).await?;
    t.commit().await?;
    Ok(Json(cred))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: CredentialId = parse_id(&id, "credential")?;
    let mut t = s.db.tenant(who.user).await?;
    t.delete_credential(id).await?;
    t.audit(
        &who.actor(),
        "credential.delete",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
