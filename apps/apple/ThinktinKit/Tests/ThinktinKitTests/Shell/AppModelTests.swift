import Foundation
import Testing

@testable import ThinktinKit

// AppModel：登录状态、启动时先缓存再刷新、角标、冻结重查、强制升级停事件流、连接横幅、离线、当前实例。

@MainActor
@Suite("应用框架的全局状态")
struct AppModelTests {
    private func make(signedIn: Bool = true, defaults: UserDefaults? = nil) -> (MockClient, AppModel) {
        let mock = makeShellMock(signedIn: signedIn)
        return (mock, AppModel(client: mock, defaults: defaults))
    }

    @Test("初始状态跟着本地有没有会话；没登录时先不跳转")
    func initialPhase() {
        let (_, signedIn) = make()
        #expect(signedIn.phase == .signedIn)
        #expect(!signedIn.router.isHoldingRoutes)
        let (_, signedOut) = make(signedIn: false)
        #expect(signedOut.phase == .signedOut)
        #expect(signedOut.router.isHoldingRoutes)
        #expect(signedOut.client is ObservedClient)
    }

    @Test("启动：实例按最近活跃排序，选中最近的，角标按演示数据")
    func start() async {
        let (mock, model) = make()
        await model.start()
        #expect(model.user?.displayName == "张三")
        #expect(model.instances.map(\.id) == [DemoData.writerID, DemoData.reviewerID])
        #expect(model.hasLoadedInstances)
        #expect(model.router.currentInstanceID == DemoData.writerID)
        #expect(model.currentInstance?.name == "写作助手")
        #expect(
            model.badges
                == ShellBadges(
                    inboxUnread: mock.state.unreadCount, pendingApprovals: 1, activeRuns: 2,
                    plansAwaitingConfirmation: 1))
        // 写作助手在等审批，代码审查在跑。
        #expect(model.activity(for: DemoData.writerID).waitingRuns == 1)
        #expect(model.activity(for: DemoData.writerID).needsAttention)
        #expect(model.activity(for: DemoData.reviewerID).activeRuns == 1)
        #expect(!model.activity(for: DemoData.reviewerID).needsAttention)
        #expect(model.activity(for: "nope") == .none)
        #expect(!model.isOffline)
        // 只启动一次。
        await model.start()
    }

    @Test("启动时先显示缓存，网络的结果回来再换")
    func cacheFirst() async {
        let mock = MockClient(state: DemoData.state(), latency: 0.5, stepDelay: 0, autoReply: false)
        let model = AppModel(client: mock, defaults: nil)
        let start = Task { await model.start() }
        // 网络调用还在路上（每个 0.5 秒），缓存已经显示出来了。
        #expect(await eventually { model.hasLoadedInstances })
        #expect(model.instances.count == 2)
        #expect(model.router.currentInstanceID == DemoData.writerID)
        #expect(model.badges.inboxUnread == mock.state.unreadCount)
        #expect(model.badges.activeRuns == 2)
        #expect(model.user == nil)
        await start.value
        #expect(model.user != nil)
        #expect(model.badges.pendingApprovals == 1)
    }

    @Test("网络不通：留着已有的数据，标离线；恢复后取消")
    func refreshOffline() async {
        let (mock, model) = make()
        await model.start()
        // instances()、角标的五个调用（收件箱、审批、计划、两个实例的运行）都失败。
        for _ in 0..<6 { mock.failNext(with: .network(message: "offline")) }
        await model.refresh()
        #expect(model.isOffline)
        #expect(model.instances.count == 2)
        #expect(model.refreshError == nil)
        #expect(model.badges.pendingApprovals == 1)
        #expect(model.phase == .signedIn)
        // 网络恢复。
        await model.refresh()
        #expect(!model.isOffline)
    }

    @Test("刷新实例失败（不是网络）：显示错误，可以重试")
    func refreshError() async {
        let (mock, model) = make()
        await model.start()
        mock.failNext(with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        await model.refresh()
        #expect(model.refreshError?.apiCode == .internal)
        #expect(model.phase == .signedIn)
        await model.refresh()
        #expect(model.refreshError == nil)
    }

    @Test("启动时发现账号被冻结：进冻结页；解冻后重查回到正常")
    func frozenAtStart() async {
        let (mock, model) = make()
        mock.update { $0.user.status = .frozen }
        await model.start()
        #expect(model.phase == .frozen)
        #expect(model.router.isHoldingRoutes)

        // 还冻着。
        await model.recheckAccount()
        #expect(model.phase == .frozen)
        // 重查时网络不通。
        mock.failNext(with: .network(message: "offline"))
        await model.recheckAccount()
        #expect(model.phase == .frozen)
        #expect(model.accountCheckError?.isOffline == true)
        // 服务端说还冻着（AccountFrozen）。
        mock.failNext(with: .accountFrozen)
        await model.recheckAccount()
        #expect(model.phase == .frozen)
        #expect(model.accountCheckError == nil)

        mock.update { $0.user.status = .active }
        await model.sceneDidBecomeActive()
        #expect(model.phase == .signedIn)
        #expect(!model.router.isHoldingRoutes)
        #expect(model.instances.count == 2)
        #expect(model.badges.pendingApprovals == 1)
    }

    @Test("任何调用遇到冻结、登录失效都切换全局状态")
    func globalErrorsFromAnyCall() async throws {
        let (mock, model) = make()
        await model.start()
        model.router.open(.plans)

        mock.failNext(with: .accountFrozen)
        _ = try? await model.client.plans(instanceID: nil)
        #expect(await eventually { model.phase == .frozen })
        // 冻结时登录状态和数据保留。
        #expect(model.instances.count == 2)
        #expect(model.router.path == [.plans])

        mock.failNext(with: .api(status: 401, code: .sessionRevoked, message: "revoked", retryAfterSecs: nil))
        _ = try? await model.client.me()
        #expect(await eventually { model.phase == .signedOut })
        // 回登录页：清掉上一个账号的一切。
        #expect(model.instances.isEmpty)
        #expect(model.user == nil)
        #expect(model.badges == .zero)
        #expect(model.router.path.isEmpty)
        #expect(model.router.currentInstanceID == nil)
        #expect(model.router.isHoldingRoutes)
    }

    @Test("没有会话时的冻结错误留给登录页行内提示")
    func frozenWithoutSession() async {
        let (_, model) = make(signedIn: false)
        #expect(!model.handle(ClientError.accountFrozen))
        #expect(model.phase == .signedOut)
        #expect(!model.handle(CancellationError()))
        #expect(!model.handle(ClientError.api(status: 404, code: .notFound, message: "", retryAfterSecs: nil)))
    }

    @Test("强制升级：停掉事件流，之后一直停在升级页")
    func upgrade() async throws {
        let (mock, model) = make()
        await model.start()
        let collector = StatusCollector()
        let handle = try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: collector)
        #expect(await collector.wait(for: .live))

        mock.failNext(with: .upgradeRequired)
        _ = try? await model.client.agents()
        #expect(await eventually { model.phase == .upgradeRequired })
        #expect(collector.statuses.value.last == .upgradeRequired)
        #expect(model.connection == .idle)
        #expect(throws: ClientError.upgradeRequired) {
            try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
        }
        // 之后什么都不再切换。
        #expect(model.handle(ClientError.signedOut))
        #expect(model.handle(ClientError.network(message: "x")))
        try await model.client.logout()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.phase == .upgradeRequired)
        #expect(model.router.isHoldingRoutes)
        handle.stop()
    }

    @Test("读缓存时就说要升级：当场进升级页，不再刷新")
    func upgradeDuringCacheLoad() async {
        let (mock, model) = make()
        mock.failNext(with: .upgradeRequired)
        await model.start()
        #expect(model.phase == .upgradeRequired)
        #expect(model.instances.isEmpty)
        #expect(model.user == nil)
    }

    @Test("缓存坏了当作没有缓存，照常刷新")
    func brokenCache() async {
        let (mock, model) = make()
        mock.failNext(with: .cache(message: "corrupt"))
        await model.start()
        #expect(model.phase == .signedIn)
        #expect(model.instances.count == 2)
        #expect(model.refreshError == nil)
    }

    @Test("api 返回 upgrade_required 也算")
    func upgradeFromAPI() {
        let (_, model) = make()
        #expect(model.handle(ClientError.api(status: 426, code: .upgradeRequired, message: "", retryAfterSecs: nil)))
        #expect(model.phase == .upgradeRequired)
    }

    @Test("登录成功自动进来，记下的深链登录后再跳")
    func signInFlow() async throws {
        let (mock, model) = make(signedIn: false)
        await model.start()
        #expect(model.instances.isEmpty)
        model.router.handle(url: try #require(URL(string: "thinktin://run/\(DemoData.reviewRunID.rawValue)")))
        #expect(model.router.path.isEmpty)

        _ = try await model.client.login(phone: "+8613800138000", code: mock.state.verificationCode)
        #expect(await eventually { model.phase == .signedIn })
        #expect(model.user?.phone == "+8613800138000")
        #expect(model.router.path == [.run(DemoData.reviewRunID)])
        #expect(await eventually { model.instances.count == 2 && model.badges.pendingApprovals == 1 })
        #expect(model.router.currentInstanceID == DemoData.writerID)
    }

    @Test("退出登录、下线本机：回登录页")
    func signOut() async throws {
        let (_, model) = make()
        await model.start()
        try await model.signOut()
        #expect(model.phase == .signedOut)
        #expect(model.instances.isEmpty)

        let (mock2, other) = make()
        await other.start()
        try await other.client.revokeDevice(DemoData.deviceID)
        #expect(await eventually { other.phase == .signedOut })
        #expect(!mock2.signedIn())
    }

    @Test("退出登录失败但本地会话还在：把错误抛出去")
    func signOutFailure() async {
        let (mock, model) = make()
        await model.start()
        mock.failNext(with: .network(message: "offline"))
        await #expect(throws: ClientError.network(message: "offline")) { try await model.signOut() }
        #expect(model.phase == .signedIn)
    }

    @Test("网络不通和恢复：任何调用都算")
    func offline() async throws {
        let (mock, model) = make()
        await model.start()
        mock.failNext(with: .network(message: "offline"))
        _ = try? await model.client.vendors()
        #expect(await eventually { model.isOffline })
        _ = try await model.client.vendors()
        #expect(await eventually { !model.isOffline })
    }

    @Test("连接横幅：汇总各个事件流的状态")
    func connectionBanner() async throws {
        let (mock, model) = make()
        await model.start()
        let collector = StatusCollector()
        let handle = try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: collector)
        #expect(await collector.wait(for: .live))
        #expect(await eventually { model.connection == .idle })

        mock.play(MockEventScript(steps: [.status(.reconnecting(retryIn: 5))]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(
            await eventually {
                if case .reconnecting = model.connection { return true }
                return false
            })
        mock.play(MockEventScript(steps: [.status(.connecting)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.connection == .connecting })
        mock.play(MockEventScript(steps: [.status(.live)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.connection == .idle })

        // 断开的流停掉之后横幅也没了。
        mock.play(MockEventScript(steps: [.status(.connecting)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.connection == .connecting })
        handle.stop()
        #expect(await eventually { model.connection == .idle })
    }

    @Test("事件流说账号被冻结、登录失效")
    func streamGlobalStates() async throws {
        let (mock, model) = make()
        await model.start()
        let handle = try model.client.subscribe(
            instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
        mock.play(MockEventScript(steps: [.status(.accountFrozen)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.phase == .frozen })
        handle.stop()

        let (mock2, other) = make()
        await other.start()
        let handle2 = try other.client.subscribe(
            instanceID: DemoData.reviewerID, afterSeq: nil, listener: StatusCollector())
        try await mock2.logout()  // Mock 给订阅者发 signedOut
        #expect(await eventually { other.phase == .signedOut })
        handle2.stop()
    }

    @Test("当前实例被删了：换成最近活跃的另一个，回到根")
    func currentInstanceDeleted() async throws {
        let (_, model) = make()
        await model.start()
        model.router.open(.instance(DemoData.writerID))
        try await model.client.deleteInstance(DemoData.writerID)
        await model.refresh()
        #expect(model.instances.map(\.id) == [DemoData.reviewerID])
        #expect(model.router.currentInstanceID == DemoData.reviewerID)
        #expect(model.router.path.isEmpty)
        #expect(model.activity[DemoData.writerID] == nil)
        #expect(model.badges.activeRuns == 1)
    }

    @Test("事件流说实例不存在：从列表拿掉，换实例")
    func streamNotFound() async throws {
        let (mock, model) = make()
        await model.start()
        let handle = try model.client.subscribe(
            instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
        mock.play(MockEventScript(steps: [.status(.notFound)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.router.currentInstanceID == DemoData.reviewerID })
        handle.stop()
    }

    @Test("没有实例：根是首页")
    func noInstances() async {
        let mock = makeShellMock()
        mock.update {
            $0.instances = []
            $0.runs = []
        }
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        #expect(model.hasLoadedInstances)
        #expect(model.instances.isEmpty)
        #expect(model.router.rootRoute == .home)
        #expect(model.badges.activeRuns == 0)
    }

    @Test("记住上次选的实例；退出登录时忘掉")
    func rememberSelection() async throws {
        let suite = "AppModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let (_, first) = make(defaults: defaults)
        await first.start()
        first.selectInstance(DemoData.reviewerID)
        #expect(defaults.string(forKey: InstanceSelectionStore.key) == DemoData.reviewerID.rawValue)

        let (_, second) = make(defaults: defaults)
        await second.start()
        #expect(second.router.currentInstanceID == DemoData.reviewerID)
        try await second.signOut()
        #expect(defaults.string(forKey: InstanceSelectionStore.key) == nil)
    }

    @Test("角标：打开抽屉时太久没刷新才刷新")
    func badgeThrottle() async {
        let mock = makeShellMock()
        let clock = Locked(Date())
        let model = AppModel(client: mock, defaults: nil, now: { clock.value })
        await model.start()
        #expect(model.badges.inboxUnread == mock.state.unreadCount)

        _ = try? await mock.markInboxRead(ids: [], upTo: nil)
        await model.refreshBadgesIfStale()
        #expect(model.badges.inboxUnread == 3)  // 刚刷过，不刷
        clock.withLock { $0 = $0.addingTimeInterval(AppModel.badgeMaxAge + 1) }
        await model.refreshBadgesIfStale()
        #expect(model.badges.inboxUnread == 0)
    }

    @Test("过期的审批不算待审批")
    func expiredApprovals() async {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil, now: { Date().addingTimeInterval(48 * 3600) })
        await model.start()
        #expect(model.badges.pendingApprovals == 0)
    }

    @Test("新任务：一个实例直接回对话，几个时弹出选择，没有时去领养")
    func newTask() async {
        let (mock, model) = make()
        await model.start()
        model.router.open(.plans)
        model.router.openDrawer()
        model.startNewTask()
        #expect(model.router.sheet == .newTask)
        #expect(!model.router.isDrawerOpen)

        model.router.dismissSheet()
        try? await model.client.deleteInstance(DemoData.reviewerID)
        await model.refresh()
        model.startNewTask()
        #expect(model.router.sheet == nil)
        #expect(model.router.path.isEmpty)
        #expect(model.router.currentInstanceID == DemoData.writerID)
        #expect(model.router.newTaskRequest == 1)

        try? await model.client.deleteInstance(DemoData.writerID)
        await model.refresh()
        #expect(model.router.rootRoute == .home)
        model.startNewTask()
        #expect(model.router.path == [.agentCatalog])
        #expect(mock.state.instances.isEmpty)
    }

    @Test("没登录时刷新什么都不做")
    func refreshWhenSignedOut() async {
        let (_, model) = make(signedIn: false)
        await model.refresh()
        await model.refreshBadges()
        await model.sceneDidBecomeActive()
        await model.recheckAccount()
        #expect(model.instances.isEmpty)
        #expect(model.badges == .zero)
    }
}

@Suite("抽屉与横幅的数据")
struct ShellStateTests {
    @Test("角标：按入口取数，超过 99 显示 99+")
    func badges() {
        let badges = ShellBadges(inboxUnread: 3, pendingApprovals: 1, activeRuns: 120, plansAwaitingConfirmation: 2)
        #expect(DrawerEntry.allCases.map { badges.count(for: $0) } == [3, 1, 120, 2, 0, 0])
        #expect(ShellBadges.text(7) == "7")
        #expect(ShellBadges.text(99) == "99")
        #expect(ShellBadges.text(120) == "99+")
        #expect(DrawerEntry.inbox.badgeAccessibilityLabel(count: 3, language: .chinese) == "3 条未读")
        #expect(DrawerEntry.approvals.badgeAccessibilityLabel(count: 0) == nil)
        #expect(DrawerEntry.activeRuns.title(.chinese) == "进行中")
        #expect(DrawerEntry.artifacts.route == .artifacts(instanceID: nil))
    }

    @Test("实例的运行概况")
    func activity() {
        let now = Fixture.now
        let runs = [
            Fixture.run("a", state: .succeeded, createdAt: now.addingTimeInterval(-300)),
            Fixture.run("b", state: .waitingQuota, createdAt: now.addingTimeInterval(-60)),
            Fixture.run("c", state: .running, createdAt: now.addingTimeInterval(-120)),
            Fixture.run("d", state: .backoff, createdAt: now.addingTimeInterval(-200)),
        ]
        let activity = InstanceActivity(runs: runs)
        #expect(activity.activeRuns == 3)
        #expect(activity.waitingRuns == 1)
        #expect(activity.latestRunState == .waitingQuota)
        #expect(activity.latestRunAt == now.addingTimeInterval(-60))
        #expect(InstanceActivity(runs: []) == .none)
    }

    @Test("连接横幅的文案")
    func connectionMessages() {
        let now = Fixture.now
        #expect(ConnectionState.idle.message(.chinese) == nil)
        #expect(!ConnectionState.idle.isVisible)
        #expect(ConnectionState.connecting.message(.chinese) == "正在连接…")
        let retry = ConnectionState.reconnecting(retryAt: now.addingTimeInterval(2.4))
        #expect(retry.message(.chinese, now: now) == "连接已断开，3 秒后重连")
        #expect(retry.message(.english, now: now) == "Connection lost. Retrying in 3s")
        #expect(retry.message(.chinese, now: now.addingTimeInterval(5)) == "正在重新连接…")
        #expect(retry.isVisible)
    }
}
