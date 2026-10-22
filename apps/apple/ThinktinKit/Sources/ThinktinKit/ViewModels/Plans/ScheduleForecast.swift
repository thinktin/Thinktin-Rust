import Foundation

/// 在本地预先算触发规则接下来几次的触发时间（WBS 12.6）。
///
/// 12.6 的决定：触发器编辑器“接下来几次”按 cron / RRULE 在本地算；App 算不了的写法只描述、不预测（返回 nil，
/// 界面写“保存后以服务端算的为准”）。规则和服务端（crates/orchestrator/src/schedule.rs：croner 4、rrule 0.14）尽量一致：
///
/// - cron：五段（分 时 日 月 周），按规则的时区；“日”和“周”都不是 `*`（或 `?`）时两者满足一个就算（croner 的默认，
///   不是“同时满足”）；夏令时跳过的那段时间里的固定时刻，在跳过之后的第一刻触发；`L`、`W`、`#`、`@daily` 这类写法算不了。
/// - RRULE：FREQ 是 YEARLY、MONTHLY、WEEKLY、DAILY、HOURLY，带 INTERVAL、COUNT、UNTIL、BYMONTH、BYMONTHDAY、BYDAY
///   （MONTHLY、YEARLY 里可以带序号，比如 `1MO`、`-1FR`）、BYHOUR、BYMINUTE、WKST；DTSTART 本身不符合规则时不算一次
///   （和 python-dateutil、rrule crate 一样）。BYSETPOS、BYWEEKNO、BYYEARDAY、BYSECOND、EXDATE、EXRULE 算不了。
/// - 一次性：就是那个时间，已经过去了就没有。
///
/// 只是预览：实际触发以服务端算的为准，削峰还会再晚几分钟。
public enum ScheduleForecast {
    /// 严格晚于 `date` 的前 `count` 次触发，按时间先后；算不了这种写法时为 nil，再也不会触发时是空数组。
    public static func nextFires(_ schedule: Schedule, after date: Date, count: Int) -> [Date]? {
        guard count > 0 else { return [] }
        switch schedule {
        case .once(let at):
            return at > date ? [at] : []
        case .cron(let expression, let timeZone):
            guard let cron = CronSchedule(expression: expression, timeZone: timeZone) else { return nil }
            var out: [Date] = []
            var cursor = date
            while out.count < count, let next = cron.next(after: cursor) {
                out.append(next)
                cursor = next
            }
            return out
        case .rrule(let text):
            guard let rule = RecurrenceRule(text: text) else { return nil }
            return rule.occurrences(after: date, limit: count)
        }
    }

    /// 能不能在本地预测这条规则。
    public static func canForecast(_ schedule: Schedule) -> Bool {
        switch schedule {
        case .once: true
        case .cron(let expression, let timeZone): CronSchedule(expression: expression, timeZone: timeZone) != nil
        case .rrule(let text): RecurrenceRule(text: text) != nil
        }
    }

    /// 从 `date` 起前 `samples` 次触发里相邻两次的最小间隔（服务端按同样的办法查“不比档位允许的更频繁”，看前 50 次）。
    /// 一次性的、算不了的、不到两次的为 nil。
    public static func minimumGap(_ schedule: Schedule, after date: Date, samples: Int = 50) -> TimeInterval? {
        if case .once = schedule { return nil }
        guard let fires = nextFires(schedule, after: date, count: samples), fires.count > 1 else { return nil }
        return zip(fires, fires.dropFirst()).map { $1.timeIntervalSince($0) }.min()
    }

    /// 服务端默认允许的最小触发间隔（crates/gateway 的 `min_trigger_interval`、agent 的 schedule 工具都是 5 分钟）。
    public static let minimumInterval: TimeInterval = 5 * 60

    /// 按规则的时区算日历用的公历。
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 本地时间转成时刻。这一刻不存在（夏令时跳过的那段）时：`fixedTime` 的取跳过之后的第一刻（croner 的做法），
    /// 否则跳过（nil）。重复的那段（夏令时结束）取较早的那一次。
    static func localDate(
        _ calendar: Calendar, year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0,
        fixedTime: Bool
    ) -> Date? {
        let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: wanted) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute {
            return date
        }
        guard fixedTime else { return nil }
        return calendar.timeZone.nextDaylightSavingTimeTransition(after: date.addingTimeInterval(-3 * 3600))
    }
}

// MARK: - cron

