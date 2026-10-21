import Foundation

/// 把触发规则说成人话：“每天 09:00”、“工作日 09:00、18:00”、“每 15 分钟” / “Every day at 09:00”……
/// 认不出的规则返回 nil（`describe(_ schedule:)` 再退回显示原文）。
public enum ScheduleDescription {
    /// 五段 cron（分 时 日 月 周）。
    public static func describeCron(_ expression: String, language: DisplayLanguage = .current) -> String? {
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5,
            let minute = CronField(parts[0], range: 0...59),
            let hour = CronField(parts[1], range: 0...23),
            let dom = CronField(parts[2], range: 1...31),
            let month = CronField(parts[3], range: 1...12, names: monthNames),
            let dowRaw = CronField(parts[4], range: 0...7, names: weekdayNames)
        else { return nil }
        // 周日写成 0 或 7 都行。
        let dow = dowRaw.normalizingSunday()
        let zh = language == .chinese

        // 每分钟 / 每 n 分钟
        if hour == .any, dom == .any, month == .any, dow == .any {
            switch minute {
            case .any: return zh ? "每分钟" : "Every minute"
            case .step(let n): return zh ? "每 \(n) 分钟" : "Every \(n) minutes"
            case .values(let ms) where ms.count == 1:
                return zh ? "每小时的第 \(ms[0]) 分" : "Every hour at :\(Formatting.pad2(ms[0]))"
            default: return nil
            }
        }
        // 每 n 小时
        if case .step(let n) = hour, case .values(let ms) = minute, ms.count == 1, dom == .any, month == .any,
            dow == .any
        {
            return zh ? "每 \(n) 小时（第 \(ms[0]) 分）" : "Every \(n) hours at :\(Formatting.pad2(ms[0]))"
        }
        // 固定时刻
        guard case .values(let ms) = minute, case .values(let hs) = hour else { return nil }
        let times = hs.flatMap { h in ms.map { m in Formatting.pad2(h) + ":" + Formatting.pad2(m) } }
        guard !times.isEmpty, times.count <= 6 else { return nil }
        let at = join(times, language: language)

        switch (dom, month, dow) {
        case (.any, .any, .any):
            return zh ? "每天 \(at)" : "Every day at \(at)"
        case (.any, .any, .values(let days)):
            if days == [1, 2, 3, 4, 5] { return zh ? "工作日 \(at)" : "Weekdays at \(at)" }
            if days == [0, 6] { return zh ? "周末 \(at)" : "Weekends at \(at)" }
            if days.count == 7 { return zh ? "每天 \(at)" : "Every day at \(at)" }
            if zh {
                return "每" + days.map { zhWeekdays[$0] }.joined(separator: "、") + " \(at)"
            }
            return "Every " + join(days.map { enWeekdays[$0] }, language: .english) + " at \(at)"
        case (.values(let days), .any, .any):
            if zh { return "每月 " + days.map { "\($0) 日" }.joined(separator: "、") + " \(at)" }
            return "Monthly on the " + join(days.map(ordinal), language: .english) + " at \(at)"
        case (.values(let days), .values(let months), .any):
            if zh {
                let ds = days.map { "\($0) 日" }.joined(separator: "、")
                return "每年 " + months.map { "\($0) 月" }.joined(separator: "、") + " " + ds + " \(at)"
            }
            let ms = join(months.map { Formatting.englishMonths[$0 - 1] }, language: .english)
            return "Every year on \(ms) " + days.map(String.init).joined(separator: ", ") + " at \(at)"
        default:
            return nil
        }
    }

