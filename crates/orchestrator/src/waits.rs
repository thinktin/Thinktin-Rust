//! 等待电脑与等待 key（WBS 7.11）。
//!
//! **等 key**：模型网关按降级链试完所有 key 都不行（失效、欠费、被限流、停用或当日额度用完）时，
//! agent 的模型调用一直失败。执行器从网关记下的调用结果（`usage_records`，只有状态码和结果）认出这种情况：
//! 停下 agent 这一轮，运行转入“等待额度 / key”，放掉租约和执行名额，要用户处理的发通知。
//! 用户补上、换了或启用了 key、改了模型路由时马上接着跑；被限流、服务繁忙的过几分钟自己再试；
//! 欠费、额度用完的每小时试一次（可能在厂商那边充了值，当日额度过了零点也会恢复）。
//! 超过计划的 `wait_timeout_secs`（默认 24 小时）还没恢复就结束运行；计划策略是“暂停计划”的同时暂停计划。
//!
//! **等电脑**：需要用户电脑的工具（14.x）调用时电脑不在线，运行转入“等待电脑上线”，同样放掉租约，
//! 电脑上线（macOS 设备登录）时接着跑，超时按同样的策略结束。电脑工具还没做，等待、唤醒、超时先备好。

use std::time::Duration;

use chrono::{DateTime, TimeDelta, Utc};
use store::ModelCall;

/// agent 的模型调用卡在哪儿。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyProblem {
    /// key 无效或没有权限（厂商回 401、403）。
    Invalid,
    /// 余额不足、额度用完（厂商回 402）。
    NoBalance,
    /// 没有能用的 key：都停用了、当日预算用完、解不开（网关没把请求发出去）。
    Unavailable,
    /// 被限流（429）。
    RateLimited,
    /// 模型服务繁忙（503、529）或连不上。
    Overloaded,
}

/// 最近一次失败离现在超过这么久，就不算卡住（agent 在干别的，比如跑工具）。
fn stale() -> TimeDelta {
    TimeDelta::minutes(10)
}

/// 只有暂时性的失败（限流、繁忙）时，连续失败持续这么久才算卡住：短暂的限流 agent 自己会重试。
fn persistent() -> TimeDelta {
    TimeDelta::minutes(2)
}

impl KeyProblem {
    fn of(call: &ModelCall) -> Option<Self> {
        match call.outcome.as_str() {
            "unavailable" => return Some(Self::Unavailable),
            "connect_failed" => return Some(Self::Overloaded),
            _ => {}
        }
        match call.status {
            401 | 403 => Some(Self::Invalid),
            402 => Some(Self::NoBalance),
            429 => Some(Self::RateLimited),
            503 | 529 => Some(Self::Overloaded),
            _ => None,
        }
    }

    /// 过一会儿多半自己就好，不用用户处理。
    pub fn transient(self) -> bool {
        matches!(self, Self::RateLimited | Self::Overloaded)
    }

    /// 多久以后自己再试一次；`None` 表示等用户处理（换 key）。
    pub fn retry_after(self) -> Option<Duration> {
        match self {
            Self::RateLimited | Self::Overloaded => Some(Duration::from_secs(5 * 60)),
            Self::NoBalance | Self::Unavailable => Some(Duration::from_secs(3600)),
            Self::Invalid => None,
        }
    }

    /// 给用户看的说明（运行的状态说明、通知正文）。
    pub fn describe(self) -> &'static str {
        match self {
            Self::Invalid => "模型 key 无效或没有权限，任务已暂停。更换 key 后自动继续。",
            Self::NoBalance => "模型 key 余额不足，任务已暂停。充值或更换 key 后自动继续。",
            Self::Unavailable => {
                "没有能用的模型 key（停用了或今天的额度用完），任务已暂停。启用或更换 key 后自动继续。"
            }
            Self::RateLimited => "模型 key 被限流，任务暂停几分钟后自动继续。",
            Self::Overloaded => "模型服务繁忙，任务暂停几分钟后自动继续。",
        }
    }
}

