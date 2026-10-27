import Foundation
import Testing

@testable import ThinktinKit

// 开源许可页的视图模型（WBS 12.12）：清单在本机读、agent 的许可证联网拉、搜索同时过滤三节、原文页。

@MainActor
@Suite("开源许可页")
struct LicensesModelTests {
    @Test("加载：清单和 agent 列表；说明里有组件数和许可证数")
    func load() async throws {
        let directory = try SettingsFixture.inventoryDirectory()
        defer { SettingsFixture.remove(directory) }
        let mock = makeShellMock()
        let model = LicensesModel(client: mock, directory: directory)
        #expect(model.inventoryState == .loading)
        await model.load()
        #expect(model.inventory?.components.count == 7)
        #expect(model.groups.count == 4)
        #expect(model.hasLoadedAgents)
        #expect(model.agentsError == nil)
        #expect(model.inventorySummary(.chinese) == "7 个第三方组件，4 种许可证。点开组件看许可证原文。")
        #expect(model.inventorySummary(.english)?.hasPrefix("7 third-party components under 4 licenses.") == true)
        #expect(model.noticesPath == "NOTICES.md")

        // agent：商标规则下的名字、许可证的显示名、许可说明、上游地址。
        let entries = model.agentEntries(.chinese)
        #expect(entries.map(\.id) == DemoData.agents.map(\.id))
        let claude = try #require(entries.first { $0.id == AgentsText.claudeAgentID })
        #expect(claude.name == "Claude Agent")
        #expect(claude.isProprietary)
        #expect(claude.spdx == "LicenseRef-Anthropic-Commercial")
        #expect(claude.licenseName == AgentsText.licenseName("LicenseRef-Anthropic-Commercial", language: .chinese))
        #expect(claude.note?.contains("Apache-2.0") == true)
        #expect(claude.upstreamURL?.host == "github.com")
        #expect(claude.byline != nil)
        let codex = try #require(entries.first { $0.id == AgentsText.codexAgentID })
        #expect(codex.licenseName == "Apache-2.0")
        #expect(codex.note == nil)
        #expect(!codex.isProprietary)

        // 读过的不再读（目录删了也还在）。
        SettingsFixture.remove(directory)
        await model.loadInventory()
        #expect(model.inventory != nil)
    }

    @Test("搜索同时过滤 agent、Swift 包和客户端核心的组件")
    func search() async throws {
        let directory = try SettingsFixture.inventoryDirectory()
        defer { SettingsFixture.remove(directory) }
        let model = LicensesModel(client: makeShellMock(), directory: directory)
        await model.load()
        #expect(!model.isSearching)

        model.query = "apache"
        #expect(model.isSearching)
        #expect(model.agentEntries(.chinese).map(\.id) == [AgentsText.codexAgentID])
        #expect(model.groups.map(\.license) == ["Apache-2.0 OR MIT", "Apache-2.0 AND ISC"])
        #expect(!model.hasNoResults(.chinese))

        model.query = "claude"
        #expect(model.agentEntries(.english).map(\.id) == [AgentsText.claudeAgentID])
        #expect(model.groups.isEmpty)

        model.query = "no-such-thing"
        #expect(model.hasNoResults(.chinese))
        #expect(model.swiftPackages.isEmpty)

        model.query = ""
        #expect(model.agentEntries(.chinese).count == DemoData.agents.count)
        #expect(!model.hasNoResults(.chinese))
    }

    @Test("App 里没带清单、清单坏了：只有那一节显示提示")
    func inventoryFailures() async throws {
        let none = LicensesModel(client: makeShellMock(), directory: nil)
        await none.load()
        #expect(none.inventoryState == .failed(.notBundled))
        #expect(none.inventory == nil)
        #expect(none.groups.isEmpty)
        #expect(none.inventorySummary(.chinese) == nil)
        #expect(none.noticesPath == nil)
        #expect(none.hasLoadedAgents)

        let directory = try SettingsFixture.temporaryDirectory()
        defer { SettingsFixture.remove(directory) }
        let missing = LicensesModel(client: makeShellMock(), directory: directory)
        await missing.loadInventory()
        #expect(missing.inventoryState == .failed(.unreadable("inventory.json")))

        try SettingsFixture.write("[1, 2]", to: "inventory.json", in: directory)
        let broken = LicensesModel(client: makeShellMock(), directory: directory)
        await broken.loadInventory()
        guard case .failed(.malformed) = broken.inventoryState else {
            Issue.record("expected malformed, got \(broken.inventoryState)")
            return
        }
    }

    @Test("离线：agent 那一节报网络错误，清单照样显示；联网后重拉")
    func agentsOffline() async throws {
        let directory = try SettingsFixture.inventoryDirectory()
        defer { SettingsFixture.remove(directory) }
        let mock = makeShellMock()
        let model = LicensesModel(client: mock, directory: directory)
        await model.loadInventory()
        mock.failNext(with: .network(message: "offline"))
        await model.loadAgents()
        #expect(model.agentsError?.isOffline == true)
        #expect(!model.hasLoadedAgents)
        #expect(model.agents.isEmpty)
        #expect(model.inventory != nil)

        await model.loadAgents()
        #expect(model.agentsError == nil)
        #expect(model.agents.count == DemoData.agents.count)
    }

    @Test("原文页：在后台读、分段；读不到的报错；全文给复制用")
    func textModel() async throws {
        let directory = try SettingsFixture.inventoryDirectory()
        defer { SettingsFixture.remove(directory) }
        let text = LicenseTextModel(path: "texts/by-hash/bbbb/LICENSE-APACHE", directory: directory)
        #expect(text.state == .loading)
        #expect(text.fullText == nil)
        await text.load()
        #expect(text.state == .loaded(paragraphs: ["Apache License\nVersion 2.0, January 2004", "   1. Definitions."]))
        #expect(text.fullText == "Apache License\nVersion 2.0, January 2004\n\n   1. Definitions.")

        let notices = LicenseTextModel(path: LicenseInventory.noticesFileName, directory: directory)
        await notices.load()
        guard case .loaded(let paragraphs) = notices.state else {
            Issue.record("NOTICES.md not loaded: \(notices.state)")
            return
        }
        #expect(paragraphs.first == "# 第三方组件许可证")

        let missing = LicenseTextModel(path: "texts/none", directory: directory)
        await missing.load()
        #expect(missing.state == .failed(.unreadable("texts/none")))

        let unsafe = LicenseTextModel(path: "../outside", directory: directory)
        await unsafe.load()
        #expect(unsafe.state == .failed(.invalidPath("../outside")))

        let unbundled = LicenseTextModel(path: "NOTICES.md", directory: nil)
        await unbundled.load()
        #expect(unbundled.state == .failed(.notBundled))
    }

    @Test("说明文字中英文都有")
    func texts() {
        for language in DisplayLanguage.allCases {
            #expect(!LicensesModel.intro(language).isEmpty)
            #expect(!LicensesModel.noSwiftPackagesMessage(language).isEmpty)
            #expect(!LicensesModel.agentsFootnote(language).isEmpty)
        }
        #expect(LicensesModel.noSwiftPackagesMessage(.chinese).contains("Swift"))
    }
}
