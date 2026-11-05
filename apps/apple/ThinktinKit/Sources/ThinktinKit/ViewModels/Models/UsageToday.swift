import Foundation

/// “今天用了多少”（改版规范 4.9.1 设置根页“用量”那一行的值、4.9.3 用量页顶上的“今天”一组，参考 55 的进度条卡片）。
///
/// 模型网关的每日上限按东八区切天（docs/llm-gateway.md），所以“今天”从东八区的零点算，不用手机本地的零点；
/// 用量按 key 分组拉（`usage(group: .credential, from: 今天零点, timeZone: 东八区)`），每把设了每日上限的 key 一条进度。
public enum UsageToday {
    /// 模型网关切天用的时区。
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    /// 东八区今天的零点。
    public static func startOfDay(_ now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: now)
    }

    /// 拉今天按 key 分组的用量。
    public static func load(client: any ClientProtocol, now: Date) async throws -> UsageSummary {
        try await client.usage(group: .credential, from: startOfDay(now), to: now, timeZone: timeZone)
    }

    /// 设了每日上限的 key，每把一条（停用的也列：上限照样算）；按 key 的顺序。没有上限的不列。
    public static func gauges(credentials: [Credential], usage: UsageSummary?) -> [UsageGauge] {
        credentials.compactMap { credential in
            guard let limit = credential.dailyTokenLimit, limit > 0 else { return nil }
            let used = usage?.buckets.first { $0.key == credential.id.rawValue }?.totalTokens ?? 0
            return UsageGauge(
                credentialID: credential.id, title: credential.label, isDisabled: credential.isDisabled, used: used,
                limit: limit)
        }
    }

    /// 设置根页“用量”那一行右边的值：“今天 1.2 万”/“Today 12K”。没拉到为 nil（不显示）。
    public static func rowValue(_ usage: UsageSummary?, language: DisplayLanguage = .current) -> String? {
        guard let usage else { return nil }
        let tokens = Formatting.tokens(usage.total.totalTokens, language: language)
        return language == .chinese ? "今天 \(tokens)" : "Today \(tokens)"
    }

    /// “今天”那一组的标题和脚注。
    public static func sectionTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "今天" : "Today"
    }

    public static func sectionFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "每日上限按北京时间零点重新计算，用满后这把 key 当天停用。没设上限的 key 不在这里。"
            : "Daily limits reset at midnight Beijing time; a key that reaches its limit pauses for the rest of the day. "
                + "Keys without a limit aren't shown."
    }
}

/// 一把 key 今天用了多少（相对每日上限）。
public struct UsageGauge: Identifiable, Hashable, Sendable {
    public var credentialID: CredentialID
    public var title: String
    public var isDisabled: Bool
    public var used: Int
    public var limit: Int

    public var id: CredentialID { credentialID }

    public init(credentialID: CredentialID, title: String, isDisabled: Bool = false, used: Int, limit: Int) {
        self.credentialID = credentialID
        self.title = title
        self.isDisabled = isDisabled
        self.used = used
        self.limit = limit
    }

    /// 进度条的值，0...1（超了也是 1）。
    public var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(limit)))
    }

    /// 用满了。
    public var isExhausted: Bool { limit > 0 && used >= limit }

    /// 进度条下面的百分比：“18%”（不到 1% 但用过的写“<1%”）。
    public var percentText: String {
        if used > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded(.down)))%"
    }

    /// 右上角的“1.2 万 / 200 万”。
    public func amountText(_ language: DisplayLanguage = .current) -> String {
        Formatting.tokens(used, language: language) + " / " + Formatting.tokens(limit, language: language)
    }

    /// 读屏念的一句话。
    public func accessibilityValue(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "今天用了 \(amountText(language)) token，\(percentText)"
            : "\(amountText(language)) tokens used today, \(percentText)"
    }
}
