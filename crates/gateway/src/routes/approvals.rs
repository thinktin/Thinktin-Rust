//! 审批：待我决定的请求、查一条、做决定（执行器轮询到决定后转给 agent）。

use axum::Json;
use axum::extract::{Path, State};
use proto::domain::{Approval, ApprovalId};
use serde::Deserialize;
use serde_json::{Value, json};

use super::parse_id;
use crate::{ApiJson, ApiResult, AppState, Authed};

pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let approvals = t.pending_approvals().await?;
    t.rollback().await?;
    Ok(Json(json!({ "approvals": approvals })))
}

/// 一条审批，什么状态都行：点审批推送、收件箱条目进来时先查，已处理、已过期的给提示，不要报错。
pub async fn get(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<Approval>> {
    let id: ApprovalId = parse_id(&id, "approval")?;
    let mut t = s.db.tenant(who.user).await?;
    let approval = t.approval(id).await?;
    t.rollback().await?;
    Ok(Json(approval))
}

#[derive(Deserialize)]
pub struct DecideReq {
    option_id: String,
}

pub async fn decide(
    State(s): State<AppState>,
    Authed(who): Authed,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<DecideReq>,
) -> ApiResult<Json<Approval>> {
    let id: ApprovalId = parse_id(&id, "approval")?;
    let mut t = s.db.tenant(who.user).await?;
    let approval = t.decide_approval(id, &req.option_id, who.device).await?;
    t.append_event(
        approval.instance_id,
        Some(approval.run_id),
        "approval.decided",
        &json!({ "approval_id": approval.id, "state": approval.state, "option_id": req.option_id }),
    )
    .await?;
    t.audit(
        &who.actor(),
        "approval.decide",
        Some(&id.to_string()),
        &json!({ "state": approval.state }),
    )
    .await?;
    t.commit().await?;
    Ok(Json(approval))
}
