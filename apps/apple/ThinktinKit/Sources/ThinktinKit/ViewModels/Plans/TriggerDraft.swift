import Foundation

/// 触发器编辑器里正在编的一条规则（WBS 12.6）：常用的几种（每天、每周几、每月几号、一次性）和高级的 cron、RRULE，
/// 时区默认是设备的时区。`schedule` 生成服务端要的 `Schedule`；`init(schedule:)` 把已有的规则拆回来（认得出的
/// cron 拆成常用写法，认不出的进“高级 cron”）；`setKind(_:)` 在几种写法之间换时尽量带上已经填的内容。
public struct TriggerDraft: Hashable, Sendable {
    /// 规则的写法。
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case daily, weekly, monthly, once, cron, rrule

        /// 常用写法（每天、每周、每月）：用时刻 + 日子拼成 cron。
        public var isCalendar: Bool { self == .daily || self == .weekly || self == .monthly }
    }

    public var kind: Kind
    /// 时刻（每天、每周、每月、RRULE 的开始时间），按 `timeZoneID` 的本地时间。
    public var hour: Int
    public var minute: Int
    /// 每周的哪几天：0 是周日，1 到 6 是周一到周六（和 cron 一样）。
    public var weekdays: Set<Int>
    /// 每月的哪几号（1 到 31；没有这一天的月份跳过）。
    public var monthDays: Set<Int>
    /// 一次性的时间。
    public var onceAt: Date
    /// 高级：五段 cron。
    public var cronExpression: String
    /// 高级：RRULE 那一行（`FREQ=WEEKLY;BYDAY=MO`，可以带 `RRULE:`）。也可以直接贴带 DTSTART 的完整规则，
    /// 那样开始日期和时刻以贴进来的为准。
    public var rruleText: String
    /// RRULE 的开始日期（DTSTART 的日期部分，时刻用 `hour`、`minute`）。
    public var startDay: LocalDay
    /// 规则的时区（IANA 名称）。一次性的规则是绝对时间，不用它。
    public var timeZoneID: String

    /// 新的一条：每天 09:00，设备的时区。
    public init(timeZone: TimeZone = .current, now: Date = Date()) {
        let calendar = ScheduleForecast.calendar(timeZone)
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        kind = .daily
        hour = 9
        minute = 0
        weekdays = [((c.weekday ?? 2) - 1)]
        monthDays = [c.day ?? 1]
        onceAt = Self.roundedUp(now.addingTimeInterval(3600), calendar: calendar)
        cronExpression = "0 9 * * *"
        rruleText = "FREQ=WEEKLY;BYDAY=MO"
        startDay = LocalDay(year: c.year ?? 2026, month: c.month ?? 1, day: c.day ?? 1)
        timeZoneID = timeZone.identifier
    }

    /// 把已有的规则拆回来编辑。`timeZone` 是设备的时区（规则没写时区、一次性的规则用它）。
    public init(schedule: Schedule, timeZone: TimeZone = .current, now: Date = Date()) {
        self.init(timeZone: timeZone, now: now)
        switch schedule {
        case .cron(let expression, let zone):
            if !zone.isEmpty { timeZoneID = zone }
            cronExpression = Self.normalizedCron(expression)
            // 认得出的直接用常用写法显示，认不出的进“高级 cron”。
            kind = adoptCron(cronExpression) ?? .cron
        case .rrule(let text):
            kind = .rrule
            adoptRRule(text)
        case .once(let at):
            kind = .once
            onceAt = at
            let c = ScheduleForecast.calendar(timeZone).dateComponents([.hour, .minute], from: at)
            hour = c.hour ?? hour
            minute = c.minute ?? minute
        }
    }

    // MARK: 生成规则

    /// 按现在填的内容生成规则（没检查过，先看 `problem(now:)`）。
    public var schedule: Schedule {
        switch kind {
        case .daily, .weekly, .monthly: .cron(expression: calendarCron, timeZone: timeZoneID)
        case .once: .once(onceAt)
        case .cron: .cron(expression: Self.normalizedCron(cronExpression), timeZone: timeZoneID)
        case .rrule: .rrule(composedRRule)
        }
    }

    /// 常用写法对应的 cron：每天 `M H * * *`，每周 `M H * * 1-5`，每月 `M H 1,15 * *`。
    var calendarCron: String {
        let time = "\(minute) \(hour)"
        switch kind {
        case .weekly:
            let days = weekdays.sorted()
            if days == [1, 2, 3, 4, 5] { return "\(time) * * 1-5" }
            if days.count == 7 { return "\(time) * * *" }
            return "\(time) * * " + days.map(String.init).joined(separator: ",")
        case .monthly:
            return "\(time) " + monthDays.sorted().map(String.init).joined(separator: ",") + " * *"
        default:
            return "\(time) * * *"
        }
    }

    /// RRULE 的完整文本：贴进来的带 DTSTART 就原样用（换行统一成 `\n`），否则按开始日期、时刻、时区补上
    /// `DTSTART;TZID=…`（服务端要求 DTSTART 带时区）。
    var composedRRule: String {
        let text = rruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.uppercased().hasPrefix("DTSTART") }) {
            return lines.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        var body = text.uppercased().replacingOccurrences(of: " ", with: "")
        if body.hasPrefix("RRULE:") { body.removeFirst(6) }
        let stamp =
            String(format: "%04d%02d%02d", startDay.year, startDay.month, startDay.day)
            + String(format: "T%02d%02d00", hour, minute)
        return "DTSTART;TZID=\(timeZoneID):\(stamp)\nRRULE:\(body)"
    }

    // MARK: 换写法

    /// 换一种写法，尽量带上已经填的：常用写法换成 cron 时填好对应的表达式，cron 换回常用写法时拆得出来就用拆出来的；
    /// 换成 RRULE 时写好等价的规则；换成一次性时，时间已经过去了就改成下一个这个时刻。
    public mutating func setKind(_ newKind: Kind, now: Date = Date()) {
        guard newKind != kind else { return }
        let old = kind
        switch newKind {
        case .cron:
            if old.isCalendar { cronExpression = calendarCron }
        case .rrule:
            if old.isCalendar {
                rruleText = equivalentRRule(for: old)
                startDay = today(now: now)
            } else if old == .cron, let found = adoptCron(cronExpression) {
                rruleText = equivalentRRule(for: found)
                startDay = today(now: now)
            }
        case .once:
            if onceAt <= now { onceAt = nextOccurrence(hour: hour, minute: minute, after: now) }
        case .daily, .weekly, .monthly:
            if old == .cron { adoptCron(cronExpression) }
            if old == .rrule {
                adoptRRule(composedRRule)
                adoptRRuleCalendar(rruleText)
            }
        }
        if newKind == .weekly && weekdays.isEmpty { weekdays = [1] }
        if newKind == .monthly && monthDays.isEmpty { monthDays = [1] }
        kind = newKind
    }

    /// cron 拆成常用写法：分、时都是一个值，月是 `*`，“日”“周”至少一个是 `*`。拆得出就填好时刻、日子并返回写法。
    @discardableResult
    mutating func adoptCron(_ expression: String) -> Kind? {
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5, parts[3] == "*",
            case .values(let ms)? = CronField(parts[0], range: 0...59), ms.count == 1,
            case .values(let hs)? = CronField(parts[1], range: 0...23), hs.count == 1
        else { return nil }
        let dayStar = parts[2] == "*"
        let weekStar = parts[4] == "*"
        var found: Kind?
        if dayStar && weekStar {
            found = .daily
        } else if dayStar,
            case .values(let ds)? = CronField(parts[4], range: 0...7, names: ScheduleDescription.weekdayNames)?
                .normalizingSunday()
        {
            weekdays = Set(ds)
            found = ds.count == 7 ? .daily : .weekly
        } else if weekStar, case .values(let ds)? = CronField(parts[2], range: 1...31) {
            monthDays = Set(ds)
            found = .monthly
        }
        guard let found else { return nil }
        hour = hs[0]
        minute = ms[0]
        return found
    }

    /// RRULE 那一行拆成常用写法的日子和时刻（换回每天、每周、每月时用）：WEEKLY 的不带序号的 BYDAY、MONTHLY 的
    /// 正数 BYMONTHDAY、只有一个值的 BYHOUR / BYMINUTE。拆不出的部分不动。
    mutating func adoptRRuleCalendar(_ body: String) {
        var fields: [String: String] = [:]
        for pair in body.uppercased().split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        if let h = fields["BYHOUR"].flatMap(Int.init), (0...23).contains(h) { hour = h }
        if let m = fields["BYMINUTE"].flatMap(Int.init), (0...59).contains(m) { minute = m }
        if fields["FREQ"] == "WEEKLY", let raw = fields["BYDAY"] {
            let days = raw.split(separator: ",").compactMap { RecurrenceRule.weekdayCodes.firstIndex(of: String($0)) }
            if !days.isEmpty { weekdays = Set(days) }
        }
        if fields["FREQ"] == "MONTHLY", let raw = fields["BYMONTHDAY"] {
            let days = raw.split(separator: ",").compactMap { Int($0) }.filter { (1...31).contains($0) }
            if !days.isEmpty { monthDays = Set(days) }
        }
    }

    /// RRULE 拆回来：一行带时区的 DTSTART 加一行 RRULE 时，开始日期、时刻、时区放进各自的字段，RRULE 只留那一行；
    /// 别的（浮动时间、多行）原样放进文本框。
    mutating func adoptRRule(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let starts = lines.filter { $0.uppercased().hasPrefix("DTSTART") }
        let rules = lines.filter { !$0.uppercased().hasPrefix("DTSTART") }
        guard starts.count == 1, rules.count == 1, let start = Self.parseStart(starts[0]) else {
            rruleText = lines.joined(separator: "\n")
            return
        }
        var body = rules[0]
        if body.uppercased().hasPrefix("RRULE:") { body.removeFirst(6) }
        rruleText = body
        timeZoneID = start.timeZoneID
        startDay = start.day
        hour = start.hour
        minute = start.minute
    }

    /// 常用写法对应的 RRULE 那一行。
    func equivalentRRule(for kind: Kind) -> String {
        let codes = RecurrenceRule.weekdayCodes
        switch kind {
        case .weekly:
            return "FREQ=WEEKLY;BYDAY="
                + weekdays.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { codes[$0] }.joined(
                    separator: ",")
        case .monthly:
            return "FREQ=MONTHLY;BYMONTHDAY=" + monthDays.sorted().map(String.init).joined(separator: ",")
        default:
            return "FREQ=DAILY"
        }
    }

    // MARK: 检查

    /// 保存前要改的问题；没有为 nil。
    public func problem(now: Date = Date()) -> TriggerProblem? {
        switch kind {
        case .once:
            return onceAt > now ? nil : .onceInPast
        case .daily, .weekly, .monthly:
            guard TimeZone(identifier: timeZoneID) != nil else { return .unknownTimeZone }
            if kind == .weekly && weekdays.isEmpty { return .noWeekdays }
            if kind == .monthly && monthDays.isEmpty { return .noMonthDays }
        case .cron:
            guard TimeZone(identifier: timeZoneID) != nil else { return .unknownTimeZone }
            let expression = Self.normalizedCron(cronExpression)
            if expression.isEmpty { return .cronEmpty }
            // `L`、`W`、`#`、`@daily` 这些 App 算不了，交给服务端检查（只提示，不拦）。
            if expression.hasPrefix("@") || expression.uppercased().contains(where: { "LW#".contains($0) }) {
                return nil
            }
            if expression.split(separator: " ").count != 5 { return .cronFieldCount }
            if CronSchedule(expression: expression, timeZone: timeZoneID) == nil { return .cronInvalid }
        case .rrule:
            if let problem = rruleProblem(now: now) { return problem }
        }
        // 能在本地算的：再也不会触发、比服务端允许的更频繁，保存时一定会被拒。
        let schedule = self.schedule
        if let fires = ScheduleForecast.nextFires(schedule, after: now, count: 1), fires.isEmpty {
            return .neverFires
        }
        if let gap = ScheduleForecast.minimumGap(schedule, after: now), gap < ScheduleForecast.minimumInterval {
            return .tooFrequent(minimumMinutes: Int(ScheduleForecast.minimumInterval / 60))
        }
        return nil
    }

    /// RRULE 的格式问题（服务端 `Schedule::parse_new` 的几条规矩）。
    func rruleProblem(now: Date) -> TriggerProblem? {
        let body = rruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return .rruleEmpty }
        let full = composedRRule
        if full.count > Self.maxRRuleLength { return .rruleTooLong(max: Self.maxRRuleLength) }
        let lines = full.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        if lines.contains(where: { $0.hasPrefix("RDATE") }) { return .rruleExtraDates }
        let ruleLines = lines.filter { !$0.hasPrefix("DTSTART") && !$0.hasPrefix("EXDATE") }
        if ruleLines.count > 1 { return .rruleMultipleRules }
        guard let rule = ruleLines.first, rule.contains("FREQ=") else { return .rruleNoFrequency }
        if rule.contains("FREQ=SECONDLY") { return .rruleTooFrequent }
        guard
            let startLine = full.split(whereSeparator: \.isNewline).first(where: {
                $0.uppercased().hasPrefix("DTSTART")
            }),
            let start = RecurrenceRule.parseStart(String(startLine))
        else { return .rruleNoTimeZone }
        // DTSTART 要在“一天前”到“一年后”之间（服务端怕从很早的 DTSTART 往后数太慢）。
        if start.0 < now.addingTimeInterval(-86400) || start.0 > now.addingTimeInterval(366 * 86400) {
            return .rruleStartOutOfRange
        }
        return nil
    }

    /// 不拦保存、但要告诉用户的事（有 `problem` 时界面先显示问题）；没有为 nil。
    public var warning: TriggerWarning? {
        if kind == .once { return nil }
        return ScheduleForecast.canForecast(schedule) ? nil : .cannotPreview
    }

    /// RRULE 文本里自己带了 DTSTART（开始日期、时刻、时区以贴进来的为准，界面上那几个选择器不起作用）。
    public var rruleHasOwnStart: Bool {
        rruleText.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DTSTART")
        }
    }

    /// 接下来几次触发（本地算的预览）；算不了为 nil。
    public func upcoming(now: Date = Date(), count: Int = 5) -> [Date]? {
        ScheduleForecast.nextFires(schedule, after: now, count: count)
    }

    /// RRULE 文本最长几个字符（服务端的 `MAX_RULE_LEN`）。
    public static let maxRRuleLength = 1000

    // MARK: 工具

    /// cron 去掉首尾空白、多个空白并成一个。
    static func normalizedCron(_ expression: String) -> String {
        expression.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 往后取整到整分钟（一次性的默认时间）。
    static func roundedUp(_ date: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let floored = calendar.date(from: c) ?? date
        return floored < date ? floored.addingTimeInterval(60) : floored
    }

    /// 规则时区里的今天。
    func today(now: Date) -> LocalDay {
        let zone = TimeZone(identifier: timeZoneID) ?? .current
        let c = ScheduleForecast.calendar(zone).dateComponents([.year, .month, .day], from: now)
        return LocalDay(year: c.year ?? startDay.year, month: c.month ?? startDay.month, day: c.day ?? startDay.day)
    }

    /// `now` 之后第一个 `hour:minute`（按规则的时区）。
    func nextOccurrence(hour: Int, minute: Int, after now: Date) -> Date {
        let calendar = ScheduleForecast.calendar(TimeZone(identifier: timeZoneID) ?? .current)
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        let today = calendar.date(from: c) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? now
    }

    /// 解析 DTSTART 行里的本地日期、时刻和时区（带 TZID 的，或者 UTC 的 `…Z`）。
    static func parseStart(_ line: String) -> (timeZoneID: String, day: LocalDay, hour: Int, minute: Int)? {
        guard let (date, zone) = RecurrenceRule.parseStart(line) else { return nil }
        let c = ScheduleForecast.calendar(zone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let y = c.year, let m = c.month, let d = c.day, let h = c.hour, let mi = c.minute else { return nil }
        // `…Z` 的 DTSTART 解析出来的时区叫 GMT；写回去用 UTC（服务端的 chrono-tz 两个都认）。
        let id = ["GMT", "UTC"].contains(zone.identifier) ? "UTC" : zone.identifier
        return (id, LocalDay(year: y, month: m, day: d), h, mi)
    }
}

/// 不带时区的日期（RRULE 的开始日期）。
public struct LocalDay: Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

/// 触发规则保存前要改的问题（和服务端的校验对应；服务端回的英文说明不给用户看）。
public enum TriggerProblem: Hashable, Sendable {
    case onceInPast
    case unknownTimeZone
    case noWeekdays
    case noMonthDays
    case cronEmpty
    case cronFieldCount
    case cronInvalid
    case rruleEmpty
    case rruleTooLong(max: Int)
    case rruleExtraDates
    case rruleMultipleRules
    case rruleNoFrequency
    case rruleTooFrequent
    case rruleNoTimeZone
    case rruleStartOutOfRange
    /// 再也不会触发（时间都过去了、COUNT 用完了、2 月 30 日这种）。
    case neverFires
    /// 比服务端允许的更频繁（默认最少隔 5 分钟）。
    case tooFrequent(minimumMinutes: Int)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .onceInPast: return zh ? "这个时间已经过去了，选一个将来的时间。" : "That time has passed. Pick a time in the future."
        case .unknownTimeZone: return zh ? "认不出这个时区，换一个吧。" : "That time zone isn't recognized. Pick another one."
        case .noWeekdays: return zh ? "至少选一天。" : "Pick at least one day."
        case .noMonthDays: return zh ? "至少选一个日子。" : "Pick at least one day of the month."
        case .cronEmpty: return zh ? "填上 cron 表达式。" : "Enter a cron expression."
        case .cronFieldCount:
            return zh
                ? "cron 要五段：分 时 日 月 周，用空格隔开。" : "A cron expression has five fields: minute hour day month weekday."
        case .cronInvalid:
            return zh
                ? "这个 cron 表达式有写错的地方，检查一下每一段的取值。"
                : "Something in this cron expression is off. Check each field's values."
        case .rruleEmpty:
            return zh ? "填上重复规则，比如 FREQ=WEEKLY;BYDAY=MO。" : "Enter a rule, for example FREQ=WEEKLY;BYDAY=MO."
        case .rruleTooLong(let max):
            return zh ? "规则太长了，最多 \(max) 个字符。" : "The rule is too long (up to \(max) characters)."
        case .rruleExtraDates: return zh ? "不支持 RDATE，只能写一条 RRULE。" : "RDATE isn't supported. Use a single RRULE."
        case .rruleMultipleRules: return zh ? "只能写一条 RRULE。" : "Only one RRULE is allowed."
        case .rruleNoFrequency: return zh ? "规则里要有 FREQ（重复的频率）。" : "The rule needs a FREQ."
        case .rruleTooFrequent: return zh ? "不能按秒重复。" : "Rules can't repeat every second."
        case .rruleNoTimeZone:
            return zh ? "DTSTART 要带时区（TZID=…）或者用 UTC 时间。" : "DTSTART needs a time zone (TZID=…) or a UTC time."
        case .rruleStartOutOfRange:
            return zh ? "开始时间要在昨天到一年后之间。" : "The start has to be between yesterday and a year from now."
        case .neverFires: return zh ? "按这条规则以后不会再触发了。" : "This rule never fires again."
        case .tooFrequent(let minutes):
            return zh
                ? "太频繁了：两次触发至少隔 \(minutes) 分钟。" : "Too frequent: runs need to be at least \(minutes) minutes apart."
        }
    }
}

/// 不拦保存、但要提示的事。
public enum TriggerWarning: Hashable, Sendable {
    /// App 算不了这种写法的触发时间：只能描述，保存时由服务端检查、算下一次。
    case cannotPreview

    public func message(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "App 没法预先算出这条规则的触发时间，保存时由服务端检查，下次触发以服务端算的为准。"
            : "The app can't work out when this rule fires. The server checks it when you save and works out the next run."
    }
}
