//! 受控出网通道（WBS 2.7，docs/egress.md）：每个实例每天的流量和访问日志。
//!
//! - 出口代理在模型网关里，用 `thinktin_llmgw` 角色：开隧道前、转发途中先 [`Tx::egress_reserve`] 预留一段再转发，
//!   结束时 [`Tx::egress_refund`] 退回没用完的，多副本同时转发也不会超过每天的上限；每条隧道写一行日志。
//! - App 用业务角色（行级安全）读自己实例今天的用量和最近的日志。
//! - 后台到期删掉旧日志（6 个月）和旧的用量行。

use chrono::{DateTime, NaiveDate, Utc};
use proto::domain::{InstanceId, UserId};
use uuid::Uuid;

use crate::{Llmgw, Result, Tenant, Tx, Worker, signed, unsigned};

/// 一条访问日志：只有元数据，没有路径、令牌和内容。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EgressLogEntry {
    pub user_id: UserId,
    pub instance_id: InstanceId,
    pub at: DateTime<Utc>,
    /// CONNECT 里的网站名（整理过的写法；不合规的原样截短后记下）。
    pub host: String,
    pub port: u16,
    /// 实际连上的地址；没连（被拒绝、解析失败）时为空。
    pub address: Option<String>,
    pub allowed: bool,
    /// 结果：`ok`，或者拒绝、断开的原因（`not_allowed`、`quota`、`private_address`……）。
    pub reason: String,
    pub bytes_up: u64,
    pub bytes_down: u64,
    pub duration_ms: u64,
    /// 这一行合并了几条隧道（超过每分钟的日志上限时合并），平常是 1。
    pub count: u32,
}

#[derive(sqlx::FromRow)]
struct LogRow {
    user_id: Uuid,
    instance_id: Uuid,
    at: DateTime<Utc>,
    host: String,
    port: i32,
    address: Option<String>,
    allowed: bool,
    reason: String,
    bytes_up: i64,
    bytes_down: i64,
    duration_ms: i64,
    count: i32,
}

impl LogRow {
    fn into_entry(self) -> Result<EgressLogEntry> {
        Ok(EgressLogEntry {
            user_id: self.user_id.into(),
            instance_id: self.instance_id.into(),
            at: self.at,
            host: self.host,
            port: u16::try_from(self.port).unwrap_or_default(),
            address: self.address,
            allowed: self.allowed,
            reason: self.reason,
            bytes_up: unsigned(self.bytes_up, "egress bytes")?,
            bytes_down: unsigned(self.bytes_down, "egress bytes")?,
            duration_ms: unsigned(self.duration_ms, "egress duration")?,
            count: u32::try_from(self.count).unwrap_or(1),
        })
    }
}

impl Tx<Llmgw> {
    /// 从实例 `day` 这天的额度里预留最多 `want` 字节，返回实际预留到的（0 表示今天用完了）。和别的副本并发预留时
    /// 按行锁排队，合计不会超过 `limit`。
    pub async fn egress_reserve(
        &mut self,
        instance: InstanceId,
        user: UserId,
        day: NaiveDate,
        want: u64,
        limit: u64,
    ) -> Result<u64> {
        let want = signed(want, "egress reservation")?;
        let limit = signed(limit, "egress limit")?;
        sqlx::query(
            "INSERT INTO egress_usage (instance_id, user_id, day) VALUES ($1, $2, $3) \
             ON CONFLICT (instance_id, day) DO NOTHING",
        )
        .bind(instance.0)
        .bind(user.0)
        .bind(day)
        .execute(self.conn())
        .await?;
        let granted: Option<i64> = sqlx::query_scalar(
            "WITH cur AS (SELECT bytes FROM egress_usage WHERE instance_id = $1 AND day = $2 FOR UPDATE) \
             UPDATE egress_usage e SET bytes = e.bytes + LEAST($3, $4 - cur.bytes) FROM cur \
             WHERE e.instance_id = $1 AND e.day = $2 AND cur.bytes < $4 \
             RETURNING LEAST($3, $4 - cur.bytes)",
        )
        .bind(instance.0)
        .bind(day)
        .bind(want)
        .bind(limit)
        .fetch_optional(self.conn())
        .await?;
        unsigned(granted.unwrap_or(0), "egress reservation")
    }

