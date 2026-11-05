import Foundation
import Testing

@testable import ThinktinKit

// Botin 资料、编辑、头像、工作区（规范 4.4.1–4.4.4、4.6.1）：行上的值、“…”菜单、工作区的版本操作和说明、改头像。

@MainActor
@Suite("Botin 资料、编辑、工作区")
struct InstanceProfileTests {
    @Test("计划那一行：生效的数（不算暂停的、等确认的），没拉到时没有值")
    func planCount() async {
        let mock = AgentsFixture.mock { state in
            state.plans.append(
                Plan(
                    id: "paused", instanceID: DemoData.writerID, title: "暂停的", goal: "g", isPaused: true,
                    createdBy: .user, createdAt: Fixture.now))
            state.plans.append(
                Plan(
                    id: "awaiting", instanceID: DemoData.writerID, title: "等确认", goal: "g", createdBy: .agent,
                    awaitingConfirmation: true, createdAt: Fixture.now))
        }
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        #expect(model.activePlanCount == nil)
        await model.load()
        let plans = model.plans ?? []
        let active = plans.filter { !$0.isPaused && !$0.awaitingConfirmation }.count
        #expect(active >= 1)
        #expect(model.activePlanCount == active)
        #expect(model.plansAwaitingConfirmation == 1)
        #expect(InstanceProfileText.plansValue(active: 0, language: .chinese) == "0 个生效")
        #expect(InstanceProfileText.plansValue(active: 2, awaiting: 1, language: .chinese) == "2 个生效 · 1 个待确认")
        #expect(InstanceProfileText.plansValue(active: 3, language: .english) == "3 active")
    }

    @Test("默认模型那一行：main 的上游模型；没配写“未配置”；没拉到不写")
    func defaultModel() async {
        #expect(InstanceRouteStatus.unknown.defaultModelValue(.chinese) == nil)
        #expect(InstanceRouteStatus.notConfigured.defaultModelValue(.chinese) == "未配置")
        #expect(InstanceRouteStatus.missingMain(aliases: 1).defaultModelValue(.english) == "Not set")
        let model = InstanceDetailModel(client: AgentsFixture.mock(), instanceID: DemoData.writerID)
        await model.load()
        #expect(model.routeStatus.defaultModelValue(.chinese) == "claude-sonnet-5-5")
    }

