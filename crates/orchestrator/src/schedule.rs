//! 触发时间计算（架构方案 4.4，WBS 7.1、7.2、7.6）：cron、RRULE、一次性，带时区；削峰抖动；补跑策略。
//!
//! 这里只做纯计算，不碰数据库。调度循环用它算下一次触发时间、错过的触发怎么补。
//! - 时区存 IANA 名称，夏令时由 croner / rrule 按 chrono-tz 处理；
//! - 抖动由触发器 id 和名义触发时间确定性地算出，多副本、重启后结果一致；
//!   运行的唯一键用名义触发时间，抖动只影响实际启动时间。

use std::str::FromStr;
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use chrono_tz::Tz;
use croner::Cron;
use croner::parser::{CronParser, Seconds};

/// 一次最多展开这么多个触发时间（补跑、校验最小间隔时用），防止病态规则拖垮调度循环。
pub const MAX_EXPANSION: usize = 1000;
/// RRULE 文本的长度上限（新建、修改计划时）。
const MAX_RULE_LEN: usize = 1000;
/// rrule 每次计算都从 DTSTART 往后数，DTSTART 越早越慢：新建、修改计划时 DTSTART 只能在现在附近，
/// 长期运行的规则由调度循环定期把 DTSTART 挪到最近一次触发（[`Schedule::rebased_rrule`]）。
const DTSTART_PAST_DAYS: i64 = 1;
const DTSTART_FUTURE_DAYS: i64 = 366;
/// DTSTART 比最近一次触发早这么多天就挪。
const REBASE_AFTER_DAYS: i64 = 7;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ScheduleError {
    #[error("unknown time zone {0:?}")]
    TimeZone(String),
    #[error("invalid cron expression: {0}")]
    Cron(String),
    #[error("invalid recurrence rule: {0}")]
    RRule(String),
    #[error("the schedule fires more often than every {min_secs} seconds")]
    TooFrequent { min_secs: u64 },
}

pub use proto::domain::ScheduleSpec;

/// 解析好的触发方式。
#[derive(Debug, Clone)]
pub enum Schedule {
    Cron { cron: Box<Cron>, tz: Tz },
    Rrule { set: Box<rrule::RRuleSet> },
    Once { at: DateTime<Utc> },
}

pub use proto::domain::CatchUp;

pub fn parse_tz(name: &str) -> Result<Tz, ScheduleError> {
    Tz::from_str(name).map_err(|_| ScheduleError::TimeZone(name.to_owned()))
}

impl Schedule {
    pub fn parse(spec: &ScheduleSpec) -> Result<Self, ScheduleError> {
        match spec {
            ScheduleSpec::Cron { expr, tz } => {
                let tz = parse_tz(tz)?;
                let cron = CronParser::builder()
                    .seconds(Seconds::Disallowed)
                    .build()
                    .parse(expr)
                    .map_err(|e| ScheduleError::Cron(e.to_string()))?;
                Ok(Self::Cron {
                    cron: Box::new(cron),
                    tz,
                })
            }
            ScheduleSpec::Rrule { rule } => {
                let set: rrule::RRuleSet = rule
                    .parse()
                    .map_err(|e: rrule::RRuleError| ScheduleError::RRule(e.to_string()))?;
                if !rule.contains("TZID=")
                    && !rule
                        .lines()
                        .any(|l| l.starts_with("DTSTART:") && l.trim_end().ends_with('Z'))
                {
                    return Err(ScheduleError::RRule(
                        "DTSTART must carry a TZID (or be UTC)".into(),
                    ));
                }
                if rule.contains("FREQ=SECONDLY") {
                    return Err(ScheduleError::RRule("FREQ=SECONDLY is not allowed".into()));
                }
                // 只允许一条 RRULE、不允许 RDATE：多条规则或额外的日期能让前面的触发稀疏、后面的密集，
                // 躲过只看前几十次的频率检查。一条规则的间隔是周期性的。
                let upper: Vec<String> = rule
                    .lines()
                    .map(|l| l.trim().to_ascii_uppercase())
                    .collect();
                if upper.iter().filter(|l| l.starts_with("RRULE")).count() > 1 {
                    return Err(ScheduleError::RRule("only one RRULE is allowed".into()));
                }
                if upper.iter().any(|l| l.starts_with("RDATE")) {
                    return Err(ScheduleError::RRule("RDATE is not allowed".into()));
                }
                Ok(Self::Rrule { set: Box::new(set) })
            }
            ScheduleSpec::Once { at } => Ok(Self::Once { at: *at }),
        }
    }

