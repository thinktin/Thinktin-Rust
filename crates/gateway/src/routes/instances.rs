//! 实例：领养、列表、改名字和用途说明、交流开关、删除、模型别名。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use proto::domain::{
    EgressMode, Instance, InstanceId, MAX_INSTANCE_PURPOSE_CHARS, ModelRoute, RunState,
};
use serde::Deserialize;
use serde_json::{Value, json};
use store::InstanceChange;

use super::{check_len, default_scope, parse_id};
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

/// 领养：建实例，并签发它的运行授权（用户直接下的任务用它；和登录会话无关）。实例数到了账号的上限
/// （`[api.limits] instances_per_user`）报 409 `instance_limit`。
pub async fn adopt(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<AdoptReq>,
) -> ApiResult<(StatusCode, Json<Instance>)> {
    let instance = control::adopt_capped(
        &s.db,
        s.templates.as_ref(),
        who.user,
        &who.actor(),
        control::AdoptSpec {
            agent_id: &req.agent_id,
            harness: req.harness.as_deref(),
            name: &req.name,
        },
        u64::from(s.limits().config().instances_per_user),
    )
    .await?;
    let mut t = s.db.tenant(who.user).await?;
    t.create_run_grant(instance.id, None, &default_scope(&s), s.cfg.grant_ttl)
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

/// 改实例：给了才改。
#[derive(Deserialize)]
pub struct UpdateReq {
    name: Option<String>,
    /// 用途说明（8.9），空串清掉。
    purpose: Option<String>,
    /// “允许其他 agent 查我、问我”（8.9）。
    peer_access: Option<bool>,
    /// 能上哪些网站（2.7）：档位和用户加的网站一起改。
    egress: Option<EgressReq>,
}

#[derive(Deserialize)]
pub struct EgressReq {
    mode: EgressMode,
    #[serde(default)]
    hosts: Vec<String>,
    /// 打开“全部公网”时 App 先提示风险，用户确认了才带上 true（用户 2026-11-04 定）。
    #[serde(default)]
    accept_risk: bool,
}

/// 整理、检查用户加的网站（去重，按 `proto::egress::normalize_host` 的写法存）。
fn egress_change(req: &EgressReq) -> ApiResult<(EgressMode, Vec<String>)> {
    if req.mode == EgressMode::All && !req.accept_risk {
        return Err(crate::ApiError::invalid(
            "turning on the whole internet needs accept_risk: true (show the user the risks first)",
        ));
    }
    if req.hosts.len() > proto::egress::MAX_HOSTS {
        return Err(crate::ApiError::invalid(format!(
            "at most {} hosts",
            proto::egress::MAX_HOSTS
        )));
    }
    let mut hosts: Vec<String> = Vec::with_capacity(req.hosts.len());
    for raw in &req.hosts {
        let host = proto::egress::normalize_host(raw.trim(), false)
            .map_err(|e| crate::ApiError::invalid(format!("{raw:?}: {e}")))?;
        if !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    if req.mode == EgressMode::Custom && hosts.is_empty() {
        return Err(crate::ApiError::invalid("custom needs at least one host"));
    }
    Ok((req.mode, hosts))
}

pub async fn update(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<UpdateReq>,
) -> ApiResult<Json<Instance>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let name = req.name.as_deref().map(str::trim);
    if let Some(name) = name {
        check_len("name", name, 1, 64)?;
    }
    let purpose = req.purpose.as_deref().map(str::trim);
    if let Some(purpose) = purpose {
        check_len("purpose", purpose, 0, MAX_INSTANCE_PURPOSE_CHARS)?;
        if purpose.chars().any(|c| c.is_control() && c != '\n') {
            return Err(crate::ApiError::invalid(
                "purpose must not contain control characters",
            ));
        }
    }
    let egress = req.egress.as_ref().map(egress_change).transpose()?;
    if name.is_none() && purpose.is_none() && req.peer_access.is_none() && egress.is_none() {
        return Err(crate::ApiError::invalid("nothing to change"));
    }
    let mut t = s.db.tenant(who.user).await?;
    let before = t.instance(id).await?;
    let switched = req.peer_access.filter(|on| *on != before.peer_access);

    // 关了以后别人问它、还没答的问题也不答了（8.11）：提问方拿到“没问成”。先拿提问用的那把锁，同时在建的
    // 提问要么已经提交、这里取消得到，要么等这里提交后再看开关、被拒绝；先锁运行再改实例（和执行器同序）。
    if switched == Some(false) {
        t.lock_run_waits(who.user).await?;
        for run in t
            .cancel_asks_to(id, "the agent stopped taking questions")
            .await?
        {
            t.append_event(
                run.instance_id,
                Some(run.id),
                "run.state",
                &json!({ "state": run.state, "reason": run.state_reason }),
            )
            .await?;
        }
    }
    t.update_instance(
        id,
        &InstanceChange {
            name: name.map(String::from),
            purpose: purpose.map(String::from),
            peer_access: req.peer_access,
            egress: egress.clone(),
        },
    )
    .await?;
    // 出网档位是安全相关的改动（尤其是“全部公网”），请求里带了就记审计（不和改之前的比：两台设备同时改时，
    // 比较用的旧值可能已经过时，会漏记最后生效的那次）。出口代理按它放行，已经开着的隧道最多半分钟后按新档位重新核对。
    if let Some((mode, hosts)) = &egress {
        t.audit(
            &who.actor(),
            "instance.egress",
            Some(&id.to_string()),
            &json!({ "mode": mode, "hosts": hosts }),
        )
        .await?;
    }
    // 关掉交流开关是安全相关的改动（能控制电脑、能用保险箱的实例常常要关），记审计。
    if let Some(on) = switched {
        t.audit(
            &who.actor(),
            "instance.peer_access",
            Some(&id.to_string()),
            &json!({ "on": on }),
        )
        .await?;
    }
    let instance = t.instance(id).await?;
    t.commit().await?;
    Ok(Json(instance))
}

#[derive(Deserialize)]
pub struct EgressQuery {
    /// 最近被拒绝的最多列几条。
    limit: Option<u32>,
}

/// 实例的出网情况（2.7）：档位、加的网站、“开发网站”自带哪些、今天用了多少，最近被拒绝的访问（App 里
/// 让用户看 agent 想上哪些网站没上成，决定要不要放行）。
pub async fn egress(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    axum::extract::Query(q): axum::extract::Query<EgressQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    let instance = t.instance(id).await?;
    let today = (chrono::Utc::now()
        + chrono::Duration::seconds(proto::egress::DAY_UTC_OFFSET_SECS))
    .date_naive();
    let used = t.egress_used(id, today).await?;
    let denied = t
        .egress_log(id, true, q.limit.unwrap_or(20).clamp(1, 100))
        .await?;
    t.rollback().await?;
    let denied: Vec<_> = denied
        .into_iter()
        .map(|e| json!({ "at": e.at, "host": e.host, "port": e.port, "reason": e.reason }))
        .collect();
    Ok(Json(json!({
        "mode": instance.egress_mode,
        "hosts": instance.egress_hosts,
        "dev_hosts": proto::egress::DEV_HOSTS,
        "used_today": used,
        "daily_limit": proto::egress::DAILY_BYTES,
        "max_tunnels": proto::egress::MAX_TUNNELS,
        "recent_denied": denied,
    })))
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

/// 删除：它的计划标记删除（别的实例的流水线有一步在它上面的暂停）、取消没结束的运行、吊销授权、标记删除（别名一起删）；
/// 沙箱和工作区卷由后台回收。先处理计划：正在触发的那一次提交以后，它建的运行接着被取消。
pub async fn delete(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let mut t = s.db.tenant(who.user).await?;
    t.instance(id).await?;
    let retired = t.retire_instance_plans(id).await?;
    t.cancel_instance_runs(id, "instance deleted").await?;
    t.revoke_instance_grants(id, "instance deleted").await?;
    t.delete_instance(id).await?;
    t.audit(
        &who.actor(),
        "instance.delete",
        Some(&id.to_string()),
        &json!({ "plans_deleted": retired.deleted, "plans_paused": retired.paused }),
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
        if r.fallbacks.len() > proto::domain::MAX_ROUTE_FALLBACKS {
            return Err(crate::ApiError::invalid(format!(
                "at most {} fallbacks per model alias",
                proto::domain::MAX_ROUTE_FALLBACKS
            )));
        }
        for f in &r.fallbacks {
            check_len("upstream_model", &f.upstream_model, 1, 128)?;
        }
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
    // 换了 key 或者加了备用 key：等 key 的运行（7.11）马上接着跑。
    t.wake_waiting_runs(RunState::WaitingQuota).await?;
    let routes = t.model_routes(id).await?;
    t.commit().await?;
    Ok(Json(json!({ "routes": routes })))
}