/// agent 是不是卡在模型 key 上。`calls` 是这次尝试以来的模型调用，新的在前。
/// 只看最近一次成功之后的连续失败：
///
/// - 要用户处理的失败（key 无效、欠费、没有能用的 key）连续两次：卡住了（降级链试过所有 key、
///   agent 也重试过）；
/// - 只有限流、繁忙：连续三次以上、持续两分钟以上才算（短暂的限流 agent 自己会重试）；
/// - `turn_ended`：agent 这一轮刚结束，最后的调用失败了，说明它是因为失败放弃的：
///   一次要用户处理的失败、或者两次暂时性失败就算。
///
/// 要用户处理的原因优先报（最近的一次），都是暂时性的就报最近的那种。
pub fn key_problem(
    calls: &[ModelCall],
    now: DateTime<Utc>,
    turn_ended: bool,
) -> Option<KeyProblem> {
    let streak: Vec<(KeyProblem, DateTime<Utc>)> = calls
        .iter()
        .map_while(|c| KeyProblem::of(c).map(|p| (p, c.at)))
        .collect();
    let &(latest, newest) = streak.first()?;
    if now - newest > stale() {
        return None;
    }
    let oldest = streak.last().map_or(newest, |(_, at)| *at);
    let fatal = streak.iter().filter(|(p, _)| !p.transient()).count();
    let stuck = if turn_ended {
        fatal >= 1 || streak.len() >= 2
    } else {
        fatal >= 2 || (streak.len() >= 3 && newest - oldest >= persistent())
    };
    if !stuck {
        return None;
    }
    Some(
        streak
            .iter()
            .map(|(p, _)| *p)
            .find(|p| !p.transient())
            .unwrap_or(latest),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(status: u16, outcome: &str, secs_ago: i64, now: DateTime<Utc>) -> ModelCall {
        ModelCall {
            status,
            outcome: outcome.into(),
            at: now - TimeDelta::seconds(secs_ago),
        }
    }

    #[test]
    fn fatal_failures_block_after_two_in_a_row() {
        let now = Utc::now();
        let failed = |s, ago| call(s, "upstream_status", ago, now);
        // 主 key 401、备用 key 402：降级链试完了。
        let calls = [failed(402, 1), failed(401, 2)];
        assert_eq!(key_problem(&calls, now, false), Some(KeyProblem::NoBalance));
        // 只失败了一次：agent 还会重试，先不管。
        assert_eq!(key_problem(&calls[..1], now, false), None);
        // 一轮刚结束、最后一次调用失败了：一次就算。
        assert_eq!(
            key_problem(&calls[1..], now, true),
            Some(KeyProblem::Invalid)
        );
        // 网关没把请求发出去（停用、当日额度用完）。
        let unavailable = [
            call(402, "unavailable", 1, now),
            call(403, "unavailable", 3, now),
        ];
        assert_eq!(
            key_problem(&unavailable, now, false),
            Some(KeyProblem::Unavailable)
        );
    }

    #[test]
    fn a_success_after_the_failures_clears_it() {
        let now = Utc::now();
        let calls = [
            call(200, "complete", 1, now),
            call(401, "upstream_status", 5, now),
            call(401, "upstream_status", 6, now),
        ];
        assert_eq!(key_problem(&calls, now, false), None);
        assert_eq!(key_problem(&calls, now, true), None);
        // 请求本身的问题（400）、厂商的 500 不是 key 的问题。
        let calls = [
            call(400, "upstream_status", 1, now),
            call(500, "upstream_status", 2, now),
        ];
        assert_eq!(key_problem(&calls, now, true), None);
        assert_eq!(key_problem(&[], now, true), None);
    }

    #[test]
    fn rate_limits_must_persist() {
        let now = Utc::now();
        let limited = |ago| call(429, "upstream_status", ago, now);
        // 三次 429，但只持续了几秒：agent 自己会退避重试。
        let brief = [limited(1), limited(3), limited(6)];
        assert_eq!(key_problem(&brief, now, false), None);
        // 持续了两分钟以上。
        let long = [limited(1), limited(60), limited(130)];
        assert_eq!(
            key_problem(&long, now, false),
            Some(KeyProblem::RateLimited)
        );
        // 一轮结束时最后两次都是暂时性失败：agent 放弃了。
        assert_eq!(
            key_problem(&brief[..2], now, true),
            Some(KeyProblem::RateLimited)
        );
        assert_eq!(key_problem(&brief[..1], now, true), None);
        // 暂时性和要用户处理的混在一起：报要用户处理的。
        let mixed = [limited(1), call(401, "upstream_status", 2, now), limited(3)];
        assert_eq!(key_problem(&mixed, now, true), Some(KeyProblem::Invalid));
        // 连不上厂商、厂商繁忙也算暂时性的。
        let down = [
            call(0, "connect_failed", 1, now),
            call(529, "upstream_status", 70, now),
            call(503, "upstream_status", 140, now),
        ];
        assert_eq!(key_problem(&down, now, false), Some(KeyProblem::Overloaded));
    }

    #[test]
    fn old_failures_do_not_count() {
        let now = Utc::now();
        let calls = [
            call(401, "upstream_status", 900, now),
            call(401, "upstream_status", 901, now),
        ];
        assert_eq!(key_problem(&calls, now, true), None);
    }

    #[test]
    fn retry_and_wording() {
        assert_eq!(KeyProblem::Invalid.retry_after(), None);
        assert!(KeyProblem::RateLimited.retry_after().unwrap() < Duration::from_secs(600));
        assert!(KeyProblem::NoBalance.retry_after().is_some());
        for p in [
            KeyProblem::Invalid,
            KeyProblem::NoBalance,
            KeyProblem::Unavailable,
            KeyProblem::RateLimited,
            KeyProblem::Overloaded,
        ] {
            assert!(p.describe().chars().count() <= 100, "{p:?}");
            assert_eq!(
                p.transient(),
                p.retry_after() == Some(Duration::from_secs(300))
            );
        }
    }
}