    /// 新建、修改计划时用：在 `parse` 之外还要求 RRULE 不太长、DTSTART 在现在附近。
    pub fn parse_new(spec: &ScheduleSpec, now: DateTime<Utc>) -> Result<Self, ScheduleError> {
        if let ScheduleSpec::Rrule { rule } = spec
            && rule.len() > MAX_RULE_LEN
        {
            return Err(ScheduleError::RRule(format!(
                "the rule is longer than {MAX_RULE_LEN} characters"
            )));
        }
        let s = Self::parse(spec)?;
        if let Self::Rrule { set } = &s {
            let start = set.get_dt_start().with_timezone(&Utc);
            if start < now - chrono::Duration::days(DTSTART_PAST_DAYS)
                || start > now + chrono::Duration::days(DTSTART_FUTURE_DAYS)
            {
                return Err(ScheduleError::RRule(
                    "DTSTART must be between a day before and a year after now".into(),
                ));
            }
        }
        Ok(s)
    }

    /// DTSTART 是不是比 `last_fire` 早太久，该挪了（只对 RRULE）。
    pub fn needs_rebase(&self, last_fire: DateTime<Utc>) -> bool {
        match self {
            Self::Rrule { set } => {
                set.get_dt_start().with_timezone(&Utc)
                    < last_fire - chrono::Duration::days(REBASE_AFTER_DAYS)
            }
            _ => false,
        }
    }

