import Foundation

/// 界面上的数字、时间格式（中英文）。都是纯函数，测试时传固定的 `now`、`calendar`。
public enum Formatting {
    // MARK: 相对时间

    /// 相对时间：“刚刚”、“5 分钟前”、“3 小时前”、“昨天 14:05”、“3 天前”、“10月21日”、“2025年10月21日”。
    /// 将来的时间：“5 分钟后”、“3 小时后”、“明天 09:00”，再远显示日期。
    public static func relativeTime(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        let zh = language == .chinese
        let delta = now.timeIntervalSince(date)
        let future = delta < 0
        let seconds = abs(delta)

        if seconds < 60 {
            return zh ? "刚刚" : "just now"
        }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            if zh { return future ? "\(m) 分钟后" : "\(m) 分钟前" }
            return future ? "in \(m) min" : "\(m) min ago"
        }
        let dayDiff = calendarDays(from: date, to: now, calendar: calendar)
        if seconds < 6 * 3600 || dayDiff == 0 {
            let h = Int(seconds / 3600)
            if zh { return future ? "\(h) 小时后" : "\(h) 小时前" }
            return future ? "in \(h) hr" : "\(h) hr ago"
        }
        let time = clockTime(date, calendar: calendar)
        if dayDiff == 1 { return zh ? "昨天 \(time)" : "yesterday \(time)" }
        if dayDiff == -1 { return zh ? "明天 \(time)" : "tomorrow \(time)" }
        if dayDiff > 1 && dayDiff < 7 { return zh ? "\(dayDiff) 天前" : "\(dayDiff) days ago" }
        if dayDiff < -1 && dayDiff > -7 { return zh ? "\(-dayDiff) 天后" : "in \(-dayDiff) days" }
        return shortDate(date, now: now, language: language, calendar: calendar)
    }

    /// 日期：今年的“10月21日” / “Oct 21”，往年的“2025年10月21日” / “Oct 21, 2025”。
    public static func shortDate(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let thisYear = calendar.component(.year, from: now)
        let (y, m, d) = (c.year ?? 0, c.month ?? 1, c.day ?? 1)
        switch language {
        case .chinese:
            return y == thisYear ? "\(m)月\(d)日" : "\(y)年\(m)月\(d)日"
        case .english:
            let month = englishMonths[max(0, min(11, m - 1))]
            return y == thisYear ? "\(month) \(d)" : "\(month) \(d), \(y)"
        }
    }

    /// 日期加时间：“10月22日 09:00” / “Oct 22, 09:00”（往年的带年份）。
    public static func dateTime(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        let day = shortDate(date, now: now, language: language, calendar: calendar)
        let time = clockTime(date, calendar: calendar)
        return language == .chinese ? "\(day) \(time)" : "\(day), \(time)"
    }

    /// 24 小时制的“09:05”。
    public static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return pad2(c.hour ?? 0) + ":" + pad2(c.minute ?? 0)
    }

    /// 两个时间之间差几个日历日（`to` 在后为正）。
    static func calendarDays(from date: Date, to now: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: date)
        let b = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // MARK: 时长

    /// 时长：“45 秒”、“3 分 20 秒”、“2 小时 5 分”、“3 天 4 小时” / “45s”、“3m 20s”、“2h 5m”、“3d 4h”。
    public static func duration(_ interval: TimeInterval, language: DisplayLanguage = .current) -> String {
        let total = max(0, Int(interval.rounded()))
        let (d, h, m, s) = (total / 86400, total % 86400 / 3600, total % 3600 / 60, total % 60)
        let zh = language == .chinese
        func part(_ n: Int, _ zhUnit: String, _ enUnit: String) -> String {
            zh ? "\(n) \(zhUnit)" : "\(n)\(enUnit)"
        }
        var parts: [String]
        if d > 0 {
            parts = [part(d, "天", "d")] + (h > 0 ? [part(h, "小时", "h")] : [])
        } else if h > 0 {
            parts = [part(h, "小时", "h")] + (m > 0 ? [part(m, "分", "m")] : [])
        } else if m > 0 {
            parts = [part(m, "分", "m")] + (s > 0 ? [part(s, "秒", "s")] : [])
        } else {
            parts = [part(s, "秒", "s")]
        }
        return parts.joined(separator: " ")
    }

    // MARK: 数量

    /// token 数：中文按“万 / 亿”（“9,876”、“1.2 万”、“3.5 亿”），英文按 K / M / B（“950”、“1.2K”、“3.4M”）。
    /// 四舍五入后到了下一级的进位（99,999,999 → “1 亿”，而不是“10000 万”）。
    public static func tokens(_ count: Int, language: DisplayLanguage = .current) -> String {
        let n = abs(count)
        let sign = count < 0 ? "-" : ""
        switch language {
        case .chinese:
            if n < 10_000 { return sign + grouped(n) }
            return sign + scaled(Double(n), units: [(1e4, " 万"), (1e8, " 亿")])
        case .english:
            if n < 1_000 { return sign + String(n) }
            return sign + scaled(Double(n), units: [(1e3, "K"), (1e6, "M"), (1e9, "B")])
        }
    }

    /// 字节数（1024 进制）：“512 B”、“1.5 KB”、“3.2 MB”、“1.1 GB”。四舍五入后满 1024 的进位（“1 MB”，而不是“1024 KB”）。
    public static func bytes(_ count: Int) -> String {
        guard count >= 1024 else { return "\(max(0, count)) B" }
        let k = 1024.0
        return scaled(Double(count), units: [(k, " KB"), (k * k, " MB"), (k * k * k, " GB"), (k * k * k * k, " TB")])
    }

    /// 按单位缩放成一位小数（`units` 从小到大）：用不大于它的最大单位；四舍五入后满了下一级时进位
    /// （999,999 → “1M” 而不是“1000K”；950,000 还是“950K”）。
    static func scaled(_ value: Double, units: [(divisor: Double, suffix: String)]) -> String {
        var i = units.lastIndex { value >= $0.divisor } ?? 0
        if i + 1 < units.count, rounded1(value / units[i].divisor) * units[i].divisor >= units[i + 1].divisor {
            i += 1
        }
        return oneDecimal(value / units[i].divisor) + units[i].suffix
    }

    /// 四舍五入到一位小数。
    static func rounded1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// 千分位分组：“1,234,567”。
    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// 一位小数，去掉“.0”：1.25 → “1.3”，2.0 → “2”。
    static func oneDecimal(_ value: Double) -> String {
        let rounded = rounded1(value)
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    static let englishMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
