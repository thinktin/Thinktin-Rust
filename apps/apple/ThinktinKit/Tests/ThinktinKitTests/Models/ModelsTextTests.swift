import Foundation
import Testing

@testable import ThinktinKit

// 模型 key 的文案、本地校验规则、服务端拒收原因的识别、别名规则、同意记录。

@Suite("模型 key：文案与规则")
struct ModelsTextTests {
    @Test("这几页没有 agent 写的字段，不带 AI 生成标识")
    func aiLabelRule() {
        #expect(!ModelsText.showsAIGeneratedLabel)
    }

    @Test("厂商名：预置的用厂商表、自定义地址、认不出的用 id")
    func vendorNames() {
        let vendors = DemoData.vendors
        #expect(ModelsText.vendorName("anthropic", vendors: vendors, language: .chinese) == "Anthropic (Claude)")
        #expect(ModelsText.vendorName("custom", vendors: vendors, language: .chinese) == "自定义地址")
        #expect(ModelsText.vendorName("custom", vendors: vendors, language: .english) == "Custom endpoint")
        #expect(ModelsText.vendorName("retired", vendors: vendors, language: .chinese) == "retired")
        let unnamed = Credential(id: "c1", vendor: "deepseek", label: "  ", last4: "abcd", createdAt: Date())
        #expect(ModelsText.credentialName(unnamed, vendors: vendors) == "DeepSeek")
        #expect(ModelsText.credentialMenuTitle(unnamed, vendors: vendors) == "DeepSeek · ••••abcd")
    }

