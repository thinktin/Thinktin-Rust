//! 平台搜索工具的记账（docs/search.md）：每个用户每天搜了几次、花了多少；每人每天、全站每月各有上限（用户
//! 2026-11-04 定：每人每天 50 次、测试期每月 ¥100）。先预留再调接口，调完按实际结果改（失败、没结果不收钱的退回）。

use chrono::NaiveDate;
use proto::domain::UserId;

use crate::{Result, Tenant, Tx, Worker, signed, unsigned};

/// 预留一次搜索的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchReserve {
    Reserved,
    /// 这个用户今天的次数用完了。
    UserDaily,
    /// 全站这个月的钱用完了。
    MonthlyBudget,
}

/// 所有预留排队用的咨询锁（一个固定的数）：每月总额按全站算，并发预留不能一起超过。
const SEARCH_LOCK: i64 = 0x5EA2_C400;

impl Tx<Worker> {
    /// 给 `user` 在 `day` 预留一次搜索，按 `cost_millicents` 先记上钱：今天已经 `per_user_daily` 次，或者 `month_start`
    /// 起全站加上这次会超过 `monthly_budget_millicents` 时不预留。
    pub async fn reserve_search(
        &mut self,
        user: UserId,
        day: NaiveDate,
        month_start: NaiveDate,
        per_user_daily: u32,
        monthly_budget_millicents: u64,
        cost_millicents: u64,
    ) -> Result<SearchReserve> {
        let cost = signed(cost_millicents, "search cost")?;
        // 设成 0 是“暂停平台搜索”。
        if per_user_daily == 0 {
            return Ok(SearchReserve::UserDaily);
        }
        sqlx::query("SELECT pg_advisory_xact_lock($1)")
            .bind(SEARCH_LOCK)
            .execute(self.conn())
            .await?;
        let spent: i64 = sqlx::query_scalar(
            "SELECT coalesce(sum(cost_millicents), 0)::bigint FROM search_usage WHERE day >= $1",
        )
        .bind(month_start)
        .fetch_one(self.conn())
        .await?;
        if spent.saturating_add(cost) > signed(monthly_budget_millicents, "search budget")? {
            return Ok(SearchReserve::MonthlyBudget);
        }
        let calls: Option<i32> = sqlx::query_scalar(
            "INSERT INTO search_usage (user_id, day, calls, cost_millicents) VALUES ($1, $2, 1, $3) \
             ON CONFLICT (user_id, day) DO UPDATE \
               SET calls = search_usage.calls + 1, cost_millicents = search_usage.cost_millicents + $3 \
               WHERE search_usage.calls < $4 \
             RETURNING calls",
        )
        .bind(user.0)
        .bind(day)
        .bind(cost)
        .bind(i64::from(per_user_daily))
        .fetch_optional(self.conn())
        .await?;
        Ok(if calls.is_some() {
            SearchReserve::Reserved
        } else {
            SearchReserve::UserDaily
        })
    }

    /// 调完以后按实际改：`counted` 为 false 时退回这一次（接口出错、没结果），钱从预留的 `reserved` 改成 `actual`。
    pub async fn settle_search(
        &mut self,
        user: UserId,
        day: NaiveDate,
        counted: bool,
        reserved_millicents: u64,
        actual_millicents: u64,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE search_usage SET calls = GREATEST(calls - $3, 0), \
               cost_millicents = GREATEST(cost_millicents - $4 + $5, 0) \
             WHERE user_id = $1 AND day = $2",
        )
        .bind(user.0)
        .bind(day)
        .bind(i32::from(!counted))
        .bind(signed(reserved_millicents, "search cost")?)
        .bind(signed(actual_millicents, "search cost")?)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 全站 `month_start` 起花了多少（千分之一分）。
    pub async fn search_spent_since(&mut self, month_start: NaiveDate) -> Result<u64> {
        let spent: i64 = sqlx::query_scalar(
            "SELECT coalesce(sum(cost_millicents), 0)::bigint FROM search_usage WHERE day >= $1",
        )
        .bind(month_start)
        .fetch_one(self.conn())
        .await?;
        unsigned(spent, "search cost")
    }

    /// 删掉 `before` 之前的用量行，返回删了几行。
    pub async fn purge_search_usage(&mut self, before: NaiveDate) -> Result<u64> {
        let done = sqlx::query("DELETE FROM search_usage WHERE day < $1")
            .bind(before)
            .execute(self.conn())
            .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Tenant> {
    /// 自己 `day` 这天搜了几次。
    pub async fn search_calls(&mut self, day: NaiveDate) -> Result<u32> {
        let n: Option<i32> = sqlx::query_scalar("SELECT calls FROM search_usage WHERE day = $1")
            .bind(day)
            .fetch_optional(self.conn())
            .await?;
        Ok(u32::try_from(n.unwrap_or(0)).unwrap_or(0))
    }
}
