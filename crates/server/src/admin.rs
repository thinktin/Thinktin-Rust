//! 运维命令（WBS 4.6、5.5、15.5）：`thinktin-server admin freeze|unfreeze|show|versions|reports|report|close-report`。
//!
//! 冻结、解冻走 [`orchestrator::account`]：记审计（操作人和原因）、给用户发通知。
//! 账号可以用手机号或用户 id 指定；输出里的手机号打码，不输出对话内容。唯一的例外是内容举报：`report` 输出
//! 用户举报时复制下来的那一条内容（用户提交举报就是让运营看它），别的对话内容照样不输出。

use std::io::Write;

use anyhow::{Context, bail};
use control::Templates;
use proto::domain::{ReportId, UserId};
use store::Db;

/// 按用户 id 或手机号找账号（注销了的找不到）。
pub async fn resolve(db: &Db, account: &str) -> anyhow::Result<UserId> {
    let account = account.trim();
    if let Ok(id) = account.parse::<UserId>() {
        return Ok(id);
    }
    let Ok(phone) = auth::secrets::normalize_phone(account) else {
        bail!("not a user id or phone number: {account}");
    };
    let mut w = db.worker().await?;
    let user = w.user_by_phone(&phone).await?;
    w.rollback().await?;
    user.map(|u| u.id)
        .with_context(|| format!("no account with phone {}", mask_phone(&phone)))
}

fn check(operator: &str, reason: &str) -> anyhow::Result<()> {
    check_text(operator, "--reason", reason)
}

fn check_text(operator: &str, flag: &str, text: &str) -> anyhow::Result<()> {
    let operator = operator.trim();
    if operator.is_empty() || operator.chars().count() > 64 {
        bail!("--operator (or THINKTIN_OPERATOR) must be 1-64 characters");
    }
    let text = text.trim();
    if text.is_empty() || text.chars().count() > 500 {
        bail!("{flag} must be 1-500 characters");
    }
    Ok(())
}

/// 冻结账号：停掉所有运行，登录和接口都拒绝，计划暂停触发。
pub async fn freeze(
    db: &Db,
    account: &str,
    operator: &str,
    reason: &str,
    out: &mut impl Write,
) -> anyhow::Result<()> {
    check(operator, reason)?;
    let user = resolve(db, account).await?;
    let stopped = orchestrator::account::freeze(db, user, operator.trim(), reason.trim()).await?;
    writeln!(
        out,
        "frozen {user}: {} running or queued runs cancelled",
        stopped.runs_cancelled
    )?;
    Ok(())
}

/// 解冻账号。
pub async fn unfreeze(
    db: &Db,
    account: &str,
    operator: &str,
    reason: &str,
    out: &mut impl Write,
) -> anyhow::Result<()> {
    check(operator, reason)?;
    let user = resolve(db, account).await?;
    orchestrator::account::unfreeze(db, user, operator.trim(), reason.trim()).await?;
    writeln!(out, "unfrozen {user}")?;
    Ok(())
}

/// 账号概况（给客服看）：状态、设备、实例、运行、计划、授权的个数，最近登录时间。
pub async fn show(db: &Db, account: &str, out: &mut impl Write) -> anyhow::Result<()> {
    let user = resolve(db, account).await?;
    let mut w = db.worker().await?;
    let s = w.account_summary(user).await?;
    w.rollback().await?;
    let time = |t: chrono::DateTime<chrono::Utc>| t.format("%Y-%m-%d %H:%M:%S UTC").to_string();
    writeln!(out, "user        {}", s.user.id)?;
    writeln!(out, "phone       {}", mask_phone(&s.user.phone))?;
    writeln!(out, "status      {}", s.user.status.as_str())?;
    writeln!(out, "created     {}", time(s.user.created_at))?;
    writeln!(
        out,
        "last login  {}",
        s.last_login_at.map_or_else(|| "-".to_string(), time)
    )?;
    writeln!(out, "devices     {}", s.devices)?;
    writeln!(out, "instances   {}", s.instances)?;
    writeln!(out, "runs        {} active", s.active_runs)?;
    writeln!(out, "plans       {} active", s.active_plans)?;
    writeln!(out, "grants      {} active", s.active_grants)?;
    Ok(())
}

/// 每个 agent 版本上有多少个实例（15.5）：下架一个版本后，看还有多少实例没换到新版本。
/// 下架版本上的实例在下次唤醒时自动换过去，空闲的实例要等到它下一次运行。
pub async fn versions(db: &Db, out: &mut impl Write) -> anyhow::Result<()> {
    let mut w = db.worker().await?;
    let rows = w.instance_versions().await?;
    w.rollback().await?;
    let templates = control::BuiltinTemplates;
    writeln!(
        out,
        "{:<10} {:<16} {:>9}  status",
        "agent", "version", "instances"
    )?;
    for (agent, version, n) in rows {
        let current = templates
            .current(&agent)
            .is_some_and(|m| m.agent.version == version);
        let status = match templates.withdrawn(&agent, &version) {
            Some(advisory) => {
                format!("withdrawn ({advisory}): moves to the current version on its next wake")
            }
            None if current => "current".to_string(),
            None if templates.manifest(&agent, &version).is_some() => "kept".to_string(),
            None => "unknown version".to_string(),
        };
        writeln!(out, "{agent:<10} {version:<16} {n:>9}  {status}")?;
    }
    Ok(())
}