    @Test("协议按固定顺序、去重；没给协议为 nil")
    func protocols() {
        #expect(
            ModelsText.protocolList([.responses, .anthropic, .responses], language: .chinese)
                == "Anthropic Messages、OpenAI Responses")
        #expect(
            ModelsText.protocolList([.chat, .unknown("gemini")], language: .english)
                == "OpenAI Chat Completions, gemini")
        #expect(ModelsText.protocolList([]) == nil)
    }

    @Test("每日上限、状态")
    func limits() {
        #expect(ModelsText.dailyLimit(2_000_000, language: .chinese) == "每天最多 200 万 token")
        #expect(ModelsText.dailyLimit(2_000_000, language: .english) == "Up to 2M tokens a day")
        #expect(ModelsText.dailyLimit(nil, language: .chinese) == "不限")
        #expect(ModelsText.statusName(isDisabled: true, language: .chinese) == "已停用")
        #expect(ModelsText.statusName(isDisabled: false, language: .english) == "Active")
    }

    @Test("key：去掉首尾空白，8 到 4096 个可见 ASCII 字符")
    func keyRules() {
        #expect(CredentialRules.keyProblem("") == .required)
        #expect(CredentialRules.keyProblem("   \n") == .required)
        #expect(CredentialRules.keyProblem("sk-123") == .tooShort(min: 8))
        #expect(CredentialRules.keyProblem("sk-abc def") == .invalidCharacters)
        #expect(CredentialRules.keyProblem("sk-密钥12345678") == .invalidCharacters)
        #expect(CredentialRules.keyProblem(String(repeating: "a", count: 4097)) == .tooLong(max: 4096))
        #expect(CredentialRules.keyProblem("  sk-ant-api03-abcdefgh\n") == nil)
        #expect(CredentialRules.normalizedKey("  sk-1234567\n") == "sk-1234567")
    }

    @Test("接口地址：只认 https，空的算没填")
    func baseURLRules() {
        #expect(CredentialRules.baseURLProblem("") == nil)
        #expect(CredentialRules.baseURLProblem("https://api.example.com/v1") == nil)
        #expect(CredentialRules.baseURLProblem("http://api.example.com/v1") == .notHTTPS)
        #expect(CredentialRules.baseURLProblem("api.example.com") == .notHTTPS)
        #expect(CredentialRules.baseURLProblem("HTTPS://api.example.com") == .notHTTPS)
        #expect(CredentialRules.baseURLProblem("https://") == .invalidURL)
        #expect(CredentialRules.baseURLProblem("https://api.example.com/a b") == .invalidURL)
        #expect(
            CredentialRules.baseURLProblem("https://a.example.com/" + String(repeating: "x", count: 600))
                == .tooLong(max: 512))
    }

    @Test("每日上限：空的是不限，可以写千分位，要正整数")
    func dailyLimitParsing() throws {
        #expect(try CredentialRules.parseDailyLimit("").get() == nil)
        #expect(try CredentialRules.parseDailyLimit(" 2,000,000 ").get() == 2_000_000)
        #expect(try CredentialRules.parseDailyLimit("1_000").get() == 1_000)
        for bad in ["0", "-5", "1.5", "一万", "1e6"] {
            guard case .failure(let problem) = CredentialRules.parseDailyLimit(bad) else {
                Issue.record("\(bad) should be rejected")
                continue
            }
            #expect(problem == .notPositiveInteger)
        }
        #expect(CredentialRules.labelProblem(String(repeating: "备", count: 65)) == .tooLong(max: 64))
        #expect(CredentialRules.labelProblem("") == nil)
    }

    @Test("服务端拒收：按英文说明认出原因，界面只显示本地化的文案")
    func rejections() {
        func invalid(_ message: String) -> ClientError {
            .api(status: 422, code: .invalid, message: message, retryAfterSecs: nil)
        }
        let subscription = invalid(
            "Anthropic (Claude) subscription keys (sk-ant-oat...) can only be used in the vendor's own tools; use a "
                + "pay-as-you-go API key")
        #expect(CredentialRejection(subscription) == .subscriptionKey)
        #expect(CredentialRejection(subscription)?.concernsKey == true)
        let plan = invalid(
            "openai_base: https://ark.cn-beijing.volces.com/api/coding is a coding or subscription plan address, which "
                + "only works in the vendor's own tools; use the pay-as-you-go address")
        #expect(CredentialRejection(plan) == .planOnlyEndpoint(field: .openai))
        #expect(CredentialRejection(invalid("anthropic_base must be an https URL")) == .notHTTPS(field: .anthropic))
        #expect(
            CredentialRejection(invalid("responses_base must be 9-512 characters"))
                == .invalidEndpoint(field: .responses))
        #expect(CredentialRejection(invalid("api_key must be 8-4096 bytes")) == .keyFormat)
        #expect(CredentialRejection(invalid("API key contains whitespace or non-printable characters")) == .keyFormat)
        #expect(
            CredentialRejection(
                invalid("unknown vendor: use an id from GET /v1/vendors, or custom with your own base URLs"))
                == .unknownVendor)
        #expect(
            CredentialRejection(invalid("base URLs are required for, and only allowed with, vendor custom"))
                == .endpointMismatch)
        #expect(CredentialRejection(invalid("daily_token_limit must be positive")) == .dailyLimit)
        #expect(CredentialRejection(invalid("label must be 0-64 characters")) == .label)
        #expect(CredentialRejection(invalid("something new")) == .other)
        // 不是 invalid 的照常用错误横幅。
        #expect(CredentialRejection(.network(message: "offline")) == nil)
        #expect(
            CredentialRejection(.api(status: 409, code: .conflict, message: "subscription key", retryAfterSecs: nil))
                == nil)

        let zh = CredentialRejection.subscriptionKey.message(vendorName: "Anthropic (Claude)", language: .chinese)
        #expect(zh.contains("订阅类 key") && zh.contains("按量计费"))
        #expect(!zh.contains("pay-as-you-go"))
        let en = CredentialRejection.planOnlyEndpoint(field: .openai).message(vendorName: "x", language: .english)
        #expect(en.hasPrefix("OpenAI Chat Completions address is a plan-only address"))
    }

    @Test("别名：小写字母或数字开头，只有 a-z 0-9 . _ -，最长 64")
    func aliasRules() {
        for good in ["main", "fast", "o1", "claude-haiku_4.5", "9", String(repeating: "a", count: 64)] {
            #expect(RouteRules.isValidAlias(good), "\(good)")
        }
        for bad in ["", "Main", "-fast", ".x", "fast model", "快速", String(repeating: "a", count: 65)] {
            #expect(!RouteRules.isValidAlias(bad), "\(bad)")
        }
        #expect(RouteRules.normalizedAlias("  Fast \n") == "fast")
    }

    @Test("别名的标签和用途")
    func aliasTexts() {
        #expect(ModelsText.aliasTag("main", language: .chinese) == "默认")
        #expect(ModelsText.aliasTag("fast", language: .english) == "Light")
        #expect(ModelsText.aliasTag("vision") == nil)
        #expect(ModelsText.aliasPurpose("fast", language: .chinese).contains("Haiku"))
        #expect(ModelsText.aliasPurpose("main", language: .english).contains("Required"))
        #expect(ModelsText.fallbackTitle(2, language: .chinese) == "备用 2")
    }

    @Test("数据共享的说明写明发给谁")
    func dataSharing() {
        let zh = ModelsText.dataSharingNotice(vendorNames: ["DeepSeek", "OpenAI"], language: .chinese)
        #expect(zh.contains("DeepSeek、OpenAI") && zh.contains("不出售"))
        let en = ModelsText.dataSharingNotice(vendorNames: [], language: .english)
        #expect(en.contains("the model vendors you set up"))
        #expect(ModelsText.dataSharingConsent(vendorName: "DeepSeek", language: .chinese) == "我同意把这些内容发给 DeepSeek 处理")
        #expect(
            ModelsText.routesDataSharing(instanceName: "写作助手", vendorNames: ["DeepSeek"], language: .chinese)
                .contains("“写作助手”"))
    }

    @Test("唤醒等 key 的运行之后说什么：只说操作前在等的几个马上重试，不说“还有几个在等”")
    func wakeMessages() {
        #expect(KeyWakeResult(retried: 0).message(.chinese) == nil)
        #expect(KeyWakeResult(retried: -1).retried == 0)
        #expect(
            KeyWakeResult(retried: 2).message(.chinese) == "2 个在等 key 的任务马上重试：key 能用就接着跑，还不能用的会继续等。")
        #expect(
            KeyWakeResult(retried: 1).message(.english)?.hasPrefix("1 task(s) waiting for a key are retrying") == true)
        // 服务端唤醒后运行的状态还没变：消息里不能出现“还在等”“已唤醒 N 个接着跑”这种拿前后之差算的话。
        #expect(KeyWakeResult(retried: 3).message(.chinese)?.contains("还有") == false)
        #expect(KeyWakeResult(retried: nil) == nil)
        #expect(KeyWakeResult(retried: Optional(4))?.retried == 4)
        #expect(RouteSaveResult(wake: nil).message(.chinese) == "已保存。卡在“等待 key”的任务会马上重试，key 能用就接着跑。")
        #expect(RouteSaveResult(wake: KeyWakeResult(retried: 0)).message(.english) == "Saved.")
        #expect(RouteSaveResult(wake: KeyWakeResult(retried: 1)).message(.chinese).hasPrefix("已保存。1 个在等 key 的任务马上重试"))
    }

    @Test("保存路由前确认的那段话说的是这个实例，并写明平台怎么对待这些内容")
    func routesConsentNotice() {
        let zh = ModelsText.routesConsentNotice(
            instanceName: "写作助手", vendorNames: ["Anthropic (Claude)", "DeepSeek"], language: .chinese)
        #expect(zh.contains("“写作助手”") && zh.contains("Anthropic (Claude)、DeepSeek") && zh.contains("不出售"))
        #expect(!zh.contains("这把 key"))
        let en = ModelsText.routesConsentNotice(instanceName: "Writer", vendorNames: ["DeepSeek"], language: .english)
        #expect(en.contains("“Writer”") && en.hasSuffix("doesn't sell this content or train models on it."))
    }
}