/// 五段 cron 的触发计算（croner 4 的语义，见 `ScheduleForecast`）。
struct CronSchedule: Sendable {
    let minutes: [Int]
    let hours: [Int]
    let days: Set<Int>
    let months: Set<Int>
    /// 周几：0 是周日（7 也换成 0）。
    let weekdays: Set<Int>
    /// “日”这一段写的是 `*` 或 `?`。
    let dayIsStar: Bool
    /// “周”这一段写的是 `*` 或 `?`。
    let weekdayIsStar: Bool
    let timeZone: TimeZone

    /// 最多往后找几天：够覆盖“每年 2 月 29 日”。
    static let searchDays = 366 * 8

    init?(expression: String, timeZone identifier: String) {
        guard let timeZone = TimeZone(identifier: identifier) else { return nil }
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5,
            let minute = CronField(parts[0], range: 0...59),
            let hour = CronField(parts[1], range: 0...23),
            let day = CronField(parts[2], range: 1...31),
            let month = CronField(parts[3], range: 1...12, names: ScheduleDescription.monthNames),
            let weekday = CronField(parts[4], range: 0...7, names: ScheduleDescription.weekdayNames)
        else { return nil }
        minutes = minute.expanded(in: 0...59)
        hours = hour.expanded(in: 0...23)
        days = Set(day.expanded(in: 1...31))
        months = Set(month.expanded(in: 1...12))
        weekdays = Set(weekday.expanded(in: 0...7).map { $0 == 7 ? 0 : $0 })
        dayIsStar = parts[2] == "*" || parts[2] == "?"
        weekdayIsStar = parts[4] == "*" || parts[4] == "?"
        self.timeZone = timeZone
    }

    /// 一天里只有一个时刻（夏令时跳过时挪到跳过之后，不丢）。
    var isFixedTime: Bool { minutes.count == 1 && hours.count == 1 }

    /// 这一天符不符合“日”“月”“周”三段。`weekday` 0 是周日。
    func matches(month: Int, day: Int, weekday: Int) -> Bool {
        guard months.contains(month) else { return false }
        let dayMatches = days.contains(day)
        let weekdayMatches = weekdays.contains(weekday)
        switch (dayIsStar, weekdayIsStar) {
        case (true, true): return true
        case (false, true): return dayMatches
        case (true, false): return weekdayMatches
        case (false, false): return dayMatches || weekdayMatches
        }
    }