    /// 简单的 RRULE（`FREQ`、`INTERVAL`、`BYDAY`、`BYMONTHDAY`、`BYHOUR`、`BYMINUTE`，可以带 DTSTART 行）。
    public static func describeRRule(_ rule: String, language: DisplayLanguage = .current) -> String? {
        var fields: [String: String] = [:]
        var startTime: String?
        for line in rule.split(whereSeparator: \.isNewline).map(String.init) {
            if line.uppercased().hasPrefix("DTSTART") {
                // DTSTART;TZID=Asia/Shanghai:20261022T090000、DTSTART:20261022T010000Z；只有日期的（VALUE=DATE）没有时间。
                let value = line.split(separator: ":").last.map(String.init) ?? ""
                let parts = value.uppercased().split(separator: "T", maxSplits: 1)
                if parts.count == 2, parts[1].count >= 4, let h = Int(parts[1].prefix(2)),
                    let m = Int(parts[1].dropFirst(2).prefix(2)), (0...23).contains(h), (0...59).contains(m)
                {
                    startTime = Formatting.pad2(h) + ":" + Formatting.pad2(m)
                }
                continue
            }
            let body = line.hasPrefix("RRULE:") ? String(line.dropFirst(6)) : line
            for pair in body.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0].uppercased()] = kv[1].uppercased() }
            }
        }
        guard let freq = fields["FREQ"] else { return nil }
        let zh = language == .chinese
        let interval = fields["INTERVAL"].flatMap(Int.init) ?? 1
        var time = startTime
        if let h = fields["BYHOUR"].flatMap(Int.init) {
            time = Formatting.pad2(h) + ":" + Formatting.pad2(fields["BYMINUTE"].flatMap(Int.init) ?? 0)
        }
        let at = time.map { zh ? " \($0)" : " at \($0)" } ?? ""
        switch freq {
        case "HOURLY":
            return interval == 1 ? (zh ? "每小时" : "Every hour") : (zh ? "每 \(interval) 小时" : "Every \(interval) hours")
        case "DAILY":
            let base = interval == 1 ? (zh ? "每天" : "Every day") : (zh ? "每 \(interval) 天" : "Every \(interval) days")
            return base + at
        case "WEEKLY":
            let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let days = (fields["BYDAY"] ?? "").split(separator: ",").compactMap { codes.firstIndex(of: String($0)) }
            let every = interval == 1 ? (zh ? "每周" : "Every week") : (zh ? "每 \(interval) 周" : "Every \(interval) weeks")
            guard !days.isEmpty else { return every + at }
            if zh {
                // 和 cron 的说法一致：“每周一、周三 09:00”、“每 2 周的周五 18:30”。
                let names = days.map { zhWeekdays[$0] }.joined(separator: "、")
                return interval == 1 ? "每" + names + at : every + "的" + names + at
            }
            return every + " on " + join(days.map { enWeekdays[$0] }, language: .english) + at
        case "MONTHLY":
            let every =
                interval == 1 ? (zh ? "每月" : "Every month") : (zh ? "每 \(interval) 个月" : "Every \(interval) months")
            guard let day = fields["BYMONTHDAY"].flatMap(Int.init) else { return every + at }
            return zh ? "\(every) \(day) 日\(at)" : "\(every) on the \(ordinal(day))\(at)"
        case "YEARLY":
            return (zh ? "每年" : "Every year") + at
        default:
            return nil
        }
    }

    /// 触发规则的人话描述；认不出时显示原文。`timeZone` 是用户当前的时区：规则的时区和它不同时注明。
    public static func describe(
        _ schedule: Schedule, language: DisplayLanguage = .current, timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> String {
        let zh = language == .chinese
        switch schedule {
        case .cron(let expression, let tz):
            let text = describeCron(expression, language: language) ?? (zh ? "cron 规则 \(expression)" : "Cron \(expression)")
            guard !tz.isEmpty, tz != timeZone.identifier else { return text }
            return zh ? "\(text)（\(tz) 时间）" : "\(text) (\(tz) time)"
        case .rrule(let rule):
            return describeRRule(rule, language: language) ?? (zh ? "自定义重复规则" : "Custom recurrence")
        case .once(let date):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let when = Formatting.dateTime(date, now: now, language: language, calendar: calendar)
            return zh ? "\(when) 执行一次" : "Once at \(when)"
        }
    }

    // MARK: 内部

    static let zhWeekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    static let enWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayNames = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]
    static let monthNames = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10,
        "NOV": 11, "DEC": 12,
    ]

    /// 中文用顿号连接；英文“a, b and c”。
    static func join(_ items: [String], language: DisplayLanguage) -> String {
        guard language == .english, items.count > 1 else { return items.joined(separator: "、") }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// cron 的一段。
enum CronField: Equatable {
    case any
    /// `*/n`
    case step(Int)
    /// 列出的取值（范围、带步长的范围都展开），升序去重。
    case values([Int])

    init?(_ raw: String, range: ClosedRange<Int>, names: [String: Int] = [:]) {
        if raw == "*" || raw == "?" {
            self = .any
            return
        }
        if raw.hasPrefix("*/") {
            guard let n = Int(raw.dropFirst(2)), n > 0 else { return nil }
            self = n == 1 ? .any : .step(n)
            return
        }
        func value(_ s: Substring) -> Int? {
            if let n = Int(s) { return n }
            return names[s.uppercased()]
        }
        var out = Set<Int>()
        for item in raw.split(separator: ",") {
            let stepParts = item.split(separator: "/", maxSplits: 1)
            let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
            guard let step, step > 0 else { return nil }
            let bounds = stepParts[0].split(separator: "-", maxSplits: 1)
            let lo: Int
            let hi: Int
            if bounds.count == 2 {
                guard let a = value(bounds[0]), let b = value(bounds[1]), a <= b else { return nil }
                (lo, hi) = (a, b)
            } else if stepParts[0] == "*" {
                (lo, hi) = (range.lowerBound, range.upperBound)
            } else {
                guard let a = value(bounds[0]) else { return nil }
                (lo, hi) = (a, stepParts.count == 2 ? range.upperBound : a)
            }
            guard range.contains(lo), range.contains(hi) else { return nil }
            out.formUnion(Swift.stride(from: lo, through: hi, by: step))
        }
        guard !out.isEmpty else { return nil }
        self = .values(out.sorted())
    }

    /// 周几里的 7 换成 0（都是周日）。
    func normalizingSunday() -> CronField {
        guard case .values(let v) = self else { return self }
        return .values(Set(v.map { $0 == 7 ? 0 : $0 }).sorted())
    }
}
