//! 内容举报（5.5）：用户举报 agent 的输出（运行的回复、其中一条事件、一个产出物）。
//!
//! 被举报的那一条内容在提交时复制下来，进运营的待处理队列（`thinktin-server admin reports`），处理结果发给
//! 举报的人。同一条内容再举报一次返回那一条待处理的举报。

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use proto::domain::{ArtifactId, ContentReport, ReportReason, RunId};
use serde::Deserialize;
use serde_json::{Value, json};
use store::NewReport;

use super::{check_len, parse_id};
use crate::{ApiError, ApiJson, ApiResult, AppState, Authed};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReportReq {
    run_id: String,
    #[serde(default)]
    event_seq: Option<u64>,
    #[serde(default)]
    artifact_id: Option<String>,
    reason: String,
    #[serde(default)]
    note: Option<String>,
}

pub async fn create(
    State(s): State<AppState>,
    Authed(who): Authed,
    ApiJson(req): ApiJson<ReportReq>,
) -> ApiResult<(StatusCode, Json<ContentReport>)> {
    let run: RunId = parse_id(&req.run_id, "run")?;
    let artifact: Option<ArtifactId> = req
        .artifact_id
        .as_deref()
        .map(|a| parse_id(a, "artifact"))
        .transpose()?;
    let reason: ReportReason = req.reason.parse().map_err(|_| {
        ApiError::invalid(format!(
            "reason must be one of {}",
            ReportReason::ALL
                .iter()
                .map(|r| r.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ))
    })?;
    let note = req
        .note
        .map(|n| n.trim().to_owned())
        .filter(|n| !n.is_empty());
    if let Some(n) = &note {
        check_len("note", n, 1, 1000)?;
    }
    s.limits().reports(who.user)?;
    let mut t = s.db.tenant(who.user).await?;
    let (report, created) = t
        .create_report(&NewReport {
            run_id: run,
            event_seq: req.event_seq,
            artifact_id: artifact,
            reason,
            note,
        })
        .await?;
    if created {
        t.audit(
            &who.actor(),
            "content.reported",
            Some(&report.id.to_string()),
            &json!({
                "reason": reason.as_str(),
                "run_id": run.to_string(),
                "event_seq": report.event_seq,
                "artifact_id": report.artifact_id.map(|a| a.to_string()),
            }),
        )
        .await?;
    }
    t.commit().await?;
    if created {
        // 待处理的条数和最早一条等了多久由后台报指标（`thinktin_content_reports_open`）。
        tracing::warn!(report = %report.id, reason = reason.as_str(), "content reported");
    }
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(report)))
}

/// 自己的举报和处理结果，新的在前（最多 100 条）。
pub async fn list(State(s): State<AppState>, Authed(who): Authed) -> ApiResult<Json<Value>> {
    let mut t = s.db.tenant(who.user).await?;
    let reports = t.reports(100).await?;
    t.rollback().await?;
    Ok(Json(json!({ "reports": reports })))
}
