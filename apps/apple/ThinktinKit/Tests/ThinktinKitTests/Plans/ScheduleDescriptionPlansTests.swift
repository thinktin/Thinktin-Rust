import Foundation
import Testing

@testable import ThinktinKit

// 12.6 给 ScheduleDescription 补的几种 RRULE 说法（原来的在 FormattingTests 里，照旧通过）。

@Suite("触发规则的描述：12.6 补的 RRULE")
struct ScheduleDescriptionPlansTests {
    @Test(
        "多个日子、多个时刻、序号、COUNT",
        arguments: [
            ("FREQ=MONTHLY;BYMONTHDAY=1,15;BYHOUR=8", "每月 1 日、15 日 08:00", "Every month on the 1st and 15th at 08:00"),
            ("FREQ=MONTHLY;BYMONTHDAY=-1", "每月 最后一天", "Every month on the last day"),
            ("FREQ=MONTHLY;BYDAY=1MO;BYHOUR=9", "每月第 1 个周一 09:00", "Every month on the first Monday at 09:00"),
            ("FREQ=MONTHLY;BYDAY=-1FR", "每月最后一个周五", "Every month on the last Friday"),
            ("FREQ=MONTHLY;BYDAY=TU", "每月每个周二", "Every month on every Tuesday"),
            ("FREQ=DAILY;BYHOUR=9,18", "每天 09:00、18:00", "Every day at 09:00 and 18:00"),
            ("FREQ=DAILY;BYHOUR=9;COUNT=5", "每天 09:00，共 5 次", "Every day at 09:00, 5 times"),
            (
                "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15;BYHOUR=9", "每年 3 月 15 日 09:00",
                "Every year in Mar on the 15th at 09:00"
            ),
            ("FREQ=YEARLY;INTERVAL=2", "每 2 年", "Every 2 years"),
            (
                "DTSTART;TZID=Asia/Shanghai:20261022T093000\nRRULE:FREQ=DAILY;BYHOUR=8", "每天 08:30",
                "Every day at 08:30"
            ),
        ])
    func extended(rule: String, zh: String, en: String) {
        #expect(ScheduleDescription.describeRRule(rule, language: .chinese) == zh)
        #expect(ScheduleDescription.describeRRule(rule, language: .english) == en)
    }

    @Test("UNTIL：到哪天为止")
    func until() {
        let rule = "DTSTART;TZID=Asia/Shanghai:20261022T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20300101T000000Z"
        #expect(ScheduleDescription.describeRRule(rule, language: .chinese) == "每周一 09:00，到 2030年1月1日 为止")
        #expect(
            ScheduleDescription.describeRRule(rule, language: .english)
                == "Every week on Monday at 09:00, until Jan 1, 2030")
    }

    @Test("说不准的写法不描述（显示“自定义重复规则”）")
    func refusesMisleading() {
        for rule in [
            "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1", "FREQ=YEARLY;BYWEEKNO=20", "FREQ=DAILY;BYDAY=MO,TU",
            "FREQ=DAILY;BYMONTH=1", "FREQ=WEEKLY;BYDAY=1MO", "FREQ=DAILY;BYHOUR=1,2,3,4,5,6,7", "FREQ=DAILY;BYDAY=XX",
        ] {
            #expect(ScheduleDescription.describeRRule(rule, language: .chinese) == nil, "\(rule)")
        }
        #expect(ScheduleDescription.describe(.rrule("FREQ=DAILY;BYDAY=MO,TU"), language: .chinese) == "自定义重复规则")
    }

    @Test("describe：RRULE 的时区和用户的不同时注明")
    func timeZoneNote() {
        let rule = Schedule.rrule("DTSTART;TZID=Asia/Tokyo:20261022T090000\nRRULE:FREQ=DAILY")
        #expect(
            ScheduleDescription.describe(rule, language: .chinese, timeZone: Fixture.shanghai)
                == "每天 09:00（Asia/Tokyo 时间）")
        #expect(
            ScheduleDescription.describe(rule, language: .english, timeZone: Fixture.shanghai)
                == "Every day at 09:00 (Asia/Tokyo time)")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(ScheduleDescription.describe(rule, language: .chinese, timeZone: tokyo) == "每天 09:00")
        let utc = Schedule.rrule("DTSTART:20261022T010000Z\nRRULE:FREQ=DAILY")
        #expect(ScheduleDescription.describe(utc, language: .chinese, timeZone: Fixture.shanghai) == "每天 01:00（UTC 时间）")
    }
}