    @Test("“…”菜单：复制 ID；模型路由、新建计划；最后删除（标红）；离线时只有复制和路由能用")
    func menu() {
        let sections = InstanceProfileMenu.sections(instanceID: DemoData.writerID)
        #expect(
            sections == [
                [.copyID],
                [.open(.modelRoutes(DemoData.writerID)), .open(.newPlan(instanceID: DemoData.writerID))],
                [.delete],
            ])
        let items = sections.flatMap { $0 }
        #expect(items.filter(\.isDestructive) == [.delete])
        #expect(items.filter { !$0.needsConnection } == [.copyID, .open(.modelRoutes(DemoData.writerID))])
        // 每一项都有自己的图标（不是兜底的箭头）和字。
        #expect(items.allSatisfy { $0.systemImage != "chevron.right" })
        #expect(items.map { $0.title(.chinese) }.first == "复制 Botin ID")
        #expect(InstanceProfileMenuItem.delete.title(.english) == "Delete this Botin")
    }

    @Test("工作区：最新版本时没有“升级到”，版本菜单列出全部；落后时最上面是升级到最新")
    func workspaceVersions() async {
        let latest = InstanceDetailModel(client: AgentsFixture.mock(), instanceID: DemoData.writerID)
        await latest.load()
        #expect(latest.upgradeOption == nil)
        #expect(latest.switchableVersions.map(\.change) == [.current, .rollback])
        #expect(!latest.needsDelistedVersionPlaceholder)

        let behind = InstanceDetailModel(client: AgentsFixture.mock(), instanceID: DemoData.reviewerID)
        await behind.load()
        let upgrade = behind.upgradeOption
        #expect(upgrade?.version == "2.2.2")
        #expect(upgrade?.actionTitle(.chinese) == "升级到 v2.2.2")
        #expect(behind.switchableVersions.contains { $0.isCurrent })

        // 目录里只有一个版本：不出菜单。
        let single = InstanceDetailModel(
            client: AgentsFixture.mock { state in
                if let i = state.agents.firstIndex(where: { $0.id == DemoData.claudeAgentID }) {
                    state.agents[i].versions = [state.agents[i].version]
                }
                if let i = state.instances.firstIndex(where: { $0.id == DemoData.writerID }) {
                    state.instances[i].agentVersion = state.agents.first { $0.id == DemoData.claudeAgentID }!.version
                }
            }, instanceID: DemoData.writerID)
        await single.load()
        #expect(single.switchableVersions.isEmpty)
        #expect(single.upgradeOption == nil)
    }

    @Test("工作区：现在的版本下架了，最上面照样是升级到最新")
    func workspaceUnlisted() async {
        let mock = AgentsFixture.mock { state in
            if let i = state.instances.firstIndex(where: { $0.id == DemoData.writerID }) {
                state.instances[i].agentVersion = "1.9.0"
            }
        }
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        #expect(!model.isCurrentVersionListed)
        // 版本菜单里补一项现在用的（已下架），选中值才有对应的项。
        #expect(model.needsDelistedVersionPlaceholder)
        #expect(!model.switchableVersions.contains { $0.version == "1.9.0" })
        #expect(InstanceWorkspaceText.delistedVersion("1.9.0", language: .chinese) == "v1.9.0（已下架）")
        #expect(model.upgradeOption?.isLatest == true)
        #expect(model.upgradeOption?.change == .upgrade)
        #expect(
            InstanceWorkspaceText.unlistedVersion(current: "1.9.0", latest: "2.2.2", language: .chinese)
                == "现在用的 v1.9.0 已经不在目录里了，建议升级到 v2.2.2。")
    }

    @Test("工作区说明：状态一组（四种，用界面给的名字和状态说明）、版本一组")
    func workspaceHelp() {
        let sections = WorkspaceHelp.sections(.chinese) { "名字-\($0.rawValue)" }
        #expect(sections.map(\.title) == ["状态", "版本"])
        #expect(sections[0].items.map(\.title) == ["名字-provisioning", "名字-running", "名字-paused", "名字-archived"])
        #expect(sections[0].items[2].detail == AgentsText.stateExplanation(.paused, language: .chinese))
        #expect(sections[1].items.count == 3)
        // id 不重复（`ForEach` 用）。
        for section in sections {
            #expect(Set(section.items.map(\.id)).count == section.items.count)
        }
        #expect(WorkspaceHelp.sections(.english) { _ in "x" }[1].items[0].title == "Upgrade")
    }

    @Test("改头像：从记下的开始；改了才算改过；重置回默认；完成时记下，默认的删掉记录")
    func appearanceEditor() {
        let store = InstanceAppearanceStore(defaults: nil)
        let editor = InstanceAppearanceEditor(instanceID: DemoData.writerID, name: "写作助手", store: store)
        #expect(editor.appearance == .default && editor.isDefault && !editor.hasChanges)
        #expect(editor.resolvedColor == AvatarColor.forName("写作助手"))
        editor.shape = .cloud
        editor.color = .teal
        #expect(editor.hasChanges && !editor.isDefault)
        #expect(editor.resolvedColor == .teal)
        editor.save()
        #expect(store.appearance(for: DemoData.writerID) == InstanceAppearance(shape: .cloud, color: .teal))

        // 再打开：从记下的开始。
        let again = InstanceAppearanceEditor(instanceID: DemoData.writerID, name: "写作助手", store: store)
        #expect(again.shape == .cloud && again.color == .teal && !again.hasChanges)
        again.reset()
        #expect(again.isDefault && again.hasChanges)
        again.save()
        #expect(store.appearance(for: DemoData.writerID) == nil)
        #expect(store.resolved(for: DemoData.writerID) == .default)
    }

    @Test("引擎目录的行：灰字、右边的小胶囊和读屏")
    func catalogRow() {
        let claude = AgentCatalogCard(agent: DemoData.agents[0], adoptedCount: 1, language: .chinese)
        #expect(claude.isAvailable)
        #expect(claude.rowSubtitle == claude.summary || claude.summary.isEmpty)
        #expect(claude.actionTitle(.chinese) == "选这个")
        #expect(claude.actionAccessibilityLabel(.chinese) == "用 Claude Agent 新建 Botin")
        // 没给接入方式的不能用。
        let broken = AgentCatalogCard(
            agent: AgentInfo(id: "broken", name: "Broken", version: "1.0.0", harnesses: [], defaultHarness: "acp"))
        #expect(!broken.isAvailable)
        #expect(broken.actionTitle(.english) == "Unavailable")
        // 没有介绍时用出处。
        var bare = DemoData.agents[0]
        bare.description = ""
        let fallback = AgentCatalogCard(agent: bare, language: .chinese)
        #expect(fallback.rowSubtitle == AgentsText.byline(of: bare.id, language: .chinese))
    }
}
