//! 审批（4.7）：agent 请求权限、超出预授权范围时进审批队列，用户在手机上决定。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{Approval, ApprovalId, ApprovalState, DeviceId, InstanceId, RunId, UserId};
use serde_json::Value;
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse, secs};

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    run_id: Uuid,
    instance_id: Uuid,
    request_id: String,
    title: Option<String>,
    options: Value,
    tool_call: Value,
    state: String,
    decided_option: Option<String>,
    expires_at: DateTime<Utc>,
    created_at: DateTime<Utc>,
}

/// 审批记录，带上 shim 的请求 id 和决定的选项（编排服务转回给 shim 用）。
#[derive(Debug, Clone, PartialEq)]
pub struct ApprovalRecord {
    pub approval: Approval,
    pub request_id: String,
    pub decided_option: Option<String>,
}

impl Row {
    fn into_record(self) -> Result<ApprovalRecord> {
        Ok(ApprovalRecord {
            approval: Approval {
                id: self.id.into(),
                run_id: self.run_id.into(),
                instance_id: self.instance_id.into(),
                title: self.title,
                options: self.options,
                tool_call: self.tool_call,
                state: parse(&self.state)?,
                expires_at: self.expires_at,
                created_at: self.created_at,
            },
            request_id: self.request_id,
            decided_option: self.decided_option,
        })
    }
}

macro_rules! columns {
    () => {
        "id, run_id, instance_id, request_id, title, options, tool_call, state, decided_option, expires_at, created_at"
    };
}

/// 新的审批请求。
#[derive(Debug, Clone)]
pub struct NewApproval<'a> {
    pub user: UserId,
    pub instance: InstanceId,
    pub run: RunId,
    pub request_id: &'a str,
    pub title: Option<&'a str>,
    /// shim 给的选项：`[{option_id, name, kind}]`，kind 以 allow / reject 开头。
    pub options: &'a Value,
    pub tool_call: &'a Value,
    pub expires_in: Duration,
}

impl Tx<Worker> {
    pub async fn create_approval(&mut self, new: &NewApproval<'_>) -> Result<ApprovalRecord> {
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO approvals (id, user_id, instance_id, run_id, request_id, title, options, tool_call, expires_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now() + make_interval(secs => $9)) RETURNING ",
            columns!()
        ))
        .bind(ApprovalId::new().0)
        .bind(new.user.0)
        .bind(new.instance.0)
        .bind(new.run.0)
        .bind(new.request_id)
        .bind(new.title)
        .bind(new.options)
        .bind(new.tool_call)
        .bind(secs(new.expires_in))
        .fetch_one(self.conn())
        .await?;
        row.into_record()
    }

    pub async fn approval_for_request(
        &mut self,
        run: RunId,
        request_id: &str,
    ) -> Result<Option<ApprovalRecord>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM approvals WHERE run_id = $1 AND request_id = $2"
        ))
        .bind(run.0)
        .bind(request_id)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_record).transpose()
    }

    /// shim 自己了结的请求（按预授权自动决定、等待超时、这一轮被取消）：同步到审批记录。
    /// 用户已经决定过的不覆盖。
    pub async fn settle_approval(
        &mut self,
        run: RunId,
        request_id: &str,
        state: ApprovalState,
        option: Option<&str>,
        by: &str,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE approvals SET state = $3, decided_option = $4, decided_by = $5, decided_at = now() \
             WHERE run_id = $1 AND request_id = $2 AND state = 'pending'",
        )
        .bind(run.0)
        .bind(request_id)
        .bind(state.as_str())
        .bind(option)
        .bind(by)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "UPDATE inbox_items SET read_at = now() \
             WHERE approval_id IN (SELECT id FROM approvals WHERE run_id = $1 AND request_id = $2) \
               AND read_at IS NULL",
        )
        .bind(run.0)
        .bind(request_id)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 运行结束：还没决定的审批一并作废。
    pub async fn cancel_run_approvals(&mut self, run: RunId) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE approvals SET state = 'cancelled', decided_by = 'system', decided_at = now() \
             WHERE run_id = $1 AND state = 'pending'",
        )
        .bind(run.0)
        .execute(self.conn())
        .await?;
        // 收件箱里这个运行的审批提醒都处理完了。
        sqlx::query(
            "UPDATE inbox_items SET read_at = now() \
             WHERE run_id = $1 AND approval_id IS NOT NULL AND read_at IS NULL",
        )
        .bind(run.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Tenant> {
    /// 待我决定的审批，早的在前。
    pub async fn pending_approvals(&mut self) -> Result<Vec<Approval>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM approvals WHERE state = 'pending' AND expires_at > now() ORDER BY created_at"
        ))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|r| Ok(r.into_record()?.approval))
            .collect()
    }

    /// 用户做决定：选项必须是这个请求给出的选项之一；已决定、已过期的不能再改。
    pub async fn decide_approval(
        &mut self,
        id: ApprovalId,
        option_id: &str,
        device: DeviceId,
    ) -> Result<Approval> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM approvals WHERE id = $1 FOR UPDATE"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        let rec = row.into_record()?;
        if rec.approval.state != ApprovalState::Pending {
            return Err(Error::Conflict(format!(
                "approval is already {}",
                rec.approval.state
            )));
        }
        if rec.approval.expires_at <= Utc::now() {
            return Err(Error::Conflict("approval has expired".into()));
        }
        let kind = rec
            .approval
            .options
            .as_array()
            .and_then(|opts| {
                opts.iter()
                    .find(|o| o.get("option_id").and_then(Value::as_str) == Some(option_id))
            })
            .and_then(|o| o.get("kind").and_then(Value::as_str))
            .ok_or_else(|| Error::Invalid(format!("unknown option {option_id}")))?;
        let state = if kind.starts_with("allow") {
            ApprovalState::Approved
        } else {
            ApprovalState::Rejected
        };
        let row: Row = sqlx::query_as(concat!(
            "UPDATE approvals SET state = $2, decided_option = $3, decided_by = $4, decided_at = now() \
             WHERE id = $1 RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(state.as_str())
        .bind(option_id)
        .bind(format!("device:{device}"))
        .fetch_one(self.conn())
        .await?;
        self.settle_approval_inbox(id).await?;
        Ok(row.into_record()?.approval)
    }
}
