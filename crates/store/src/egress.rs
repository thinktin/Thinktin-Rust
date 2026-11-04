//! 受控出网通道（WBS 2.7，docs/egress.md）：每个实例每天的流量和访问日志。
//!
//! - 出口代理在模型网关里，用 `thinktin_llmgw` 角色：开隧道前、转发途中先 [`Tx::egress_reserve`] 预留一段再转发，
//!   结束时 [`Tx::egress_refund`] 退回没用完的，多副本同时转发也不会超过每天的上限；每条隧道写一行日志。
//! - App 用业务角色（行级安全）读自己实例今天的用量和最近的日志。
//! - 后台到期删掉旧日志（6 个月）和旧的用量行。

use chrono::{DateTime, NaiveDate, Utc};
use proto::domain::{EgressDecision, EgressRequest, EgressRequestId, InstanceId, RunId, UserId};
use uuid::Uuid;

use crate::{Error, Llmgw, Result, Tenant, Tx, Worker, signed, unsigned};

/// 没有任务时（`run_id` 为空），“访问一次”“拒绝”管多久。
const NO_RUN_DECISION_HOURS: i32 = 1;

/// 要问用户的一个网站，加上后台发提醒要用的：实例名、是谁的。
#[derive(Debug, Clone, PartialEq)]
pub struct EgressAsk {
    pub request: EgressRequest,
    pub user_id: UserId,
    pub instance_name: String,
}

#[derive(sqlx::FromRow)]
struct RequestRow {
    id: Uuid,
    instance_id: Uuid,
    host: String,
    run_id: Option<Uuid>,
    status: String,
    created_at: DateTime<Utc>,
    decided_at: Option<DateTime<Utc>>,
}

impl From<RequestRow> for EgressRequest {
    fn from(r: RequestRow) -> Self {
        EgressRequest {
            id: r.id.into(),
            instance_id: r.instance_id.into(),
            host: r.host,
            run_id: r.run_id.map(Into::into),
            status: r.status,
            created_at: r.created_at,
            decided_at: r.decided_at,
        }
    }
}

macro_rules! request_columns {
    () => {
        "id, instance_id, host, run_id, status, created_at, decided_at"
    };
}

/// 续上一条在等的请求：换成这次任务；换了任务、上次提醒过了一小时以上的再提醒一次。
macro_rules! touch_request {
    () => {
        "run_id = $3, asked_at = now(), \
         notified_at = CASE WHEN egress_requests.run_id IS DISTINCT FROM $3 \
                             AND egress_requests.notified_at < now() - interval '1 hour' \
                            THEN NULL ELSE egress_requests.notified_at END"
    };
}

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

