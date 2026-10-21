import Foundation
import Testing

@testable import ThinktinKit

// 格式化（相对时间、时长、token、字节）和触发规则的人话描述，中英文。

private let cal = Fixture.calendar
private let now = Fixture.now  // 2026-10-22 10:00 北京时间

private func rel(_ date: Date, _ language: DisplayLanguage) -> String {
    Formatting.relativeTime(date, now: now, language: language, calendar: cal)
}

@Suite("格式化：时间")
struct RelativeTimeTests {
    @Test(
        "过去的时间",
        arguments: [
            (Fixture.date(2026, 10, 22, 9, 59, 30), "刚刚", "just now"),
            (Fixture.date(2026, 10, 22, 9, 59, 1), "刚刚", "just now"),
            (Fixture.date(2026, 10, 22, 9, 59, 0), "1 分钟前", "1 min ago"),
            (Fixture.date(2026, 10, 22, 9, 55), "5 分钟前", "5 min ago"),
            (Fixture.date(2026, 10, 22, 9, 0, 1), "59 分钟前", "59 min ago"),
            (Fixture.date(2026, 10, 22, 9, 0), "1 小时前", "1 hr ago"),
            (Fixture.date(2026, 10, 22, 7, 0), "3 小时前", "3 hr ago"),
            // 同一天的都按小时。
            (Fixture.date(2026, 10, 22, 0, 30), "9 小时前", "9 hr ago"),
            // 不到 6 小时、跨了午夜的也按小时；超过 6 小时的按“昨天”。
            (Fixture.date(2026, 10, 21, 14, 5), "昨天 14:05", "yesterday 14:05"),
            (Fixture.date(2026, 10, 19, 8, 0), "3 天前", "3 days ago"),
            (Fixture.date(2026, 10, 16, 8, 0), "6 天前", "6 days ago"),
            (Fixture.date(2026, 10, 12, 8, 0), "10月12日", "Oct 12"),
            (Fixture.date(2026, 1, 3, 8, 0), "1月3日", "Jan 3"),
            (Fixture.date(2025, 10, 21, 8, 0), "2025年10月21日", "Oct 21, 2025"),
        ])
    func past(date: Date, zh: String, en: String) {
        #expect(rel(date, .chinese) == zh)
        #expect(rel(date, .english) == en)
    }

    @Test(
        "将来的时间",
        arguments: [
            (Fixture.date(2026, 10, 22, 10, 0, 20), "刚刚", "just now"),
            (Fixture.date(2026, 10, 22, 10, 5), "5 分钟后", "in 5 min"),
            (Fixture.date(2026, 10, 22, 13, 0), "3 小时后", "in 3 hr"),
            (Fixture.date(2026, 10, 23, 9, 0), "明天 09:00", "tomorrow 09:00"),
            (Fixture.date(2026, 10, 25, 9, 0), "3 天后", "in 3 days"),
            (Fixture.date(2026, 11, 30, 9, 0), "11月30日", "Nov 30"),
            (Fixture.date(2027, 2, 1, 9, 0), "2027年2月1日", "Feb 1, 2027"),
        ])
    func future(date: Date, zh: String, en: String) {
        #expect(rel(date, .chinese) == zh)
        #expect(rel(date, .english) == en)
    }

    @Test("跨午夜不到 6 小时：按小时")
    func acrossMidnight() {
        let lateNight = Fixture.date(2026, 10, 22, 1, 0)
        let date = Fixture.date(2026, 10, 21, 23, 0)
        #expect(Formatting.relativeTime(date, now: lateNight, language: .chinese, calendar: cal) == "2 小时前")
        #expect(Formatting.relativeTime(date, now: lateNight, language: .english, calendar: cal) == "2 hr ago")
    }

