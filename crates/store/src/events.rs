//! 实例事件流（4.8、7.9）：每个实例一个单调递增的序号，客户端带上最后收到的序号续传。

use chrono::{DateTime, NaiveDate, Utc};
use proto::domain::{InstanceEvent, InstanceId, RunId};
use serde_json::Value;
use uuid::Uuid;

use crate::{Error, Result, Tx, Worker, signed, unsigned};

/// 事件追加后在这个 Postgres 通知频道上发实例 id。
pub const EVENTS_CHANNEL: &str = "thinktin_events";

#[derive(sqlx::FromRow)]
struct Row {
    instance_id: Uuid,
    seq: i64,
    run_id: Option<Uuid>,
    kind: String,
    payload: Value,
    created_at: DateTime<Utc>,
}

impl Row {
    fn into_event(self) -> Result<InstanceEvent> {
        Ok(InstanceEvent {
            instance_id: self.instance_id.into(),
            seq: unsigned(self.seq, "event seq")?,
            run_id: self.run_id.map(Into::into),
            kind: self.kind,
            payload: self.payload,
            created_at: self.created_at,
        })
    }
}

/// 两种角色都能用；业务角色下 RLS 只放行当前用户的实例。
impl<R> Tx<R> {
    /// 追加一条事件，分配下一个序号。实例行在事务提交前一直锁着（同一实例的追加按序排队），
    /// 所以追加事件的事务要短。
    pub async fn append_event(
        &mut self,
        instance: InstanceId,
        run: Option<RunId>,
        kind: &str,
        payload: &Value,
    ) -> Result<InstanceEvent> {
        let (seq, user_id): (i64, Uuid) = sqlx::query_as(
            "UPDATE instances SET event_seq = event_seq + 1 WHERE id = $1 RETURNING event_seq, user_id",
        )
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        let row: Row = sqlx::query_as(
            "INSERT INTO events (instance_id, seq, user_id, run_id, kind, payload) \
             VALUES ($1, $2, $3, $4, $5, $6) \
             RETURNING instance_id, seq, run_id, kind, payload, created_at",
        )
        .bind(instance.0)
        .bind(seq)
        .bind(user_id)
        .bind(run.map(|r| r.0))
        .bind(kind)
        .bind(payload)
        .fetch_one(self.conn())
        .await?;
        // 提交时通知在线的事件流（接入网关按实例转给订阅者，订阅者再按序号来取）。
        sqlx::query("SELECT pg_notify($1, $2)")
            .bind(EVENTS_CHANNEL)
            .bind(instance.to_string())
            .execute(self.conn())
            .await?;
        row.into_event()
    }

    /// 序号大于 `after` 的事件，按序号排序。
    pub async fn events_after(
        &mut self,
        instance: InstanceId,
        after: u64,
        limit: i64,
    ) -> Result<Vec<InstanceEvent>> {
        let rows: Vec<Row> = sqlx::query_as(
            "SELECT instance_id, seq, run_id, kind, payload, created_at FROM events \
             WHERE instance_id = $1 AND seq > $2 ORDER BY seq LIMIT $3",
        )
        .bind(instance.0)
        .bind(signed(after, "after")?)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_event).collect()
    }

    /// 还保留着的最早序号和最新序号（同一个快照里读）。一条都没保留时，最早序号是下一条的序号
    /// （最新 + 1）：客户端要续传的位置早于最早序号，说明中间的事件已经过了保留期，要整体重新加载。
    pub async fn event_range(&mut self, instance: InstanceId) -> Result<(u64, u64)> {
        let (latest, oldest): (i64, Option<i64>) = sqlx::query_as(
            "SELECT event_seq, (SELECT min(seq) FROM events WHERE instance_id = $1) \
             FROM instances WHERE id = $1",
        )
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        let latest = unsigned(latest, "event seq")?;
        let oldest = match oldest {
            Some(v) => unsigned(v, "event seq")?,
            None => latest + 1,
        };
        Ok((oldest, latest))
    }
}

impl<R> Tx<R> {
    /// 运行最近的 `limit` 条事件（只要 `kinds` 里的种类），按先后排。续跑简报（7.12）、查进度（8.9）用；
    /// 业务角色按行级安全只看得到自己的。
    pub async fn recent_run_events(
        &mut self,
        run: RunId,
        kinds: &[&str],
        limit: i64,
    ) -> Result<Vec<InstanceEvent>> {
        let kinds: Vec<String> = kinds.iter().map(|k| (*k).to_owned()).collect();
        let mut rows: Vec<Row> = sqlx::query_as(
            "SELECT instance_id, seq, run_id, kind, payload, created_at FROM events \
             WHERE run_id = $1 AND kind = ANY($2) ORDER BY seq DESC LIMIT $3",
        )
        .bind(run.0)
        .bind(&kinds)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.reverse();
        rows.into_iter().map(Row::into_event).collect()
    }
}

impl Tx<Worker> {
    /// 建好从 `from` 所在月起 `months` 个月的事件分区（维护任务每天调一次，提前建好下个月的）。
    pub async fn ensure_event_partitions(&mut self, from: NaiveDate, months: i32) -> Result<()> {
        if !(1..=24).contains(&months) {
            return Err(Error::Invalid(format!("months out of range: {months}")));
        }
        sqlx::query("SELECT ensure_event_partitions($1, $2)")
            .bind(from)
            .bind(months)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 删掉整月都早于 `before` 的事件分区（保留期 30 天：传入 30 天前的日期）。返回删掉的分区数。
    pub async fn drop_event_partitions_before(&mut self, before: NaiveDate) -> Result<i32> {
        let n: i32 = sqlx::query_scalar("SELECT drop_event_partitions_before($1)")
            .bind(before)
            .fetch_one(self.conn())
            .await?;
        Ok(n)
    }
}
