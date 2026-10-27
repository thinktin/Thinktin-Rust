import Foundation
import Testing

@testable import ThinktinKit

// 用量看板：时间范围、按天补 0、四种分组的表格、名字、总计。

@MainActor
@Suite("用量看板")
struct UsageModelTests {
    /// 固定的三天用量（北京时间 2026-10-22 是周四）。
    static let buckets = [
        UsageBucket(
            key: "2026-10-17", requests: 10, inputTokens: 1_000, cacheReadTokens: 500, outputTokens: 200,
            chargedTokens: 1_500),
        UsageBucket(
            key: "2026-10-20", requests: 40, inputTokens: 30_000, cacheWriteTokens: 2_000, outputTokens: 4_000,
            chargedTokens: 34_000, estimatedRequests: 2, failedRequests: 3),
        UsageBucket(key: "2026-10-22", requests: 5, inputTokens: 800, outputTokens: 100, chargedTokens: 900),
    ]

    private func make(
        period: UsageModel.Period = .week, group: UsageGroup = .day, _ edit: (inout MockState) -> Void = { _ in }
    ) -> (MockClient, UsageModel) {
        let mock = ModelsFixture.mock { state in
            state.dailyUsage = Self.buckets
            edit(&state)
        }
        let model = UsageModel(
            client: mock, period: period, group: group, timeZone: Fixture.shanghai, now: { Fixture.now })
        return (mock, model)
    }

    @Test("时间范围：含今天往前数，从零点开始")
    func range() {
        let (_, week) = make()
        #expect(week.range.from == Fixture.date(2026, 10, 16))
        #expect(week.range.to == Fixture.now)
        let (_, quarter) = make(period: .quarter)
        #expect(quarter.range.from == Fixture.date(2026, 7, 25))
        #expect(UsageModel.Period.month.title(.chinese) == "30 天")
        #expect(UsageModel.Period.week.title(.english) == "7 days")
    }

    @Test("按天：没用量的天补 0，旧的在前；总计")
    func dailyPoints() async throws {
        let (_, model) = make()
        await model.load()
        #expect(model.hasLoaded && model.error == nil && !model.isEmpty)
        let points = model.dayPoints
        #expect(
            points.map(\.key) == [
                "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22",
            ])
        #expect(points.map(\.tokens) == [0, 1_700, 0, 0, 36_000, 0, 900])
        #expect(points[1].axisLabel == "10/17")
        #expect(points[1].date == Fixture.date(2026, 10, 17))
        #expect(model.peakDay?.key == "2026-10-20")
        #expect(points[4].accessibilityValue(.chinese) == "3.6 万 token，40 次请求，失败 3 次")
        #expect(model.total.requests == 55)
        #expect(model.total.totalTokens == 38_600)
        #expect(model.total.failedRequests == 3)

