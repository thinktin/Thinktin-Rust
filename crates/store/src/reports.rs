//! 内容举报（WBS 5.5）：用户举报 agent 的输出，运营处理后把结果告诉用户。
//!
//! 提交时把被举报的那一条内容复制下来（运行的提问和摘要、那条事件、产出物的元数据）：运营判断时看它，用户删了
//! 运行、事件过了保留期也还在。只复制被举报的这一条，注销账号时和别的数据一起删掉。

use chrono::{DateTime, Utc};
use proto::domain::{ArtifactId, ContentReport, ReportId, ReportReason, RunId, UserId};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse};

/// 复制下来的文字最长多少个字符（提问、摘要、事件里的每段文字）。
const SNAPSHOT_TEXT_CHARS: usize = 4000;
/// 复制下来的事件载荷最大多少字节（超过的只留截断后的文字）。
const SNAPSHOT_EVENT_BYTES: usize = 64 * 1024;

/// 用户提交的举报。
#[derive(Debug, Clone)]
pub struct NewReport {
    pub run_id: RunId,
    pub event_seq: Option<u64>,
    pub artifact_id: Option<ArtifactId>,
    pub reason: ReportReason,
    pub note: Option<String>,
}

/// 运营看的举报：连同复制下来的内容和举报的人。
#[derive(Debug, Clone)]
pub struct ReportRecord {
    pub report: ContentReport,
    pub user_id: UserId,
    pub snapshot: Value,
    pub handled_by: Option<String>,
}

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    user_id: Uuid,
    instance_id: Uuid,
    run_id: Uuid,
    event_seq: Option<i64>,
    artifact_id: Option<Uuid>,
    reason: String,
    note: Option<String>,
    snapshot: Value,
    state: String,
    resolution: Option<String>,
    handled_by: Option<String>,
    handled_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
}

macro_rules! columns {
    () => {
        "id, user_id, instance_id, run_id, event_seq, artifact_id, reason, note, snapshot, state, resolution, \
         handled_by, handled_at, created_at"
    };
}

impl Row {
    fn into_record(self) -> Result<ReportRecord> {
        Ok(ReportRecord {
            report: ContentReport {
                id: self.id.into(),
                run_id: self.run_id.into(),
                instance_id: self.instance_id.into(),
                event_seq: self
                    .event_seq
                    .map(|n| {
                        u64::try_from(n).map_err(|_| Error::Corrupt("negative event_seq".into()))
                    })
                    .transpose()?,
                artifact_id: self.artifact_id.map(Into::into),
                reason: parse(&self.reason)?,
                note: self.note,
                state: parse(&self.state)?,
                resolution: self.resolution,
                created_at: self.created_at,
                handled_at: self.handled_at,
            },
            user_id: self.user_id.into(),
            snapshot: self.snapshot,
            handled_by: self.handled_by,
        })
    }
}

fn cut(s: &str) -> String {
    s.chars().take(SNAPSHOT_TEXT_CHARS).collect()
}

