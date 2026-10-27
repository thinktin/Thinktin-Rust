import Foundation
import Testing

@testable import ThinktinKit

// 本地预测触发时间：cron（croner 的语义）、RRULE（dateutil 的语义）、一次性。

@Suite("触发时间预测：cron")
struct CronForecastTests {
    let now = PlansFixture.date(2026, 10, 22, 10, 0)  // 周四

    func fires(_ expression: String, _ zone: String = "Asia/Shanghai", after: Date? = nil, count: Int = 5) -> [Date]? {
        ScheduleForecast.nextFires(.cron(expression: expression, timeZone: zone), after: after ?? now, count: count)
    }

    @Test("工作日 09:00：从明天（周五）开始，跳过周末")
    func weekdays() {
        #expect(
            fires("0 9 * * 1-5") == [
                PlansFixture.date(2026, 10, 23, 9), PlansFixture.date(2026, 10, 26, 9),
                PlansFixture.date(2026, 10, 27, 9),
                PlansFixture.date(2026, 10, 28, 9), PlansFixture.date(2026, 10, 29, 9),
            ])
    }

    @Test("严格晚于给的时间；每 15 分钟")
    func strictlyAfter() {
        #expect(fires("0 10 * * *", count: 1) == [PlansFixture.date(2026, 10, 23, 10)])
        #expect(
            fires("*/15 * * * *", count: 3) == [
                PlansFixture.date(2026, 10, 22, 10, 15), PlansFixture.date(2026, 10, 22, 10, 30),
                PlansFixture.date(2026, 10, 22, 10, 45),
            ])
    }

    @Test("“日”和“周”都写了时满足一个就算（croner 的默认）")
    func dayOrWeekday() {
        // 每月 1 日，或者每周一。
        #expect(
            fires("0 9 1 * 1", count: 3) == [
                PlansFixture.date(2026, 10, 26, 9), PlansFixture.date(2026, 11, 1, 9),
                PlansFixture.date(2026, 11, 2, 9),
            ])
        // `*/1` 不是 `*`：也按“满足一个”算，等于每天。
        #expect(
            fires("0 9 */1 * 1", count: 2) == [PlansFixture.date(2026, 10, 23, 9), PlansFixture.date(2026, 10, 24, 9)])
        // `?` 当 `*`。
        #expect(fires("0 9 ? * 5", count: 1) == [PlansFixture.date(2026, 10, 23, 9)])
    }

    @Test("月份、名字、闰年")
    func monthsAndNames() {
        #expect(fires("0 8 1 1 *", count: 1) == [PlansFixture.date(2027, 1, 1, 8)])
        #expect(
            fires("0 9 * JAN MON", count: 2) == [PlansFixture.date(2027, 1, 4, 9), PlansFixture.date(2027, 1, 11, 9)])
        #expect(fires("0 0 29 2 *", count: 1) == [PlansFixture.date(2028, 2, 29)])
        #expect(fires("0 9 * * 7", count: 1) == [PlansFixture.date(2026, 10, 25, 9)])
    }

    @Test("按规则的时区")
    func timeZone() {
        // 东京 09:00 = 北京 08:00。
        #expect(fires("0 9 * * *", "Asia/Tokyo", count: 1) == [PlansFixture.date(2026, 10, 23, 8)])
    }

    @Test("夏令时：跳过的时刻挪到跳过之后，重复的取较早的")
    func daylightSaving() {
        let ny = PlansFixture.newYork
        let before = PlansFixture.date(in: ny, 2026, 3, 7, 12)
        let gap = ScheduleForecast.nextFires(
            .cron(expression: "30 2 * * *", timeZone: ny.identifier), after: before, count: 2)
        #expect(gap == [PlansFixture.date(in: ny, 2026, 3, 8, 3, 0), PlansFixture.date(in: ny, 2026, 3, 9, 2, 30)])
        let fallBack = ScheduleForecast.nextFires(
            .cron(expression: "30 1 * * *", timeZone: ny.identifier),
            after: PlansFixture.date(in: ny, 2026, 10, 31, 12),
            count: 1)
        // 11 月 1 日 01:30 有两次（EDT、EST），取较早的 EDT（UTC 05:30）。
        #expect(fallBack == [Date(timeIntervalSince1970: 1_793_511_000)])
    }

    @Test("算不了、不会触发")
    func unsupported() {
        #expect(fires("0 9 L * *") == nil)
        #expect(fires("@daily") == nil)
        #expect(fires("0 9 * *") == nil)
        #expect(fires("0 9 * * *", "Mars/Olympus") == nil)
        #expect(fires("0 0 30 2 *") == [])
        #expect(!ScheduleForecast.canForecast(.cron(expression: "0 9 1W * *", timeZone: "Asia/Shanghai")))
        #expect(ScheduleForecast.canForecast(.cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai")))
    }

    @Test("最小间隔")
    func minimumGap() {
        let zone = "Asia/Shanghai"
        #expect(ScheduleForecast.minimumGap(.cron(expression: "* * * * *", timeZone: zone), after: now) == 60)
        #expect(ScheduleForecast.minimumGap(.cron(expression: "*/5 * * * *", timeZone: zone), after: now) == 300)
        #expect(ScheduleForecast.minimumGap(.cron(expression: "0 9 * * *", timeZone: zone), after: now) == 86400)
        #expect(ScheduleForecast.minimumGap(.cron(expression: "0,2 9 * * *", timeZone: zone), after: now) == 120)
        #expect(ScheduleForecast.minimumGap(.once(now.addingTimeInterval(60)), after: now) == nil)
    }

    @Test("一次性")
    func once() {
        let later = now.addingTimeInterval(3600)
        #expect(ScheduleForecast.nextFires(.once(later), after: now, count: 3) == [later])
        #expect(ScheduleForecast.nextFires(.once(now), after: now, count: 3) == [])
    }
}

