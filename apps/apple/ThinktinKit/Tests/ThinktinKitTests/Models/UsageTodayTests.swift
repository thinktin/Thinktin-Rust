import Foundation
import Testing

@testable import ThinktinKit

// “今天用了多少”（改版规范 4.9.1、4.9.3）：东八区切天、按 key 的每日上限进度、设置根页那一行的值。

@Suite("今天的用量")
struct UsageTodayTests {
    private func credential(_ id: String, limit: Int?, disabled: Bool = false) -> Credential {
        Credential(
            id: CredentialID(id), vendor: "anthropic", label: "key \(id)", last4: "abcd", dailyTokenLimit: limit,
            isDisabled: disabled, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func bucket(_ key: String, tokens: Int) -> UsageBucket {
        UsageBucket(
            key: key, requests: 1, inputTokens: tokens, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0,
            chargedTokens: tokens, estimatedRequests: 0, failedRequests: 0)
    }

    @Test("今天从东八区的零点算，不看手机的时区")
    func startOfDay() {
        // 2026-11-05 01:30 北京时间 = 2026-11-04 17:30 UTC。
        let now = Date(timeIntervalSince1970: 1_793_813_400)
        let start = UsageToday.startOfDay(now)
        // 北京时间 11-05 零点 = 11-04 16:00 UTC。
        #expect(start == Date(timeIntervalSince1970: 1_793_808_000))
        #expect(UsageToday.timeZone.secondsFromGMT(for: now) == 8 * 3600)
    }

    @Test("只列设了上限的 key；没用过的是 0；超了算满")
    func gauges() {
        let credentials = [
            credential("a", limit: 1_000_000), credential("b", limit: nil), credential("c", limit: 100, disabled: true),
            credential("d", limit: 0),
        ]
        let usage = UsageSummary(
            buckets: [bucket("a", tokens: 180_000), bucket("c", tokens: 250)], total: bucket("total", tokens: 180_250))
        let gauges = UsageToday.gauges(credentials: credentials, usage: usage)
        #expect(gauges.map(\.credentialID.rawValue) == ["a", "c"])
        #expect(gauges[0].fraction == 0.18)
        #expect(gauges[0].percentText == "18%")
        #expect(!gauges[0].isExhausted)
        #expect(gauges[0].amountText(.chinese) == "18 万 / 100 万")
        #expect(gauges[0].amountText(.english) == "180K / 1M")
        #expect(gauges[0].todayAmountText(.chinese) == "今天 18 万 / 100 万")
        #expect(gauges[0].todayAmountText(.english) == "Today 180K / 1M")
        #expect(gauges[1].fraction == 1)
        #expect(gauges[1].isExhausted)
        #expect(gauges[1].isDisabled)
        #expect(gauges[1].percentText == "100%")
        #expect(UsageToday.gauges(credentials: credentials, usage: nil).map(\.used) == [0, 0])
    }

    @Test("百分比：用过但不到 1% 写 <1%，没用过 0%")
    func percent() {
        #expect(UsageGauge(credentialID: "x", title: "x", used: 5, limit: 1_000_000).percentText == "<1%")
        #expect(UsageGauge(credentialID: "x", title: "x", used: 0, limit: 1_000_000).percentText == "0%")
        #expect(UsageGauge(credentialID: "x", title: "x", used: 999, limit: 1000).percentText == "99%")
        #expect(
            UsageGauge(credentialID: "x", title: "x", used: 10, limit: 100).accessibilityValue(.chinese).contains("10%")
        )
    }

    @Test("设置根页那一行：没拉到不显示，拉到了写今天的总数")
    func rowValue() {
        #expect(UsageToday.rowValue(nil, language: .chinese) == nil)
        let usage = UsageSummary(buckets: [], total: bucket("total", tokens: 12_000))
        #expect(UsageToday.rowValue(usage, language: .chinese) == "今天 1.2 万")
        #expect(UsageToday.rowValue(usage, language: .english) == "Today 12K")
    }

    @Test("演示数据：“今天”只算今天那一天，不是整周的总数（进度条不会一打开就是满的）")
    func demoTodayOnly() async throws {
        let client = MockClient(state: DemoData.state(), stepDelay: 0, autoReply: false)
        let now = Date()
        let week = try await client.usage(group: .credential, from: nil, to: nil, timeZone: nil)
        let today = try await UsageToday.load(client: client, now: now)
        #expect(today.total.totalTokens > 0)
        #expect(today.total.totalTokens < week.total.totalTokens)
        let credentials = try await client.credentials()
        let gauge = try #require(UsageToday.gauges(credentials: credentials, usage: today).first)
        #expect(!gauge.isExhausted && gauge.fraction > 0)
    }
}
