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
        let weekly = try #require(runs.results.first { $0.route == .run(DemoData.weeklyRunID) })
        #expect(!weekly.isAIGenerated, "用户自己写的任务")
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
    }
}
