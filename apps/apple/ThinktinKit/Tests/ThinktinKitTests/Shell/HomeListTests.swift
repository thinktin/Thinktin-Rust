import Foundation
import Testing

@testable import ThinktinKit

// 首页的实例列表（docs/ios-ui-redesign.md 4.2.1 第 0 轮的最小版）：排序、预览、时间。

@Suite("首页的实例列表")
struct HomeListTests {
    private static func instance(
        _ id: InstanceID, name: String, state: InstanceState = .running, lastActive: Date
    ) -> Instance {
        Instance(
            id: id, agentID: "claude", agentVersion: "1.0.0", harness: "claude-code", name: name, state: state,
            createdAt: Fixture.now.addingTimeInterval(-86_400), lastActiveAt: lastActive)
    }

    private static func run(_ id: RunID, _ instanceID: InstanceID, state: RunState, at: Date) -> Run {
        var run = Fixture.run(id, state: state, createdAt: at)
        run.instanceID = instanceID
        return run
    }

    @Test("最后活动新的在前；进行中的运行比实例的活跃时间新时按运行算；一样新的按名字、再按 id")
    func ordering() {
        let now = Fixture.now
        let instances = [
            Self.instance("a", name: "写作助手", lastActive: now.addingTimeInterval(-3_600)),
            Self.instance("b", name: "代码审查", lastActive: now.addingTimeInterval(-60)),
            Self.instance("c", name: "日报", lastActive: now.addingTimeInterval(-7_200)),
            Self.instance("e", name: "Beta", lastActive: now.addingTimeInterval(-86_400)),
            Self.instance("d", name: "Beta", lastActive: now.addingTimeInterval(-86_400)),
            Self.instance("f", name: "Alpha", lastActive: now.addingTimeInterval(-86_400)),
        ]
        // 日报的缓存比它刚开始的运行旧：按运行的时间排到最前面。
        let activity = InstanceActivity.byInstance([Self.run("r1", "c", state: .running, at: now)])
        let rows = HomeList.rows(instances: instances, activity: activity)
        #expect(rows.map(\.id) == ["c", "b", "a", "f", "d", "e"].map { InstanceID(rawValue: $0) })
        #expect(rows[0].lastActivityAt == now)
        #expect(rows[1].lastActivityAt == now.addingTimeInterval(-60))
        // 输入的顺序不影响结果（刷新时行不乱跳）。
        #expect(HomeList.rows(instances: instances.reversed(), activity: activity) == rows)
    }

    @Test("已删除的实例不显示；没有实例时是空的")
    func deletedAndEmpty() {
        let now = Fixture.now
        let rows = HomeList.rows(
            instances: [
                Self.instance("a", name: "写作助手", lastActive: now),
                Self.instance("b", name: "已删", state: .deleted, lastActive: now),
            ], activity: [:])
        #expect(rows.map(\.id) == ["a"])
        #expect(HomeList.rows(instances: [], activity: [:]).isEmpty)
    }

    @Test("预览：在等你处理的优先，其次进行中的运行，再没有就是实例的状态")
    func preview() {
        let now = Fixture.now
        let waiting = InstanceActivity(runs: [
            Self.run("r1", "a", state: .running, at: now.addingTimeInterval(-30)),
            Self.run("r2", "a", state: .waitingQuota, at: now.addingTimeInterval(-120)),
            Self.run("r3", "a", state: .waitingApproval, at: now.addingTimeInterval(-60)),
        ])
        #expect(waiting.latestWaitingState == .waitingApproval)
        #expect(HomeRowPreview(state: .running, activity: waiting) == .waiting(count: 2, state: .waitingApproval))

        let active = InstanceActivity(runs: [
            Self.run("r4", "a", state: .queued, at: now.addingTimeInterval(-10)),
            Self.run("r5", "a", state: .running, at: now.addingTimeInterval(-90)),
            Self.run("r6", "a", state: .succeeded, at: now),
        ])
        #expect(active.latestWaitingState == nil)
        #expect(HomeRowPreview(state: .running, activity: active) == .active(count: 2, state: .queued))

        #expect(HomeRowPreview(state: .paused, activity: .none) == .idle(.paused))
        #expect(HomeRowPreview(state: .provisioning, activity: .none) == .idle(.provisioning))
        // 只知道有几个在等、不知道在等什么（老的缓存）：按等审批显示。
        #expect(
            HomeRowPreview(state: .running, activity: InstanceActivity(activeRuns: 1, waitingRuns: 1))
                == .waiting(count: 1, state: .waitingApproval))

