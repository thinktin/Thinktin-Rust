//! 密码保险箱（9.11）：条目的增删改查、agent 发起的填写请求。
//!
//! 账号和密码用用户自己的 DEK 加密，库里只有密文；响应里从不出现密码，账号只在详情里返回。
//! 增删改都记审计（不含明文）。agent 只知道名字：用沙箱里的 `thinktin-vault` 按名字把值注入命令，
//! 模型网关转发前、运行日志落盘前把这些值抹掉。

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use keyvault::VaultSecret;
use proto::domain::{
    InstanceId, RunSource, UserId, VaultItem, VaultItemId, VaultRequest, VaultRequestId,
    VaultRequestStatus, valid_vault_name,
};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{NewRun, NewVaultItem, Tenant, Tx, VaultItemChange};
use zeroize::Zeroizing;

use super::runs::ensure_instance_grant;
use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

/// 每个用户最多存这么多条。
const MAX_ITEMS: u64 = 200;
/// 一条最多给这么多个实例用。
const MAX_INSTANCES: usize = 50;
/// 比这短的密码没法可靠地从对话和日志里抹掉（会误伤正常文字）。
pub const MIN_PASSWORD_LEN: usize = 4;

fn check_text(field: &str, v: &str, max: usize) -> ApiResult<()> {
    check_len(field, v, 0, max)?;
    if v.chars().any(char::is_control) {
        return Err(ApiError::invalid(format!(
            "{field} must not contain control characters"
        )));
    }
    Ok(())
}

fn check_name(name: &str) -> ApiResult<()> {
    if !valid_vault_name(name) {
        return Err(ApiError::invalid(
            "name must be 1-64 lowercase letters, digits, _ or -, starting with a letter or digit",
        ));
    }
    Ok(())
}

fn check_password(password: &str) -> ApiResult<()> {
    if password.chars().count() < MIN_PASSWORD_LEN || password.len() > 4096 {
        return Err(ApiError::invalid(format!(
            "password must be {MIN_PASSWORD_LEN} characters to 4096 bytes"
        )));
    }
    if password.chars().any(char::is_control) {
        return Err(ApiError::invalid(
            "password must not contain control characters",
        ));
    }
    Ok(())
}

fn check_instances(ids: &[InstanceId]) -> ApiResult<Vec<InstanceId>> {
    if ids.len() > MAX_INSTANCES {
        return Err(ApiError::invalid(format!(
            "at most {MAX_INSTANCES} instance_ids"
        )));
    }
    let mut out = ids.to_vec();
    out.sort();
    out.dedup();
    Ok(out)
}

/// 用用户的 DEK 加密账号和密码。用户还没有 DEK 就生成一个。
async fn seal(
    s: &AppState,
    user: UserId,
    item: VaultItemId,
    secret: &VaultSecret,
) -> ApiResult<Vec<u8>> {
    let vault = orchestrator::artifacts::user_vault(&s.db, s.kms.clone(), user, true)
        .await
        .map_err(ApiError::internal)?;
    vault
        .seal_vault(&user.to_string(), &item.to_string(), secret)
        .map_err(ApiError::internal)
}

async fn open(
    s: &AppState,
    user: UserId,
    item: VaultItemId,
    sealed: &[u8],
) -> ApiResult<VaultSecret> {
    let vault = orchestrator::artifacts::user_vault(&s.db, s.kms.clone(), user, false)
        .await
        .map_err(ApiError::internal)?;
    vault
        .open_vault(&user.to_string(), &item.to_string(), sealed)
        .map_err(ApiError::internal)
}

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let items = t.vault_items().await?;
    t.rollback().await?;
    Ok(Json(json!({ "items": items })))
}

