//! 用量看板（9.10）：按天、实例、模型或 key 汇总自己的模型用量，数据来自模型网关的计量。

use axum::Json;
use axum::extract::{Query, State};
use chrono::{DateTime, Duration, Utc};
use proto::domain::{CredentialId, InstanceId};
use serde::Deserialize;
use serde_json::{Value, json};
use store::{UsageBucket, UsageFilter, UsageGroup};

use super::parse_id;
use crate::{ApiError, ApiResult, AppState, Authed};

/// 一次最多查多长时间。
const MAX_RANGE_DAYS: i64 = 366;

#[derive(Deserialize)]
pub struct UsageQuery {
    /// day（默认）/ instance / model / credential
    group: Option<String>,
    from: Option<DateTime<Utc>>,
    to: Option<DateTime<Utc>>,
    /// 按天分组时用的时区（IANA 名称），默认 Asia/Shanghai。
    tz: Option<String>,
    instance_id: Option<String>,
    credential_id: Option<String>,
}

pub async fn summary(
    State(s): State<AppState>,
    Authed(who): Authed,
    Query(q): Query<UsageQuery>,
) -> ApiResult<Json<Value>> {
    let group = match q.group.as_deref().unwrap_or("day") {
        "day" => UsageGroup::Day,
        "instance" => UsageGroup::Instance,
        "model" => UsageGroup::Model,
        "credential" => UsageGroup::Credential,
        other => return Err(ApiError::invalid(format!("unknown group {other}"))),
    };
    let tz = q.tz.unwrap_or_else(|| "Asia/Shanghai".into());
    if tz.parse::<chrono_tz::Tz>().is_err() {
        return Err(ApiError::invalid(format!("unknown time zone {tz}")));
    }
    let to = q.to.unwrap_or_else(Utc::now);
    let from = q.from.unwrap_or(to - Duration::days(30));
    if from >= to || to - from > Duration::days(MAX_RANGE_DAYS) {
        return Err(ApiError::invalid(format!(
            "from must be before to, at most {MAX_RANGE_DAYS} days apart"
        )));
    }
    let filter = UsageFilter {
        from: Some(from),
        to: Some(to),
        instance: q
            .instance_id
            .as_deref()
            .map(|i| parse_id::<InstanceId>(i, "instance"))
            .transpose()?,
        credential: q
            .credential_id
            .as_deref()
            .map(|c| parse_id::<CredentialId>(c, "credential"))
            .transpose()?,
    };
    let mut t = s.db.tenant(who.user).await?;
    let buckets = t.usage_summary(group, &filter, &tz).await?;
    t.rollback().await?;
    let total = buckets.iter().fold(
        UsageBucket {
            key: "total".into(),
            ..UsageBucket::default()
        },
        |mut acc, b| {
            acc.requests += b.requests;
            acc.input_tokens += b.input_tokens;
            acc.cache_read_tokens += b.cache_read_tokens;
            acc.cache_write_tokens += b.cache_write_tokens;
            acc.output_tokens += b.output_tokens;
            acc.charged_tokens += b.charged_tokens;
            acc.estimated_requests += b.estimated_requests;
            acc.failed_requests += b.failed_requests;
            acc
        },
    );
    Ok(Json(json!({
        "from": from,
        "to": to,
        "buckets": buckets,
        "total": total,
    })))
}
