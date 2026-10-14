//! 实例：领养、列表、改名、删除、模型别名。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use proto::domain::{GrantScope, Instance, InstanceId, ModelRoute};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{check_len, parse_id};
use crate::{ApiJson, ApiResult, AppState, Authed};

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let instances = t.instances().await?;
    t.rollback().await?;
    Ok(Json(json!({ "instances": instances })))
}

#[derive(Deserialize)]
pub struct AdoptReq {
    agent_id: String,
    harness: Option<String>,
    name: String,
}

/// 领养：建实例，并签发它的运行授权（用户直接下的任务用它；和登录会话无关）。
pub async fn adopt(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<AdoptReq>,
) -> ApiResult<(StatusCode, Json<Instance>)> {
    let instance = control::adopt(
        &s.db,
        s.templates.as_ref(),
        who.user,
        &who.actor(),
        &req.agent_id,
        req.harness.as_deref(),
        &req.name,
    )
    .await?;
    let mut t = s.db.tenant(who.user).await?;
    let scope = GrantScope {
        platform_tools: s.cfg.default_platform_tools.clone(),
        ..GrantScope::default()
    };
    t.create_run_grant(instance.id, None, &scope, s.cfg.grant_ttl)
        .await?;
    t.commit().await?;
    Ok((StatusCode::CREATED, Json(instance)))
}

pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Instance>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    let instance = t.instance(id).await?;
    t.rollback().await?;
    Ok(Json(instance))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    name: String,
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<Instance>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    check_len("name", req.name.trim(), 1, 64)?;
    let mut t = s.db.tenant(who.user).await?;
    t.rename_instance(id, req.name.trim()).await?;
    let instance = t.instance(id).await?;
    t.commit().await?;
    Ok(Json(instance))
}

#[derive(Deserialize)]
pub struct VersionReq {
    /// 不给就是当前上架的版本（升级）；给旧版本就是回滚。
    version: Option<String>,
}

/// 换模板版本（6.7）：下次唤醒时按新版本重建沙箱，工作区保留。正在跑的任务不受影响。
pub async fn set_version(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<VersionReq>,
) -> ApiResult<(StatusCode, Json<Instance>)> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    let cur = t.instance(id).await?;
    let version = match req.version {
        Some(v) => v,
        None => s
            .templates
            .current(&cur.agent_id)
            .map(|m| m.agent.version)
            .ok_or_else(|| crate::ApiError::invalid("this agent is no longer offered"))?,
    };
    if s.templates.manifest(&cur.agent_id, &version).is_none() {
        return Err(crate::ApiError::invalid(format!(
            "version {version} of {} is not available",
            cur.agent_id
        )));
    }
    let instance = t.request_instance_version(id, &version).await?;
    t.audit(
        &who.actor(),
        "instance.version",
        Some(&id.to_string()),
        &json!({ "from": cur.agent_version, "to": version }),
    )
    .await?;
    t.commit().await?;
    Ok((StatusCode::ACCEPTED, Json(instance)))
}

/// 删除：取消没结束的运行、吊销授权、标记删除；沙箱和工作区卷由后台回收。
pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    t.instance(id).await?;
    t.cancel_instance_runs(id, "instance deleted").await?;
    t.revoke_instance_grants(id, "instance deleted").await?;
    t.delete_instance(id).await?;
    t.audit(
        &who.actor(),
        "instance.delete",
        Some(&id.to_string()),
        &json!({}),
    )
    .await?;
    t.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn routes(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    let routes = t.model_routes(id).await?;
    t.rollback().await?;
    Ok(Json(json!({ "routes": routes })))
}

#[derive(Deserialize)]
pub struct RoutesReq {
    routes: Vec<ModelRoute>,
}

/// 整体替换模型别名。第一个是默认模型，名为 fast 的用于轻量任务。
pub async fn set_routes(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<RoutesReq>,
) -> ApiResult<Json<Value>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    if req.routes.len() > 16 {
        return Err(crate::ApiError::invalid("at most 16 model aliases"));
    }
    for r in &req.routes {
        check_len("upstream_model", &r.upstream_model, 1, 128)?;
    }
    let mut t = s.db.tenant(who.user).await?;
    t.set_model_routes(id, &req.routes).await?;
    t.audit(
        &who.actor(),
        "instance.routes",
        Some(&id.to_string()),
        &json!({ "aliases": req.routes.iter().map(|r| &r.alias).collect::<Vec<_>>() }),
    )
    .await?;
    let routes = t.model_routes(id).await?;
    t.commit().await?;
    Ok(Json(json!({ "routes": routes })))
}
