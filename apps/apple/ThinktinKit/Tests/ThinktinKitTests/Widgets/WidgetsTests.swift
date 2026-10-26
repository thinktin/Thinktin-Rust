import Foundation
import Testing

@testable import ThinktinKit

/// 记下写给小组件的快照。
private actor RecordingWidgets: WidgetSnapshotSink {
    private(set) var snapshots: [WidgetSnapshot] = []

    func publish(_ snapshot: WidgetSnapshot) { snapshots.append(snapshot) }
}

@Suite("小组件的快照（12.20）")
struct WidgetSnapshotTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("从角标来；比较只看数不看时间；没登录时数都是 0")
    func snapshot() {
        var badges = ShellBadges.zero
        badges.inboxUnread = 3
        badges.pendingApprovals = 1
        badges.activeRuns = 2
        let snapshot = WidgetSnapshot(badges: badges, updatedAt: date)
        #expect(snapshot.signedIn)
        #expect(snapshot.inboxUnread == 3 && snapshot.pendingApprovals == 1 && snapshot.activeRuns == 2)
        #expect(snapshot.sameCounts(as: WidgetSnapshot(badges: badges, updatedAt: date.addingTimeInterval(60))))
        badges.activeRuns = 0
        #expect(!snapshot.sameCounts(as: WidgetSnapshot(badges: badges, updatedAt: date)))

        let signedOut = WidgetSnapshot.signedOut(at: date)
        #expect(!signedOut.signedIn)
        #expect(signedOut.inboxUnread == 0 && signedOut.pendingApprovals == 0 && signedOut.activeRuns == 0)
        #expect(!signedOut.sameCounts(as: WidgetSnapshot(badges: .zero, updatedAt: date)))
    }

    @Test("共享目录里的文件：写了能读回来；没写过、坏了读到 nil")
    func file() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = WidgetSnapshotFile(directory: directory)
        #expect(file.url.lastPathComponent == "widget-snapshot.json")
        #expect(file.load() == nil)

        let snapshot = WidgetSnapshot(
            signedIn: true, inboxUnread: 4, pendingApprovals: 2, activeRuns: 1, updatedAt: date)
        try file.save(snapshot)
        #expect(file.load() == snapshot)
        try file.save(.signedOut(at: date))
        #expect(file.load() == .signedOut(at: date))

        try Data("not json".utf8).write(to: file.url)
        #expect(file.load() == nil)
    }

    @Test("文案")
    func text() {
        #expect(WidgetText.approvals(.chinese) == "待审批")
        #expect(WidgetText.signedOut(.english) == "Open the app to sign in")
        let now = date.addingTimeInterval(5 * 60)
        #expect(WidgetText.updated(date, now: now, language: .chinese).hasSuffix("更新"))
        #expect(WidgetText.updated(date, now: now, language: .english).hasPrefix("Updated "))
    }
}

@MainActor
@Suite("App 写给小组件的快照（12.20）")
struct AppModelWidgetTests {
    @Test("登录后写角标的数，数变了再写，没变不写；退出登录写“没登录”")
    func publishes() async throws {
        let widgets = RecordingWidgets()
        let model = AppModel(client: makeShellMock(), defaults: nil, widgets: widgets)
        await model.start()
        #expect(await eventuallyAsync { await widgets.snapshots.last?.inboxUnread == 3 })
        let first = try #require(await widgets.snapshots.last)
        #expect(first.signedIn)
        #expect(first.pendingApprovals == model.badges.pendingApprovals)
        #expect(first.activeRuns == model.badges.activeRuns)

        model.inboxUnreadChanged(1)
        #expect(await eventuallyAsync { await widgets.snapshots.last?.inboxUnread == 1 })
        let count = await widgets.snapshots.count
        model.inboxUnreadChanged(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await widgets.snapshots.count == count)

        try await model.signOut()
        #expect(await eventuallyAsync { await widgets.snapshots.last?.signedIn == false })
        #expect(await widgets.snapshots.last?.inboxUnread == 0)
    }

    @Test("一开始就没登录：写“没登录”")
    func signedOutAtLaunch() async {
        let widgets = RecordingWidgets()
        let model = AppModel(client: makeShellMock(signedIn: false), defaults: nil, widgets: widgets)
        await model.start()
        #expect(model.phase == .signedOut)
        #expect(await eventuallyAsync { await widgets.snapshots.last?.signedIn == false })
    }
}