/// 事件载荷：太大的不整个留，只留里面截断后的文字。
fn event_snapshot(payload: Value) -> Value {
    if payload.to_string().len() <= SNAPSHOT_EVENT_BYTES {
        return payload;
    }
    fn texts(v: &Value, out: &mut Vec<String>) {
        match v {
            Value::String(s) => out.push(cut(s)),
            Value::Array(a) => a.iter().for_each(|x| texts(x, out)),
            Value::Object(o) => o.values().for_each(|x| texts(x, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    texts(&payload, &mut out);
    let mut total = 0;
    out.retain(|t| {
        total += t.len();
        total <= SNAPSHOT_EVENT_BYTES
    });
    json!({ "truncated": true, "texts": out })
}

impl Tx<Tenant> {
    /// 提交举报（只能举报自己的运行）。同一条内容已经有待处理的举报就返回那一条（`false`）。
    pub async fn create_report(&mut self, new: &NewReport) -> Result<(ContentReport, bool)> {
        let seq = new
            .event_seq
            .map(|n| i64::try_from(n).map_err(|_| Error::NotFound))
            .transpose()?;
        let run: Option<(Uuid, String, Option<String>, String)> =
            sqlx::query_as("SELECT instance_id, prompt, summary, state FROM runs WHERE id = $1")
                .bind(new.run_id.0)
                .fetch_optional(self.conn())
                .await?;
        let Some((instance, prompt, summary, state)) = run else {
            return Err(Error::NotFound);
        };
        let mut snapshot = json!({
            "run": { "prompt": cut(&prompt), "summary": summary.as_deref().map(cut), "state": state },
        });
        if let Some(seq) = seq {
            let event: Option<(String, Value, DateTime<Utc>)> = sqlx::query_as(
                "SELECT kind, payload, created_at FROM events \
                 WHERE instance_id = $1 AND seq = $2 AND run_id = $3",
            )
            .bind(instance)
            .bind(seq)
            .bind(new.run_id.0)
            .fetch_optional(self.conn())
            .await?;
            let Some((kind, payload, at)) = event else {
                return Err(Error::NotFound);
            };
            snapshot["event"] =
                json!({ "seq": seq, "kind": kind, "payload": event_snapshot(payload), "at": at });
        }
        if let Some(id) = new.artifact_id {
            let artifact: Option<(String, i32, String, i64, String)> = sqlx::query_as(
                "SELECT name, version, content_type, size, encode(sha256, 'hex') FROM artifacts \
                 WHERE id = $1 AND instance_id = $2",
            )
            .bind(id.0)
            .bind(instance)
            .fetch_optional(self.conn())
            .await?;
            let Some((name, version, content_type, size, sha256)) = artifact else {
                return Err(Error::NotFound);
            };
            snapshot["artifact"] = json!({
                "name": name, "version": version, "content_type": content_type, "size": size, "sha256": sha256,
            });
        }
        let row: Option<Row> = sqlx::query_as(concat!(
            "INSERT INTO content_reports (id, user_id, instance_id, run_id, event_seq, artifact_id, reason, note, \
               snapshot) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) \
             ON CONFLICT (user_id, run_id, coalesce(event_seq, -1), \
               coalesce(artifact_id, '00000000-0000-0000-0000-000000000000')) WHERE state = 'open' DO NOTHING \
             RETURNING ",
            columns!()
        ))
        .bind(ReportId::new().0)
        .bind(self.user().0)
        .bind(instance)
        .bind(new.run_id.0)
        .bind(seq)
        .bind(new.artifact_id.map(|a| a.0))
        .bind(new.reason.as_str())
        .bind(new.note.as_deref())
        .bind(&snapshot)
        .fetch_optional(self.conn())
        .await?;
        if let Some(row) = row {
            return Ok((row.into_record()?.report, true));
        }
        let existing: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM content_reports \
             WHERE user_id = $1 AND run_id = $2 AND event_seq IS NOT DISTINCT FROM $3 \
               AND artifact_id IS NOT DISTINCT FROM $4 AND state = 'open'"
        ))
        .bind(self.user().0)
        .bind(new.run_id.0)
        .bind(seq)
        .bind(new.artifact_id.map(|a| a.0))
        .fetch_one(self.conn())
        .await?;
        Ok((existing.into_record()?.report, false))
    }

    /// 自己的举报，新的在前。
    pub async fn reports(&mut self, limit: i64) -> Result<Vec<ContentReport>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM content_reports ORDER BY created_at DESC LIMIT $1"
        ))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|r| Ok(r.into_record()?.report))
            .collect()
    }
}

impl Tx<Worker> {
    /// 运营的待处理队列：先来的在前。
    pub async fn open_reports(&mut self, limit: i64) -> Result<Vec<ReportRecord>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM content_reports WHERE state = 'open' ORDER BY created_at LIMIT $1"
        ))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_record).collect()
    }

    pub async fn report(&mut self, id: ReportId) -> Result<ReportRecord> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM content_reports WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_record()
    }

    /// 处理完一条举报：记下结果和处理人。已经处理过的返回 [`Error::Conflict`]。
    pub async fn close_report(
        &mut self,
        id: ReportId,
        operator: &str,
        resolution: &str,
    ) -> Result<ReportRecord> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE content_reports SET state = 'closed', resolution = $2, handled_by = $3, handled_at = now() \
             WHERE id = $1 AND state = 'open' RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(resolution)
        .bind(operator)
        .fetch_optional(self.conn())
        .await?;
        match row {
            Some(r) => r.into_record(),
            None => {
                self.report(id).await?;
                Err(Error::Conflict("the report is already closed".into()))
            }
        }
    }

    /// 待处理的有几条、最早的一条等了多久（指标和告警用）。
    pub async fn report_backlog(&mut self) -> Result<(i64, Option<DateTime<Utc>>)> {
        Ok(sqlx::query_as(
            "SELECT count(*), min(created_at) FROM content_reports WHERE state = 'open'",
        )
        .fetch_one(self.conn())
        .await?)
    }
}
