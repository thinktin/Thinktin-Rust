import Foundation
import Testing

@testable import ThinktinKit

// 模型 key 列表、添加 key。

@MainActor
@Suite("模型 key 列表")
struct CredentialsModelTests {
    @Test("加载：在用的和停用的分开，一行显示厂商、备注、后 4 位、上限、协议")
    func load() async throws {
        let model = CredentialsModel(client: ModelsFixture.mock())
        #expect(!model.hasLoaded)
        await model.load()
        #expect(model.hasLoaded && model.error == nil && !model.isEmpty)
        #expect(model.activeCredentials.map(\.id) == [DemoData.claudeCredentialID, DemoData.deepseekCredentialID])
        #expect(model.disabledCredentials.map(\.id) == [DemoData.qwenCredentialID])

        let claude = model.summary(of: model.activeCredentials[0], language: .chinese)
        #expect(claude.name == "Claude 主力")
        #expect(claude.vendorName == "Anthropic (Claude)")
        #expect(claude.subtitle == "Anthropic (Claude) · ••••Q7mA")
        #expect(claude.monogram == "A")
        #expect(claude.dailyLimit == "每天最多 200 万 tokens")
        #expect(claude.protocols == "Anthropic Messages、OpenAI Chat Completions")
        #expect(claude.statusName == "使用中")
        #expect(claude.accessibilityLabel(.chinese).contains("尾号 Q 7 m A"))

        // 备注就是厂商名时副标题不重复。
        let deepseek = model.summary(of: model.activeCredentials[1], language: .english)
        #expect(deepseek.subtitle == "••••x9Lk")
        #expect(deepseek.dailyLimit == "No limit")

        let qwen = model.summary(of: model.disabledCredentials[0], language: .chinese)
        #expect(qwen.isDisabled && qwen.statusName == "已停用")
    }

    @Test("没有 key：空状态")
    func empty() async {
        let model = CredentialsModel(client: ModelsFixture.mock { $0.credentials = [] })
        await model.load()
        #expect(model.isEmpty)
    }

    @Test("拉不到时留着上次的；厂商表拉不到不影响列表")
    func failures() async {
        let mock = ModelsFixture.mock()
        let model = CredentialsModel(client: mock)
        await model.load()
        // key 列表和厂商表并发拉，两个都失败。
        mock.failNext(with: .network(message: "offline"))
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.error == .network(message: "offline"))
        #expect(model.credentials.count == 3)

        // 厂商表里没有它（下架了、没拉到）：厂商名退回成 id。
        let fresh = CredentialsModel(client: mock)
        mock.update { $0.vendors = [] }
        await fresh.load()
        #expect(fresh.error == nil)
        let summary = fresh.summary(of: fresh.credentials[0], language: .chinese)
        #expect(summary.vendorName == "anthropic")
    }
}

@MainActor
@Suite("添加模型 key")
struct AddCredentialModelTests {
    private func make(
        _ mock: MockClient = ModelsFixture.mock(), target: AgentID? = nil, name: String = #function
    ) -> (MockClient, AddCredentialModel, ThirdPartyAIConsentStore) {
        let consent = ModelsFixture.consent(name)
        return (mock, AddCredentialModel(client: mock, targetAgentID: target, consent: consent), consent)
    }

    @Test("选厂商：显示协议、推荐模型和说明")
    func vendorDetails() async {
        let (_, model, _) = make()
        await model.load()
        #expect(model.hasLoadedVendors && model.vendors.count == 4)
        #expect(model.choice == nil && model.selectedVendor == nil)
        model.choice = .preset("qwen-cn")
        #expect(model.selectedVendor?.name == "阿里云百炼（北京）")
        #expect(model.recommendedModels == ["qwen3.8-max", "qwen3.8-flash"])
        #expect(model.vendorNotes?.contains("Token Plan") == true)
        #expect(model.expectedProtocols == [.anthropic, .chat, .responses])
        #expect(model.vendorName(.chinese) == "阿里云百炼（北京）")
        model.choice = .preset("openai")
        #expect(model.vendorNotes == nil)
        #expect(model.expectedProtocols == [.chat, .responses])
    }

    @Test("问题：空字段要点过保存才显示，格式不对的边输边显示；要勾同意")
    func validation() async {
        let (_, model, _) = make()
        await model.load()
        #expect(!model.canSubmit)
        #expect(model.problem(for: .vendor) == nil)
        #expect(model.problem(for: .apiKey) == nil)
        model.apiKey = "sk 123"
        #expect(model.problem(for: .apiKey) == .invalidCharacters)
        model.dailyLimit = "0"
        #expect(model.problem(for: .dailyLimit) == .notPositiveInteger)

        #expect(await model.submit() == nil)
        #expect(model.didAttemptSubmit)
        #expect(model.problem(for: .vendor) == .required)
        #expect(model.problem(for: .consent) == .required)

        model.choice = .preset("deepseek")
        model.apiKey = "  sk-deepseek-0123456789\n"
        model.dailyLimit = "500,000"
        model.hasConsented = true
        #expect(model.problems.isEmpty)
        #expect(model.canSubmit)
        #expect(model.draft.apiKey == "sk-deepseek-0123456789")
        #expect(model.draft.dailyTokenLimit == 500_000)
        #expect(model.draft.anthropicBase == nil)

        // 换了厂商要重新同意（同意是对某个厂商说的）。
        model.choice = .preset("openai")
        #expect(!model.hasConsented)
        #expect(!model.canSubmit)
    }

