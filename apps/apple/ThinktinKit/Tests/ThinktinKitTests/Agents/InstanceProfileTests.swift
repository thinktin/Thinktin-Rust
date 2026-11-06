import Foundation
import Testing

@testable import ThinktinKit

// Botin 资料、编辑、头像、工作区（规范 4.4.1–4.4.4、4.6.1）：行上的值、“…”菜单、工作区的重置和磁盘空间、改头像。

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
        // 等确认的不算生效，值上也不另外提（参考 09 只有数）。
        #expect(plans.contains { $0.awaitingConfirmation })
        #expect(InstanceProfileText.plansValue(active: 0, language: .chinese) == "0 个生效")
        #expect(InstanceProfileText.plansValue(active: 2, language: .chinese) == "2 个生效")
        #expect(InstanceProfileText.plansValue(active: 3, language: .english) == "3 active")
    }

    @Test("“…”菜单（参考 10）：一组两项，替换主 Botin…、复制 ID；没有模型路由、新建计划、删除")
    func menu() {
        let sections = InstanceProfileMenu.sections(instanceID: DemoData.writerID)
        #expect(sections == [[.open(.primaryBotin), .copyID]])
        let items = sections.flatMap { $0 }
        // 每一项都有自己的图标（不是兜底的箭头）和字。
        #expect(items.allSatisfy { $0.systemImage != "chevron.right" })
        #expect(items.map { $0.title(.chinese) } == ["替换主 Botin…", "复制 Botin ID"])
        #expect(items.map { $0.title(.english) } == ["Replace Main Botin…", "Copy Botin ID"])
    }

    @Test("资料页的“通知”和工作区的重置、磁盘空间：自己的说法，还没有接口的写即将推出")
    func comingSoonRows() {
        #expect(InstanceProfileText.notifications(.chinese) == "通知")
        #expect(InstanceProfileText.notificationsFooter(.chinese).contains("即将推出"))
        #expect(!InstanceProfileText.notificationsFooter(.chinese).contains("Bot "))
        #expect(InstanceWorkspaceText.reset(.chinese) == "重置工作区")
        #expect(InstanceWorkspaceText.resetDetail(.english).hasSuffix("lost."))
        #expect(InstanceWorkspaceText.diskSpace(.chinese) == "磁盘空间")
        #expect(InstanceWorkspaceText.comingSoon(.chinese) == "即将推出")
        #expect(InstanceWorkspaceText.resetComingSoonMessage(.chinese).contains("不受影响"))
    }

    @Test("改头像：从记下的开始；改了才算改过；重置回默认；完成时记下，默认的删掉记录")
    func appearanceEditor() {
        let store = InstanceAppearanceStore(defaults: nil)
        let editor = InstanceAppearanceEditor(instanceID: DemoData.writerID, name: "写作助手", store: store)
        #expect(editor.appearance == .default && editor.isDefault && !editor.hasChanges)
        #expect(editor.resolvedColor == AvatarColor.forName("写作助手"))
        editor.shape = .cloud
        editor.color = .mint
        #expect(editor.hasChanges && !editor.isDefault)
        #expect(editor.resolvedColor == .mint)
        editor.save()
        #expect(store.appearance(for: DemoData.writerID) == InstanceAppearance(shape: .cloud, color: .mint))

        // 再打开：从记下的开始。
        let again = InstanceAppearanceEditor(instanceID: DemoData.writerID, name: "写作助手", store: store)
        #expect(again.shape == .cloud && again.color == .mint && !again.hasChanges)
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
