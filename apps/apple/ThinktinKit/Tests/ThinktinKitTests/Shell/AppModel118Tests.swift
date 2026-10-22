import Foundation
import Testing

@testable import ThinktinKit

// 应用框架接上 11.8：“进行中”改用跨实例的 listRuns(filter: .active)，启动、回到前台、事件流以 stopped 结束时查
// upgradeRequired()，ObservedClient 转发新方法。

@MainActor
@Suite("应用框架接上 11.8")
struct AppModel118Tests {
    /// 演示数据加上：代码审查一个很早就在等电脑的运行，之后又有 25 个结束了的（每个实例最近 20 条之外）。
    private func mockWithOldWaitingRun() -> MockClient {
        let mock = makeShellMock()
        let now = Date()
        mock.update { s in
            s.runs.append(
                Run(
                    id: "0192f3a0-0000-7000-8000-000000000301", instanceID: DemoData.reviewerID, prompt: "跑一遍集成测试",
                    state: .waitingDevice, createdAt: now.addingTimeInterval(-3 * 86_400), waitCode: .deviceOffline))
            for i in 0..<25 {
                s.runs.append(
                    Run(
                        id: RunID(String(format: "0192f3a0-0000-7000-8000-%012d", 400 + i)),
                        instanceID: DemoData.reviewerID, prompt: "已完成的任务 \(i)", state: .succeeded,
                        createdAt: now.addingTimeInterval(-Double(60 * (20 + i)))))
            }
        }
        return mock
    }

    @Test("进行中：一次跨实例的请求，每个实例最近 20 条之外的也算")
    func activeRunsAcrossInstances() async {
        let mock = mockWithOldWaitingRun()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        // 写作助手在等审批；代码审查一个在跑、一个在等电脑。
        #expect(model.badges.activeRuns == 3)
        #expect(
            model.activity(for: DemoData.writerID)
                == InstanceActivity(runs: mock.state.runs.filter { $0.instanceID == DemoData.writerID }))
        let reviewer = model.activity(for: DemoData.reviewerID)
        #expect(reviewer.activeRuns == 2)
        #expect(reviewer.waitingRuns == 1)
        #expect(reviewer.needsAttention)
        #expect(reviewer.latestRunState == .running)
    }

    @Test("启动时先用缓存里最近的运行凑数，网络的结果回来再换")
    func cachedActivityThenNetwork() async {
        let slow = MockClient(state: mockWithOldWaitingRun().state, latency: 0.3, stepDelay: 0, autoReply: false)
        let model = AppModel(client: slow, defaults: nil)
        let start = Task { await model.start() }
        #expect(await eventually { model.hasLoadedInstances })
        // 缓存只看每个实例最近 20 条：老的那个等电脑的不在里面。
        #expect(model.badges.activeRuns == 2)
        #expect(!model.activity(for: DemoData.reviewerID).needsAttention)
        await start.value
        #expect(model.badges.activeRuns == 3)
        #expect(model.activity(for: DemoData.reviewerID).needsAttention)
    }

    @Test("运行都结束了：再刷新时这个实例没有进行中的了")
    func finishedRunsLeave() async throws {
        let model = AppModel(client: makeShellMock(), defaults: nil)
        await model.start()
        #expect(model.activity(for: DemoData.reviewerID).activeRuns == 1)
        _ = try await model.client.cancelRun(DemoData.publishRunID, wholeTree: false)
        await model.refreshBadges()
        #expect(model.activity(for: DemoData.reviewerID) == .none)
        #expect(model.badges.activeRuns == 1)
    }

    @Test("按实例分开算，只看没结束的")
    func activityByInstance() {
        let now = Fixture.now
        var other = Fixture.run("x", state: .waitingApproval, createdAt: now.addingTimeInterval(-30))
        other.instanceID = "inst-2"
        let runs = [
            Fixture.run("a", state: .running, createdAt: now.addingTimeInterval(-120)),
            // 最新的一个已经结束了：不算“最近一个进行中的”。
            Fixture.run("b", state: .succeeded, createdAt: now),
            Fixture.run("c", state: .queued, createdAt: now.addingTimeInterval(-60)),
            other,
        ]
        let grouped = InstanceActivity.byInstance(runs)
        #expect(grouped.count == 2)
        #expect(
            grouped[Fixture.instanceID]
                == InstanceActivity(activeRuns: 2, latestRunState: .queued, latestRunAt: now.addingTimeInterval(-60)))
        #expect(grouped["inst-2"]?.needsAttention == true)
        #expect(InstanceActivity.byInstance([]).isEmpty)
        #expect(InstanceActivity(runs: [Fixture.run("d", state: .failed)]) == .none)
    }

    @Test("启动前就说要升级：第一帧就是升级页，不刷新、不能订阅")
    func upgradeRequiredBeforeLaunch() async {
        for signedIn in [true, false] {
            var state = DemoData.state(signedIn: signedIn)
            state.isUpgradeRequired = true
            let model = AppModel(client: MockClient(state: state, stepDelay: 0, autoReply: false), defaults: nil)
            #expect(model.phase == .upgradeRequired)
            #expect(model.router.isHoldingRoutes)
            #expect(model.client.upgradeRequired())
            #expect(throws: ClientError.upgradeRequired) {
                try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
            }
            await model.start()
            #expect(model.phase == .upgradeRequired)
            #expect(model.instances.isEmpty)
            #expect(model.user == nil)
        }
    }

    @Test("建好之后、启动之前说要升级：启动时进升级页")
    func upgradeRequiredBeforeStart() async {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        #expect(model.phase == .signedIn)
        mock.update { $0.isUpgradeRequired = true }
        await model.start()
        #expect(model.phase == .upgradeRequired)
        #expect(model.instances.isEmpty)
    }

    @Test("回到前台时发现要升级（冻结时也是）")
    func upgradeRequiredOnForeground() async {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        await model.sceneDidBecomeActive()
        #expect(model.phase == .signedIn)
        model.handle(ClientError.accountFrozen)
        #expect(model.phase == .frozen)
        mock.update { $0.isUpgradeRequired = true }
        await model.sceneDidBecomeActive()
        #expect(model.phase == .upgradeRequired)
    }

    @Test("事件流以 stopped 结束、客户端说要升级（握手被拒）：进升级页，别的事件流也停掉")
    func streamStoppedForUpgrade() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        let writer = StatusCollector()
        let reviewer = StatusCollector()
        let handles = [
            try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: writer),
            try model.client.subscribe(instanceID: DemoData.reviewerID, afterSeq: nil, listener: reviewer),
        ]
        #expect(await writer.wait(for: .live))
        #expect(await reviewer.wait(for: .live))
        mock.update { $0.isUpgradeRequired = true }
        mock.play(MockEventScript(steps: [.status(.stopped)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.phase == .upgradeRequired })
        #expect(await reviewer.wait(for: .stopped))
        #expect(model.connection == .idle)
        #expect((model.client as? ObservedClient)?.activeStreamCount == 0)
        for handle in handles { handle.stop() }
    }

    @Test("调用方自己停的 stopped 不算要升级")
    func streamStoppedByCaller() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        let collector = StatusCollector()
        let handle = try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: collector)
        #expect(await collector.wait(for: .live))
        mock.play(MockEventScript(steps: [.status(.stopped)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await collector.wait(for: .stopped))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.phase == .signedIn)
        handle.stop()
    }
}

