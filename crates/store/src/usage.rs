//! 模型网关的用量记录（5.7、9.4）：每个请求一行，计费 token 是预算护栏和日限额的依据。

use chrono::{DateTime, Utc};
use proto::domain::{CredentialId, GrantId, InstanceId, UserId};
use serde::Serialize;
use uuid::Uuid;

use crate::{Result, Tenant, Tx, signed, unsigned};

#[derive(Debug, Clone, Default)]
pub struct NewUsage {
    pub user: UserId,
    pub instance: InstanceId,
    pub run_grant: Option<GrantId>,
    pub credential: Option<CredentialId>,
    pub alias: String,
    pub vendor: String,
    pub upstream_model: String,
    pub endpoint: String,
    pub stream: bool,
    pub status: u16,
    pub outcome: String,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    /// 计费 token（拿不到用量时是保守估计）。
    pub charged_tokens: u64,
    pub estimated: bool,
    pub duration_ms: u64,
}

impl<R: crate::Internal> Tx<R> {
    pub async fn insert_usage(&mut self, u: &NewUsage) -> Result<()> {
        sqlx::query(
            "INSERT INTO usage_records (id, user_id, instance_id, run_grant_id, credential_id, alias, vendor, \
               upstream_model, endpoint, stream, status, outcome, input_tokens, cache_read_tokens, \
               cache_write_tokens, output_tokens, charged_tokens, estimated, duration_ms) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)",
        )
        .bind(Uuid::now_v7())
        .bind(u.user.0)
        .bind(u.instance.0)
        .bind(u.run_grant.map(|g| g.0))
        .bind(u.credential.map(|c| c.0))
        .bind(&u.alias)
        .bind(&u.vendor)
        .bind(&u.upstream_model)
        .bind(&u.endpoint)
        .bind(u.stream)
        .bind(i32::from(u.status))
        .bind(&u.outcome)
        .bind(signed(u.input_tokens, "input_tokens")?)
        .bind(signed(u.cache_read_tokens, "cache_read_tokens")?)
        .bind(signed(u.cache_write_tokens, "cache_write_tokens")?)
        .bind(signed(u.output_tokens, "output_tokens")?)
        .bind(signed(u.charged_tokens, "charged_tokens")?)
        .bind(u.estimated)
        .bind(signed(u.duration_ms, "duration_ms")?)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}

/// 用量看板（9.10）按什么分组。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsageGroup {
    /// 按天（用户的时区）。
    Day,
    Instance,
    /// 按厂商和上游模型。
    Model,
    Credential,
}

#[derive(Debug, Clone, Default)]
pub struct UsageFilter {
    pub from: Option<DateTime<Utc>>,
    pub to: Option<DateTime<Utc>>,
    pub instance: Option<InstanceId>,
    pub credential: Option<CredentialId>,
}

/// 一组的汇总。`key` 按分组是日期（YYYY-MM-DD）、实例 id、`厂商/模型` 或 key 的 id。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct UsageBucket {
    pub key: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    pub charged_tokens: u64,
    /// 有多少次请求的用量是估算的（厂商没报）。
    pub estimated_requests: u64,
    /// 厂商返回错误或连不上的请求数。
    pub failed_requests: u64,
}

type BucketRow = (String, i64, i64, i64, i64, i64, i64, i64, i64);

impl Tx<Tenant> {
    /// 汇总自己的用量。`tz` 是 IANA 时区名（按天分组时用），调用方先校验。
    pub async fn usage_summary(
        &mut self,
        group: UsageGroup,
        filter: &UsageFilter,
        tz: &str,
    ) -> Result<Vec<UsageBucket>> {
        let key = match group {
            UsageGroup::Day => "to_char((created_at AT TIME ZONE $5)::date, 'YYYY-MM-DD')",
            UsageGroup::Instance => "instance_id::text",
            UsageGroup::Model => "vendor || '/' || upstream_model",
            UsageGroup::Credential => "coalesce(credential_id::text, '')",
        };
        let sql = format!(
            "SELECT {key} AS k, count(*), coalesce(sum(input_tokens), 0)::bigint, \
               coalesce(sum(cache_read_tokens), 0)::bigint, coalesce(sum(cache_write_tokens), 0)::bigint, \
               coalesce(sum(output_tokens), 0)::bigint, coalesce(sum(charged_tokens), 0)::bigint, \
               count(*) FILTER (WHERE estimated), count(*) FILTER (WHERE outcome <> 'complete') \
             FROM usage_records \
             WHERE ($1::timestamptz IS NULL OR created_at >= $1) AND ($2::timestamptz IS NULL OR created_at < $2) \
               AND ($3::uuid IS NULL OR instance_id = $3) AND ($4::uuid IS NULL OR credential_id = $4) \
               AND $5::text IS NOT NULL \
             GROUP BY k ORDER BY k"
        );
        let rows: Vec<BucketRow> = sqlx::query_as(sqlx::AssertSqlSafe(sql))
            .bind(filter.from)
            .bind(filter.to)
            .bind(filter.instance.map(|i| i.0))
            .bind(filter.credential.map(|c| c.0))
            .bind(tz)
            .fetch_all(self.conn())
            .await?;
        rows.into_iter()
            .map(|(key, n, input, cr, cw, output, charged, est, failed)| {
                Ok(UsageBucket {
                    key,
                    requests: unsigned(n, "requests")?,
                    input_tokens: unsigned(input, "input tokens")?,
                    cache_read_tokens: unsigned(cr, "cache read tokens")?,
                    cache_write_tokens: unsigned(cw, "cache write tokens")?,
                    output_tokens: unsigned(output, "output tokens")?,
                    charged_tokens: unsigned(charged, "charged tokens")?,
                    estimated_requests: unsigned(est, "estimated")?,
                    failed_requests: unsigned(failed, "failed")?,
                })
            })
            .collect()
    }
}
