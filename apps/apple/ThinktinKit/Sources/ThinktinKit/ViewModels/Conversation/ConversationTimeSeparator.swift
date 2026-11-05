import Foundation

/// 对话时间线里运行之间居中的小灰字时间（规范 4.3.1，参考的“星期二 02:22”）：第一组前面总有；之后和上一组隔了
/// 15 分钟以上、或者跨了天才加。时间取运行的创建时间（没有运行的系统提示组取第一项的时间）。
///
/// 写法：今天“今天 22:09”，昨天“昨天 22:09”，一周内“星期二 02:22”，更早“10月21日 09:00”（往年的带年份）；
/// 英文 “Today 22:09”“Yesterday 22:09”“Tuesday 02:22”“Oct 21, 09:00”。
public enum ConversationTimeSeparator {
    /// 和上一组隔了这么久才加分隔。
    public static let minimumGap: TimeInterval = 15 * 60

    /// 一组的时间：运行的创建时间；还没拿到运行的，取第一项的时间；都没有为 nil（不加分隔，也不算“上一组”）。
    public static func date(of turn: ConversationTurn) -> Date? {
        turn.run?.createdAt ?? turn.items.first?.createdAt
    }

    /// 要加分隔的组：组的 id → 分隔上的字。
    public static func labels(
        for turns: [ConversationTurn], now: Date = Date(), language: DisplayLanguage = .current,
        calendar: Calendar = .current
    ) -> [String: String] {
        var result: [String: String] = [:]
        var previous: Date?
        for turn in turns {
            guard let date = date(of: turn) else { continue }
            if needsSeparator(date, after: previous, calendar: calendar) {
                result[turn.id] = label(date, now: now, language: language, calendar: calendar)
            }
            previous = date
        }
        return result
    }

    /// `date` 前面要不要分隔：前面没有组、隔了 15 分钟以上、跨了天。
    public static func needsSeparator(_ date: Date, after previous: Date?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        if abs(date.timeIntervalSince(previous)) >= minimumGap { return true }
        return !calendar.isDate(date, inSameDayAs: previous)
    }

    /// 分隔上的字。
    public static func label(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        let zh = language == .chinese
        let time = Formatting.clockTime(date, calendar: calendar)
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        switch days {
        case 0: return zh ? "今天 \(time)" : "Today \(time)"
        case 1: return zh ? "昨天 \(time)" : "Yesterday \(time)"
        case 2..<7: return weekdayName(date, language: language, calendar: calendar) + " " + time
        default: return Formatting.dateTime(date, now: now, language: language, calendar: calendar)
        }
    }

    /// 星期几：“星期二” / “Tuesday”。
    static func weekdayName(_ date: Date, language: DisplayLanguage, calendar: Calendar) -> String {
        let index = max(1, min(7, calendar.component(.weekday, from: date))) - 1
        switch language {
        case .chinese: return ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"][index]
        case .english: return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]
        }
    }
}

extension ConversationModel {
    /// 这一页时间线上的时间分隔（组的 id → 字），按视图模型的“现在”算。
    public func timeSeparators(language: DisplayLanguage, calendar: Calendar = .current) -> [String: String] {
        ConversationTimeSeparator.labels(for: turns, now: now(), language: language, calendar: calendar)
    }
}