    /// 严格晚于 `date` 的下一次触发；找不到（规则永远不会触发）为 nil。
    func next(after date: Date) -> Date? {
        let calendar = ScheduleForecast.calendar(timeZone)
        var day = calendar.startOfDay(for: date)
        var checked = 0
        while checked < Self.searchDays {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = c.year, let month = c.month, let dayOfMonth = c.day, let weekday = c.weekday else {
                return nil
            }
            checked += 1
            if !months.contains(month) {
                // 这个月整个不符合：直接跳到下个月 1 日。
                let next = month == 12 ? (year + 1, 1) : (year, month + 1)
                guard let first = calendar.date(from: DateComponents(year: next.0, month: next.1, day: 1)) else {
                    return nil
                }
                day = calendar.startOfDay(for: first)
                continue
            }
            if matches(month: month, day: dayOfMonth, weekday: weekday - 1) {
                for hour in hours {
                    for minute in minutes {
                        guard
                            let t = ScheduleForecast.localDate(
                                calendar, year: year, month: month, day: dayOfMonth, hour: hour, minute: minute,
                                fixedTime: isFixedTime)
                        else { continue }
                        if t > date { return t }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = calendar.startOfDay(for: next)
        }
        return nil
    }
}

extension CronField {
    /// 展开成具体的取值（升序）。
    func expanded(in range: ClosedRange<Int>) -> [Int] {
        switch self {
        case .any: Array(range)
        case .step(let n): Array(Swift.stride(from: range.lowerBound, through: range.upperBound, by: n))
        case .values(let values): values
        }
    }
}

// MARK: - RRULE

/// RRULE 的触发计算（RFC 5545 的一个子集，见 `ScheduleForecast`）。
struct RecurrenceRule: Sendable {
    enum Frequency: String, Sendable {
        case yearly = "YEARLY"
        case monthly = "MONTHLY"
        case weekly = "WEEKLY"
        case daily = "DAILY"
        case hourly = "HOURLY"
    }

    /// BYDAY 的一项：周几（0 是周日）和可选的序号（`1MO` 是第一个周一，`-1FR` 是最后一个周五）。
    struct WeekdayRule: Hashable, Sendable {
        var weekday: Int
        var ordinal: Int?
    }

    let frequency: Frequency
    let interval: Int
    let count: Int?
    let until: Date?
    let byMonth: [Int]?
    let byMonthDay: [Int]?
    let byDay: [WeekdayRule]?
    let byHour: [Int]?
    let byMinute: [Int]?
    /// 一周从周几开始（WKST，默认周一）。
    let weekStart: Int
    let start: Date
    let timeZone: TimeZone

    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// 一个 BYxxx 列表的解析结果。
    enum IntList: Equatable {
        case missing
        case invalid
        case values([Int])

        var values: [Int]? {
            if case .values(let v) = self { return v }
            return nil
        }
    }

    /// 最多往后数多少个周期（十年上下），免得永远不会触发的规则（`BYMONTH=2;BYMONTHDAY=30`）在界面上算太久。
    var maxPeriods: Int {
        switch frequency {
        case .yearly: 30
        case .monthly: 360
        case .weekly: 1600
        case .daily: 3700
        case .hourly: 24 * 370
        }
    }

    /// 解析 DTSTART + RRULE 文本。算不了的写法、格式不对的都返回 nil。
    init?(text: String) {
        var startLine: String?
        var ruleLine: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("DTSTART") {
                guard startLine == nil else { return nil }
                startLine = line
            } else if upper.hasPrefix("RRULE:") {
                guard ruleLine == nil else { return nil }
                ruleLine = String(line.dropFirst(6))
            } else if upper.hasPrefix("FREQ=") || (!upper.contains(":") && upper.contains("FREQ=")) {
                guard ruleLine == nil else { return nil }
                ruleLine = line
            } else {
                // EXDATE、RDATE、EXRULE 之类：算不了。
                return nil
            }
        }
        guard let startLine, let ruleLine, let (start, zone) = Self.parseStart(startLine) else { return nil }
        self.start = start
        self.timeZone = zone

        var fields: [String: String] = [:]
        for pair in ruleLine.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard kv.count == 2, fields[kv[0]] == nil else { return nil }
            fields[kv[0]] = kv[1]
        }
        let supported: Set<String> = [
            "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYMONTH", "BYMONTHDAY", "BYDAY", "BYHOUR", "BYMINUTE", "WKST",
        ]
        guard fields.keys.allSatisfy(supported.contains), let freq = fields["FREQ"].flatMap(Frequency.init(rawValue:))
        else { return nil }
        frequency = freq

        /// 逗号分隔的整数（BYMONTH 这些）：没给是 `.missing`，有不合法的是 `.invalid`。
        func ints(_ key: String, _ range: ClosedRange<Int>, allowNegative: Bool = false) -> IntList {
            guard let raw = fields[key] else { return .missing }
            var out: [Int] = []
            for item in raw.split(separator: ",") {
                guard let n = Int(item), range.contains(n) || (allowNegative && range.contains(-n)) else {
                    return .invalid
                }
                out.append(n)
            }
            return out.isEmpty ? .invalid : .values(out)
        }
        if let raw = fields["INTERVAL"] {
            guard let n = Int(raw), n >= 1 else { return nil }
            interval = n
        } else {
            interval = 1
        }
        if let raw = fields["COUNT"] {
            guard let n = Int(raw), n >= 1 else { return nil }
            count = n
        } else {
            count = nil
        }
        if let raw = fields["UNTIL"] {
            guard let date = Self.parseDateTime(raw, timeZone: zone, endOfDayForDates: true) else { return nil }
            until = date
        } else {
            until = nil
        }
        let lists = [
            ints("BYMONTH", 1...12), ints("BYMONTHDAY", 1...31, allowNegative: true), ints("BYHOUR", 0...23),
            ints("BYMINUTE", 0...59),
        ]
        guard !lists.contains(.invalid) else { return nil }
        byMonth = lists[0].values
        byMonthDay = lists[1].values
        byHour = lists[2].values
        byMinute = lists[3].values
        if let raw = fields["WKST"] {
            guard let i = Self.weekdayCodes.firstIndex(of: raw) else { return nil }
            weekStart = i
        } else {
            weekStart = 1
        }
        if let raw = fields["BYDAY"] {
            var rules: [WeekdayRule] = []
            for item in raw.split(separator: ",") {
                let code = String(item.suffix(2))
                guard let weekday = Self.weekdayCodes.firstIndex(of: code) else { return nil }
                let prefix = item.dropLast(2)
                if prefix.isEmpty {
                    rules.append(WeekdayRule(weekday: weekday, ordinal: nil))
                } else {
                    guard let n = Int(prefix), n != 0, (1...53).contains(abs(n)) else { return nil }
                    rules.append(WeekdayRule(weekday: weekday, ordinal: n))
                }
            }
            byDay = rules
        } else {
            byDay = nil
        }
        // 带序号的 BYDAY 只认 MONTHLY，以及带了 BYMONTH 的 YEARLY（按月里的第几个算）。
        if let byDay, byDay.contains(where: { $0.ordinal != nil }) {
            let ok = frequency == .monthly || (frequency == .yearly && byMonth != nil)
            guard ok else { return nil }
        }
        // WEEKLY 不能带 BYMONTHDAY（RFC 5545）。
        if frequency == .weekly && byMonthDay != nil { return nil }
    }

    /// DTSTART 行：`DTSTART;TZID=Asia/Shanghai:20261022T090000`、`DTSTART:20261022T010000Z`。
    /// 不带时区的（浮动时间）、只有日期的服务端不收，这里也不算。
    static func parseStart(_ line: String) -> (Date, TimeZone)? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let params = line[..<colon].split(separator: ";").dropFirst()
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        var zone: TimeZone?
        for param in params {
            let kv = param.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "TZID": zone = TimeZone(identifier: kv[1])
            case "VALUE" where kv[1].uppercased() == "DATE": return nil
            default: break
            }
        }
        if value.uppercased().hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC")
        }
        guard let zone, let date = parseDateTime(value, timeZone: zone, endOfDayForDates: false) else { return nil }
        return (date, zone)
    }

    /// `20261022T090000`（按 `timeZone`）、`20261022T010000Z`（UTC）、`20261022`（只有日期：`endOfDayForDates` 时取
    /// 这一天的最后一秒，UNTIL 用）。
    static func parseDateTime(_ raw: String, timeZone: TimeZone, endOfDayForDates: Bool) -> Date? {
        let value = raw.uppercased()
        let utc = value.hasSuffix("Z")
        let body = utc ? String(value.dropLast()) : value
        let parts = body.split(separator: "T", omittingEmptySubsequences: false)
        guard let datePart = parts.first, datePart.count == 8, let ymd = Int(datePart) else { return nil }
        let year = ymd / 10000
        let month = ymd / 100 % 100
        let day = ymd % 100
        var hour = 0
        var minute = 0
        var second = 0
        if parts.count == 2 {
            let t = parts[1]
            guard t.count == 6, let hms = Int(t) else { return nil }
            (hour, minute, second) = (hms / 10000, hms / 100 % 100, hms % 100)
        } else if parts.count == 1 {
            if endOfDayForDates { (hour, minute, second) = (23, 59, 59) }
        } else {
            return nil
        }
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute),
            (0...60).contains(second)
        else { return nil }
        let zone = utc ? TimeZone(identifier: "UTC") ?? timeZone : timeZone
        let calendar = ScheduleForecast.calendar(zone)
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        // 2 月 30 日这种：日历会顺延到下个月，算格式不对。
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    /// 严格晚于 `date` 的前 `limit` 次触发。
    func occurrences(after date: Date, limit: Int) -> [Date] {
        guard limit > 0 else { return [] }
        let calendar = ScheduleForecast.calendar(timeZone)
        let s = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: start)
        guard let sYear = s.year, let sMonth = s.month, let sDay = s.day, let sHour = s.hour, let sMinute = s.minute,
            let sWeekday = s.weekday
        else { return [] }
        let second = s.second ?? 0
        let hours = (byHour ?? [sHour]).sorted()
        let minutes = (byMinute ?? [sMinute]).sorted()
        let fixedTime = hours.count == 1 && minutes.count == 1
        let startDay = calendar.startOfDay(for: start)

        var out: [Date] = []
        var produced = 0
        /// 收下一个候选的时刻；返回 false 时停止（COUNT 用完、过了 UNTIL、收够了）。
        func take(_ t: Date) -> Bool {
            guard t >= start else { return true }
            if let until, t > until { return false }
            produced += 1
            if t > date { out.append(t) }
            if out.count >= limit { return false }
            if let count, produced >= count { return false }
            return true
        }
        /// 一天里的各个时刻（BYHOUR × BYMINUTE，默认 DTSTART 的时分）。
        func emit(year: Int, month: Int, day: Int) -> Bool {
            for hour in hours {
                for minute in minutes {
                    guard
                        let t = ScheduleForecast.localDate(
                            calendar, year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                            fixedTime: fixedTime)
                    else { continue }
                    if !take(t) { return false }
                }
            }
            return true
        }
        /// 一个日期过不过 BYMONTH、BYMONTHDAY、不带序号的 BYDAY 这几道筛选。
        func passes(year: Int, month: Int, day: Int, weekday: Int, monthLength: Int) -> Bool {
            if let byMonth, !byMonth.contains(month) { return false }
            if let byMonthDay, !byMonthDay.contains(where: { resolve($0, length: monthLength) == day }) { return false }
            if let byDay, !byDay.contains(where: { $0.weekday == weekday }) { return false }
            return true
        }

        switch frequency {
        case .daily, .weekly:
            // 每个周期里的日子：DAILY 是一天；WEEKLY 是 WKST 开始的那一周里符合 BYDAY（默认 DTSTART 的周几）的日子。
            var periodStart = startDay
            if frequency == .weekly {
                let back = (sWeekday - 1 - weekStart + 7) % 7
                periodStart = calendar.date(byAdding: .day, value: -back, to: startDay) ?? startDay
            }
            let weekdays = byDay?.map(\.weekday) ?? [sWeekday - 1]
            let step = frequency == .daily ? interval : 7 * interval
            let span = frequency == .daily ? 1 : 7
            for k in 0..<maxPeriods {
                guard let first = calendar.date(byAdding: .day, value: k * step, to: periodStart) else { break }
                for offset in 0..<span {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                    guard let y = c.year, let m = c.month, let d = c.day, let w = c.weekday else { continue }
                    let length = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
                    if frequency == .weekly && !weekdays.contains(w - 1) { continue }
                    guard passes(year: y, month: m, day: d, weekday: w - 1, monthLength: length) else { continue }
                    if !emit(year: y, month: m, day: d) { return out }
                }
            }
        case .monthly, .yearly:
            for k in 0..<maxPeriods {
                let months: [(year: Int, month: Int)]
                if frequency == .monthly {
                    let total = sYear * 12 + (sMonth - 1) + k * interval
                    months = [(total / 12, total % 12 + 1)]
                } else {
                    let year = sYear + k * interval
                    let list = byMonth ?? ((byMonthDay != nil || byDay != nil) ? Array(1...12) : [sMonth])
                    months = list.sorted().map { (year, $0) }
                }
                for (year, month) in months {
                    if let byMonth, !byMonth.contains(month) { continue }
                    for day in days(year: year, month: month, defaultDay: sDay, calendar: calendar) {
                        if !emit(year: year, month: month, day: day) { return out }
                    }
                }
            }
        case .hourly:
            for k in 0..<maxPeriods {
                guard let base = calendar.date(byAdding: .hour, value: k * interval, to: start) else { break }
                let c = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: base)
                guard let y = c.year, let m = c.month, let d = c.day, let h = c.hour, let w = c.weekday else {
                    continue
                }
                if let byHour, !byHour.contains(h) { continue }
                let length = calendar.range(of: .day, in: .month, for: base)?.count ?? 31
                guard passes(year: y, month: m, day: d, weekday: w - 1, monthLength: length) else { continue }
                for minute in minutes {
                    guard
                        let t = ScheduleForecast.localDate(
                            calendar, year: y, month: m, day: d, hour: h, minute: minute, second: second,
                            fixedTime: false)
                    else { continue }
                    if !take(t) { return out }
                }
            }
        }
        return out
    }

    /// MONTHLY、YEARLY 的一个月里哪几天（升序）：BYMONTHDAY（负数从月底数）、BYDAY（带序号是第几个，不带是每个），
    /// 两个都给时取交集；都没给是 DTSTART 那一天（这个月没有这一天就跳过）。
    func days(year: Int, month: Int, defaultDay: Int, calendar: Calendar) -> [Int] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return [] }
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 31
        let firstWeekday = calendar.component(.weekday, from: first) - 1
        var candidates: Set<Int>?
        if let byMonthDay {
            candidates = Set(byMonthDay.compactMap { resolve($0, length: length) })
        }
        if let byDay {
            var set = Set<Int>()
            for rule in byDay {
                // 这个月里所有这个周几的日子。
                let firstMatch = 1 + (rule.weekday - firstWeekday + 7) % 7
                let all = Array(Swift.stride(from: firstMatch, through: length, by: 7))
                if let n = rule.ordinal {
                    let index = n > 0 ? n - 1 : all.count + n
                    if all.indices.contains(index) { set.insert(all[index]) }
                } else {
                    set.formUnion(all)
                }
            }
            candidates = candidates.map { $0.intersection(set) } ?? set
        }
        if let candidates { return candidates.sorted() }
        return defaultDay <= length ? [defaultDay] : []
    }

    /// BYMONTHDAY 的取值换成这个月的第几天（-1 是最后一天）；这个月没有这一天为 nil。
    func resolve(_ value: Int, length: Int) -> Int? {
        let day = value > 0 ? value : length + 1 + value
        return (1...length).contains(day) ? day : nil
    }
}
