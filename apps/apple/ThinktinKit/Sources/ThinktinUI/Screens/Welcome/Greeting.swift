import Foundation
import ThinktinKit

/// 欢迎页的问候语：“早上好”“下午好”“晚上好”，有名字时带上名字（“下午好，张三”）。纯函数，测试时传固定的时间和日历。
public enum Greeting {
    /// 一天里的时段。
    public enum Period: Hashable, Sendable, CaseIterable {
        /// 5:00–11:59。
        case morning
        /// 12:00–17:59。
        case afternoon
        /// 18:00–次日 4:59。
        case evening
    }

    /// `date` 在 `calendar`（含时区）里属于哪个时段。
    public static func period(at date: Date, calendar: Calendar = .current) -> Period {
        switch calendar.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<18: .afternoon
        default: .evening
        }
    }

    /// 问候语。`name` 为空或只有空白时不带名字。
    public static func text(
        at date: Date = Date(), name: String? = nil, language: DisplayLanguage = .current,
        calendar: Calendar = .current
    ) -> String {
        let zh = language == .chinese
        let base =
            switch period(at: date, calendar: calendar) {
            case .morning: zh ? "早上好" : "Good morning"
            case .afternoon: zh ? "下午好" : "Good afternoon"
            case .evening: zh ? "晚上好" : "Good evening"
            }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return base }
        return zh ? "\(base)，\(name)" : "\(base), \(name)"
    }
}
