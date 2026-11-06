//! 实例：领养、列表、改名字和用途说明、交流开关、删除、模型别名。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use proto::domain::{
    EgressDecision, EgressMode, EgressRequest, EgressRequestId, Instance, InstanceId,
    MAX_INSTANCE_PURPOSE_CHARS, ModelRoute, RunState,
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
    // 专属于项目的 botin 不让别的 agent 查、问（8.16：别人的私事进不了项目的工作区；库里的检查兜底）。
    if req.peer_access == Some(true) && before.dedicated_project_id.is_some() {
        return Err(store::Error::InstanceDedicated.into());
    }
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

/// 把专属于项目的 botin 放回私人（8.16）：先在项目里撤下它。换全新的私人工作区（项目的记忆、文件清空），以后又能接
/// 私人任务（私人任务的授权下次发任务时重新签发）。不是专属的 422；还在项目里、还有没结束的运行 409；找不到 404。
pub async fn release(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Instance>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let instance =
        orchestrator::projects::release_instance(&s.db, who.user, &who.actor(), id).await?;
    Ok(Json(instance))
}

#[derive(Deserialize)]
pub struct EgressQuery {
    /// 最近被拒绝的最多列几条。
    limit: Option<u32>,
}

/// 实例的出网情况（2.7）：档位、用户一直允许的网站、默认就能上的搜索和开发网站、今天用了多少、在等用户回答的
/// 网站，最近被拒绝的访问（App 里让用户看 agent 想上哪些网站没上成）。
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
    let pending = t
        .egress_requests(Some(id), true, proto::egress::MAX_PENDING_ASKS * 4)
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
        "search_hosts": proto::egress::SEARCH_HOSTS,
        "pending": pending,
        "used_today": used,
        "daily_limit": proto::egress::DAILY_BYTES,
        "max_tunnels": proto::egress::MAX_TUNNELS,
        "recent_denied": denied,
    })))
}

/// 从“一直允许”的网站里删掉一个（2.7，App 的设置里用；不要用 PATCH 传整个列表，免得冲掉同时点的“一直允许”）。
/// 已经开着的这个网站的连接开到任务结束。记审计。
pub async fn remove_egress_host(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path((id, host)): Path<(String, String)>,
) -> ApiResult<Json<Instance>> {
    let id: InstanceId = parse_id(&id, "instance")?;
    let host = proto::egress::normalize_host(host.trim(), false)
        .map_err(|e| crate::ApiError::invalid(format!("host: {e}")))?;
    let mut t = s.db.tenant(who.user).await?;
    let instance = t.remove_egress_host(id, &host).await?;
    t.audit(
        &who.actor(),
        "instance.egress",
        Some(&id.to_string()),
        &json!({ "removed": host }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(instance))
}

#[derive(Deserialize)]
pub struct EgressRequestsQuery {
    /// 只看这个实例的。
    instance_id: Option<String>,
    /// 也列答过、过期了的（默认只列还在等的）。
    #[serde(default)]
    all: bool,
    limit: Option<u32>,
}

/// agent 想访问、要用户回答的网站（2.7），新的在前。默认只列还在等的。
pub async fn egress_requests(
    State(s): State<AppState>,
    Authed(who): Authed,
    axum::extract::Query(q): axum::extract::Query<EgressRequestsQuery>,
) -> ApiResult<Json<Value>> {
    let instance = q
        .instance_id
        .as_deref()
        .map(|i| parse_id::<InstanceId>(i, "instance"))
        .transpose()?;
    let mut t = s.db.tenant(who.user).await?;
    let requests = t
        .egress_requests(instance, !q.all, q.limit.unwrap_or(50).clamp(1, 200))
        .await?;
    t.rollback().await?;
    Ok(Json(json!({ "requests": requests })))
}

#[derive(Deserialize)]
pub struct DecideEgressReq {
    decision: EgressDecision,
}

/// 回答一条在等的请求（2.7）：`once` 这次任务里能访问，`always` 以后都能（记进实例的网站），`deny` 这次任务里
/// 不再问。已经答过、过期了的返回冲突；一直允许的网站满了返回参数错误。记审计。
pub async fn decide_egress_request(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<DecideEgressReq>,
) -> ApiResult<Json<EgressRequest>> {
    let id: EgressRequestId = parse_id(&id, "egress request")?;
    let mut t = s.db.tenant(who.user).await?;
    let decided = t.decide_egress_request(id, req.decision).await?;
    t.audit(
        &who.actor(),
        "egress.decide",
        Some(&id.to_string()),
        &json!({
            "instance_id": decided.instance_id,
            "host": decided.host,
            "decision": req.decision,
        }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(decided))
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
    // 先拿它所在项目的锁（改实例行之前），和往项目里加 agent 排队。
    t.lock_instance_projects(id).await?;
    // 再锁它的出网请求（还是在改实例行之前）：放回私人、标专属、用户回答出网请求都是先请求后实例（8.16）。
    t.lock_instance_egress_requests(id).await?;
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
    // 共享项目里的 agent 行租户改不了：提交以后由 worker 撤下（失败了后台维护兜底）。
    if let Err(e) = orchestrator::projects::retire_deleted_instance(&s.db, who.user, id).await {
        tracing::warn!(instance = %id, error = %e, "could not retire the deleted instance from its projects");
    }
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
