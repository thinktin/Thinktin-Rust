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
}