@MainActor
@Suite("第三方 AI 数据共享的同意记录")
struct ThirdPartyAIConsentTests {
    @Test("按厂商记；自定义地址按 key 记；不记的（nil）每次都要确认")
    func store() {
        let defaults = ModelsFixture.defaults()
        let store = ThirdPartyAIConsentStore(defaults: defaults)
        #expect(!store.hasConsented(to: "deepseek"))
        store.record(["deepseek"])
        #expect(store.hasConsented(to: "deepseek"))
        #expect(!store.hasConsented(to: "anthropic"))
        // 同一个 UserDefaults 再建一个也记得。
        #expect(ThirdPartyAIConsentStore(defaults: defaults).hasConsented(to: "deepseek"))

        let custom = ModelsFixture.customCredential()
        #expect(
            ThirdPartyAIConsentStore.vendorKey(for: custom) == "custom:\(ModelsFixture.customCredentialID.rawValue)")
        let claude = DemoData.state().credentials[0]
        #expect(ThirdPartyAIConsentStore.vendorKey(for: claude) == "anthropic")
        #expect(!store.hasConsented(toAllOf: [claude, custom]))
        store.record([ThirdPartyAIConsentStore.vendorKey(for: claude), ThirdPartyAIConsentStore.vendorKey(for: custom)])
        #expect(store.hasConsented(toAllOf: [claude, custom]))

        store.withdrawAll()
        #expect(!store.hasConsented(to: "deepseek"))

        let forgetful = ThirdPartyAIConsentStore(defaults: nil)
        forgetful.record(["deepseek"])
        #expect(!forgetful.hasConsented(to: "deepseek"))
    }

    @Test("说明改版后要重新同意")
    func versioned() {
        let defaults = ModelsFixture.defaults()
        defaults.set(["deepseek": "2020-01"], forKey: ThirdPartyAIConsentStore.storageKey)
        #expect(!ThirdPartyAIConsentStore(defaults: defaults).hasConsented(to: "deepseek"))
    }
}
