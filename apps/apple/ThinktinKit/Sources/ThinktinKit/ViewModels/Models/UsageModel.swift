import Foundation
import Observation

/// 用量看板（WBS 12.4，`.usage`，入口：设置、模型 key 列表、对话页的用量按钮）：最近 7 / 30 / 90 天，
/// 按天的柱状图（Swift Charts）、总计卡片，下面的表格可以按天 / 实例 / 模型 / key 分组，标出估算和失败的请求。
///
/// - 按天的数据总是拉（画图、算总计）；表格选了别的分组时再拉那一组。时区用这台设备的（`timeZone`），按天分组也按它。
/// - 服务端只返回有用量的那几天，画图前把没用量的天补成 0（`dayPoints`）。
/// - 实例、key、厂商的名字另外拉（拉不到退回成 id 的后几位）；删掉了的实例、key 写“已删除”。
/// - 不缓存（离线时“暂无数据”）。换时间范围时清掉上一个范围的数据（不把 30 天的总数显示成 90 天的）；
///   切得快时，旧范围、旧分组的结果回来了也不用。
@Observable @MainActor
public final class UsageModel {
    /// 看多长时间。
    public enum Period: Int, CaseIterable, Hashable, Sendable {
        case week = 7
        case month = 30
        case quarter = 90

        public var days: Int { rawValue }

        public func title(_ language: DisplayLanguage = .current) -> String {
            language == .chinese ? "\(days) 天" : "\(days) days"
        }
    }

    public private(set) var period: Period
    public private(set) var group: UsageGroup
    /// 按天的汇总（画图、总计）。
    public private(set) var daily: UsageSummary?
    /// 表格的分组（选的是按天时和 `daily` 一样）。
    public private(set) var grouped: UsageSummary?
    public private(set) var instances: [Instance] = []
    public private(set) var credentials: [Credential] = []
    public private(set) var vendors: [VendorInfo] = []

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 表格那一组拉不到（图和总计照常）。
    public private(set) var groupError: ClientError?

    /// 按天分组用的时区。
    public let timeZone: TimeZone
    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let now: @Sendable () -> Date
    /// 拉的是哪一次（切换得快时丢掉旧的结果）。
    @ObservationIgnored private var generation = 0

    public init(
        client: any ClientProtocol, period: Period = .month, group: UsageGroup = .day, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.period = period
        self.group = group
        self.timeZone = timeZone
        self.now = now
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 时间范围：从 `days - 1` 天前的零点到现在（含今天）。
    public var range: (from: Date, to: Date) {
        let to = now()
        let today = calendar.startOfDay(for: to)
        let from = calendar.date(byAdding: .day, value: -(period.days - 1), to: today) ?? today
        return (from, to)
    }

    // MARK: 加载

    /// 拉按天的汇总、表格的分组和名字。结果回来时时间范围已经换了就整个不用，分组换了就只用按天的。
    public func load() async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        let client = self.client
        let (from, to) = range
        let zone = timeZone
        let group = self.group
        let period = self.period
        async let daily = AgentsErrors.attempt {
            try await client.usage(group: .day, from: from, to: to, timeZone: zone)
        }
        async let grouped = AgentsErrors.attempt { () async throws -> UsageSummary? in
            if group == .day { return nil }
            return try await client.usage(group: group, from: from, to: to, timeZone: zone)
        }
        async let names = Self.loadNames(client: client, group: group)

        let (dailyResult, groupedResult, nameLists) = await (daily, grouped, names)
        guard current == generation, period == self.period else { return }
        if let instances = nameLists.instances { self.instances = instances }
        if let credentials = nameLists.credentials { self.credentials = credentials }
        if let vendors = nameLists.vendors { self.vendors = vendors }
        switch dailyResult {
        case .success(let summary):
            self.daily = summary
            error = nil
            hasLoaded = true
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { error = failure }
        }
        // 等结果的时候换了分组：这一组用不上了（换过去的那一组界面会再拉）。
        guard group == self.group else { return }
        switch groupedResult {
        case .success(let summary):
            self.grouped = summary ?? self.daily
            groupError = nil
        case .failure(let failure):
            self.grouped = nil
            if let failure = AgentsErrors.from(failure) { groupError = failure }
        }
    }

    /// 换时间范围（界面接着调 `load()`）：上一个范围的数据清掉，界面显示“加载中”，不把旧范围的总数当成新范围的。
    public func select(period: Period) {
        guard period != self.period else { return }
        self.period = period
        daily = nil
        grouped = nil
        hasLoaded = false
        error = nil
        groupError = nil
    }

    /// 换表格的分组（界面接着调 `load()`）。按天的直接用已经拉到的。
    public func select(group: UsageGroup) {
        guard group != self.group else { return }
        self.group = group
        grouped = group == .day ? daily : nil
        groupError = nil
    }

    private struct NameLists: Sendable {
        var instances: [Instance]?
        var credentials: [Credential]?
        var vendors: [VendorInfo]?
    }

