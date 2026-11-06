import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("搜索")
struct SearchModelTests {
    private func model() -> SearchModel {
        SearchModel(client: MockClient(state: DemoData.state(), stepDelay: 0, autoReply: false))
    }

    @Test("关键词：按空白拆开，每个都要出现，不分大小写、全角半角")
    func matching() {
        #expect(SearchModel.terms("  周报  要点 ") == ["周报", "要点"])
        #expect(SearchModel.matches(["github"], in: "每日 GitHub 通知汇总"))
        #expect(SearchModel.matches(["ｇｉｔｈｕｂ"], in: "GitHub"))
        #expect(!SearchModel.matches(["周报", "日报"], in: "这周的周报"))
        #expect(SearchModel.rank(["周报"], title: "周报", body: "") == 0)
        #expect(SearchModel.rank(["周报", "三组"], title: "周报", body: "分了三组") == 1)
        #expect(SearchModel.rank(["没有"], title: "周报", body: "") == nil)
        let long = String(repeating: "前", count: 50) + "关键" + String(repeating: "后", count: 50)
        let snippet = SearchModel.snippet(long, terms: ["关键"])!
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.contains("关键"))
        #expect(SearchModel.firstLine("第一行\n第二行") == "第一行")
    }

    @Test("搜缓存：运行的任务和摘要、收件箱、实例；空的不出结果")
    func cache() throws {
        let model = model()
        model.loadCache()
        #expect(!model.isSearching)
        model.query = "周报"
        let runs = try #require(model.groups.first { $0.kind == .run })
        let weekly = try #require(
            runs.results.first { $0.route == .run(DemoData.weeklyRunID) && $0.direction == .sent })
        #expect(!weekly.isAIGenerated, "用户自己写的任务")
        #expect(weekly.instanceID == DemoData.writerID)
        #expect(weekly.title == "写作助手", "消息的标题是 Botin 名，界面拼成“你发给 X”")
        // 摘要里也有“周报”：同一次运行另有一条“写作助手 发给你”，带 AI 标识。
        let reply = try #require(
            runs.results.first { $0.route == .run(DemoData.weeklyRunID) && $0.direction == .received })
        #expect(reply.isAIGenerated)
        #expect(reply.id != weekly.id)
        // 都是标题匹配：新的在前。
        let dates = runs.results.compactMap(\.date)
        #expect(dates == dates.sorted(by: >))

        // 只在摘要里出现的：片段来自摘要，带 AI 标识。
        model.query = "三组"
        let bySummary = try #require(model.groups.first { $0.kind == .run }?.results.first)
        #expect(bySummary.snippet?.contains("三组") == true)
        #expect(bySummary.isAIGenerated)

        model.query = "代码审查"
        #expect(model.groups.map(\.kind).contains(.instance))
        #expect(model.groups.first { $0.kind == .instance }?.results.first?.route == .conversation(DemoData.reviewerID))
        let inbox = try #require(model.groups.first { $0.kind == .inbox })
        #expect(inbox.results.count == 3)

        model.query = "根本不存在的词"
        #expect(model.isEmpty)
        model.query = " "
        #expect(model.groups.isEmpty)
        #expect(!model.isSearching)
    }

    @Test("联网时另拉计划和产出物；标题匹配的排前面")
    func online() async throws {
        let model = model()
        model.loadCache()
        model.query = "依赖升级"
        #expect(model.groups.first { $0.kind == .plan } == nil)
        await model.loadOnline()
        #expect(model.hasOnlineSources)
        let plan = try #require(model.groups.first { $0.kind == .plan }?.results.first)
        #expect(plan.route == .plan(DemoData.agentPlanID))
        #expect(plan.isAIGenerated, "agent 建的计划")

        model.query = "周报要点"
        let artifact = try #require(model.groups.first { $0.kind == .artifact }?.results.first)
        #expect(artifact.route == .artifact(DemoData.weeklyArtifactID, runID: DemoData.weeklyRunID))
        #expect(artifact.isAIGenerated)
    }

    @Test("离线：计划和产出物拉不到，只搜缓存")
    func offline() async {
        let mock = MockClient(state: DemoData.state(), stepDelay: 0, autoReply: false)
        let model = SearchModel(client: mock)
        model.loadCache()
        mock.failNext(with: .network(message: "offline"))
        await model.loadOnline()
        #expect(!model.hasOnlineSources)
        model.query = "周报"
        #expect(!model.isEmpty)
    }

    @Test("筛选胶囊：只留这一类、上限放宽；没输入时“全部”和“Botin”列出 Botin，别的类为空")
    func filters() throws {
        let model = model()
        model.loadCache()
        #expect(SearchModel.filters == [nil, .run, .instance, .inbox, .artifact, .plan])
        // 没输入：列出 Botin，最近活动的在前。
        #expect(!model.suggestions.isEmpty)
        #expect(model.suggestions.allSatisfy { $0.kind == .instance && $0.instanceID != nil })
        let dates = model.suggestions.compactMap(\.date)
        #expect(dates == dates.sorted(by: >))
        model.filter = .run
        #expect(model.suggestions.isEmpty)
        model.filter = .instance
        #expect(!model.suggestions.isEmpty)

        model.filter = .inbox
        model.query = "代码审查"
        #expect(model.groups.map(\.kind) == [.inbox])
        #expect(model.suggestions.isEmpty)
        model.filter = nil
        #expect(model.groups.map(\.kind).contains(.instance))
        #expect(SearchText.filterTitle(nil, language: .chinese) == "全部")
        #expect(SearchText.filterTitle(.run, language: .chinese) == "消息")
        #expect(SearchText.searchKind(.run, language: .chinese) == "搜索消息")
        // 占位字是一个词，在首页底部的胶囊里不截断（参考 01、78）；能搜什么由筛选胶囊说。
        #expect(SearchText.prompt(.chinese) == "搜索")
        #expect(SearchText.prompt(.english) == "Search")
    }

    @Test("消息的标题和右边的时间")
    func messageTexts() {
        #expect(SearchText.messageTitle(.sent, botin: "写作助手", language: .chinese) == "你发给 写作助手")
        #expect(SearchText.messageTitle(.received, botin: "写作助手", language: .chinese) == "写作助手 发给你")
        #expect(SearchText.messageTitle(.received, botin: "Writer", language: .english) == "Writer to you")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-11-05（星期四）15:00，上海。
        let now = Date(timeIntervalSince1970: 1_793_862_000)
        let hour: TimeInterval = 3600
        #expect(
            SearchText.date(now.addingTimeInterval(-hour), now: now, language: .chinese, calendar: calendar) == "14:00")
        #expect(
            SearchText.date(now.addingTimeInterval(-24 * hour), now: now, language: .chinese, calendar: calendar)
                == "昨天")
        #expect(
            SearchText.date(now.addingTimeInterval(-48 * hour), now: now, language: .chinese, calendar: calendar)
                == "星期二")
        #expect(
            SearchText.date(now.addingTimeInterval(-10 * 24 * hour), now: now, language: .chinese, calendar: calendar)
                == "10月26日")
        #expect(SearchText.kindLabel(.instance, language: .chinese) == "Botin")
    }

    @Test("每组最多显示 20 条，记下一共几条")
    func limit() {
        var state = DemoData.state()
        state.runs += (0..<30).map { i in
            Run(
                id: RunID(rawValue: "r\(i)"), instanceID: DemoData.writerID, prompt: "批量任务 \(i)",
                createdAt: Date().addingTimeInterval(Double(-i)))
        }
        let model = SearchModel(client: MockClient(state: state, stepDelay: 0, autoReply: false))
        model.loadCache()
        model.query = "批量任务"
        let runs = model.groups.first { $0.kind == .run }
        #expect(runs?.results.count == SearchModel.groupLimit)
        #expect(runs?.total == 30)
        #expect(runs?.results.first?.key == "r0", "新的在前")
        // 只看消息时放宽到 100 条。
        model.filter = .run
        #expect(model.groups.first?.results.count == 30)
    }
}