    @Test("日期、日期加时间、时钟")
    func dates() {
        let d = Fixture.date(2026, 3, 5, 9, 7)
        #expect(Formatting.shortDate(d, now: now, language: .chinese, calendar: cal) == "3月5日")
        #expect(Formatting.shortDate(d, now: now, language: .english, calendar: cal) == "Mar 5")
        #expect(Formatting.dateTime(d, now: now, language: .chinese, calendar: cal) == "3月5日 09:07")
        #expect(Formatting.dateTime(d, now: now, language: .english, calendar: cal) == "Mar 5, 09:07")
        let old = Fixture.date(2024, 12, 31, 23, 59)
        #expect(Formatting.dateTime(old, now: now, language: .chinese, calendar: cal) == "2024年12月31日 23:59")
        #expect(Formatting.dateTime(old, now: now, language: .english, calendar: cal) == "Dec 31, 2024, 23:59")
        #expect(Formatting.clockTime(Fixture.date(2026, 1, 1, 0, 0), calendar: cal) == "00:00")
        #expect(Formatting.clockTime(Fixture.date(2026, 1, 1, 18, 30), calendar: cal) == "18:30")
        // 同一时刻换个时区显示。
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(Formatting.clockTime(Fixture.date(2026, 1, 1, 18, 30), calendar: utc) == "10:30")
    }

    @Test(
        "时长",
        arguments: [
            (0.0, "0 秒", "0s"), (0.4, "0 秒", "0s"), (45, "45 秒", "45s"), (60, "1 分", "1m"), (200, "3 分 20 秒", "3m 20s"),
            (3600, "1 小时", "1h"), (7500, "2 小时 5 分", "2h 5m"), (7530, "2 小时 5 分", "2h 5m"),
            (86400, "1 天", "1d"), (3 * 86400 + 4 * 3600 + 59, "3 天 4 小时", "3d 4h"), (-5, "0 秒", "0s"),
        ] as [(TimeInterval, String, String)])
    func duration(seconds: TimeInterval, zh: String, en: String) {
        #expect(Formatting.duration(seconds, language: .chinese) == zh)
        #expect(Formatting.duration(seconds, language: .english) == en)
    }
}

@Suite("格式化：数量")
struct QuantityFormattingTests {
    @Test(
        "token 数",
        arguments: [
            (0, "0", "0"), (950, "950", "950"), (1_000, "1,000", "1K"), (1_234, "1,234", "1.2K"), (9_876, "9,876", "9.9K"),
            (10_000, "1 万", "10K"), (12_000, "1.2 万", "12K"), (18_420, "1.8 万", "18.4K"), (125_000, "12.5 万", "125K"),
            (950_000, "95 万", "950K"), (999_949, "100 万", "999.9K"), (999_999, "100 万", "1M"),
            (3_400_000, "340 万", "3.4M"), (99_999_999, "1 亿", "100M"),
            (350_000_000, "3.5 亿", "350M"), (999_999_999, "10 亿", "1B"), (2_500_000_000, "25 亿", "2.5B"),
            (-1_234, "-1,234", "-1.2K"),
        ])
    func tokens(count: Int, zh: String, en: String) {
        #expect(Formatting.tokens(count, language: .chinese) == zh)
        #expect(Formatting.tokens(count, language: .english) == en)
    }

    @Test(
        "字节数（1024 进制）",
        arguments: [
            (0, "0 B"), (512, "512 B"), (1023, "1023 B"), (1024, "1 KB"), (1536, "1.5 KB"), (2048, "2 KB"),
            (1_048_575, "1 MB"), (1_048_576, "1 MB"), (3_355_443, "3.2 MB"), (1_181_116_006, "1.1 GB"),
            (5 * 1_099_511_627_776, "5 TB"), (2_000 * 1_099_511_627_776, "2000 TB"), (-1, "0 B"),
        ])
    func bytes(count: Int, expected: String) {
        #expect(Formatting.bytes(count) == expected)
    }

    @Test("千分位、一位小数")
    func helpers() {
        #expect(Formatting.grouped(0) == "0")
        #expect(Formatting.grouped(999) == "999")
        #expect(Formatting.grouped(1_234_567) == "1,234,567")
        #expect(Formatting.grouped(-1_234) == "-1,234")
        #expect(Formatting.oneDecimal(1.25) == "1.3")
        #expect(Formatting.oneDecimal(2.0) == "2")
        #expect(Formatting.oneDecimal(1.04) == "1")
        #expect(Formatting.pad2(7) == "07")
        #expect(Formatting.pad2(12) == "12")
    }
}