    /// 表格要的名字：按实例分组要实例名，按 key 分组要 key 的备注和厂商名，按模型分组要厂商名。拉不到为 nil。
    nonisolated private static func loadNames(client: any ClientProtocol, group: UsageGroup) async -> NameLists {
        var out = NameLists()
        switch group {
        case .day:
            break
        case .instance:
            out.instances = (try? await client.instances()) ?? (try? client.cachedInstances())
        case .model:
            out.vendors = try? await client.vendors()
        case .credential:
            async let credentials = try? await client.credentials()
            async let vendors = try? await client.vendors()
            out.credentials = await credentials
            out.vendors = await vendors
        }
        return out
    }

    // MARK: 显示

    /// 这段时间的总计（还没拉到时全 0）。
    public var total: UsageBucket { daily?.total ?? UsageBucket(key: "total") }

    /// 这段时间一次请求都没有。
    public var isEmpty: Bool { hasLoaded && total.requests == 0 }

    /// 画图的点：每天一个（没用量的天是 0），旧的在前。
    public var dayPoints: [UsageDayPoint] {
        let byKey = Dictionary((daily?.buckets ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let calendar = self.calendar
        let (from, _) = range
        return (0..<period.days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: from) else { return nil }
            let key = Self.dayKey(date, calendar: calendar)
            return UsageDayPoint(date: date, key: key, bucket: byKey[key] ?? UsageBucket(key: key))
        }
    }

    /// 用量最多的一天（图上标出来）；一天都没有为 nil。
    public var peakDay: UsageDayPoint? {
        dayPoints.filter { $0.tokens > 0 }.max { $0.tokens < $1.tokens }
    }

    /// 表格的行：按天的新的在前（只列有用量的天），别的按 token 数从多到少。
    public func rows(language: DisplayLanguage = .current) -> [UsageRow] {
        guard let summary = group == .day ? daily : grouped else { return [] }
        let buckets: [UsageBucket]
        switch group {
        case .day: buckets = summary.buckets.filter { $0.requests > 0 }.sorted { $0.key > $1.key }
        default: buckets = summary.buckets.sorted { ($0.totalTokens, $1.key) > ($1.totalTokens, $0.key) }
        }
        return buckets.map { bucket in
            let (title, subtitle) = label(for: bucket.key, language: language)
            return UsageRow(key: bucket.key, title: title, subtitle: subtitle, bucket: bucket)
        }
    }

    /// 一行的名字和副标题。
    func label(for key: String, language: DisplayLanguage) -> (String, String?) {
        let zh = language == .chinese
        switch group {
        case .day:
            guard let date = Self.date(fromDayKey: key, calendar: calendar) else { return (key, nil) }
            let weekday = Self.weekday(date, calendar: calendar, language: language)
            return (Formatting.shortDate(date, now: now(), language: language, calendar: calendar), weekday)
        case .instance:
            if let instance = instances.first(where: { $0.id.rawValue == key }) { return (instance.name, nil) }
            return (zh ? "已删除的实例" : "Deleted instance", Self.shortID(key))
        case .model:
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return (key, nil) }
            return (parts[1], ModelsText.vendorName(parts[0], vendors: vendors, language: language))
        case .credential:
            if key.isEmpty { return (zh ? "平台提供的额度" : "Platform credit", nil) }
            if let credential = credentials.first(where: { $0.id.rawValue == key }) {
                let vendor = ModelsText.vendorName(credential.vendor, vendors: vendors, language: language)
                let name = ModelsText.credentialName(credential, vendors: vendors, language: language)
                return (name, (name == vendor ? "" : vendor + " · ") + credential.maskedKey)
            }
            return (zh ? "已删除的 key" : "Deleted key", Self.shortID(key))
        }
    }

    /// 表格每一行的跳转目标：实例 → 它的模型路由，key → key 详情；按天、按模型没有。
    public func destination(of row: UsageRow) -> AppRoute? {
        switch group {
        case .instance:
            guard let instance = instances.first(where: { $0.id.rawValue == row.key }) else { return nil }
            return .modelRoutes(instance.id)
        case .credential:
            guard let credential = credentials.first(where: { $0.id.rawValue == row.key }) else { return nil }
            return .credential(credential.id)
        case .day, .model:
            return nil
        }
    }

    // MARK: 日期

    /// “2026-10-22”（和服务端按天分组的键一样）。
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(Formatting.pad2(c.month ?? 1))-\(Formatting.pad2(c.day ?? 1))"
    }

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func weekday(_ date: Date, calendar: Calendar, language: DisplayLanguage) -> String {
        // Calendar 的 weekday：周日 = 1、周一 = 2……换成周一 = 0。
        let index = (calendar.component(.weekday, from: date) + 5) % 7
        let zh = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let en = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return language == .chinese ? zh[index] : en[index]
    }

    /// id 的后 6 位（认不出名字时给个线索）。
    static func shortID(_ id: String) -> String {
        "…" + String(id.suffix(6))
    }
}

