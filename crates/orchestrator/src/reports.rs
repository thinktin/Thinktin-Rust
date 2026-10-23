//! 内容举报的处理（WBS 5.5）：运营看完复制下来的内容、处理后（`thinktin-server admin close-report`）记下结果，
//! 告诉举报的人（收件箱和推送）。记审计，和状态变更在同一个事务里。

use notify::PushKind;
use proto::domain::{ReportId, UserStatus};
use serde_json::json;
use store::{Db, ReportRecord};

use crate::outbox::{Notice, notify};
use crate::texts;

/// 处理完一条举报。`operator` 只进审计；`resolution` 记在举报上，也发给举报的人（不要写别人的信息）。
/// 已经处理过的返回冲突。
pub async fn close(
    db: &Db,
    id: ReportId,
    operator: &str,
    resolution: &str,
) -> store::Result<ReportRecord> {
    let mut w = db.worker().await?;
    let closed = w.close_report(id, operator, resolution).await?;
    let user = closed.user_id;
    w.audit(
        Some(user),
        &format!("operator:{operator}"),
        "content.report_closed",
        Some(&id.to_string()),
        &json!({ "reason": closed.report.reason.as_str() }),
    )
    .await?;
    let account = w.user(user).await?;
    if account.status != UserStatus::Deleted {
        let (title, body) = texts::report_handled(account.locale, resolution);
        let notice = Notice::new(PushKind::Info, title, body)
            .subtype(proto::domain::notice_subtype::REPORT_HANDLED);
        notify(&mut w, user, &notice).await?;
    }
    w.commit().await?;
    Ok(closed)
}
