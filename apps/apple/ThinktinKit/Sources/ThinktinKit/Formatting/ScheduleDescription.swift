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

    /// 简单的 RRULE（`FREQ`、`INTERVAL`、`BYDAY`、`BYMONTHDAY`、`BYMONTH`、`BYHOUR`、`BYMINUTE`、`COUNT`、`UNTIL`，
    /// 可以带 DTSTART 行）。说不准的写法（`BYSETPOS`、`BYWEEKNO` 这些，DAILY 带 `BYDAY`、不是 YEARLY 却带 `BYMONTH`、
    /// 不是 MONTHLY 却带序号的 `BYDAY`）返回 nil，免得描述得和实际不一样。
    public static func describeRRule(_ rule: String, language: DisplayLanguage = .current) -> String? {
        var fields: [String: String] = [:]
        var startTime: (hour: Int, minute: Int)?
        var startZone: TimeZone?
        for line in rule.split(whereSeparator: \.isNewline).map(String.init) {
            if line.uppercased().hasPrefix("DTSTART") {
                // DTSTART;TZID=Asia/Shanghai:20261022T090000、DTSTART:20261022T010000Z；只有日期的（VALUE=DATE）没有时间。
                let value = line.split(separator: ":").last.map(String.init) ?? ""
                let parts = value.uppercased().split(separator: "T", maxSplits: 1)
                if parts.count == 2, parts[1].count >= 4, let h = Int(parts[1].prefix(2)),
                    let m = Int(parts[1].dropFirst(2).prefix(2)), (0...23).contains(h), (0...59).contains(m)
                {
                    startTime = (h, m)
                }
                startZone = RecurrenceRule.parseStart(line)?.1
                continue
            }
            let body = line.uppercased().hasPrefix("RRULE:") ? String(line.dropFirst(6)) : line
            for pair in body.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0].uppercased()] = kv[1].uppercased() }
            }
        }
        guard let freq = fields["FREQ"] else { return nil }
        let known: Set<String> = [
            "FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYHOUR", "BYMINUTE", "COUNT", "UNTIL", "WKST",
        ]
        guard fields.keys.allSatisfy(known.contains) else { return nil }
        let zh = language == .chinese
        let interval = fields["INTERVAL"].flatMap(Int.init) ?? 1
        func list(_ key: String) -> [Int]? {
            guard let raw = fields[key] else { return nil }
            let values = raw.split(separator: ",").compactMap { Int($0) }
            return values.isEmpty ? nil : values
        }
        // 时刻：BYHOUR × BYMINUTE（BYMINUTE 没给时取 DTSTART 的分，都没有是整点），没有 BYHOUR 时是 DTSTART 的时刻。
        var times: [String] = []
        if let hours = list("BYHOUR") {
            let minutes = list("BYMINUTE") ?? [startTime?.minute ?? 0]
            times = hours.sorted().flatMap { h in
                minutes.sorted().map { Formatting.pad2(h) + ":" + Formatting.pad2($0) }
            }
        } else if let startTime {
            times = [Formatting.pad2(startTime.hour) + ":" + Formatting.pad2(startTime.minute)]
        }
        guard times.count <= 6 else { return nil }
        let at = times.isEmpty ? "" : (zh ? " " : " at ") + join(times, language: language)
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        // BYDAY：（序号，周几）。
        var byDay: [(ordinal: Int?, day: Int)] = []
        for item in (fields["BYDAY"] ?? "").split(separator: ",") {
            guard let day = codes.firstIndex(of: String(item.suffix(2))) else { return nil }
            let prefix = item.dropLast(2)
            if prefix.isEmpty {
                byDay.append((nil, day))
            } else {
                guard let n = Int(prefix), n != 0 else { return nil }
                byDay.append((n, day))
            }
        }
        if fields["BYMONTH"] != nil && freq != "YEARLY" { return nil }
        if byDay.contains(where: { $0.ordinal != nil }) && freq != "MONTHLY" { return nil }
        let base: String
        switch freq {
        case "HOURLY":
            guard byDay.isEmpty, fields["BYMONTHDAY"] == nil else { return nil }
            base = interval == 1 ? (zh ? "每小时" : "Every hour") : (zh ? "每 \(interval) 小时" : "Every \(interval) hours")
        case "DAILY":
            guard byDay.isEmpty, fields["BYMONTHDAY"] == nil else { return nil }
            base =
                (interval == 1 ? (zh ? "每天" : "Every day") : (zh ? "每 \(interval) 天" : "Every \(interval) days")) + at
        case "WEEKLY":
            guard fields["BYMONTHDAY"] == nil else { return nil }
            let days = byDay.map(\.day)
            let every =
                interval == 1 ? (zh ? "每周" : "Every week") : (zh ? "每 \(interval) 周" : "Every \(interval) weeks")
            if days.isEmpty {
                base = every + at
            } else if zh {
                // 和 cron 的说法一致：“每周一、周三 09:00”、“每 2 周的周五 18:30”。
                let names = days.map { zhWeekdays[$0] }.joined(separator: "、")
                base = (interval == 1 ? "每" + names : every + "的" + names) + at
            } else {
                base = every + " on " + join(days.map { enWeekdays[$0] }, language: .english) + at
            }
        case "MONTHLY":
            let every =
                interval == 1 ? (zh ? "每月" : "Every month") : (zh ? "每 \(interval) 个月" : "Every \(interval) months")
            if let days = list("BYMONTHDAY") {
                guard byDay.isEmpty else { return nil }
                let names = monthDays(days, language: language)
                base = zh ? "\(every) \(names)\(at)" : "\(every) on the \(names)\(at)"
            } else if !byDay.isEmpty {
                let names = byDay.map { weekdayOccurrence($0.ordinal, $0.day, language: language) }
                base =
                    zh
                    ? every + names.joined(separator: "、") + at : every + " on " + join(names, language: .english) + at
            } else {
                base = every + at
            }
        case "YEARLY":
            guard byDay.isEmpty else { return nil }
            let every =
                interval == 1 ? (zh ? "每年" : "Every year") : (zh ? "每 \(interval) 年" : "Every \(interval) years")
            if let months = list("BYMONTH") {
                let days = list("BYMONTHDAY").map { monthDays($0, language: language) }
                if zh {
                    let ms = months.map { "\($0) 月" }.joined(separator: "、")
                    base = "\(every) \(ms)" + (days.map { " \($0)" } ?? "") + at
                } else {
                    let ms = join(months.map { Formatting.englishMonths[max(0, min(11, $0 - 1))] }, language: .english)
                    base = "\(every) in \(ms)" + (days.map { " on the \($0)" } ?? "") + at
                }
            } else {
                guard fields["BYMONTHDAY"] == nil else { return nil }
                base = every + at
            }
        default:
            return nil
        }
        return base + limits(fields, zone: startZone, language: language)
    }

    /// COUNT、UNTIL：“，共 5 次”“，到 2027年1月1日 为止” / “, 5 times”“, until Jan 1, 2027”。
    static func limits(_ fields: [String: String], zone: TimeZone?, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        if let count = fields["COUNT"].flatMap(Int.init) {
            return zh ? "，共 \(count) 次" : ", \(count) times"
        }
        if let raw = fields["UNTIL"],
            let until = RecurrenceRule.parseDateTime(raw, timeZone: zone ?? .current, endOfDayForDates: true)
        {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone ?? .current
            let day = Formatting.shortDate(until, language: language, calendar: calendar)
            return zh ? "，到 \(day) 为止" : ", until \(day)"
        }
        return ""
    }

    /// 每月的几号：“1 日、15 日”“最后一天” / “1st and 15th”“last day”。
    static func monthDays(_ days: [Int], language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let names = days.map { day -> String in
            if day == -1 { return zh ? "最后一天" : "last day" }
            if day < 0 { return zh ? "倒数第 \(-day) 天" : "\(ordinal(-day)) to last day" }
            return zh ? "\(day) 日" : ordinal(day)
        }
        return zh ? names.joined(separator: "、") : join(names, language: .english)
    }

    /// “第 1 个周一”“最后一个周五”“每个周三” / “the first Monday”“the last Friday”“every Wednesday”。
    static func weekdayOccurrence(_ ordinal: Int?, _ day: Int, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let enOrdinals = ["first", "second", "third", "fourth", "fifth"]
        guard let n = ordinal else { return zh ? "每个" + zhWeekdays[day] : "every " + enWeekdays[day] }
        if n == -1 { return zh ? "最后一个" + zhWeekdays[day] : "the last " + enWeekdays[day] }
        if n < 0 {
            return zh ? "倒数第 \(-n) 个" + zhWeekdays[day] : "the \(Self.ordinal(-n)) to last " + enWeekdays[day]
        }
        if zh { return "第 \(n) 个" + zhWeekdays[day] }
        return "the " + (n <= enOrdinals.count ? enOrdinals[n - 1] : Self.ordinal(n)) + " " + enWeekdays[day]
    }

    /// 触发规则的人话描述；认不出时显示原文。`timeZone` 是用户当前的时区：规则的时区和它不同时注明。
    public static func describe(
        _ schedule: Schedule, language: DisplayLanguage = .current, timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> String {
        let zh = language == .chinese
        switch schedule {
        case .cron(let expression, let tz):
            let text =
                describeCron(expression, language: language) ?? (zh ? "cron 规则 \(expression)" : "Cron \(expression)")
            guard !tz.isEmpty, tz != timeZone.identifier else { return text }
            return zh ? "\(text)（\(tz) 时间）" : "\(text) (\(tz) time)"
        case .rrule(let rule):
            guard let text = describeRRule(rule, language: language) else {
                return zh ? "自定义重复规则" : "Custom recurrence"
            }
            // DTSTART 的时区（TZID，或者 UTC 的 …Z）和用户的不同时注明，和 cron 一样。
            let startLine = rule.split(whereSeparator: \.isNewline).first { $0.uppercased().hasPrefix("DTSTART") }
            guard let zone = startLine.flatMap({ RecurrenceRule.parseStart(String($0))?.1 }),
                zone.identifier != timeZone.identifier
            else { return text }
            // `…Z` 解析出来的时区叫 GMT，显示成 UTC。
            let name = ["GMT", "UTC"].contains(zone.identifier) ? "UTC" : zone.identifier
            return zh ? "\(text)（\(name) 时间）" : "\(text) (\(name) time)"
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