extension UsageGroup {
    /// 分组的名字（分段控件上）。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .day: return zh ? "按天" : "By day"
        case .instance: return zh ? "按实例" : "By instance"
        case .model: return zh ? "按模型" : "By model"
        case .credential: return zh ? "按 key" : "By key"
        }
    }
}

/// 图上的一天。
public struct UsageDayPoint: Identifiable, Hashable, Sendable {
    /// 那天的零点（设备时区）。
    public var date: Date
    /// “2026-10-22”。
    public var key: String
    public var bucket: UsageBucket

    public var id: String { key }

    public init(date: Date, key: String, bucket: UsageBucket) {
        self.date = date
        self.key = key
        self.bucket = bucket
    }

    /// 柱子的高度：输入（含缓存）加输出。
    public var tokens: Int { bucket.totalTokens }

    /// 横轴上的“10/22”。
    public var axisLabel: String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return key }
        return "\(m)/\(d)"
    }

    /// 读屏念的：“10月22日，3.6 万 tokens，40 次请求”。
    public func accessibilityValue(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        var parts = [
            Formatting.tokens(tokens, language: language) + " tokens",
            zh ? "\(bucket.requests) 次请求" : "\(bucket.requests) requests",
        ]
        if bucket.failedRequests > 0 {
            parts.append(zh ? "失败 \(bucket.failedRequests) 次" : "\(bucket.failedRequests) failed")
        }
        return parts.joined(separator: zh ? "，" : ", ")
    }
}

/// 表格的一行。
public struct UsageRow: Identifiable, Hashable, Sendable {
    /// 分组的键（日期、实例 id、`厂商/模型`、key 的 id）。
    public var key: String
    public var title: String
    public var subtitle: String?
    public var bucket: UsageBucket

    public var id: String { key }

    public init(key: String, title: String, subtitle: String?, bucket: UsageBucket) {
        self.key = key
        self.title = title
        self.subtitle = subtitle?.isEmpty == true ? nil : subtitle
        self.bucket = bucket
    }

    /// 右边的大数字：token 数。
    public func tokens(_ language: DisplayLanguage = .current) -> String {
        Formatting.tokens(bucket.totalTokens, language: language)
    }

    /// 下面一行：“40 次请求 · 失败 3 · 估算 2”。
    public func detail(_ language: DisplayLanguage = .current) -> String {
        UsageText.requestsLine(bucket, language: language)
    }

    /// 读屏念的一句话。
    public func accessibilityLabel(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        var parts = [title]
        if let subtitle { parts.append(subtitle) }
        parts.append(tokens(language) + " tokens")
        parts.append(detail(language))
        return parts.joined(separator: zh ? "，" : ", ")
    }
}

/// 用量的文案。
public enum UsageText {
    /// “40 次请求 · 失败 3 · 估算 2”（没有失败、估算的不写）。
    public static func requestsLine(_ bucket: UsageBucket, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        var parts = [
            zh ? "\(Formatting.grouped(bucket.requests)) 次请求" : "\(Formatting.grouped(bucket.requests)) requests"
        ]
        if bucket.failedRequests > 0 {
            parts.append(zh ? "失败 \(bucket.failedRequests)" : "\(bucket.failedRequests) failed")
        }
        if bucket.estimatedRequests > 0 {
            parts.append(zh ? "估算 \(bucket.estimatedRequests)" : "\(bucket.estimatedRequests) estimated")
        }
        return parts.joined(separator: " · ")
    }

    /// 估算、失败是什么意思（表格下面的说明）。
    public static func footnote(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "“估算”是上游没返回用量、按内容长度估的请求；“失败”是没拿到完整回复的请求（出错、被取消、超时）。token 数含缓存读写。"
            : "“Estimated” requests had no usage from the vendor, so they were estimated from content length. “Failed” "
                + "requests didn't get a complete reply (errors, cancellations, timeouts). Token counts include cache "
                + "reads and writes."
    }

    /// 总计卡片里的各项（名字、数值）。
    public static func totalItems(_ total: UsageBucket, language: DisplayLanguage = .current) -> [(String, String)] {
        let zh = language == .chinese
        return [
            (zh ? "输入" : "Input", Formatting.tokens(total.inputTokens, language: language)),
            (zh ? "输出" : "Output", Formatting.tokens(total.outputTokens, language: language)),
            (
                zh ? "缓存读写" : "Cache",
                Formatting.tokens(total.cacheReadTokens + total.cacheWriteTokens, language: language)
            ),
            (zh ? "计费" : "Billed", Formatting.tokens(total.chargedTokens, language: language)),
            (zh ? "请求" : "Requests", Formatting.grouped(total.requests)),
            (zh ? "失败" : "Failed", Formatting.grouped(total.failedRequests)),
        ]
    }
}