    /// 退回预留了没用完的字节。
    pub async fn egress_refund(
        &mut self,
        instance: InstanceId,
        day: NaiveDate,
        bytes: u64,
    ) -> Result<()> {
        if bytes == 0 {
            return Ok(());
        }
        sqlx::query(
            "UPDATE egress_usage SET bytes = GREATEST(bytes - $3, 0) WHERE instance_id = $1 AND day = $2",
        )
        .bind(instance.0)
        .bind(day)
        .bind(signed(bytes, "egress refund")?)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 记访问日志。
    pub async fn insert_egress_log(&mut self, entries: &[EgressLogEntry]) -> Result<()> {
        for e in entries {
            sqlx::query(
                "INSERT INTO egress_log (id, user_id, instance_id, at, host, port, address, allowed, reason, \
                   bytes_up, bytes_down, duration_ms, count) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)",
            )
            .bind(Uuid::now_v7())
            .bind(e.user_id.0)
            .bind(e.instance_id.0)
            .bind(e.at)
            .bind(&e.host)
            .bind(i32::from(e.port))
            .bind(e.address.as_deref())
            .bind(e.allowed)
            .bind(&e.reason)
            .bind(signed(e.bytes_up, "egress bytes")?)
            .bind(signed(e.bytes_down, "egress bytes")?)
            .bind(signed(e.duration_ms, "egress duration")?)
            .bind(i32::try_from(e.count.max(1)).unwrap_or(i32::MAX))
            .execute(self.conn())
            .await?;
        }
        Ok(())
    }
}

impl Tx<Tenant> {
    /// 实例 `day` 这天用掉（含预留中）的字节。
    pub async fn egress_used(&mut self, instance: InstanceId, day: NaiveDate) -> Result<u64> {
        let n: Option<i64> = sqlx::query_scalar(
            "SELECT bytes FROM egress_usage WHERE instance_id = $1 AND day = $2",
        )
        .bind(instance.0)
        .bind(day)
        .fetch_optional(self.conn())
        .await?;
        unsigned(n.unwrap_or(0), "egress bytes")
    }

    /// 实例最近的访问日志，新的在前；`denied_only` 时只要被拒绝的。
    pub async fn egress_log(
        &mut self,
        instance: InstanceId,
        denied_only: bool,
        limit: u32,
    ) -> Result<Vec<EgressLogEntry>> {
        let rows: Vec<LogRow> = sqlx::query_as(
            "SELECT user_id, instance_id, at, host, port, address, allowed, reason, bytes_up, bytes_down, \
               duration_ms, count \
             FROM egress_log WHERE instance_id = $1 AND (NOT $2 OR NOT allowed) \
             ORDER BY at DESC, id DESC LIMIT $3",
        )
        .bind(instance.0)
        .bind(denied_only)
        .bind(i64::from(limit))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(LogRow::into_entry).collect()
    }
}

impl Tx<Worker> {
    /// 删掉 `log_before` 之前的访问日志和 `usage_before` 之前的用量行，每次最多 `limit` 行。返回删了几行日志。
    pub async fn purge_egress(
        &mut self,
        log_before: DateTime<Utc>,
        usage_before: NaiveDate,
        limit: i64,
    ) -> Result<u64> {
        let done = sqlx::query(
            "DELETE FROM egress_log WHERE id IN (SELECT id FROM egress_log WHERE at < $1 ORDER BY at LIMIT $2)",
        )
        .bind(log_before)
        .bind(limit)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "DELETE FROM egress_usage WHERE (instance_id, day) IN \
               (SELECT instance_id, day FROM egress_usage WHERE day < $1 LIMIT $2)",
        )
        .bind(usage_before)
        .bind(limit)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}