@Suite("触发规则的描述")
struct ScheduleDescriptionTests {
    @Test(
        "cron",
        arguments: [
            ("0 9 * * *", "每天 09:00", "Every day at 09:00"),
            ("0 9 * * 1-5", "工作日 09:00", "Weekdays at 09:00"),
            ("0 9 * * MON-FRI", "工作日 09:00", "Weekdays at 09:00"),
            ("0 9,18 * * 1-5", "工作日 09:00、18:00", "Weekdays at 09:00 and 18:00"),
            ("0 10 * * 0,6", "周末 10:00", "Weekends at 10:00"),
            ("0 10 * * 6,7", "周末 10:00", "Weekends at 10:00"),
            ("0 10 * * SAT,SUN", "周末 10:00", "Weekends at 10:00"),
            ("0 7 * * 0-6", "每天 07:00", "Every day at 07:00"),
            ("0 7 * * 1-7", "每天 07:00", "Every day at 07:00"),
            ("30 10 * * 1", "每周一 10:30", "Every Monday at 10:30"),
            ("0 9 * * 1,3,5", "每周一、周三、周五 09:00", "Every Monday, Wednesday and Friday at 09:00"),
            ("* * * * *", "每分钟", "Every minute"),
            ("*/1 * * * *", "每分钟", "Every minute"),
            ("*/15 * * * *", "每 15 分钟", "Every 15 minutes"),
            ("5 * * * *", "每小时的第 5 分", "Every hour at :05"),
            ("0 */2 * * *", "每 2 小时（第 0 分）", "Every 2 hours at :00"),
            ("0 8 1 * *", "每月 1 日 08:00", "Monthly on the 1st at 08:00"),
            ("0 8 1,15 * *", "每月 1 日、15 日 08:00", "Monthly on the 1st and 15th at 08:00"),
            ("0 8 22 * *", "每月 22 日 08:00", "Monthly on the 22nd at 08:00"),
            ("0 0 25 12 *", "每年 12 月 25 日 00:00", "Every year on Dec 25 at 00:00"),
            ("0 0 1 JAN,JUL *", "每年 1 月、7 月 1 日 00:00", "Every year on Jan and Jul 1 at 00:00"),
            ("0,30 9 * * *", "每天 09:00、09:30", "Every day at 09:00 and 09:30"),
            ("0 9-11 * * *", "每天 09:00、10:00、11:00", "Every day at 09:00, 10:00 and 11:00"),
            ("0 8-18/5 * * *", "每天 08:00、13:00、18:00", "Every day at 08:00, 13:00 and 18:00"),
        ])
    func cron(expression: String, zh: String, en: String) {
        #expect(ScheduleDescription.describeCron(expression, language: .chinese) == zh)
        #expect(ScheduleDescription.describeCron(expression, language: .english) == en)
    }

    @Test(
        "认不出的 cron 返回 nil",
        arguments: [
            "", "0 9 * *", "0 9 * * * *", "61 * * * *", "0 25 * * *", "0 9 32 * *", "0 9 * 13 *", "0 9 * * 8",
            "abc def * * *", "*/0 * * * *", "5-3 * * * *", "0 9 1 * 1", "*/5 9 * * *", "0-59 0-23 * * *",
            "0 9 * JAN *", "0 9 * * */2",
        ])
    func cronUnrecognized(expression: String) {
        #expect(ScheduleDescription.describeCron(expression, language: .chinese) == nil)
    }