impl Tx<Llmgw> {
    /// 实例现在在做的任务（同一个实例同时只有一个在跑的 agent 任务）。
    pub async fn egress_current_run(&mut self, instance: InstanceId) -> Result<Option<RunId>> {
        let id: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM runs WHERE instance_id = $1 AND kind = 'agent' AND state IN ('starting', 'running', \
               'waiting_approval', 'waiting_device', 'waiting_quota', 'waiting_children', 'backoff') LIMIT 1",
        )
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        Ok(id.map(Into::into))
    }

    /// 用户对这次任务（`run`）访问 `host` 的回答：`once`、`denied`，还没答过为空。没有任务时看一小时内的回答。
    pub async fn egress_decision(
        &mut self,
        instance: InstanceId,
        host: &str,
        run: Option<RunId>,
    ) -> Result<Option<String>> {
        let status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM egress_requests \
             WHERE instance_id = $1 AND host = $2 AND status IN ('once', 'denied') \
               AND (run_id = $3 OR ($3 IS NULL AND run_id IS NULL \
                    AND decided_at > now() - make_interval(hours => $4))) \
             ORDER BY decided_at DESC LIMIT 1",
        )
        .bind(instance.0)
        .bind(host)
        .bind(run.map(|r| r.0))
        .bind(NO_RUN_DECISION_HOURS)
        .fetch_optional(self.conn())
        .await?;
        Ok(status)
    }

    /// 问用户能不能访问 `host`：已经有一条在等就接着等那条（换成这次任务；换了任务、上次提醒过了一小时以上的再提醒
    /// 一次），没有就新建一条。这个实例已经有 `max_pending` 个网站在等时返回空。
    pub async fn egress_ask(
        &mut self,
        user: UserId,
        instance: InstanceId,
        host: &str,
        run: Option<RunId>,
        max_pending: u32,
    ) -> Result<Option<EgressRequestId>> {
        // 先续上已经在等的（不受个数限制）。
        let touched: Option<Uuid> = sqlx::query_scalar(concat!(
            "UPDATE egress_requests SET ",
            touch_request!(),
            " WHERE instance_id = $1 AND host = $2 AND status = 'pending' RETURNING id"
        ))
        .bind(instance.0)
        .bind(host)
        .bind(run.map(|r| r.0))
        .fetch_optional(self.conn())
        .await?;
        if let Some(id) = touched {
            return Ok(Some(id.into()));
        }
        // 并发时个数可能多出一两个，不要紧：上限只是不让 agent 一口气弹一堆提示。
        let id: Option<Uuid> = sqlx::query_scalar(concat!(
            "INSERT INTO egress_requests (id, user_id, instance_id, host, run_id) \
             SELECT $4, $5, $1, $2, $3 \
             WHERE (SELECT count(*) FROM egress_requests WHERE instance_id = $1 AND status = 'pending') < $6 \
             ON CONFLICT (instance_id, host) WHERE status = 'pending' DO UPDATE SET ",
            touch_request!(),
            " RETURNING id"
        ))
        .bind(instance.0)
        .bind(host)
        .bind(run.map(|r| r.0))
        .bind(Uuid::now_v7())
        .bind(user.0)
        .bind(i64::from(max_pending))
        .fetch_optional(self.conn())
        .await?;
        Ok(id.map(Into::into))
    }

    /// 一条请求现在的状态和对应的任务；没有这条时为空。
    pub async fn egress_request_status(
        &mut self,
        id: EgressRequestId,
    ) -> Result<Option<(String, Option<RunId>)>> {
        let row: Option<(String, Option<Uuid>)> =
            sqlx::query_as("SELECT status, run_id FROM egress_requests WHERE id = $1")
                .bind(id.0)
                .fetch_optional(self.conn())
                .await?;
        Ok(row.map(|(s, r)| (s, r.map(Into::into))))
    }
}

