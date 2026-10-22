import Foundation
import Testing

@testable import ThinktinKit

// 实例详情：状态、改名、版本升级 / 回滚、路由情况、计划和团队、删除。

@MainActor
@Suite("实例详情")
struct InstanceDetailModelTests {
    @Test("加载：实例、agent、路由、本实例的计划、所在团队")
    func load() async throws {
        let mock = AgentsFixture.mockWithPipeline()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.error == nil && model.detailsError == nil)
        #expect(model.instance?.name == "写作助手")
        #expect(model.agent?.id == DemoData.claudeAgentID)
        #expect(model.agentDisplayName == "Claude Agent")
        #expect(Set(model.plans?.map(\.id) ?? []) == [DemoData.digestPlanID, AgentsFixture.pipelinePlanID])
        #expect(model.teams?.map(\.id) == [DemoData.releaseTeamID])
        let team = try #require(model.teams?.first)
        #expect(model.role(in: team) == .member)
        guard case .configured(let main, let aliases) = model.routeStatus else {
            Issue.record("main should be configured")
            return
        }
        #expect(main.upstreamModel == "claude-sonnet-5-5")
        #expect(aliases == 2)
        #expect(model.routeStatus.summary(.chinese) == "main → claude-sonnet-5-5，另有 1 个别名")
        #expect(!model.routeStatus.needsAttention)
        // 已经是最新版本。
        #expect(!model.upgradeAvailable)
        #expect(model.isCurrentVersionListed)
        #expect(model.versionOptions.map(\.change) == [.current, .rollback])
        #expect(model.versionOptions.first?.isLatest == true)
    }

    @Test("先显示传进来的实例；传错的不用")
    func seeded() {
        let mock = AgentsFixture.mock()
        let writer = mock.state.instances[0]
        #expect(InstanceDetailModel(client: mock, instanceID: DemoData.writerID, instance: writer).instance == writer)
        #expect(InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID, instance: writer).instance == nil)
    }

    @Test("版本落后：提示升级，列表里新的是升级、旧的是回滚")
    func versionOptions() {
        let options = InstanceVersionOption(version: "2.2.2", isLatest: true, change: .upgrade)
        #expect(options.actionTitle(.chinese) == "升级到 v2.2.2")
        #expect(
            InstanceVersionOption(version: "2.1.0", isLatest: false, change: .rollback).actionTitle(.english)
                == "Roll back to v2.1.0")
        #expect(
            InstanceVersionOption(version: "1", isLatest: false, change: .switchTo).actionTitle(.chinese) == "换到 v1")
        #expect(InstanceVersionOption(version: "1", isLatest: false, change: .current).isCurrent)
    }

    @Test("升级：下次唤醒生效，提示里写上")
    func upgrade() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        await model.load()
        #expect(model.upgradeAvailable)
        #expect(model.latestVersion == "2.2.2")
        #expect(model.versionOptions.map(\.version) == ["2.2.2", "2.2.1", "2.1.0"])
        #expect(model.versionOptions.map(\.change) == [.upgrade, .current, .rollback])

        #expect(await model.setVersion("2.2.2"))
        #expect(model.instance?.agentVersion == "2.2.2")
        #expect(mock.state.instances.first { $0.id == DemoData.reviewerID }?.agentVersion == "2.2.2")
        #expect(model.versionChange == InstanceVersionChange(from: "2.2.1", to: "2.2.2"))
        #expect(model.versionChange?.message(.chinese).contains("下次唤醒") == true)
        #expect(!model.upgradeAvailable)
        #expect(model.versionOptions.map(\.change) == [.current, .rollback, .rollback])
    }

    @Test("回滚到旧版本；换成现在的版本什么也不做")
    func rollback() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        await model.load()
        #expect(!(await model.setVersion("2.2.1")))
        #expect(model.versionChange == nil)
        #expect(await model.setVersion("2.1.0"))
        #expect(model.instance?.agentVersion == "2.1.0")
        #expect(model.versionOptions.map(\.change) == [.upgrade, .upgrade, .current])
        #expect(model.versionChange?.from == "2.2.1")
    }

    @Test("换版本失败：记下错误，版本不变")
    func versionFails() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        await model.load()
        mock.failNext(with: .api(status: 422, code: .invalid, message: "not available", retryAfterSecs: nil))
        #expect(!(await model.setVersion("2.1.0")))
        #expect(model.versionError?.isInvalidInput == true)
        #expect(model.instance?.agentVersion == "2.2.1")
        #expect(await model.setVersion("2.1.0"))
        #expect(model.versionError == nil)
    }

    @Test("现在的版本不在目录里（下架了）：建议升级，别的版本只是切换")
    func unlistedVersion() async {
        let mock = AgentsFixture.mock { s in
            if let i = s.instances.firstIndex(where: { $0.id == DemoData.reviewerID }) {
                s.instances[i].agentVersion = "1.9.0"
            }
        }
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        await model.load()
        #expect(!model.isCurrentVersionListed)
        #expect(model.upgradeAvailable)
        #expect(model.versionOptions.map(\.change) == [.upgrade, .switchTo, .switchTo])
    }

    @Test("改名：去掉首尾空白；名字不对不发请求；没变直接成功")
    func rename() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        #expect(await model.rename(to: "  周报助手 "))
        #expect(model.instance?.name == "周报助手")
        #expect(mock.state.instances.first { $0.id == DemoData.writerID }?.name == "周报助手")
        #expect(!(await model.rename(to: "  ")))
        #expect(!(await model.rename(to: String(repeating: "名", count: 65))))
        #expect(await model.rename(to: "周报助手"))
        #expect(model.renameError == nil)
    }

    @Test("改名失败：记下错误，清掉后再试")
    func renameFails() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        #expect(!(await model.rename(to: "新名字")))
        #expect(model.renameError?.isOffline == true)
        #expect(model.instance?.name == "写作助手")
        model.clearRenameError()
        #expect(model.renameError == nil)
    }

    @Test("实例不存在了：标成不存在，不再拉别的")
    func missing() async {
        let model = InstanceDetailModel(client: AgentsFixture.mock(), instanceID: "gone")
        await model.load()
        #expect(model.isMissing)
        #expect(model.error == nil)
        #expect(model.hasLoaded)
        #expect(model.agent == nil && model.routes == nil)
        #expect(model.agentDisplayName == "")
    }

    @Test("离线：照样显示已有的实例，记下网络错误")
    func offline() async {
        let mock = AgentsFixture.mock()
        let reviewer = mock.state.instances[1]
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID, instance: reviewer)
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.instance?.name == "代码审查")
        #expect(model.error?.isOffline == true)
        #expect(!model.isMissing)
        #expect(model.hasLoaded)
    }

    @Test("没传实例时先读缓存，网络的结果回来之前就能显示")
    func cacheFirst() async {
        let mock = MockClient(state: DemoData.state(), latency: 0.3, stepDelay: 0, autoReply: false)
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        let loading = Task { await model.load() }
        #expect(await eventually { model.instance != nil })
        #expect(model.isLoading)
        #expect(model.instance?.name == "代码审查")
        await loading.value
        #expect(model.agent?.id == DemoData.codexAgentID)
    }

    @Test("路由的几种情况：没配、缺 main")
    func routeStatus() async {
        let none = InstanceDetailModel(
            client: AgentsFixture.mock { $0.routes[DemoData.writerID] = [] }, instanceID: DemoData.writerID)
        #expect(none.routeStatus == .unknown)
        #expect(!none.routeStatus.needsAttention)
        await none.load()
        #expect(none.routeStatus == .notConfigured)
        #expect(none.routeStatus.needsAttention)

        let fastOnly = InstanceDetailModel(
            client: AgentsFixture.mock {
                $0.routes[DemoData.writerID] = [
                    ModelRoute(
                        alias: "fast", credentialID: DemoData.claudeCredentialID, upstreamModel: "claude-haiku-5-5")
                ]
            }, instanceID: DemoData.writerID)
        await fastOnly.load()
        #expect(fastOnly.routeStatus == .missingMain(aliases: 1))
        #expect(fastOnly.routeStatus.needsAttention)
        #expect(fastOnly.routeStatus.summary(.english).contains("main"))
    }
}