        let items = UsageText.totalItems(model.total, language: .chinese)
        #expect(items.map(\.0) == ["输入", "输出", "缓存读写", "计费", "请求", "失败"])
        #expect(items[0].1 == "3.2 万")
        #expect(items[4].1 == "55")
    }

    @Test("按天的表格：只列有用量的天，新的在前，标出失败和估算")
    func dailyRows() async {
        let (_, model) = make()
        await model.load()
        let rows = model.rows(language: .chinese)
        #expect(rows.map(\.key) == ["2026-10-22", "2026-10-20", "2026-10-17"])
        #expect(rows[0].title == "10月22日")
        #expect(rows[0].subtitle == "周四")
        #expect(rows[1].detail(.chinese) == "40 次请求 · 失败 3 · 估算 2")
        #expect(rows[1].tokens(.chinese) == "3.6 万")
        #expect(rows[2].detail(.english) == "10 requests")
        #expect(rows[1].accessibilityLabel(.english).contains("36K tokens"))
        #expect(model.destination(of: rows[0]) == nil)
    }

    @Test("按实例：实例名，用量多的在前，点开去它的模型路由")
    func byInstance() async throws {
        let (_, model) = make()
        await model.load()
        model.select(group: .instance)
        #expect(model.grouped == nil)
        await model.load()
        #expect(model.groupError == nil)
        let rows = model.rows(language: .chinese)
        #expect(rows.map(\.title) == ["写作助手", "代码审查"])
        #expect(model.destination(of: rows[0]) == .modelRoutes(DemoData.writerID))
        let (title, subtitle) = model.label(for: "0192f3a0-0000-7000-8000-0000000009ff", language: .chinese)
        #expect(title == "已删除的实例")
        #expect(subtitle == "…0009ff")
        #expect(UsageGroup.instance.title(.chinese) == "按实例")
    }

    @Test("按模型：模型名和厂商")
    func byModel() async {
        let (_, model) = make(group: .model)
        await model.load()
        let rows = model.rows(language: .chinese)
        #expect(rows.map(\.title) == ["claude-sonnet-5-5", "deepseek-v4-pro"])
        #expect(rows.map(\.subtitle) == ["Anthropic (Claude)", "DeepSeek"])
        #expect(model.destination(of: rows[0]) == nil)
    }

    @Test("按 key：备注、厂商和后 4 位，点开去 key 详情；没有 key 的是平台额度")
    func byCredential() async {
        let (_, model) = make(group: .credential)
        await model.load()
        let rows = model.rows(language: .chinese)
        #expect(rows.map(\.title) == ["Claude 主力", "DeepSeek"])
        #expect(rows.map(\.subtitle) == ["Anthropic (Claude) · ••••Q7mA", "••••x9Lk"])
        #expect(model.destination(of: rows[0]) == .credential(DemoData.claudeCredentialID))
        #expect(model.label(for: "", language: .english).0 == "Platform credit")
        #expect(model.label(for: "gone-key-123456", language: .chinese).0 == "已删除的 key")
        #expect(UsageGroup.credential.title(.english) == "By key")
    }

    @Test("切回按天直接用已经拉到的；换时间范围")
    func switching() async {
        let (_, model) = make(group: .model)
        await model.load()
        model.select(group: .day)
        #expect(model.grouped == model.daily)
        model.select(period: .quarter)
        #expect(model.period == .quarter)
        await model.load()
        #expect(model.dayPoints.count == 90)
    }

    @Test("换时间范围：清掉上一个范围的数据（不把 7 天的总数显示成 30 天的）；旧范围的结果晚回来也不用")
    func periodSwitchClears() async {
        let mock = ModelsFixture.mock(latency: 0.05) { $0.dailyUsage = Self.buckets }
        let model = UsageModel(client: mock, period: .week, timeZone: Fixture.shanghai, now: { Fixture.now })
        await model.load()
        #expect(model.hasLoaded && model.total.requests == 55)
        // 再拉一次 7 天的，还在路上时换成 30 天。
        let stale = Task { await model.load() }
        while !model.isLoading { await Task.yield() }
        model.select(period: .month)
        #expect(!model.hasLoaded && model.daily == nil && model.grouped == nil)
        #expect(model.total.requests == 0 && !model.isEmpty)
        await stale.value
        #expect(model.daily == nil && !model.hasLoaded && !model.isLoading)
        await model.load()
        #expect(model.hasLoaded && model.dayPoints.count == 30 && model.total.requests == 55)
    }

    @Test("等结果的时候换了分组：旧分组的表格不用，按天的照常")
    func groupSwitchRace() async {
        let mock = ModelsFixture.mock(latency: 0.05) { $0.dailyUsage = Self.buckets }
        let model = UsageModel(
            client: mock, period: .week, group: .instance, timeZone: Fixture.shanghai, now: { Fixture.now })
        let pending = Task { await model.load() }
        while !model.isLoading { await Task.yield() }
        model.select(group: .model)
        await pending.value
        #expect(model.grouped == nil)
        #expect(model.daily != nil && model.hasLoaded)
        await model.load()
        #expect(model.rows(language: .chinese).map(\.title) == ["claude-sonnet-5-5", "deepseek-v4-pro"])
    }

    @Test("没有用量：空状态")
    func empty() async {
        let (_, model) = make { $0.dailyUsage = [] }
        await model.load()
        #expect(model.isEmpty)
        #expect(model.dayPoints.allSatisfy { $0.tokens == 0 })
        #expect(model.rows().isEmpty)
        #expect(model.peakDay == nil)
    }

    @Test("拉不到：显示错误，联网后再拉")
    func failure() async {
        let (mock, model) = make()
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.error == .network(message: "offline"))
        #expect(!model.hasLoaded && !model.isEmpty)
        await model.load()
        #expect(model.error == nil && model.hasLoaded)
    }

    @Test("表格那一组拉不到：图和总计照常")
    func groupFailure() async {
        let (mock, model) = make(group: .model)
        await model.load()
        model.select(group: .credential)
        // 按天、按 key、key 列表、厂商表四个调用并发：都失败。
        for _ in 0..<4 {
            mock.failNext(with: .api(status: 503, code: .unavailable, message: "busy", retryAfterSecs: nil))
        }
        await model.load()
        #expect(model.groupError?.apiCode == .unavailable)
        #expect(model.error?.apiCode == .unavailable)
        #expect(model.rows().isEmpty)
        // 之前拉到的按天数据还在。
        #expect(model.total.requests == 55)
    }
}