        let row = HomeRow(instance: Self.instance("a", name: "写作助手", lastActive: now), activity: waiting)
        #expect(row.needsAttention)
        #expect(!HomeRow(instance: Self.instance("a", name: "写作助手", lastActive: now), activity: active).needsAttention)
    }

    @Test("右边的时间：今天的显示几点几分，更早的显示日期，往年的带年份")
    func timestamp() {
        let now = Fixture.now
        let calendar = Fixture.calendar
        #expect(HomeList.timestamp(Fixture.date(2026, 10, 22, 9, 5), now: now, calendar: calendar) == "09:05")
        #expect(HomeList.timestamp(Fixture.date(2026, 10, 22, 0, 0), now: now, calendar: calendar) == "00:00")
        #expect(
            HomeList.timestamp(Fixture.date(2026, 10, 21, 23, 59), now: now, language: .chinese, calendar: calendar)
                == "10月21日")
        #expect(
            HomeList.timestamp(Fixture.date(2026, 10, 21, 23, 59), now: now, language: .english, calendar: calendar)
                == "Oct 21")
        #expect(
            HomeList.timestamp(Fixture.date(2025, 12, 31, 8, 0), now: now, language: .chinese, calendar: calendar)
                == "2025年12月31日")
    }

    @Test("空状态的文案：叫 Botin，按钮是“新建 Botin”")
    func emptyText() {
        #expect(HomeText.emptyTitle(.chinese) == "还没有 Botin")
        #expect(
            HomeText.emptyMessage(.chinese) == "Botin 是替你干活的助手。起个名字、选一个引擎，它就能帮你写东西、查资料、跑任务。")
        #expect(AppRoute.adopt(agentID: nil).title(.chinese) == "新建 Botin")
        #expect(HomeText.emptyTitle(.english) == "No Botins yet")
        #expect(HomeText.emptyMessage(.english).hasPrefix("A Botin is an assistant that works for you."))
        #expect(AppRoute.adopt(agentID: nil).title(.english) == "New Botin")
        for language in [DisplayLanguage.chinese, .english] {
            #expect(!HomeText.offlineEmptyMessage(language).isEmpty)
            #expect(!HomeText.offlineEmptyMessage(language).contains("实例"))
        }
    }

    @Test("演示数据：首页的行和实例列表一一对应，按最后活动排")
    @MainActor
    func demoRows() async {
        let model = AppModel(client: makeShellMock(), defaults: nil)
        await model.start()
        let rows = model.homeRows
        #expect(Set(rows.map(\.id)) == Set(model.instances.map(\.id)))
        #expect(!rows.isEmpty)
        #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.lastActivityAt >= $1.lastActivityAt })
        for row in rows {
            #expect(row.activity == model.activity(for: row.id))
        }
    }

    @Test("空着时显示什么：转圈、离线没缓存、还没有 Botin；有行或刷新失败时不显示")
    func placeholder() {
        typealias P = HomePlaceholder
        func check(_ empty: Bool, _ loaded: Bool, _ offline: Bool, _ error: Bool) -> P? {
            HomeList.placeholder(isEmpty: empty, hasLoaded: loaded, isOffline: offline, hasError: error)
        }
        #expect(check(true, false, false, false) == .loading)
        #expect(check(true, true, false, false) == .noBotins)
        // 离线：不管拿没拿到过都不引导新建（表单离线不能提交）。
        #expect(check(true, false, true, false) == .offlineWithoutCache)
        #expect(check(true, true, true, false) == .offlineWithoutCache)
        #expect(check(true, false, true, true) == .offlineWithoutCache)
        // 刷新失败：横幅说了怎么回事，列表空着。
        #expect(check(true, false, false, true) == nil)
        #expect(check(true, true, false, true) == nil)
        for loaded in [false, true] {
            for offline in [false, true] {
                for error in [false, true] { #expect(check(false, loaded, offline, error) == nil) }
            }
        }
    }

    @Test("第一次登录（新账号）：拉到了、联网，首页是“还没有 Botin”；有了缓存的账号离线时不是")
    @MainActor
    func newAccountPlaceholder() async {
        let empty = MockClient(state: DemoData.newAccountState(), stepDelay: 0, autoReply: false)
        let model = AppModel(client: empty, defaults: nil)
        #expect(model.homePlaceholder == .loading)
        await model.start()
        #expect(model.instances.isEmpty && model.hasLoadedInstances)
        #expect(model.homePlaceholder == .noBotins)
        // 网络断了（刷新的每个请求都失败）：只说这台设备上没有。
        for _ in 0..<6 { empty.failNext(with: .network(message: "offline")) }
        await model.refresh()
        #expect(await eventually { model.isOffline })
        #expect(model.homePlaceholder == .offlineWithoutCache)

        let demo = AppModel(client: makeShellMock(), defaults: nil)
        await demo.start()
        #expect(demo.homePlaceholder == nil)
    }

    @Test("新账号的演示数据：没有 Botin 和它们的东西，引擎目录、团队模板、这台设备照旧")
    func newAccountState() {
        let state = DemoData.newAccountState()
        #expect(state.session != nil)
        #expect(state.instances.isEmpty && state.runs.isEmpty && state.events.isEmpty && state.routes.isEmpty)
        #expect(state.plans.isEmpty && state.teams.isEmpty && state.approvals.isEmpty && state.inbox.isEmpty)
        #expect(state.artifacts.isEmpty && state.vaultRequests.isEmpty && state.credentials.isEmpty)
        #expect(state.agents == DemoData.agents)
        #expect(!state.teamTemplates.isEmpty && !state.devices.isEmpty && !state.vendors.isEmpty)
    }

    @Test("新建了 Botin：马上进实例列表、关掉表单、从首页压栈进它的对话，再刷新")
    @MainActor
    func openCreatedInstance() async throws {
        let mock = MockClient(state: DemoData.newAccountState(), stepDelay: 0, autoReply: false)
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        model.router.open(.adopt(agentID: nil))
        model.router.open(.agentCatalog)
        let instance = try await mock.adopt(agentID: DemoData.hermesAgentID, name: "资料员", harness: nil)
        await model.openCreatedInstance(instance)
        #expect(model.instances.map(\.id) == [instance.id])
        #expect(model.homePlaceholder == nil)
        #expect(model.router.sheet == nil && model.router.sheetPath.isEmpty)
        #expect(model.router.path == [.conversation(instance.id)])
        #expect(model.router.currentInstanceID == instance.id)
        // 已经在列表里（刷新先到了）也不会多出一行。
        await model.openCreatedInstance(instance)
        #expect(model.instances.count == 1)
        #expect(model.router.path == [.conversation(instance.id)])

        // 有别的 Botin 时，新的排在最前面（刚活跃）。
        let demo = AppModel(client: makeShellMock(), defaults: nil)
        await demo.start()
        demo.router.open(.conversation(DemoData.reviewerID))
        let fresh = try await demo.client.adopt(agentID: DemoData.codexAgentID, name: "校对", harness: nil)
        await demo.openCreatedInstance(fresh)
        #expect(demo.homeRows.first?.id == fresh.id)
        #expect(demo.router.path == [.conversation(fresh.id)])
    }
}