    @Test("英文序数词")
    func ordinals() {
        let cases = [
            (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (11, "11th"), (12, "12th"), (13, "13th"), (21, "21st"),
            (22, "22nd"), (23, "23rd"), (31, "31st"),
        ]
        for (n, expected) in cases {
            #expect(ScheduleDescription.ordinal(n) == expected)
        }
    }

    @Test(
        "RRULE",
        arguments: [
            ("FREQ=DAILY;BYHOUR=9;BYMINUTE=30", "每天 09:30", "Every day at 09:30"),
            ("RRULE:FREQ=DAILY;INTERVAL=2;BYHOUR=8", "每 2 天 08:00", "Every 2 days at 08:00"),
            ("FREQ=DAILY", "每天", "Every day"),
            ("FREQ=HOURLY", "每小时", "Every hour"),
            ("FREQ=HOURLY;INTERVAL=3", "每 3 小时", "Every 3 hours"),
            (
                "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE", "每周一、周三 09:00",
                "Every week on Monday and Wednesday at 09:00"
            ),
            (
                "DTSTART;TZID=Asia/Shanghai:20261022T183000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR",
                "每 2 周的周五 18:30", "Every 2 weeks on Friday at 18:30"
            ),
            ("FREQ=WEEKLY", "每周", "Every week"),
            ("freq=weekly;byday=sa,su", "每周六、周日", "Every week on Saturday and Sunday"),
            (
                "DTSTART:20261001T080000Z\nRRULE:FREQ=MONTHLY;BYMONTHDAY=15", "每月 15 日 08:00",
                "Every month on the 15th at 08:00"
            ),
            ("FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1", "每 3 个月 1 日", "Every 3 months on the 1st"),
            ("FREQ=MONTHLY", "每月", "Every month"),
            ("DTSTART;VALUE=DATE:20261022\nRRULE:FREQ=YEARLY", "每年", "Every year"),
            ("DTSTART;TZID=Asia/Shanghai:20261022T070000\r\nRRULE:FREQ=YEARLY", "每年 07:00", "Every year at 07:00"),
        ])
    func rrule(rule: String, zh: String, en: String) {
        #expect(ScheduleDescription.describeRRule(rule, language: .chinese) == zh)
        #expect(ScheduleDescription.describeRRule(rule, language: .english) == en)
    }

    @Test("认不出的 RRULE 返回 nil")
    func rruleUnrecognized() {
        for rule in ["", "INTERVAL=2", "FREQ=SECONDLY", "FREQ=MINUTELY;INTERVAL=5", "garbage"] {
            #expect(ScheduleDescription.describeRRule(rule, language: .chinese) == nil, "\(rule)")
        }
    }

    @Test("describe：cron 的时区和用户的不同时注明；认不出时显示原文")
    func describeCron() {
        let cron = Schedule.cron(expression: "0 9 * * 1-5", timeZone: "Asia/Shanghai")
        #expect(ScheduleDescription.describe(cron, language: .chinese, timeZone: Fixture.shanghai) == "工作日 09:00")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(ScheduleDescription.describe(cron, language: .chinese, timeZone: tokyo) == "工作日 09:00（Asia/Shanghai 时间）")
        #expect(ScheduleDescription.describe(cron, language: .english, timeZone: tokyo) == "Weekdays at 09:00 (Asia/Shanghai time)")
        let noZone = Schedule.cron(expression: "0 9 * * *", timeZone: "")
        #expect(ScheduleDescription.describe(noZone, language: .english, timeZone: tokyo) == "Every day at 09:00")
        let odd = Schedule.cron(expression: "0 9 1 * 1", timeZone: "Asia/Shanghai")
        #expect(ScheduleDescription.describe(odd, language: .chinese, timeZone: Fixture.shanghai) == "cron 规则 0 9 1 * 1")
        #expect(ScheduleDescription.describe(odd, language: .english, timeZone: Fixture.shanghai) == "Cron 0 9 1 * 1")
    }

    @Test("describe：RRULE 认不出时显示“自定义重复规则”")
    func describeRRule() {
        #expect(ScheduleDescription.describe(.rrule("FREQ=DAILY;BYHOUR=7"), language: .chinese) == "每天 07:00")
        #expect(ScheduleDescription.describe(.rrule("FREQ=SECONDLY"), language: .chinese) == "自定义重复规则")
        #expect(ScheduleDescription.describe(.rrule("FREQ=SECONDLY"), language: .english) == "Custom recurrence")
    }

    @Test("describe：一次性定时，按用户的时区显示")
    func describeOnce() {
        let at = Fixture.date(2026, 10, 23, 9, 0)
        #expect(
            ScheduleDescription.describe(.once(at), language: .chinese, timeZone: Fixture.shanghai, now: now)
                == "10月23日 09:00 执行一次")
        #expect(
            ScheduleDescription.describe(.once(at), language: .english, timeZone: Fixture.shanghai, now: now)
                == "Once at Oct 23, 09:00")
        let utc = TimeZone(identifier: "UTC")!
        #expect(
            ScheduleDescription.describe(.once(at), language: .english, timeZone: utc, now: now) == "Once at Oct 23, 01:00")
        let nextYear = Fixture.date(2027, 1, 2, 8, 30)
        #expect(
            ScheduleDescription.describe(.once(nextYear), language: .chinese, timeZone: Fixture.shanghai, now: now)
                == "2027年1月2日 08:30 执行一次")
    }
}
