//! 账号冻结与全部停止（WBS 4.6）。
//!
//! - **冻结**（风控、运维：`thinktin-server admin freeze`）：账号状态改成冻结，没结束的运行全部取消
//!   （实例的令牌代数加一，发出去的沙箱令牌马上作废）。运行授权和计划留着但用不了：
//!   登录、刷新、接口一律拒绝（`account_frozen`），调度器不给冻结的账号建运行、执行器不领，
//!   也换不出沙箱令牌。解冻后计划照常触发。
//! - **全部停止**（用户在 App 里按，或者“下线其他设备”时勾选）：取消运行、吊销全部运行授权、
//!   暂停全部计划。之后用户在实例上发起运行、恢复计划时重新签发授权。
//!
//! 每一种都记审计、给用户发通知（收件箱和推送），和状态变更在同一个事务里。

use notify::PushKind;
use proto::domain::{UserId, UserStatus, notice_subtype};
use serde::Serialize;
use serde_json::json;
use store::{Db, Error};

use crate::outbox::{Notice, notify};
use crate::texts;

/// 停下来了多少东西。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Stopped {
    pub runs_cancelled: u64,
    pub grants_revoked: u64,
    pub plans_paused: u64,
}

/// 运维操作在审计里的身份。
fn operator_actor(operator: &str) -> String {
    format!("operator:{operator}")
}

/// 冻结账号。`operator` 是做这件事的运维、`reason` 是原因，都只进审计，不发给用户。
/// 已经冻结的返回冲突，注销了的返回不存在。
pub async fn freeze(db: &Db, user: UserId, operator: &str, reason: &str) -> store::Result<Stopped> {
    let mut w = db.worker().await?;
    let account = w.user(user).await?;
    match account.status {
        UserStatus::Active => {}
        UserStatus::Frozen => return Err(Error::Conflict("the account is already frozen".into())),
        UserStatus::Deleted => return Err(Error::NotFound),
    }
    w.set_user_status(user, UserStatus::Frozen).await?;
    let stopped = Stopped {
        runs_cancelled: w.cancel_user_runs(user, "account frozen").await?,
        ..Stopped::default()
    };
    w.audit(
        Some(user),
        &operator_actor(operator),
        "account.freeze",
        None,
        &json!({ "reason": reason, "runs_cancelled": stopped.runs_cancelled }),
    )
    .await?;
    let (title, body) = texts::account_frozen(account.locale);
    let notice = Notice::new(PushKind::Info, title, body).subtype(notice_subtype::ACCOUNT_FROZEN);
    notify(&mut w, user, &notice).await?;
    w.commit().await?;
    Ok(stopped)
}

/// 解冻账号。没冻结的返回冲突。
pub async fn unfreeze(db: &Db, user: UserId, operator: &str, reason: &str) -> store::Result<()> {
    let mut w = db.worker().await?;
    let account = w.user(user).await?;
    match account.status {
        UserStatus::Frozen => {}
        UserStatus::Active => return Err(Error::Conflict("the account is not frozen".into())),
        UserStatus::Deleted => return Err(Error::NotFound),
    }
    w.set_user_status(user, UserStatus::Active).await?;
    w.audit(
        Some(user),
        &operator_actor(operator),
        "account.unfreeze",
        None,
        &json!({ "reason": reason }),
    )
    .await?;
    let (title, body) = texts::account_restored(account.locale);
    let notice = Notice::new(PushKind::Info, title, body).subtype(notice_subtype::ACCOUNT_RESTORED);
    notify(&mut w, user, &notice).await?;
    w.commit().await?;
    Ok(())
}

/// 全部停止：取消用户所有没结束的运行、吊销全部运行授权、暂停全部计划。`actor` 记进审计
/// （用户自己是 `user:<设备 id>`）。之后在实例上发起运行、恢复计划时重新签发授权。
pub async fn stop_all(db: &Db, user: UserId, actor: &str) -> store::Result<Stopped> {
    let mut w = db.worker().await?;
    let stopped = Stopped {
        runs_cancelled: w.cancel_user_runs(user, "stopped by the user").await?,
        grants_revoked: w.revoke_user_grants(user, "stop_all").await?,
        plans_paused: w.pause_user_plans(user).await?,
    };
    w.audit(
        Some(user),
        actor,
        "account.stop_all",
        None,
        &serde_json::to_value(stopped).unwrap_or_default(),
    )
    .await?;
    let locale = w.user_locale(user).await?;
    let (title, body) = texts::stopped_all(locale, stopped.runs_cancelled, stopped.plans_paused);
    let notice = Notice::new(PushKind::Info, title, body).subtype(notice_subtype::STOPPED_ALL);
    notify(&mut w, user, &notice).await?;
    w.commit().await?;
    Ok(stopped)
}
