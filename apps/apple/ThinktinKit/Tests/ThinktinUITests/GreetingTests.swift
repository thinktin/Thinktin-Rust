import Foundation
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 欢迎页的问候语。
@Suite("问候语")
struct GreetingTests {
    /// 北京时间的公历。
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    static func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour, minute: minute))!
    }

    @Test("时段的边界")
    func periods() {
        let cases: [(Int, Int, Greeting.Period)] = [
            (4, 59, .evening), (5, 0, .morning), (11, 59, .morning), (12, 0, .afternoon),
            (17, 59, .afternoon), (18, 0, .evening), (0, 0, .evening),
        ]
        for (hour, minute, period) in cases {
            #expect(Greeting.period(at: Self.date(hour: hour, minute: minute), calendar: Self.calendar) == period)
        }
    }

    @Test("中文：下午好，带名字")
    func chinese() {
        let afternoon = Self.date(hour: 15)
        #expect(Greeting.text(at: afternoon, language: .chinese, calendar: Self.calendar) == "下午好")
        #expect(Greeting.text(at: afternoon, name: "张三", language: .chinese, calendar: Self.calendar) == "下午好，张三")
        #expect(Greeting.text(at: afternoon, name: "  ", language: .chinese, calendar: Self.calendar) == "下午好")
        #expect(Greeting.text(at: Self.date(hour: 8), language: .chinese, calendar: Self.calendar) == "早上好")
        #expect(Greeting.text(at: Self.date(hour: 22), language: .chinese, calendar: Self.calendar) == "晚上好")
    }

    @Test("英文")
    func english() {
        #expect(
            Greeting.text(at: Self.date(hour: 15), name: "Ada", language: .english, calendar: Self.calendar)
                == "Good afternoon, Ada")
        #expect(Greeting.text(at: Self.date(hour: 6), language: .english, calendar: Self.calendar) == "Good morning")
    }
}