    @Test("保存：加进列表，记下对这个厂商的同意，清掉输入的 key")
    func submit() async throws {
        let (mock, model, consent) = make()
        await model.load()
        model.choice = .preset("openai")
        model.label = "  OpenAI 备用 "
        model.apiKey = "sk-proj-0123456789abcd"
        model.hasConsented = true
        let created = try #require(await model.submit())
        #expect(created.vendor == "openai")
        #expect(created.label == "OpenAI 备用")
        #expect(created.last4 == "abcd")
        #expect(created.protocols == [.chat, .responses])
        #expect(model.created == created)
        #expect(model.apiKey.isEmpty)
        #expect(!model.canSubmit)
        #expect(mock.state.credentials.contains { $0.id == created.id })
        #expect(consent.hasConsented(to: "openai"))
        #expect(!consent.hasConsented(to: "deepseek"))
        let message = model.createdMessage(.chinese)
        #expect(message.contains("OpenAI Chat Completions、OpenAI Responses") && message.contains("自动接着跑"))
    }

    @Test("自定义地址：至少填一个 https 地址；协议按填了哪几个算；同意按这把 key 记")
    func custom() async throws {
        let (mock, model, consent) = make()
        await model.load()
        model.choice = .custom
        model.apiKey = "gw-0123456789"
        model.hasConsented = true
        #expect(model.problems[.endpoint(.anthropic)] == .required)
        model.openaiBase = "http://gateway.example.com/v1"
        #expect(model.problem(for: .endpoint(.openai)) == .notHTTPS)
        #expect(model.problems[.endpoint(.anthropic)] == nil)
        model.openaiBase = ""
        model.anthropicBase = "https://gateway.example.com/anthropic"
        model.responsesBase = " https://gateway.example.com/v1 "
        #expect(model.problems.isEmpty)
        #expect(model.expectedProtocols == [.anthropic, .responses])
        #expect(model.vendorName(.chinese) == "gateway.example.com")
        #expect(model.draft.responsesBase == "https://gateway.example.com/v1")
        #expect(model.draft.openaiBase == nil)
        let created = try #require(await model.submit())
        #expect(created.vendor == NewCredential.customVendor)
        #expect(created.protocols == [.anthropic, .responses])
        #expect(mock.state.credentials.last?.id == created.id)
        #expect(consent.hasConsented(to: "custom:\(created.id.rawValue)"))
        #expect(!consent.hasConsented(to: NewCredential.customVendor))

        // 选回预置厂商时不带地址。
        let (_, other, _) = make(name: "custom-preset")
        await other.load()
        other.choice = .preset("deepseek")
        other.anthropicBase = "https://gateway.example.com/anthropic"
        #expect(other.draft.anthropicBase == nil)
        #expect(other.problems[.endpoint(.anthropic)] == nil)
    }

    @Test("订阅类 key 被拒：显示原因，改了 key 后原因消失")
    func subscriptionRejected() async {
        let (mock, model, consent) = make()
        await model.load()
        model.choice = .preset("anthropic")
        model.apiKey = "sk-ant-oat01-0123456789"
        model.hasConsented = true
        mock.failNext(
            with: .api(
                status: 422, code: .invalid,
                message: "Anthropic (Claude) subscription keys (sk-ant-oat...) can only be used in the vendor's own "
                    + "tools; use a pay-as-you-go API key", retryAfterSecs: nil))
        #expect(await model.submit() == nil)
        #expect(model.rejection == .subscriptionKey)
        #expect(model.error == nil)
        #expect(model.created == nil)
        #expect(!consent.hasConsented(to: "anthropic"))
        #expect(
            model.rejection?.message(vendorName: model.vendorName(.chinese), language: .chinese).contains(
                "Anthropic (Claude) 的订阅类 key") == true)
        model.apiKey = "sk-ant-api03-0123456789"
        #expect(model.rejection == nil)
    }

    @Test("别的错误（网络）照常显示，可以重试")
    func networkError() async throws {
        let (mock, model, _) = make()
        await model.load()
        model.choice = .preset("deepseek")
        model.apiKey = "sk-0123456789"
        model.hasConsented = true
        mock.failNext(with: .network(message: "timed out"))
        #expect(await model.submit() == nil)
        #expect(model.error == .network(message: "timed out"))
        #expect(model.rejection == nil)
        _ = try #require(await model.submit())
        #expect(model.error == nil)
    }

    @Test("从实例的路由页过来：提示这把 key 能不能给它的 agent 用")
    func compatibility() async {
        let (_, model, _) = make(target: DemoData.codexAgentID)
        await model.load()
        #expect(model.targetAgent?.id == DemoData.codexAgentID)
        #expect(model.compatibility == nil)
        model.choice = .preset("anthropic")
        #expect(model.compatibility == .incompatible(agentName: "Codex", required: .responses))
        #expect(model.compatibility?.message(.chinese).contains("OpenAI Responses") == true)
        model.choice = .preset("deepseek")
        #expect(model.compatibility == .compatible(agentName: "Codex"))
        #expect(model.compatibility?.isCompatible == true)
        model.choice = .custom
        #expect(model.compatibility == nil)
        model.anthropicBase = "https://gateway.example.com/anthropic"
        #expect(model.compatibility?.isCompatible == false)
    }

    @Test("厂商表拉不到：显示错误")
    func vendorsFailed() async {
        let (mock, model, _) = make()
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.vendorsError == .network(message: "offline"))
        #expect(!model.hasLoadedVendors)
        await model.load()
        #expect(model.vendorsError == nil && model.hasLoadedVendors)
    }
}