impl Tx<Tenant> {
    /// 自己的 agent 想访问的网站，新的在前；`pending_only` 时只要还在等回答的。
    pub async fn egress_requests(
        &mut self,
        instance: Option<InstanceId>,
        pending_only: bool,
        limit: u32,
    ) -> Result<Vec<EgressRequest>> {
        let rows: Vec<RequestRow> = sqlx::query_as(concat!(
            "SELECT ",
            request_columns!(),
            " FROM egress_requests \
             WHERE ($1::uuid IS NULL OR instance_id = $1) AND (NOT $2 OR status = 'pending') \
             ORDER BY created_at DESC, id DESC LIMIT $3"
        ))
        .bind(instance.map(|i| i.0))
        .bind(pending_only)
        .bind(i64::from(limit))
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// 回答一条在等的请求。“一直允许”把网站记进实例的 `egress_hosts`（已经有了就不重复记；满了
    /// [`proto::egress::MAX_HOSTS`] 个返回 [`Error::Invalid`]，请求还是在等）。不在等了（答过、过期了）返回
    /// [`Error::Conflict`]，看不到返回 [`Error::NotFound`]。
    pub async fn decide_egress_request(
        &mut self,
        id: EgressRequestId,
        decision: EgressDecision,
    ) -> Result<EgressRequest> {
        let status = match decision {
            EgressDecision::Once => "once",
            EgressDecision::Always => "always",
            EgressDecision::Deny => "denied",
        };
        let row: Option<RequestRow> = sqlx::query_as(concat!(
            "SELECT ",
            request_columns!(),
            " FROM egress_requests WHERE id = $1 FOR UPDATE"
        ))
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        let row = row.ok_or(Error::NotFound)?;
        if row.status != "pending" {
            return Err(Error::Conflict(format!(
                "request is already {}",
                row.status
            )));
        }
        if decision == EgressDecision::Always {
            let max = i32::try_from(proto::egress::MAX_HOSTS).unwrap_or(i32::MAX);
            let done = sqlx::query(
                "UPDATE instances SET egress_hosts = CASE WHEN $2 = ANY(egress_hosts) THEN egress_hosts \
                                                          ELSE egress_hosts || $2 END, \
                   updated_at = now() \
                 WHERE id = $1 AND state <> 'deleted' \
                   AND ($2 = ANY(egress_hosts) OR cardinality(egress_hosts) < $3)",
            )
            .bind(row.instance_id)
            .bind(&row.host)
            .bind(max)
            .execute(self.conn())
            .await?;
            if done.rows_affected() == 0 {
                return Err(Error::Invalid(format!(
                    "the agent already has {} always-allowed sites; remove one first",
                    proto::egress::MAX_HOSTS
                )));
            }
        }
        let row: RequestRow = sqlx::query_as(concat!(
            "UPDATE egress_requests SET status = $2, decided_at = now() WHERE id = $1 RETURNING ",
            request_columns!()
        ))
        .bind(id.0)
        .bind(status)
        .fetch_one(self.conn())
        .await?;
        Ok(row.into())
    }

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
    /// 领走最多 `limit` 条还没提醒过的请求，记下提醒时间（和发提醒在同一个事务里：事务没提交就当没领）。
    pub async fn claim_egress_asks(&mut self, limit: i64) -> Result<Vec<EgressAsk>> {
        #[derive(sqlx::FromRow)]
        struct AskRow {
            #[sqlx(flatten)]
            request: RequestRow,
            user_id: Uuid,
            instance_name: String,
        }
        let rows: Vec<AskRow> = sqlx::query_as(
            "WITH due AS (SELECT id FROM egress_requests \
                          WHERE status = 'pending' AND notified_at IS NULL \
                          ORDER BY asked_at LIMIT $1 FOR UPDATE SKIP LOCKED), \
                  done AS (UPDATE egress_requests e SET notified_at = now() FROM due WHERE e.id = due.id \
                           RETURNING e.id, e.instance_id, e.host, e.run_id, e.status, e.created_at, \
                                     e.decided_at, e.user_id) \
             SELECT done.*, i.name AS instance_name FROM done JOIN instances i ON i.id = done.instance_id",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| EgressAsk {
                request: r.request.into(),
                user_id: r.user_id.into(),
                instance_name: r.instance_name,
            })
            .collect())
    }

    /// 等了 `before` 之前还没人回答的标成过期；返回标了几条。
    pub async fn expire_egress_asks(&mut self, before: DateTime<Utc>, limit: i64) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE egress_requests SET status = 'expired' WHERE id IN \
               (SELECT id FROM egress_requests WHERE status = 'pending' AND asked_at < $1 LIMIT $2)",
        )
        .bind(before)
        .bind(limit)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

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
        // 答过、过期了的请求和用量行留得一样久（`usage_before`）。
        sqlx::query(
            "DELETE FROM egress_requests WHERE id IN \
               (SELECT id FROM egress_requests WHERE status <> 'pending' AND created_at < $1 LIMIT $2)",
        )
        .bind(usage_before.and_time(chrono::NaiveTime::MIN).and_utc())
        .bind(limit)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}