@Suite("触发时间预测：RRULE")
struct RRuleForecastTests {
    let now = PlansFixture.date(2026, 10, 22, 10, 0)  // 周四

    func fires(_ text: String, after: Date? = nil, count: Int = 4) -> [Date]? {
        ScheduleForecast.nextFires(.rrule(text), after: after ?? now, count: count)
    }

    @Test("每周一、周三：DTSTART（周四）不符合规则，不算一次")
    func weekly() {
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE") == [
                PlansFixture.date(2026, 10, 26, 9), PlansFixture.date(2026, 10, 28, 9),
                PlansFixture.date(2026, 11, 2, 9),
                PlansFixture.date(2026, 11, 4, 9),
            ])
    }

    @Test("每 2 周的周五：按 DTSTART 所在的那一周（周一开始）数")
    func biweekly() {
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T183000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR", count: 3) == [
                PlansFixture.date(2026, 10, 23, 18, 30), PlansFixture.date(2026, 11, 6, 18, 30),
                PlansFixture.date(2026, 11, 20, 18, 30),
            ])
    }

    @Test("每 2 天；DTSTART 本身算第一次")
    func daily() {
        let early = PlansFixture.date(2026, 10, 22, 8)
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=DAILY;INTERVAL=2", after: early, count: 3)
                == [
                    PlansFixture.date(2026, 10, 22, 9), PlansFixture.date(2026, 10, 24, 9),
                    PlansFixture.date(2026, 10, 26, 9),
                ])
    }

    @Test("COUNT 从 DTSTART 数起，UNTIL 包含当天")
    func countAndUntil() {
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=DAILY;COUNT=3") == [
                PlansFixture.date(2026, 10, 23, 9), PlansFixture.date(2026, 10, 24, 9),
            ])
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=DAILY;UNTIL=20261024") == [
                PlansFixture.date(2026, 10, 23, 9), PlansFixture.date(2026, 10, 24, 9),
            ])
        #expect(fires("DTSTART;TZID=Asia/Shanghai:20261020T090000\nRRULE:FREQ=DAILY;COUNT=2") == [])
    }

    @Test("每月最后一个周五、每月 31 日（没有 31 日的月份跳过）、每月 -1 日")
    func monthly() {
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MONTHLY;BYDAY=-1FR", count: 3) == [
                PlansFixture.date(2026, 10, 30, 9), PlansFixture.date(2026, 11, 27, 9),
                PlansFixture.date(2026, 12, 25, 9),
            ])
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MONTHLY;BYMONTHDAY=31", count: 3) == [
                PlansFixture.date(2026, 10, 31, 9), PlansFixture.date(2026, 12, 31, 9),
                PlansFixture.date(2027, 1, 31, 9),
            ])
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MONTHLY;BYMONTHDAY=-1", count: 2) == [
                PlansFixture.date(2026, 10, 31, 9), PlansFixture.date(2026, 11, 30, 9),
            ])
        // 没写日子：DTSTART 那一天。
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MONTHLY", count: 2) == [
                PlansFixture.date(2026, 11, 22, 9), PlansFixture.date(2026, 12, 22, 9),
            ])
        // 第一个周一，BYHOUR 两个时刻。
        #expect(
            fires(
                "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MONTHLY;BYDAY=1MO;BYHOUR=9,18;BYMINUTE=0",
                count: 2) == [PlansFixture.date(2026, 11, 2, 9), PlansFixture.date(2026, 11, 2, 18)])
    }

    @Test("每年 3 月 15 日；每 6 小时；UTC 的 DTSTART")
    func yearlyHourlyUTC() {
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15", count: 1)
                == [
                    PlansFixture.date(2027, 3, 15, 9)
                ])
        #expect(
            fires("DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=HOURLY;INTERVAL=6", count: 3) == [
                PlansFixture.date(2026, 10, 22, 15), PlansFixture.date(2026, 10, 22, 21),
                PlansFixture.date(2026, 10, 23, 3),
            ])
        #expect(
            fires("DTSTART:20261022T010000Z\nRRULE:FREQ=DAILY", count: 2) == [
                PlansFixture.date(2026, 10, 23, 9), PlansFixture.date(2026, 10, 24, 9),
            ])
    }

    @Test("算不了的写法")
    func unsupported() {
        for text in [
            "FREQ=DAILY",  // 没有 DTSTART
            "DTSTART:20261022T090000\nRRULE:FREQ=DAILY",  // 浮动时间
            "DTSTART;VALUE=DATE:20261022\nRRULE:FREQ=DAILY",
            "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1",
            "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=DAILY\nEXDATE:20261023T090000",
            "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=MINUTELY;INTERVAL=10",
            "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=WEEKLY;BYDAY=1MO",
            "DTSTART;TZID=Nowhere/City:20261022T090000\nRRULE:FREQ=DAILY",
            "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=DAILY;BYHOUR=25",
        ] {
            #expect(fires(text) == nil, "\(text)")
        }
    }
}
