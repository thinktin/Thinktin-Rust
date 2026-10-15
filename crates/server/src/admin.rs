//! 运维命令（WBS 4.6）：`thinktin-server admin freeze|unfreeze|show`。
//!
//! 冻结、解冻走 [`orchestrator::account`]：记审计（操作人和原因）、给用户发通知。
//! 账号可以用手机号或用户 id 指定；输出里的手机号打码，不输出对话内容。

use std::io::Write;

use anyhow::{Context, bail};
use proto::domain::UserId;
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
    let operator = operator.trim();
    if operator.is_empty() || operator.chars().count() > 64 {
        bail!("--operator (or THINKTIN_OPERATOR) must be 1-64 characters");
    }
    let reason = reason.trim();
    if reason.is_empty() || reason.chars().count() > 500 {
        bail!("--reason must be 1-500 characters");
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