@Suite("包了一层的客户端：11.8 的方法")
struct ObservedClient118Tests {
    private func make() -> (MockClient, ObservedClient, ActivityLog) {
        let mock = makeShellMock()
        let log = ActivityLog()
        return (mock, ObservedClient(mock) { log.record($0) }, log)
    }

    @Test("跨实例的运行、往前翻缓存原样转发")
    func forwardsRunsAndEvents() async throws {
        let (mock, client, log) = make()
        let active = try await client.listRuns(filter: .active)
        #expect(active == (try await mock.listRuns(filter: .active)))
        #expect(Set(active.map(\.id)) == [DemoData.postRunID, DemoData.publishRunID])
        #expect(try await client.listRuns(filter: .all, before: DemoData.postRunID, limit: 1).count == 1)
        let latest = try client.latestCachedEvents(instanceID: DemoData.writerID, limit: 3)
        #expect(latest == (try mock.cachedEventsBefore(instanceID: DemoData.writerID, beforeSeq: nil, limit: 3)))
        #expect(latest.count == 3)
        mock.failNext(with: .cache(message: "disk"))
        #expect(throws: ClientError.cache(message: "disk")) {
            try client.cachedEventsBefore(instanceID: DemoData.writerID, beforeSeq: 10, limit: 3)
        }
        mock.failNext(with: .network(message: "offline"))
        await #expect(throws: ClientError.network(message: "offline")) {
            try await client.listRuns(filter: .active)
        }
        #expect(log.failures == [.cache(message: "disk"), .network(message: "offline")])
    }

    @Test("请求语言：校验不过的报错，原来的值不变")
    func acceptLanguage() throws {
        let (mock, client, log) = make()
        try client.setAcceptLanguage(for: .english)
        #expect(mock.state.requestLocale == .en)
        #expect(throws: ClientError.self) { try client.setAcceptLanguage("en\r\nX-Evil: 1") }
        #expect(mock.state.requestLocale == .en)
        #expect(log.failures.count == 1)
        try client.setAcceptLanguage(nil)
        #expect(mock.state.acceptLanguage == nil)
    }

    @Test("要升级：被包的客户端说过，或者停过事件流")
    func upgradeRequired() {
        let (mock, client, _) = make()
        #expect(!client.upgradeRequired())
        mock.update { $0.isUpgradeRequired = true }
        #expect(client.upgradeRequired())
        let (_, halted, _) = make()
        halted.haltStreams()
        #expect(halted.upgradeRequired())
    }
}