    /// 把 RRULE 的 DTSTART 挪到 `at`（规则的一次触发），得到之后触发完全一样、算起来快的规则。
    /// 带 COUNT 的规则（挪了次数会变）、不带时区的 DTSTART、挪完后面几次触发对不上的（比如夏令时调整过的那次），
    /// 都返回 `None`，保持原样。
    pub fn rebased_rrule(rule: &str, at: DateTime<Utc>) -> Option<String> {
        if rule.to_ascii_uppercase().contains("COUNT=") {
            return None;
        }
        let line = rule
            .lines()
            .find(|l| l.trim_start().to_ascii_uppercase().starts_with("DTSTART"))?;
        let (params, value) = line.trim().rsplit_once(':')?;
        let new_value = match params.split_once("TZID=") {
            Some((_, tz)) => {
                let tz = parse_tz(tz.split(';').next()?).ok()?;
                at.with_timezone(&tz).format("%Y%m%dT%H%M%S").to_string()
            }
            None if value.ends_with('Z') => at.format("%Y%m%dT%H%M%SZ").to_string(),
            None => return None,
        };
        let rebased: String = rule
            .lines()
            .map(|l| {
                if std::ptr::eq(l, line) {
                    format!("{params}:{new_value}")
                } else {
                    l.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        let old = Self::parse(&ScheduleSpec::Rrule { rule: rule.into() }).ok()?;
        let new = Self::parse(&ScheduleSpec::Rrule {
            rule: rebased.clone(),
        })
        .ok()?;
        let one_second = chrono::Duration::seconds(1);
        if old.next_after(at - one_second) != Some(at) {
            return None;
        }
        let ahead = |s: &Self| s.first_after(at - one_second, 6);
        (ahead(&old) == ahead(&new)).then_some(rebased)
    }

    /// 严格晚于 `from` 的前 `n` 次触发。RRULE 一次遍历（每次单独算都要从 DTSTART 重新数）。
    fn first_after(&self, from: DateTime<Utc>, n: usize) -> Vec<DateTime<Utc>> {
        let n = n.min(MAX_EXPANSION);
        match self {
            Self::Rrule { set } => {
                let start = (from + chrono::Duration::seconds(1)).with_timezone(&rrule::Tz::UTC);
                (**set)
                    .clone()
                    .after(start)
                    .all(u16::try_from(n).unwrap_or(u16::MAX))
                    .dates
                    .into_iter()
                    .map(|t| t.with_timezone(&Utc))
                    .collect()
            }
            _ => {
                let mut out = Vec::new();
                let mut cursor = from;
                while out.len() < n {
                    match self.next_after(cursor) {
                        Some(t) => {
                            out.push(t);
                            cursor = t;
                        }
                        None => break,
                    }
                }
                out
            }
        }
    }

    /// 严格晚于 `after` 的下一次触发；没有了返回 `None`。
    pub fn next_after(&self, after: DateTime<Utc>) -> Option<DateTime<Utc>> {
        match self {
            Self::Cron { cron, tz } => cron
                .find_next_occurrence(&after.with_timezone(tz), false)
                .ok()
                .map(|t| t.with_timezone(&Utc)),
            Self::Rrule { set } => {
                // rrule 的 after 是闭区间，往后挪 1 秒变成开区间（规则的最小粒度是秒）。
                let start = (after + chrono::Duration::seconds(1)).with_timezone(&rrule::Tz::UTC);
                (**set)
                    .clone()
                    .after(start)
                    .all(1)
                    .dates
                    .first()
                    .map(|t| t.with_timezone(&Utc))
            }
            Self::Once { at } => (*at > after).then_some(*at),
        }
    }

    /// `(from, to]` 区间内的触发时间，最多 `cap` 个（按时间先后）。
    pub fn fires_between(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        cap: usize,
    ) -> Vec<DateTime<Utc>> {
        if let Self::Rrule { set } = self {
            let start = (from + chrono::Duration::seconds(1)).with_timezone(&rrule::Tz::UTC);
            let cap = u16::try_from(cap.min(MAX_EXPANSION)).unwrap_or(u16::MAX);
            return (**set)
                .clone()
                .after(start)
                .before(to.with_timezone(&rrule::Tz::UTC))
                .all(cap)
                .dates
                .into_iter()
                .map(|t| t.with_timezone(&Utc))
                .collect();
        }
        let mut out = Vec::new();
        let mut cursor = from;
        while out.len() < cap.min(MAX_EXPANSION) {
            match self.next_after(cursor) {
                Some(t) if t <= to => {
                    out.push(t);
                    cursor = t;
                }
                _ => break,
            }
        }
        out
    }

    /// 从 `from` 起相邻两次触发的最小间隔（只看前 `samples` 次），用于按档位限制触发频率。
    pub fn min_interval(&self, from: DateTime<Utc>, samples: usize) -> Option<Duration> {
        self.first_after(from, samples)
            .windows(2)
            .map(|w| (w[1] - w[0]).to_std().unwrap_or_default())
            .min()
    }

    /// 校验触发间隔不小于档位允许的最小值。
    pub fn check_min_interval(
        &self,
        now: DateTime<Utc>,
        min: Duration,
    ) -> Result<(), ScheduleError> {
        match self.min_interval(now, 50) {
            Some(gap) if gap < min => Err(ScheduleError::TooFrequent {
                min_secs: min.as_secs(),
            }),
            _ => Ok(()),
        }
    }
}

/// 补跑计划：现在要生成哪些运行（名义触发时间），以及触发器的下一次触发时间。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatchUpPlan {
    pub fires: Vec<DateTime<Utc>>,
    /// 因为上限丢掉的触发次数（要写日志，不能悄悄丢）。
    pub dropped: usize,
    pub next: Option<DateTime<Utc>>,
}

/// 调度循环处理一个到点的触发器：`due` 是它记录的下一次触发时间（已经 <= now）。
/// 正常情况只有 `due` 这一次；平台停机期间错过的，按补跑策略处理。
pub fn plan_due(
    schedule: &Schedule,
    due: DateTime<Utc>,
    now: DateTime<Utc>,
    policy: CatchUp,
) -> CatchUpPlan {
    let mut missed = vec![due];
    missed.extend(schedule.fires_between(due, now, MAX_EXPANSION));
    let next = schedule.next_after(now.max(*missed.last().unwrap()));
    let total = missed.len();
    // 只错过了 `due` 这一次（正常到点），任何策略都照常执行。
    if total == 1 {
        return CatchUpPlan {
            fires: missed,
            dropped: 0,
            next,
        };
    }
    let fires = match policy {
        CatchUp::Once => vec![*missed.last().unwrap()],
        CatchUp::All => missed,
        CatchUp::Skip => Vec::new(),
    };
    let dropped = if policy == CatchUp::All && total >= MAX_EXPANSION {
        // fires_between 碰到上限：可能还有更多没展开。
        1
    } else {
        0
    };
    CatchUpPlan {
        fires,
        dropped,
        next,
    }
}

/// 不管规则怎么写，同一个触发器相邻两次触发至少隔 `min`：太近的丢掉，下一次排到最后一次之后至少 `min`。
/// 解析时的频率检查只看前几十次，这里是最后一道兜底。返回丢掉的个数。
pub fn enforce_min_gap(
    plan: &mut CatchUpPlan,
    schedule: &Schedule,
    last_fire: Option<DateTime<Utc>>,
    min: Duration,
) -> usize {
    let Ok(min) = chrono::Duration::from_std(min) else {
        return 0;
    };
    let before = plan.fires.len();
    let mut prev = last_fire;
    plan.fires.retain(|f| {
        // 和上一次是同一个名义时间：是重复扫描，交给 (plan_id, fire_time) 唯一约束去重，不算太频繁。
        let ok = prev.is_none_or(|p| *f == p || *f - p >= min);
        if ok {
            prev = Some(*f);
        }
        ok
    });
    if let (Some(p), Some(next)) = (prev, plan.next)
        && next - p < min
    {
        plan.next = schedule.next_after(p + min - chrono::Duration::seconds(1));
    }
    before - plan.fires.len()
}

/// 确定性的削峰抖动：`[0, max)` 之间，由触发器 id 和名义触发时间决定（FNV-1a，跨版本稳定）。
pub fn jitter(trigger_id: &[u8], fire: DateTime<Utc>, max: Duration) -> Duration {
    let ms = max.as_millis() as u64;
    if ms == 0 {
        return Duration::ZERO;
    }
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in trigger_id
        .iter()
        .chain(fire.timestamp().to_be_bytes().iter())
    {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    Duration::from_millis(h % ms)
}

/// 本地时间转 UTC 的小工具（测试和界面预览用）。歧义时间取较早的那个。
pub fn local_to_utc(tz: Tz, y: i32, mo: u32, d: u32, h: u32, mi: u32) -> Option<DateTime<Utc>> {
    tz.with_ymd_and_hms(y, mo, d, h, mi, 0)
        .earliest()
        .map(|t| t.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        s.parse().unwrap()
    }

    fn cron(expr: &str, tz: &str) -> Schedule {
        Schedule::parse(&ScheduleSpec::Cron {
            expr: expr.into(),
            tz: tz.into(),
        })
        .unwrap()
    }

    #[test]
    fn cron_in_user_time_zone() {
        // 每天早上 8 点（上海）= UTC 0 点。
        let s = cron("0 8 * * *", "Asia/Shanghai");
        assert_eq!(
            s.next_after(utc("2026-10-14T00:00:00Z")),
            Some(utc("2026-10-15T00:00:00Z"))
        );
        assert_eq!(
            s.next_after(utc("2026-10-13T23:59:59Z")),
            Some(utc("2026-10-14T00:00:00Z"))
        );
        let fires = s.fires_between(utc("2026-10-14T00:00:00Z"), utc("2026-10-17T00:00:00Z"), 10);
        assert_eq!(fires.len(), 3);
    }

    #[test]
    fn dst_transitions() {
        // 纽约 2026-03-08 凌晨 2 点跳到 3 点：2:30 的定时当天在跳过后的第一个有效时间执行。
        let s = cron("30 2 * * *", "America/New_York");
        let t = s.next_after(utc("2026-03-08T05:00:00Z")).unwrap(); // 当地 00:00 EST
        assert_eq!(
            t.with_timezone(&chrono_tz::America::New_York)
                .date_naive()
                .to_string(),
            "2026-03-08"
        );
        // 秋天 1 点重复一小时：1:30 的定时只触发一次。
        let s = cron("30 1 * * *", "America/New_York");
        let fires = s.fires_between(utc("2026-11-01T04:00:00Z"), utc("2026-11-02T04:00:00Z"), 10);
        assert_eq!(fires.len(), 1, "{fires:?}");
        // 每天 8 点（纽约）：夏令时前后 UTC 时间不同。
        let s = cron("0 8 * * *", "America/New_York");
        assert_eq!(
            s.next_after(utc("2026-03-06T00:00:00Z")),
            Some(utc("2026-03-06T13:00:00Z"))
        );
        assert_eq!(
            s.next_after(utc("2026-03-10T00:00:00Z")),
            Some(utc("2026-03-10T12:00:00Z"))
        );
    }

    /// 多条 RRULE 或 RDATE：前几十次稀疏、后面密集，躲过频率检查。解析时拒绝，调度时还有兜底。
    #[test]
    fn dense_later_fires_cannot_slip_past_the_frequency_limit() {
        for rule in [
            "DTSTART;TZID=Asia/Shanghai:20261015T090000\nRRULE:FREQ=DAILY;COUNT=60\nRRULE:FREQ=MINUTELY;BYMONTH=6",
            "DTSTART;TZID=Asia/Shanghai:20261015T090000\nRRULE:FREQ=DAILY\nRDATE;TZID=Asia/Shanghai:20270601T000000,20270601T000100",
        ] {
            assert!(
                Schedule::parse(&ScheduleSpec::Rrule { rule: rule.into() }).is_err(),
                "{rule}"
            );
        }
        // 兜底：每分钟一次的规则（假设绕过了解析检查）到调度时按最小间隔丢掉太近的。
        let s = cron("* * * * *", "UTC");
        let mut plan = CatchUpPlan {
            fires: vec![
                utc("2026-10-15T00:00:00Z"),
                utc("2026-10-15T00:01:00Z"),
                utc("2026-10-15T00:05:00Z"),
                utc("2026-10-15T00:06:00Z"),
            ],
            dropped: 0,
            next: Some(utc("2026-10-15T00:07:00Z")),
        };
        let five = Duration::from_secs(300);
        let dropped = enforce_min_gap(&mut plan, &s, Some(utc("2026-10-14T23:58:00Z")), five);
        assert_eq!(
            dropped, 3,
            "00:00 and 00:01 follow 23:58 too soon, 00:06 follows 00:05"
        );
        assert_eq!(plan.fires, [utc("2026-10-15T00:05:00Z")]);
        assert_eq!(plan.next, Some(utc("2026-10-15T00:10:00Z")));
    }

    /// rrule 每次都从 DTSTART 往后数：新建时 DTSTART 只能在现在附近；长期运行的规则把 DTSTART 挪到最近一次触发。
    #[test]
    fn rrule_start_is_bounded_and_moved_forward() {
        let now = utc("2026-10-15T00:00:00Z");
        let rule = |r: &str| ScheduleSpec::Rrule { rule: r.into() };
        assert!(
            Schedule::parse_new(
                &rule("DTSTART:20250101T000000Z\nRRULE:FREQ=MINUTELY;INTERVAL=5"),
                now
            )
            .is_err(),
            "a DTSTART long ago makes every evaluation walk from it"
        );
        assert!(
            Schedule::parse_new(&rule("DTSTART:20261015T080000Z\nRRULE:FREQ=DAILY"), now).is_ok()
        );
        let long = format!(
            "DTSTART:20261015T080000Z\nRRULE:FREQ=DAILY\nEXDATE:{}",
            "20261016T080000Z,".repeat(80)
        );
        assert!(Schedule::parse_new(&rule(&long), now).is_err());

        // 每天早上 9 点（上海），从年初开始：挪到 10 月 14 日那次，之后完全一样。
        let daily = "DTSTART;TZID=Asia/Shanghai:20260101T090000\nRRULE:FREQ=DAILY;BYDAY=MO,WE,FR";
        let at = utc("2026-10-14T01:00:00Z"); // 周三上海 9 点
        let s = Schedule::parse(&rule(daily)).unwrap();
        assert!(s.needs_rebase(at));
        let moved = Schedule::rebased_rrule(daily, at).unwrap();
        assert!(
            moved.starts_with("DTSTART;TZID=Asia/Shanghai:20261014T090000"),
            "{moved}"
        );
        let m = Schedule::parse(&rule(&moved)).unwrap();
        assert!(!m.needs_rebase(at));
        let span = (utc("2026-10-14T01:00:00Z"), utc("2027-01-01T00:00:00Z"));
        assert_eq!(
            s.fires_between(span.0, span.1, 100),
            m.fires_between(span.0, span.1, 100)
        );
        // 带 COUNT 的规则挪了次数会变；不是规则里的触发时间也不挪。
        let counted = "DTSTART;TZID=Asia/Shanghai:20260101T090000\nRRULE:FREQ=DAILY;COUNT=400";
        assert_eq!(Schedule::rebased_rrule(counted, at), None);
        assert_eq!(
            Schedule::rebased_rrule(daily, utc("2026-10-14T02:00:00Z")),
            None
        );
    }

    #[test]
    fn rrule_and_once() {
        let s = Schedule::parse(&ScheduleSpec::Rrule {
            rule:
                "DTSTART;TZID=Asia/Shanghai:20261014T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3"
                    .into(),
        })
        .unwrap();
        // 2026-10-14 是周三。
        let all = s.fires_between(utc("2026-10-01T00:00:00Z"), utc("2027-01-01T00:00:00Z"), 10);
        assert_eq!(
            all,
            [
                utc("2026-10-14T01:00:00Z"),
                utc("2026-10-19T01:00:00Z"),
                utc("2026-10-21T01:00:00Z")
            ]
        );
        assert_eq!(
            s.next_after(utc("2026-10-14T01:00:00Z")),
            Some(utc("2026-10-19T01:00:00Z"))
        );
        assert_eq!(s.next_after(utc("2026-10-21T01:00:00Z")), None);

        let once = Schedule::parse(&ScheduleSpec::Once {
            at: utc("2026-10-20T00:00:00Z"),
        })
        .unwrap();
        assert_eq!(
            once.next_after(utc("2026-10-19T00:00:00Z")),
            Some(utc("2026-10-20T00:00:00Z"))
        );
        assert_eq!(once.next_after(utc("2026-10-20T00:00:00Z")), None);
    }

    #[test]
    fn invalid_specs_are_rejected() {
        let bad = [
            ScheduleSpec::Cron {
                expr: "0 8 * * *".into(),
                tz: "Mars/Olympus".into(),
            },
            ScheduleSpec::Cron {
                expr: "61 8 * * *".into(),
                tz: "UTC".into(),
            },
            ScheduleSpec::Cron {
                expr: "*/5 * * * * *".into(),
                tz: "UTC".into(),
            },
            ScheduleSpec::Rrule {
                rule: "RRULE:FREQ=DAILY".into(),
            },
            ScheduleSpec::Rrule {
                rule: "DTSTART:20261014T090000\nRRULE:FREQ=DAILY".into(),
            },
            ScheduleSpec::Rrule {
                rule: "DTSTART:20261014T090000Z\nRRULE:FREQ=SECONDLY".into(),
            },
        ];
        for spec in bad {
            assert!(Schedule::parse(&spec).is_err(), "{spec:?}");
        }
    }

    #[test]
    fn minimum_interval_enforcement() {
        let now = utc("2026-10-14T00:00:00Z");
        let every_minute = cron("* * * * *", "UTC");
        assert_eq!(
            every_minute.check_min_interval(now, Duration::from_secs(600)),
            Err(ScheduleError::TooFrequent { min_secs: 600 })
        );
        assert!(
            cron("0 */2 * * *", "UTC")
                .check_min_interval(now, Duration::from_secs(600))
                .is_ok()
        );
    }

    #[test]
    fn catch_up_policies() {
        let s = cron("0 * * * *", "UTC");
        let due = utc("2026-10-14T00:00:00Z");
        // 正常到点：只有这一次。
        let on_time = plan_due(&s, due, utc("2026-10-14T00:00:05Z"), CatchUp::Skip);
        assert_eq!(on_time.fires, [due]);
        assert_eq!(on_time.next, Some(utc("2026-10-14T01:00:00Z")));
        // 停机 3 小时多：错过 00、01、02、03 点。
        let now = utc("2026-10-14T03:30:00Z");
        let once = plan_due(&s, due, now, CatchUp::Once);
        assert_eq!(once.fires, [utc("2026-10-14T03:00:00Z")]);
        assert_eq!(once.next, Some(utc("2026-10-14T04:00:00Z")));
        assert_eq!(plan_due(&s, due, now, CatchUp::All).fires.len(), 4);
        assert!(plan_due(&s, due, now, CatchUp::Skip).fires.is_empty());
    }

    #[test]
    fn jitter_is_deterministic_and_bounded() {
        let t = utc("2026-10-14T00:00:00Z");
        let max = Duration::from_secs(30);
        let a = jitter(b"trig-1", t, max);
        assert_eq!(a, jitter(b"trig-1", t, max));
        assert!(a < max);
        let spread: std::collections::HashSet<_> = (0..50)
            .map(|i| jitter(format!("trig-{i}").as_bytes(), t, max))
            .collect();
        assert!(spread.len() > 40, "jitter spreads triggers apart");
        assert_eq!(jitter(b"x", t, Duration::ZERO), Duration::ZERO);
    }
}
