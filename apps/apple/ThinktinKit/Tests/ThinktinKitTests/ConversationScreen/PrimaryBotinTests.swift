import Foundation
import Testing

@testable import ThinktinKit

private func instance(_ id: String, _ name: String, state: InstanceState = .running) -> Instance {
    Instance(
        id: InstanceID(id), agentID: DemoData.claudeAgentID, agentVersion: "1.0.0", harness: "acp", name: name,
        state: state, createdAt: Date(timeIntervalSince1970: 0), lastActiveAt: Date(timeIntervalSince1970: 0))
}

@MainActor
@Suite("主 Botin（参考 10、11）")
struct PrimaryBotinTests {
    @Test("存在这台设备上：换、清掉、删了 Botin 时清掉；换一个实例读得回来")
    func store() {
        let name = "PrimaryBotinTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PrimaryBotinStore(defaults: defaults)
        #expect(store.primaryID == nil)
        store.set("a")
        #expect(PrimaryBotinStore(defaults: defaults).primaryID == "a")
        store.forget(instanceID: "b")
        #expect(store.primaryID == "a", "删的不是主 Botin，不动")
        store.forget(instanceID: "a")
        #expect(store.primaryID == nil)
        #expect(PrimaryBotinStore(defaults: defaults).primaryID == nil)
        let memory = PrimaryBotinStore(defaults: nil)
        memory.set("x")
        #expect(memory.primaryID == "x")
        #expect(memory.primary(in: [instance("x", "写作助手")])?.name == "写作助手")
        #expect(memory.primary(in: [instance("x", "写作助手", state: .deleted)]) == nil)
        #expect(memory.primary(in: []) == nil)
    }

    @Test("能选的：不列现在的主 Botin 和删掉的，按名字排、按名字搜；一个都没有时是空状态")
    func candidates() {
        let list = [
            instance("c", "代码审查"), instance("w", "写作助手"), instance("d", "旧的", state: .deleted),
            instance("r", "Research"),
        ]
        #expect(PrimaryBotinPicker.candidates(list, primaryID: nil, query: "").map(\.id) == ["r", "c", "w"])
        #expect(PrimaryBotinPicker.candidates(list, primaryID: "w", query: "").map(\.id) == ["r", "c"])
        #expect(PrimaryBotinPicker.candidates(list, primaryID: nil, query: " research ").map(\.id) == ["r"])
        #expect(PrimaryBotinPicker.candidates(list, primaryID: nil, query: "助手").map(\.id) == ["w"])
        #expect(PrimaryBotinPicker.candidates(list, primaryID: nil, query: "没有").isEmpty)
        #expect(!PrimaryBotinPicker.hasNoOthers(list, primaryID: "w"))
        #expect(PrimaryBotinPicker.hasNoOthers([instance("w", "写作助手")], primaryID: "w"), "只有主 Botin 自己（参考 11）")
        #expect(PrimaryBotinPicker.hasNoOthers([], primaryID: nil))
        #expect(PrimaryBotinPicker.canConfirm(selection: "c", primaryID: "w"))
        #expect(!PrimaryBotinPicker.canConfirm(selection: nil, primaryID: "w"))
        #expect(!PrimaryBotinPicker.canConfirm(selection: "w", primaryID: "w"))
    }

    @Test("文案：参考 11 的空状态、搜索、确认；资料页菜单里是“替换主 Botin…”")
    func text() {
        #expect(ConversationText.noOtherBotins(.chinese) == "暂无其他可选的 Botin")
        #expect(ConversationText.searchBotins(.chinese) == "搜索 Botin")
        #expect(ConversationText.confirm(.english) == "Confirm")
        #expect(ConversationText.replacePrimaryBotin(hasPrimary: false, language: .chinese) == "设置主 Botin…")
        #expect(InstanceProfileMenuItem.open(.primaryBotin).title(.chinese) == "替换主 Botin…")
        #expect(InstanceProfileMenuItem.open(.primaryBotin).systemImage == "arrow.left.arrow.right")
        #expect(!InstanceProfileMenuItem.open(.primaryBotin).needsConnection)
        let note = ConversationText.primaryBotinNote(current: "写作助手", language: .chinese)
        #expect(note.hasPrefix("现在的主 Botin 是 写作助手。") && note.contains("这台设备"))
        #expect(!ConversationText.primaryBotinNote(current: nil, language: .english).contains("Your main Botin is"))
    }
}