/// 内容举报（5.5）的待处理队列，先来的在前：id、提交时间、原因、等了多久。
pub async fn reports(db: &Db, out: &mut impl Write) -> anyhow::Result<()> {
    let mut w = db.worker().await?;
    let open = w.open_reports(200).await?;
    w.rollback().await?;
    if open.is_empty() {
        writeln!(out, "no open reports")?;
        return Ok(());
    }
    writeln!(
        out,
        "{:<36}  {:<20}  {:<14}  waiting",
        "report", "submitted (UTC)", "reason"
    )?;
    let now = chrono::Utc::now();
    for r in &open {
        let r = &r.report;
        let hours = (now - r.created_at).num_minutes() as f64 / 60.0;
        writeln!(
            out,
            "{:<36}  {:<20}  {:<14}  {hours:.1}h",
            r.id.to_string(),
            r.created_at.format("%Y-%m-%d %H:%M:%S"),
            r.reason.as_str(),
        )?;
    }
    Ok(())
}

/// 一条举报的详情：举报的人（手机号打码）、原因和说明、复制下来的内容。
pub async fn report(db: &Db, id: &str, out: &mut impl Write) -> anyhow::Result<()> {
    let id: ReportId = id.trim().parse().context("not a report id")?;
    let mut w = db.worker().await?;
    let r = w.report(id).await.context("no such report")?;
    let reporter = w.user(r.user_id).await?;
    w.rollback().await?;
    let time = |t: chrono::DateTime<chrono::Utc>| t.format("%Y-%m-%d %H:%M:%S UTC").to_string();
    writeln!(out, "report      {}", r.report.id)?;
    writeln!(out, "state       {}", r.report.state.as_str())?;
    writeln!(out, "submitted   {}", time(r.report.created_at))?;
    writeln!(
        out,
        "user        {} ({})",
        r.user_id,
        mask_phone(&reporter.phone)
    )?;
    writeln!(out, "reason      {}", r.report.reason.as_str())?;
    writeln!(
        out,
        "note        {}",
        r.report.note.as_deref().unwrap_or("-")
    )?;
    writeln!(out, "run         {}", r.report.run_id)?;
    if let Some(seq) = r.report.event_seq {
        writeln!(out, "event       #{seq}")?;
    }
    if let Some(a) = r.report.artifact_id {
        writeln!(out, "artifact    {a}")?;
    }
    if let Some(at) = r.report.handled_at {
        writeln!(
            out,
            "handled     {} by {}: {}",
            time(at),
            r.handled_by.as_deref().unwrap_or("-"),
            r.report.resolution.as_deref().unwrap_or("-")
        )?;
    }
    writeln!(out, "content (copied when reported):")?;
    writeln!(out, "{}", serde_json::to_string_pretty(&r.snapshot)?)?;
    Ok(())
}

/// 处理完一条举报：记下结果（发给举报的人）和处理人（只进审计）。
pub async fn close_report(
    db: &Db,
    id: &str,
    operator: &str,
    resolution: &str,
    out: &mut impl Write,
) -> anyhow::Result<()> {
    check_text(operator, "--resolution", resolution)?;
    let id: ReportId = id.trim().parse().context("not a report id")?;
    orchestrator::reports::close(db, id, operator.trim(), resolution.trim()).await?;
    writeln!(out, "closed {id}; the reporter was told the resolution")?;
    Ok(())
}

/// 手机号打码：留国家码和前几位、后四位，比如 `+86138****8000`。
pub fn mask_phone(phone: &str) -> String {
    let chars: Vec<char> = phone.chars().collect();
    let n = chars.len();
    if n <= 6 {
        return "*".repeat(n);
    }
    let (head, tail) = if n > 10 { (6, 4) } else { (n - 6, 2) };
    let shown_head: String = chars[..head].iter().collect();
    let shown_tail: String = chars[n - tail..].iter().collect();
    format!("{shown_head}{}{shown_tail}", "*".repeat(n - head - tail))
}

#[cfg(test)]
mod tests {
    use super::mask_phone;

    #[test]
    fn phones_are_masked() {
        assert_eq!(mask_phone("+8613800138000"), "+86138****8000");
        assert_eq!(mask_phone("+14155550123"), "+14155**0123");
        assert_eq!(mask_phone("+4930123"), "+4****23");
        assert_eq!(mask_phone("deleted"), "d****ed");
        assert_eq!(mask_phone("+123"), "****");
    }
}
