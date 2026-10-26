import Foundation
import Testing

@testable import ThinktinKit

/// 假的系统实时活动：记下开、改、结束。
private actor FakeLiveActivities: LiveActivityControlling {
    var enabled = true
    var allowsStart = true
    private(set) var open: [RunID: LiveActivityRun] = [:]
    private(set) var updates: [RunActivityContentState] = []
    private(set) var ended: [(RunID, immediately: Bool)] = []

    func setEnabled(_ value: Bool) { enabled = value }
    func setAllowsStart(_ value: Bool) { allowsStart = value }
    /// 用户在锁屏上划掉了（系统里没有了）。
    func remove(_ runID: RunID) { open[runID] = nil }
    func add(_ activity: LiveActivityRun) { open[activity.runID] = activity }

    func areActivitiesEnabled() -> Bool { enabled }
    func openActivities() -> [LiveActivityRun] { Array(open.values) }

    func start(_ activity: LiveActivityRun) -> Bool {
        guard allowsStart else { return false }
        open[activity.runID] = activity
        return true
    }

    func update(runID: RunID, state: RunActivityContentState) {
        updates.append(state)
        open[runID]?.state = state
    }

    func end(runID: RunID, state: RunActivityContentState?, immediately: Bool) {
        ended.append((runID, immediately))
        open[runID] = nil
    }
}

private func token(_ seed: UInt8) -> Data { Data(repeating: seed, count: 16) }