#[derive(Deserialize)]
pub struct CreateReq {
    name: String,
    #[serde(default)]
    purpose: String,
    #[serde(default)]
    username: String,
    password: String,
    #[serde(default)]
    instance_ids: Vec<InstanceId>,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<CreateReq>,
) -> ApiResult<(StatusCode, Json<VaultItem>)> {
    let secret = VaultSecret {
        username: req.username,
        password: req.password,
    };
    check_name(&req.name)?;
    check_text("purpose", &req.purpose, 200)?;
    check_text("username", &secret.username, 256)?;
    check_password(&secret.password)?;
    let instance_ids = check_instances(&req.instance_ids)?;
    let mut t = s.db.tenant(who.user).await?;
    if t.vault_item_count().await? >= MAX_ITEMS {
        return Err(ApiError::invalid(format!(
            "the vault holds at most {MAX_ITEMS} items"
        )));
    }
    t.rollback().await?;
    let id = VaultItemId::new();
    let sealed = seal(&s, who.user, id, &secret).await?;
    let mut t = s.db.tenant(who.user).await?;
    let item = t
        .create_vault_item(&NewVaultItem {
            id,
            name: req.name,
            purpose: req.purpose.trim().into(),
            sealed,
            has_username: !secret.username.is_empty(),
            instance_ids,
        })
        .await?;
    t.audit(
        &who.actor(),
        "vault.create",
        Some(&item.id.to_string()),
        &json!({ "name": item.name }),
    )
    .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(item)))
}

/// 详情：条目加上账号（解密后返回）。密码永远不返回。
pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: VaultItemId = parse_id(&id, "vault item")?;
    let mut t = s.db.tenant(who.user).await?;
    let found = t.sealed_vault_item(id).await?;
    t.rollback().await?;
    let secret = open(&s, who.user, id, &found.sealed).await?;
    let mut v = serde_json::to_value(&found.item).map_err(ApiError::internal)?;
    v["username"] = json!(secret.username);
    Ok(Json(v))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    purpose: Option<String>,
    username: Option<String>,
    password: Option<String>,
    instance_ids: Option<Vec<InstanceId>>,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<VaultItem>> {
    let id: VaultItemId = parse_id(&id, "vault item")?;
    let username = req.username.map(Zeroizing::new);
    let password = req.password.map(Zeroizing::new);
    if let Some(p) = &req.purpose {
        check_text("purpose", p, 200)?;
    }
    if let Some(u) = &username {
        check_text("username", u, 256)?;
    }
    if let Some(p) = &password {
        check_password(p)?;
    }
    let instance_ids = req
        .instance_ids
        .as_deref()
        .map(check_instances)
        .transpose()?;
    let mut t = s.db.tenant(who.user).await?;
    let found = t.sealed_vault_item(id).await?;
    t.rollback().await?;
    let sealed = if username.is_some() || password.is_some() {
        let mut secret = open(&s, who.user, id, &found.sealed).await?;
        if let Some(u) = &username {
            secret.username = u.as_str().to_owned();
        }
        if let Some(p) = &password {
            secret.password = p.as_str().to_owned();
        }
        let has_username = !secret.username.is_empty();
        Some((seal(&s, who.user, id, &secret).await?, has_username))
    } else {
        None
    };
    let secret_changed = sealed.is_some();
    let mut t = s.db.tenant(who.user).await?;
    let item = t
        .update_vault_item(
            id,
            &VaultItemChange {
                purpose: req.purpose.map(|p| p.trim().to_owned()),
                instance_ids,
                sealed,
            },
        )
        .await?;
    t.audit(
        &who.actor(),
        "vault.update",
        Some(&id.to_string()),
        &json!({ "name": item.name, "secret_changed": secret_changed }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(item))
}

pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: VaultItemId = parse_id(&id, "vault item")?;
    let mut t = s.db.tenant(who.user).await?;
    let found = t.sealed_vault_item(id).await?;
    t.delete_vault_item(id).await?;
    t.audit(
        &who.actor(),
        "vault.delete",
        Some(&id.to_string()),
        &json!({ "name": found.item.name }),
    )
    .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------- agent 发起的填写请求 ----------

#[derive(Deserialize)]
pub struct RequestsQuery {
    /// 带上已经处理过的（默认只要还在等的）。
    #[serde(default)]
    all: bool,
}

pub async fn requests(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<RequestsQuery>,
) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let list = t.vault_requests(!q.all).await?;
    t.rollback().await?;
    Ok(Json(json!({ "requests": list })))
}

#[derive(Deserialize)]
pub struct FulfillReq {
    #[serde(default)]
    username: String,
    password: String,
    /// 用途，不给就用 agent 写的。
    purpose: Option<String>,
}