@Suite("快捷指令的操作（12.20）")
struct QuickActionsTests {
    @Test("全部停止：和设置里的一样，取消运行、暂停计划")
    func stopAll() async throws {
        let mock = makeShellMock()
        let result = try await QuickActions(client: mock).stopAll()
        #expect(mock.callCount("stopAll()") == 1)
        #expect(result.runsCancelled > 0 || result.plansPaused > 0)
        #expect(QuickActionText.stopped(result, language: .chinese).hasPrefix("已经全部停止"))
    }

    @Test("待审批数：过期的不算")
    func pendingApprovals() async throws {
        let mock = makeShellMock()
        let actions = QuickActions(client: mock)
        let now = Date()
        let expected = try await mock.approvals().filter { $0.isPending && !$0.isExpired(now: now) }.count
        #expect(expected > 0)
        #expect(try await actions.pendingApprovals(now: now) == expected)
        // 过了所有审批的期限：一个都不算。
        #expect(try await actions.pendingApprovals(now: now.addingTimeInterval(365 * 86_400)) == 0)
        #expect(QuickActionText.pendingApprovals(0, language: .english) == "Nothing is waiting for approval.")
        #expect(QuickActionText.pendingApprovals(1, language: .english) == "1 approval is waiting.")
        #expect(QuickActionText.pendingApprovals(2, language: .chinese) == "有 2 个待审批。")
    }

    @Test("下任务：去掉首尾空白再发；空的、像密码的不发")
    func sendTask() async throws {
        let mock = makeShellMock()
        let actions = QuickActions(client: mock)
        let run = try await actions.sendTask(to: DemoData.writerID, text: "  写一份周报 \n")
        #expect(run.prompt == "写一份周报")
        #expect(run.instanceID == DemoData.writerID)

        await #expect(throws: QuickActionError.emptyTask) {
            try await actions.sendTask(to: DemoData.writerID, text: " \n ")
        }
        let calls = mock.callCount("sendMessage(instanceID:text:allowSecrets:)")
        await #expect(throws: QuickActionError.containsSecrets) {
            try await actions.sendTask(to: DemoData.writerID, text: "用这个 key：sk-ant-abcdefghijklmnopqrstuvwxyz0123")
        }
        // 本机就拦下了，没发出去。
        #expect(mock.callCount("sendMessage(instanceID:text:allowSecrets:)") == calls)
    }

    @Test("错误：没登录、找不到、别的错误带着原来的")
    func errors() async throws {
        let actions = QuickActions(client: makeShellMock(signedIn: false))
        await #expect(throws: QuickActionError.signedOut) { try await actions.stopAll() }

        let mock = makeShellMock()
        let signedIn = QuickActions(client: mock)
        await #expect(throws: QuickActionError.notFound) {
            try await signedIn.sendTask(to: "0192f3a0-0000-7000-8000-00000000ffff", text: "hi")
        }
        mock.failNext(with: .network(message: "timeout"))
        await #expect(throws: QuickActionError.failed(.network(message: "timeout"))) {
            try await signedIn.pendingApprovals()
        }
        mock.failNext(with: .containsSecrets(count: 1))
        await #expect(throws: QuickActionError.containsSecrets) {
            try await signedIn.sendTask(to: DemoData.writerID, text: "hello")
        }

        #expect(QuickActionText.error(.signedOut, language: .chinese) == "先打开 ThinkTin 登录。")
        #expect(
            QuickActionText.error(.failed(.network(message: "timeout")), language: .chinese)
                == ClientError.network(message: "timeout").localizedMessage(.chinese))
    }

    @Test("暂停、恢复计划")
    func pausePlan() async throws {
        let mock = makeShellMock()
        let actions = QuickActions(client: mock)
        let paused = try await actions.setPlanPaused(DemoData.digestPlanID, paused: true)
        #expect(paused.isPaused)
        let resumed = try await actions.setPlanPaused(DemoData.digestPlanID, paused: false)
        #expect(!resumed.isPaused)
        #expect(QuickActionText.planPaused("日报", paused: true, language: .chinese) == "已暂停“日报”。")
        #expect(QuickActionText.planPaused("Digest", paused: false, language: .english) == "Resumed “Digest”.")
    }

    @Test("能选的实例：不含已删除的，最近活跃的在前")
    func instances() async throws {
        let mock = makeShellMock()
        mock.update { state in
            state.instances[state.instances.count - 1].state = .deleted
        }
        let list = try await QuickActions(client: mock).instances()
        #expect(!list.isEmpty)
        #expect(list.allSatisfy { $0.state != .deleted })
        #expect(list.map(\.lastActiveAt) == list.map(\.lastActiveAt).sorted(by: >))
        #expect(try await QuickActions(client: mock).plans().count == (try await mock.plans(instanceID: nil)).count)
    }
}
