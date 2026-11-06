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
                for error in [false, true] {
                    #expect(check(false, loaded, offline, error) == nil)
                    // 有 Botin 但都隐藏了：离线、出错也这么说（隐藏是这台设备上的事）。
                    #expect(
                        HomeList.placeholder(
                            isEmpty: false, hasLoaded: loaded, isOffline: offline, hasError: error, isAllHidden: true)
                            == .allHidden)
                }
            }
        }
        // 一个 Botin 都没有时说不上“都隐藏了”。
        #expect(
            HomeList.placeholder(isEmpty: true, hasLoaded: true, isOffline: false, hasError: false, isAllHidden: true)
                == .noBotins)
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

    @Test("离线启动、没有缓存：网络回来时先成功的是别的调用也补拉实例列表，首页不会一直转圈")
    @MainActor
    func reconnectLoadsInstances() async throws {
        let offline = ClientError.network(message: "offline")
        let calls = [
            "me()", "instances()", "syncInbox(limit:)", "approvals()", "plans(instanceID:)",
            "listRuns(filter:limit:)", "deviceMessages()",
        ]
        let empty = MockClient(state: DemoData.newAccountState(), stepDelay: 0, autoReply: false)
        for call in calls { empty.failNext(call, with: offline) }
        let model = AppModel(client: empty, defaults: nil)
        await model.start()
        #expect(model.isOffline && !model.hasLoadedInstances)
        #expect(model.homePlaceholder == .offlineWithoutCache)
        // 网络回来了，先成功的是别的页面的调用（比如设置拉用户）。
        _ = try await model.client.me()
        #expect(await eventually { model.homePlaceholder == .noBotins })
        #expect(model.hasLoadedInstances && !model.isOffline)

        // 刷新到一半网络回来了：实例列表那一步失败，角标成功。
        let flaky = MockClient(state: DemoData.newAccountState(), stepDelay: 0, autoReply: false)
        flaky.failNext("me()", with: offline)
        flaky.failNext("instances()", with: offline)
        let flakyModel = AppModel(client: flaky, defaults: nil)
        await flakyModel.start()
        #expect(await eventually { flakyModel.homePlaceholder == .noBotins })
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
        // 从新任务的选择里点“新建 Botin”：表单叠成第二层；建好了两层都关掉。
        demo.router.present(.newTask)
        demo.router.open(.adopt(agentID: nil))
        #expect(demo.router.sheet == .newTask && demo.router.nestedSheet == .adopt(agentID: nil))
        let another = try await demo.client.adopt(agentID: DemoData.claudeAgentID, name: "主笔", harness: nil)
        await demo.openCreatedInstance(another)
        #expect(demo.router.sheet == nil && demo.router.nestedSheet == nil)
        #expect(demo.router.path == [.conversation(another.id)])
    }

    // MARK: 第 1 轮 A 线：置顶、隐藏、最后一条、长按菜单

    private static func message(_ runID: RunID, prompt: String, summary: String?, source: RunSource = .user, at: Date)
        -> Run
    {
        var run = Fixture.run(
            runID, prompt: prompt, state: summary == nil ? .failed : .succeeded, createdAt: at, source: source)
        run.summary = summary
        run.finishedAt = summary == nil ? nil : at.addingTimeInterval(30)
        return run
    }

    @Test("三部分：置顶的按置顶先后、不管活动；隐藏的不在首页；又置顶又隐藏按隐藏；没了的 Botin 不管")
    func content() {
        let now = Fixture.now
        let instances = [
            Self.instance("a", name: "写作助手", lastActive: now),
            Self.instance("b", name: "代码审查", lastActive: now.addingTimeInterval(-60)),
            Self.instance("c", name: "日报", lastActive: now.addingTimeInterval(-120)),
            Self.instance("d", name: "翻译", lastActive: now.addingTimeInterval(-180)),
        ]
        let content = HomeList.content(
            instances: instances, activity: [:], pinned: ["c", "gone", "b", "c", "d"], hidden: ["a", "d"])
        #expect(content.pinned.map(\.id) == ["c", "b"])
        #expect(content.rows.isEmpty)
        #expect(content.hidden.map(\.id) == ["a", "d"])
        #expect(content.visible.map(\.id) == ["c", "b"])
        #expect(!content.isAllHidden)

        let plain = HomeList.content(instances: instances, activity: [:])
        #expect(plain.pinned.isEmpty && plain.hidden.isEmpty)
        #expect(plain.rows == HomeList.rows(instances: instances, activity: [:]))

        let allHidden = HomeList.content(instances: instances, activity: [:], hidden: ["a", "b", "c", "d"])
        #expect(allHidden.isAllHidden && allHidden.visible.isEmpty)
        #expect(!HomeListContent().isAllHidden)
    }

    @Test("最后一条：最新一次有摘要就是摘要；没摘要、是你发的就是任务；计划派的没摘要往前找")
    func lastMessage() {
        let now = Fixture.now
        let summary = Self.message("r1", prompt: "整理周报", summary: "周报整理好了，\n分了三组。", at: now.addingTimeInterval(-600))
        let failedTask = Self.message("r2", prompt: "  发到群里  ", summary: nil, at: now.addingTimeInterval(-60))
        let planTask = Self.message("r3", prompt: "汇总通知", summary: nil, source: .plan, at: now)

        let reply = HomeLastMessage.latest(in: [summary])
        #expect(reply?.author == .agent)
        #expect(reply?.text == "周报整理好了，\n分了三组。")
        #expect(reply?.singleLine == "周报整理好了， 分了三组。")
        #expect(reply?.at == now.addingTimeInterval(-570))

        // 计划派的、没摘要的跳过；你发的任务没回答也算。顺序不影响。
        let task = HomeLastMessage.latest(in: [summary, planTask, failedTask])
        #expect(task == HomeLastMessage(author: .user, text: "发到群里", runID: "r2", at: now.addingTimeInterval(-60)))
        #expect(HomeLastMessage.latest(in: [failedTask, planTask, summary]) == task)
        #expect(HomeLastMessage.latest(in: [planTask]) == nil)
        #expect(HomeLastMessage.latest(in: []) == nil)

        // 引用回复只取正文。
        let quoted = Self.message(
            "r4", prompt: MessageQuote.compose(quote: "原来那段", body: "就按这个改"), summary: nil, at: now)
        #expect(HomeLastMessage.latest(in: [quoted])?.text == "就按这个改")
    }

    @Test("预览：没有进行中的运行时显示最后一条；创建中、不认识的状态照旧说状态；最后一条比实例新时按它排")
    func messagePreview() {
        let now = Fixture.now
        let last = HomeLastMessage(author: .agent, text: "好了", runID: "r1", at: now)
        #expect(HomeRowPreview(state: .running, activity: .none, lastMessage: last) == .message(last, state: .running))
        #expect(HomeRowPreview(state: .paused, activity: .none, lastMessage: last) == .message(last, state: .paused))
        #expect(
            HomeRowPreview(state: .archived, activity: .none, lastMessage: last) == .message(last, state: .archived))
        #expect(HomeRowPreview(state: .provisioning, activity: .none, lastMessage: last) == .idle(.provisioning))
        #expect(HomeRowPreview(state: .unknown("x"), activity: .none, lastMessage: last) == .idle(.unknown("x")))
        // 在等你处理、进行中的照旧优先。
        let active = InstanceActivity(activeRuns: 1, latestRunState: .running, latestRunAt: now)
        #expect(
            HomeRowPreview(state: .running, activity: active, lastMessage: last) == .active(count: 1, state: .running))

        let row = HomeRow(
            instance: Self.instance("a", name: "写作助手", lastActive: now.addingTimeInterval(-3_600)), activity: .none,
            lastMessage: last)
        #expect(row.lastActivityAt == now)
        #expect(row.lastMessage == last)
    }

    @Test("长按菜单（参考 32、112 的一列）：资料、置顶 / 取消置顶、新建计划、改名、隐藏，更多里复制 ID 和删除")
    func menu() {
        typealias Item = HomeInstanceMenuItem
        #expect(HomeInstanceMenu.items(isPinned: false) == [.profile, .pin, .newPlan, .rename, .hide])
        #expect(HomeInstanceMenu.items(isPinned: true) == [.profile, .unpin, .newPlan, .rename, .hide])
        #expect(HomeInstanceMenu.more == [.copyID, .delete])
        // 左滑：最右边是隐藏，再是置顶。
        #expect(HomeInstanceMenu.swipeItems(isPinned: false) == [.hide, .pin])
        #expect(HomeInstanceMenu.swipeItems(isPinned: true) == [.hide, .unpin])

        let all: [Item] = [.profile, .pin, .unpin, .newPlan, .rename, .hide, .copyID, .delete]
        #expect(Set(all.map(\.systemImage)).count == all.count)
        #expect(all.filter(\.isDestructive) == [.hide, .delete])
        #expect(all.filter(\.needsConnection) == [.newPlan, .rename, .delete])
        let id: InstanceID = "a"
        #expect(Item.profile.route(for: id) == .instance(id))
        #expect(Item.newPlan.route(for: id) == .newPlan(instanceID: id))
        #expect(all.filter { $0.route(for: id) != nil } == [.profile, .newPlan])
        #expect(Item.profile.title(.chinese) == "Botin 资料")
        #expect(Item.copyID.title(.chinese) == "复制 Botin ID")
        #expect(Item.rename.title(.english) == "Rename…")
        for language in [DisplayLanguage.chinese, .english] {
            #expect(Set(all.map { $0.title(language) }).count == all.count)
            #expect(HomeText.hidingFacts(language).count == 3)
            #expect(!HomeText.hiddenCount(2, language: language).isEmpty)
        }
        #expect(HomeText.hiddenCount(1, language: .english) == "1 hidden Botin")
        #expect(HomeText.hiddenCount(3, language: .chinese) == "已隐藏 3 个 Botin")
    }

    @Test("改名：去掉首尾空白，改好了首页马上变；名字没变不调；不合规、失败返回错误")
    @MainActor
    func rename() async {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        let id = DemoData.writerID
        #expect(await model.renameInstance(id, to: "  主笔  ") == nil)
        #expect(model.instances.first { $0.id == id }?.name == "主笔")
        #expect(model.homeRows.first { $0.id == id }?.instance.name == "主笔")

        let calls = mock.callCount("renameInstance(_:name:)")
        #expect(await model.renameInstance(id, to: "主笔") == nil)
        #expect(mock.callCount("renameInstance(_:name:)") == calls)

        #expect(await model.renameInstance(id, to: "   ") != nil)
        #expect(await model.renameInstance(id, to: String(repeating: "长", count: 65)) != nil)
        #expect(mock.callCount("renameInstance(_:name:)") == calls)

        mock.failNext(
            "renameInstance(_:name:)", with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        #expect(await model.renameInstance(id, to: "校对") != nil)
        #expect(model.instances.first { $0.id == id }?.name == "主笔")
    }

    @Test("最后一条从缓存读：启动时有；新跑完的回首页时重读就有")
    @MainActor
    func reloadLastMessages() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        // 写作助手最新的一次（发到群里）在等审批，没摘要、是你发的。
        let writer = try #require(model.lastMessages[DemoData.writerID])
        #expect(writer.author == .user)
        #expect(writer.runID == DemoData.postRunID)

        let run = try await mock.createRun(instanceID: DemoData.reviewerID, prompt: "看看新的 PR")
        model.reloadLastMessages()
        #expect(model.lastMessages[DemoData.reviewerID]?.runID == run.id)
        #expect(model.lastMessages[DemoData.reviewerID]?.text == "看看新的 PR")
    }

    @Test("“等你处理”提示行：有待审批或未读才有；有审批进审批中心，只有未读进收件箱；文字只写有的那几样")
    func attentionHint() {
        #expect(HomeAttentionHint(badges: .zero) == nil)
        #expect(HomeAttentionHint(badges: ShellBadges(activeRuns: 3, plansAwaitingConfirmation: 2)) == nil, "进行中、待确认不算")

        let both = HomeAttentionHint(badges: ShellBadges(inboxUnread: 3, pendingApprovals: 2))
        #expect(both?.text(.chinese) == "2 个审批在等你 · 3 条未读")
        #expect(both?.text(.english) == "2 approvals waiting · 3 unread")
        #expect(both?.route == .approvals)
        #expect(both?.accessibilityHint(.chinese) == "打开审批")

        let approvals = HomeAttentionHint(badges: ShellBadges(pendingApprovals: 1))
        #expect(approvals?.text(.chinese) == "1 个审批在等你")
        #expect(approvals?.text(.english) == "1 approval waiting")
        #expect(approvals?.route == .approvals)

        let unread = HomeAttentionHint(badges: ShellBadges(inboxUnread: 5))
        #expect(unread?.text(.chinese) == "5 条未读")
        #expect(unread?.route == .inbox)
        #expect(unread?.accessibilityHint(.english) == "Opens Inbox")
    }
}