/// 用户按 agent 的请求填好账号密码：存进保险箱（同名的已经有了就更新它的账号密码，并允许发起请求的实例使用），
/// 请求标记为已完成。发起请求的那次运行已经结束时，在实例上接着跑一轮，告诉 agent 可以用了。
pub async fn fulfill(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<FulfillReq>,
) -> ApiResult<Json<VaultRequest>> {
    let id: VaultRequestId = parse_id(&id, "vault request")?;
    let secret = VaultSecret {
        username: req.username,
        password: req.password,
    };
    check_text("username", &secret.username, 256)?;
    check_password(&secret.password)?;
    if let Some(p) = &req.purpose {
        check_text("purpose", p, 200)?;
    }
    let mut t = s.db.tenant(who.user).await?;
    let request = t.vault_request(id).await?;
    if request.status != VaultRequestStatus::Pending {
        return Err(ApiError::conflict(format!(
            "the request is already {}",
            request.status
        )));
    }
    let existing = match t.sealed_vault_item_named(&request.name).await {
        Ok(found) => Some(found.item),
        Err(store::Error::NotFound) => None,
        Err(e) => return Err(e.into()),
    };
    if existing.is_none() && t.vault_item_count().await? >= MAX_ITEMS {
        return Err(ApiError::invalid(format!(
            "the vault holds at most {MAX_ITEMS} items"
        )));
    }
    t.rollback().await?;
    let item_id = existing.as_ref().map_or_else(VaultItemId::new, |i| i.id);
    let sealed = seal(&s, who.user, item_id, &secret).await?;
    let has_username = !secret.username.is_empty();
    let purpose = req
        .purpose
        .map(|p| p.trim().to_owned())
        .unwrap_or_else(|| request.purpose.clone());
    let mut t = s.db.tenant(who.user).await?;
    let item = match existing {
        Some(old) => {
            let mut instance_ids = old.instance_ids.clone();
            if !instance_ids.is_empty() && !instance_ids.contains(&request.instance_id) {
                instance_ids.push(request.instance_id);
            }
            t.update_vault_item(
                old.id,
                &VaultItemChange {
                    purpose: Some(purpose),
                    instance_ids: Some(instance_ids),
                    sealed: Some((sealed, has_username)),
                },
            )
            .await?
        }
        None => {
            t.create_vault_item(&NewVaultItem {
                id: item_id,
                name: request.name.clone(),
                purpose,
                sealed,
                has_username,
                instance_ids: vec![request.instance_id],
            })
            .await?
        }
    };
    let done = t.resolve_vault_request(id, Some(item.id)).await?;
    t.append_event(
        request.instance_id,
        request.run_id,
        "vault.fulfilled",
        &json!({ "request_id": id, "name": item.name }),
    )
    .await?;
    resume_after_request(&s, &mut t, &who, &done, &item.name).await?;
    t.audit(
        &who.actor(),
        "vault.request.fulfill",
        Some(&id.to_string()),
        &json!({ "name": item.name, "item": item.id }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(done))
}

/// 发起请求的运行已经结束（或者没有运行）时，在实例上接着跑一轮。运行还在跑就不用：agent 自己能查到。
async fn resume_after_request(
    s: &AppState,
    t: &mut Tx<Tenant>,
    who: &auth::service::Principal,
    request: &VaultRequest,
    name: &str,
) -> ApiResult<()> {
    if let Some(run) = request.run_id
        && !t.run(run).await?.state.is_terminal()
    {
        return Ok(());
    }
    let instance = match t.instance(request.instance_id).await {
        Ok(i) => i,
        Err(store::Error::NotFound) => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    ensure_instance_grant(s, t, who, instance.id).await?;
    let prompt = format!(
        "（系统消息）用户已经把你请求的「{name}」存进了密码保险箱。需要时用 thinktin-vault 按名字引用，\
         比如 `thinktin-vault exec --env PASSWORD={name}.password -- <命令>`，或者在命令参数里写 \
         `{{{{{name}.password}}}}`；不要把值打印出来。继续刚才的任务。"
    );
    t.create_run(&NewRun::new(
        instance.id,
        RunSource::User,
        prompt,
        instance.agent_version,
    ))
    .await?;
    Ok(())
}

pub async fn decline(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<VaultRequest>> {
    let id: VaultRequestId = parse_id(&id, "vault request")?;
    let mut t = s.db.tenant(who.user).await?;
    let done = t.resolve_vault_request(id, None).await?;
    t.append_event(
        done.instance_id,
        done.run_id,
        "vault.declined",
        &json!({ "request_id": id, "name": done.name }),
    )
    .await?;
    t.audit(
        &who.actor(),
        "vault.request.decline",
        Some(&id.to_string()),
        &json!({ "name": done.name }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(done))
}