private func makeDefaults() -> UserDefaults {
    let name = "live-activities-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite("实时活动（12.10）")
struct LiveActivityModelTests {
    @Test("自己发的任务开实时活动，标题是实例名；设置里关了不开")
    func myRuns() async throws {
        let system = FakeLiveActivities()
        let defaults = makeDefaults()
        let app = AppModel(client: makeShellMock(), defaults: defaults, liveActivities: system)
        await app.start()
        let live = try #require(app.liveActivities)
        #expect(live.showsMyRuns)

        let run = try await app.client.sendMessage(instanceID: DemoData.writerID, text: "整理一下周报")
        #expect(await eventuallyAsync { await system.open[run.id] != nil })
        let activity = try #require(await system.open[run.id])
        #expect(activity.title == app.instances.first { $0.id == DemoData.writerID }?.name)
        #expect(activity.state.runState == run.state)
        #expect(live.openRunIDs.contains(run.id))

        live.showsMyRuns = false
        #expect(defaults.object(forKey: "liveActivities.myRuns") as? Bool == false)
        let second = try await app.client.sendMessage(instanceID: DemoData.writerID, text: "再来一个")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await system.open[second.id] == nil)
    }

    @Test("开不了：系统设置关了、已经结束的、子运行、开着的、系统拒绝")
    func cannotStart() async throws {
        let mock = makeShellMock()
        let system = FakeLiveActivities()
        let live = LiveActivityModel(client: mock, system: system, defaults: makeDefaults())
        let post = try await mock.getRun(DemoData.postRunID)
        let weekly = try await mock.getRun(DemoData.weeklyRunID)

        await system.setEnabled(false)
        #expect(!(await live.start(post, title: "写手")))
        #expect(live.isSystemDisabled)
        await system.setEnabled(true)

        #expect(!live.canStart(weekly))
        #expect(!(await live.start(weekly, title: "写手")))
        var child = post
        child.parentRunID = DemoData.weeklyRunID
        #expect(!live.canStart(child))

        await system.setAllowsStart(false)
        #expect(!(await live.start(post, title: "写手")))
        await system.setAllowsStart(true)
        #expect(await live.start(post, title: "写手"))
        #expect(!live.canStart(post))
        #expect(!(await live.start(post, title: "写手")))
    }

    @Test("推送令牌登记给服务端，同一个不再报；服务端拒绝（运行早就结束）就在本地马上结束")
    func registersTokens() async throws {
        let mock = makeShellMock()
        let system = FakeLiveActivities()
        let live = LiveActivityModel(client: mock, system: system, defaults: makeDefaults())
        let post = try await mock.getRun(DemoData.postRunID)
        #expect(await live.start(post, title: "写手"))

        await live.tokenChanged(runID: post.id, token: token(1))
        #expect(mock.state.liveActivities[post.id]?.token == LiveActivityToken.hex(token(1)))
        let calls = mock.callCount("registerLiveActivity(runID:token:)")
        await live.tokenChanged(runID: post.id, token: token(1))
        #expect(mock.callCount("registerLiveActivity(runID:token:)") == calls)
        // 太短的不报。
        await live.tokenChanged(runID: post.id, token: Data([1, 2]))
        #expect(mock.callCount("registerLiveActivity(runID:token:)") == calls)

        // 一天前就结束的运行（App 重新启动后还开着）：服务端拒绝，本地马上结束。
        let weekly = try await mock.getRun(DemoData.weeklyRunID)
        let stale = LiveActivityRun(
            runID: weekly.id, instanceID: weekly.instanceID, title: "写手", state: RunActivityContentState(run: weekly))
        await system.add(stale)
        live.appeared(stale)
        #expect(live.openRunIDs.contains(weekly.id))
        await live.tokenChanged(runID: weekly.id, token: token(2))
        #expect(!live.openRunIDs.contains(weekly.id))
        #expect(await system.ended.contains { $0.0 == weekly.id && $0.immediately })
    }

    @Test("用户划掉了：告诉服务端不再推送")
    func dismissed() async throws {
        let mock = makeShellMock()
        let system = FakeLiveActivities()
        let live = LiveActivityModel(client: mock, system: system, defaults: makeDefaults())
        let post = try await mock.getRun(DemoData.postRunID)
        #expect(await live.start(post, title: "写手"))
        await live.tokenChanged(runID: post.id, token: token(1))
        await live.dismissed(runID: post.id)
        #expect(mock.state.liveActivities[post.id]?.isEnded == true)
        #expect(!live.openRunIDs.contains(post.id))
        // 再来一次（系统的结束通知）什么都不做。
        let calls = mock.callCount("endLiveActivity(runID:)")
        await live.dismissed(runID: post.id)
        #expect(mock.callCount("endLiveActivity(runID:)") == calls)
    }

    @Test("计划运行：打开才报推送开启令牌，还没令牌时等令牌；关掉清掉；报过的不重报")
    func scheduledRuns() async throws {
        let mock = makeShellMock()
        let defaults = makeDefaults()
        let live = LiveActivityModel(client: mock, system: FakeLiveActivities(), defaults: defaults)
        #expect(!live.showsScheduledRuns)

        // 关着时拿到令牌：不报。
        await live.startTokenChanged(token(3))
        #expect(mock.state.liveActivityStartToken == nil)
        #expect(mock.callCount("setLiveActivityStartToken(_:)") == 0)

        await live.setShowsScheduledRuns(true)
        #expect(mock.state.liveActivityStartToken == LiveActivityToken.hex(token(3)))
        #expect(defaults.bool(forKey: "liveActivities.scheduledRuns"))
        // 同一个令牌再给一次（每次启动 ActivityKit 都会给）：不再报。
        await live.startTokenChanged(token(3))
        #expect(mock.callCount("setLiveActivityStartToken(_:)") == 1)
        // 换了令牌：报新的。
        await live.startTokenChanged(token(4))
        #expect(mock.state.liveActivityStartToken == LiveActivityToken.hex(token(4)))

        await live.setShowsScheduledRuns(false)
        #expect(mock.state.liveActivityStartToken == nil)

        // 报失败了（离线）：下次回到前台再报。
        await live.setShowsScheduledRuns(true)
        mock.update { $0.liveActivityStartToken = nil }
        defaults.removeObject(forKey: "liveActivities.reportedStartToken")
        mock.failNext("setLiveActivityStartToken(_:)", with: .network(message: "offline"))
        await live.startTokenChanged(token(5))
        #expect(mock.state.liveActivityStartToken == nil)
        await live.resume()
        #expect(mock.state.liveActivityStartToken == LiveActivityToken.hex(token(5)))
    }

    @Test("前台跟着事件流：工具调用加一步，状态马上变，结束时在本地结束")
    func followsEvents() async throws {
        let mock = makeShellMock()
        let system = FakeLiveActivities()
        let live = LiveActivityModel(client: mock, system: system, defaults: makeDefaults())
        let run = try await mock.sendMessage(instanceID: DemoData.writerID, text: "写一份周报")
        await live.resume()
        #expect(await live.start(run, title: "写手"))
        await live.tokenChanged(runID: run.id, token: token(1))

        mock.emit(.runState, payload: ["state": "running"], runID: run.id, instanceID: DemoData.writerID)
        #expect(await eventuallyAsync { await system.open[run.id]?.state.runState == .running })
        #expect(await system.open[run.id]?.state.startedAt != nil)

        mock.emit(
            .toolCall, payload: ["tool_call_id": "c1", "title": "读文件"], runID: run.id, instanceID: DemoData.writerID)
        #expect(await eventuallyAsync { await system.open[run.id]?.state.steps == 1 })
        // 别的运行的事件不管。
        mock.emit(
            .toolCall, payload: ["tool_call_id": "c2", "title": "读文件"], runID: DemoData.postRunID,
            instanceID: DemoData.writerID)

        mock.emit(.runState, payload: ["state": "succeeded"], runID: run.id, instanceID: DemoData.writerID)
        #expect(await eventuallyAsync { await system.ended.contains { $0.0 == run.id && !$0.immediately } })
        #expect(!live.openRunIDs.contains(run.id))
        #expect(await eventuallyAsync { mock.state.liveActivities[run.id]?.isEnded == true })
        #expect(await system.updates.allSatisfy { $0.steps <= 1 })
    }

    @Test("进后台不再跟事件流，回到前台对一遍：系统里没了的忘掉")
    func pauseAndResume() async throws {
        let mock = makeShellMock()
        let system = FakeLiveActivities()
        let live = LiveActivityModel(client: mock, system: system, defaults: makeDefaults())
        let run = try await mock.sendMessage(instanceID: DemoData.writerID, text: "写一份周报")
        await live.resume()
        #expect(await live.start(run, title: "写手"))

        live.pause()
        mock.emit(.runState, payload: ["state": "running"], runID: run.id, instanceID: DemoData.writerID)
        try await Task.sleep(nanoseconds: 50_000_000)
        let updates = await system.updates
        #expect(updates.isEmpty, "\(updates)")

        await system.remove(run.id)
        await live.resume()
        #expect(!live.openRunIDs.contains(run.id))
    }

    @Test("退出登录：开着的都在本地马上结束")
    func signOut() async throws {
        let system = FakeLiveActivities()
        let app = AppModel(client: makeShellMock(), defaults: makeDefaults(), liveActivities: system)
        await app.start()
        let live = try #require(app.liveActivities)
        let post = try await app.client.getRun(DemoData.postRunID)
        #expect(await live.start(post, title: "写手"))
        try await app.signOut()
        #expect(await eventuallyAsync { await system.open.isEmpty })
        #expect(await system.ended.allSatisfy { $0.immediately })
        #expect(live.openRunIDs.isEmpty)
    }
}
