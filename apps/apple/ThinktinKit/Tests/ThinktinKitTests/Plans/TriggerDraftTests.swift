import Foundation
import Testing

@testable import ThinktinKit

// 触发器编辑器：常用写法生成 cron、已有规则拆回来、写法之间换、保存前的检查。

@Suite("触发器编辑器")
struct TriggerDraftTests {
    let now = PlansFixture.date(2026, 10, 22, 10, 0)  // 周四
    let zone = PlansFixture.shanghai

    func draft(_ edit: (inout TriggerDraft) -> Void = { _ in }) -> TriggerDraft {
        var d = TriggerDraft(timeZone: zone, now: now)
        edit(&d)
        return d
    }

    @Test("新的一条：每天 09:00、设备时区；每周默认今天，每月默认今天的日子")
    func defaults() {
        let d = draft()
        #expect(d.kind == .daily)
        #expect(d.schedule == .cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai"))
        #expect(d.weekdays == [4])
        #expect(d.monthDays == [22])
        #expect(d.onceAt == PlansFixture.date(2026, 10, 22, 11, 0))
        #expect(d.problem(now: now) == nil)
    }

    @Test("常用写法生成 cron")
    func calendarSchedules() {
        #expect(
            draft {
                $0.kind = .weekly
                $0.weekdays = [1, 2, 3, 4, 5]
                $0.hour = 8
                $0.minute = 30
            }.schedule == .cron(expression: "30 8 * * 1-5", timeZone: "Asia/Shanghai"))
        #expect(
            draft {
                $0.kind = .weekly
                $0.weekdays = [5, 1]
            }.schedule == .cron(expression: "0 9 * * 1,5", timeZone: "Asia/Shanghai"))
        #expect(
            draft {
                $0.kind = .weekly
                $0.weekdays = Set(0...6)
            }.schedule == .cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai"))
        #expect(
            draft {
                $0.kind = .monthly
                $0.monthDays = [15, 1]
                $0.timeZoneID = "Asia/Tokyo"
            }.schedule == .cron(expression: "0 9 1,15 * *", timeZone: "Asia/Tokyo"))
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = "  */30   9-17  * * 1-5 "
            }.schedule == .cron(expression: "*/30 9-17 * * 1-5", timeZone: "Asia/Shanghai"))
    }

    @Test("RRULE：补上带时区的 DTSTART；贴进来的完整规则原样用")
    func rrule() {
        let d = draft {
            $0.kind = .rrule
            $0.rruleText = "rrule:freq=weekly;byday=mo"
            $0.startDay = LocalDay(year: 2026, month: 10, day: 23)
            $0.hour = 7
            $0.minute = 5
        }
        #expect(d.schedule == .rrule("DTSTART;TZID=Asia/Shanghai:20261023T070500\nRRULE:FREQ=WEEKLY;BYDAY=MO"))
        #expect(d.problem(now: now) == nil)
        let full = draft {
            $0.kind = .rrule
            $0.rruleText = "DTSTART:20261023T010000Z\r\nRRULE:FREQ=DAILY"
        }
        #expect(full.schedule == .rrule("DTSTART:20261023T010000Z\nRRULE:FREQ=DAILY"))
        #expect(full.rruleHasOwnStart)
        #expect(!d.rruleHasOwnStart)
        // UTC 的 DTSTART 拆回来，时区写成 UTC（不是 GMT）。
        let utc = TriggerDraft(schedule: .rrule("DTSTART:20261023T010000Z\nRRULE:FREQ=DAILY"), timeZone: zone, now: now)
        #expect(utc.timeZoneID == "UTC")
        #expect(utc.schedule == .rrule("DTSTART;TZID=UTC:20261023T010000\nRRULE:FREQ=DAILY"))
    }

    @Test("已有规则拆回来：认得出的 cron 用常用写法，认不出的进高级")
    func adoptExisting() {
        let weekly = TriggerDraft(
            schedule: .cron(expression: "30 10 * * 1", timeZone: "Asia/Tokyo"), timeZone: zone, now: now)
        #expect(weekly.kind == .weekly)
        #expect(weekly.weekdays == [1])
        #expect((weekly.hour, weekly.minute) == (10, 30))
        #expect(weekly.timeZoneID == "Asia/Tokyo")
        #expect(weekly.schedule == .cron(expression: "30 10 * * 1", timeZone: "Asia/Tokyo"))

        let sundays = TriggerDraft(schedule: .cron(expression: "0 20 * * 7", timeZone: "Asia/Shanghai"), timeZone: zone)
        #expect(sundays.kind == .weekly)
        #expect(sundays.weekdays == [0])

        let monthly = TriggerDraft(
            schedule: .cron(expression: "0 8 1,15 * *", timeZone: "Asia/Shanghai"), timeZone: zone)
        #expect(monthly.kind == .monthly)
        #expect(monthly.monthDays == [1, 15])

        let daily = TriggerDraft(schedule: .cron(expression: "0 7 * * 0-6", timeZone: "Asia/Shanghai"), timeZone: zone)
        #expect(daily.kind == .daily)

        for odd in ["0 9 1 * 1", "*/15 * * * *", "0 9,18 * * *", "0 9 * 1 *", "0 9 L * *"] {
            let d = TriggerDraft(schedule: .cron(expression: odd, timeZone: "Asia/Shanghai"), timeZone: zone)
            #expect(d.kind == .cron, "\(odd)")
            #expect(d.cronExpression == odd)
        }

        let rule = TriggerDraft(
            schedule: .rrule("DTSTART;TZID=Asia/Tokyo:20261101T183000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"),
            timeZone: zone)
        #expect(rule.kind == .rrule)
        #expect(rule.rruleText == "FREQ=WEEKLY;INTERVAL=2;BYDAY=FR")
        #expect(rule.startDay == LocalDay(year: 2026, month: 11, day: 1))
        #expect((rule.hour, rule.minute) == (18, 30))
        #expect(rule.timeZoneID == "Asia/Tokyo")
        #expect(
            rule.schedule == .rrule("DTSTART;TZID=Asia/Tokyo:20261101T183000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"))

        let at = PlansFixture.date(2026, 10, 30, 14, 45)
        let once = TriggerDraft(schedule: .once(at), timeZone: zone)
        #expect(once.kind == .once)
        #expect(once.onceAt == at)
        #expect((once.hour, once.minute) == (14, 45))
    }

    @Test("换写法：常用 → cron 填好表达式；cron → 常用拆得出就用；→ RRULE 写好等价规则；→ 一次性挪到将来")
    func switchKinds() {
        var d = draft {
            $0.kind = .weekly
            $0.weekdays = [1, 3]
            $0.hour = 18
        }
        d.setKind(.cron, now: now)
        #expect(d.cronExpression == "0 18 * * 1,3")
        d.cronExpression = "15 7 10,20 * *"
        d.setKind(.monthly, now: now)
        #expect(d.kind == .monthly)
        #expect(d.monthDays == [10, 20])
        #expect((d.hour, d.minute) == (7, 15))
        d.setKind(.rrule, now: now)
        #expect(d.rruleText == "FREQ=MONTHLY;BYMONTHDAY=10,20")
        #expect(d.startDay == LocalDay(year: 2026, month: 10, day: 22))
        #expect(d.schedule == .rrule("DTSTART;TZID=Asia/Shanghai:20261022T071500\nRRULE:FREQ=MONTHLY;BYMONTHDAY=10,20"))
        d.rruleText = "FREQ=WEEKLY;BYDAY=SA,SU;BYHOUR=10;BYMINUTE=0"
        d.setKind(.weekly, now: now)
        #expect(d.weekdays == [0, 6])
        #expect((d.hour, d.minute) == (10, 0))
        d.onceAt = now.addingTimeInterval(-60)
        d.setKind(.once, now: now)
        #expect(d.onceAt == PlansFixture.date(2026, 10, 23, 10, 0))

        var weekly = draft {
            $0.kind = .weekly
            $0.weekdays = [0, 5, 1]
        }
        weekly.setKind(.rrule, now: now)
        #expect(weekly.rruleText == "FREQ=WEEKLY;BYDAY=MO,FR,SU")
    }

    @Test("检查：一次性要在将来，每周至少一天，cron 五段，时区认得")
    func problems() {
        #expect(
            draft {
                $0.kind = .once
                $0.onceAt = now
            }.problem(now: now) == .onceInPast)
        #expect(
            draft {
                $0.kind = .weekly
                $0.weekdays = []
            }.problem(now: now) == .noWeekdays)
        #expect(
            draft {
                $0.kind = .monthly
                $0.monthDays = []
            }.problem(now: now) == .noMonthDays)
        #expect(draft { $0.timeZoneID = "Mars/Olympus" }.problem(now: now) == .unknownTimeZone)
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = " "
            }.problem(now: now) == .cronEmpty)
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = "0 9 * *"
            }.problem(now: now) == .cronFieldCount)
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = "61 9 * * *"
            }.problem(now: now) == .cronInvalid)
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = "0 0 30 2 *"
            }.problem(now: now) == .neverFires)
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = "*/2 * * * *"
            }.problem(now: now) == .tooFrequent(minimumMinutes: 5))
        #expect(
            draft {
                $0.kind = .cron
                $0.cronExpression = "*/5 * * * *"
            }.problem(now: now) == nil)
    }

    @Test("App 算不了的 cron 只提示、不拦")
    func cannotPreview() {
        let d = draft {
            $0.kind = .cron
            $0.cronExpression = "0 9 L * *"
        }
        #expect(d.problem(now: now) == nil)
        #expect(d.warning == .cannotPreview)
        #expect(d.upcoming(now: now) == nil)
        #expect(draft().warning == nil)
        #expect(
            draft {
                $0.kind = .once
            }.warning == nil)
        #expect(
            draft().upcoming(now: now, count: 2) == [
                PlansFixture.date(2026, 10, 23, 9), PlansFixture.date(2026, 10, 24, 9),
            ])
    }

    @Test("RRULE 的检查（服务端 parse_new 的规矩）")
    func rruleProblems() {
        func problem(_ text: String, start: LocalDay = LocalDay(year: 2026, month: 10, day: 23)) -> TriggerProblem? {
            draft {
                $0.kind = .rrule
                $0.rruleText = text
                $0.startDay = start
            }.problem(now: now)
        }
        #expect(problem("") == .rruleEmpty)
        #expect(problem("INTERVAL=2") == .rruleNoFrequency)
        #expect(problem("FREQ=SECONDLY") == .rruleTooFrequent)
        #expect(problem("FREQ=DAILY\nRRULE:FREQ=WEEKLY") == .rruleMultipleRules)
        #expect(
            problem("DTSTART;TZID=Asia/Shanghai:20261023T090000\nRDATE:20261030T090000\nRRULE:FREQ=DAILY")
                == .rruleExtraDates)
        #expect(problem("DTSTART:20261023T090000\nRRULE:FREQ=DAILY") == .rruleNoTimeZone)
        #expect(problem("FREQ=DAILY", start: LocalDay(year: 2026, month: 10, day: 1)) == .rruleStartOutOfRange)
        #expect(problem("FREQ=DAILY", start: LocalDay(year: 2028, month: 1, day: 1)) == .rruleStartOutOfRange)
        #expect(problem("FREQ=DAILY;" + String(repeating: "X", count: 1000)) == .rruleTooLong(max: 1000))
        #expect(problem("FREQ=MINUTELY;INTERVAL=1") == nil)  // App 算不了 MINUTELY：交给服务端
        #expect(problem("FREQ=HOURLY;BYMINUTE=0,1") == .tooFrequent(minimumMinutes: 5))
        #expect(problem("FREQ=DAILY;COUNT=1", start: LocalDay(year: 2026, month: 10, day: 22)) == .neverFires)
        #expect(problem("FREQ=WEEKLY;BYDAY=MO") == nil)
    }

    @Test("每条问题都有中英文说明")
    func messages() {
        let all: [TriggerProblem] = [
            .onceInPast, .unknownTimeZone, .noWeekdays, .noMonthDays, .cronEmpty, .cronFieldCount, .cronInvalid,
            .rruleEmpty, .rruleTooLong(max: 1000), .rruleExtraDates, .rruleMultipleRules, .rruleNoFrequency,
            .rruleTooFrequent, .rruleNoTimeZone, .rruleStartOutOfRange, .neverFires, .tooFrequent(minimumMinutes: 5),
        ]
        for problem in all {
            #expect(!problem.message(.chinese).isEmpty)
            #expect(!problem.message(.english).isEmpty)
            #expect(problem.message(.chinese) != problem.message(.english))
        }
        #expect(TriggerProblem.tooFrequent(minimumMinutes: 5).message(.chinese).contains("5 分钟"))
        #expect(TriggerWarning.cannotPreview.message(.english).contains("server"))
    }
}
