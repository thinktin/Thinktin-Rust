import Foundation
import Testing

@testable import ThinktinKit

// 设置里还没有后端的几页（参考 56、62–64、71、76、77、100；规范 4.9.4、4.9.8、4.9.10、4.9.14）：演示数据、表单校验、
// 反馈邮件的链接、“即将推出”的说明。

private func instance(_ id: InstanceID, _ name: String, state: InstanceState = .running) -> Instance {
    Instance(
        id: id, agentID: "claude", agentVersion: "1.0.0", harness: "claude-code", name: name, state: state,
        createdAt: Fixture.now, lastActiveAt: Fixture.now)
}

@Suite("权限与规则")
struct PermissionRulesTests {
    @Test("演示数据：自动审查开着，始终询问没有规则，自动允许 3 条（参考 62）")
    func demo() {
        for language in DisplayLanguage.allCases {
            let overview = PermissionsDemoData.overview(language)
            #expect(overview.autoReview)
            #expect(overview.rules(of: .alwaysAsk).isEmpty)
            #expect(overview.rules(of: .autoAllow).count == 3)
            #expect(Set(overview.rules.map(\.id)).count == overview.rules.count)
            #expect(overview.rules.allSatisfy { !$0.text.isEmpty })
        }
        // 中英文的规则 id 一样（换语言时修改页还能找到同一条）。
        #expect(
            PermissionsDemoData.overview(.chinese).rules.map(\.id)
                == PermissionsDemoData.overview(.english).rules.map(\.id))
        let first = PermissionsDemoData.overview(.chinese).rules[0]
        #expect(PermissionsDemoData.overview(.chinese).rule(id: first.id) == first)
        #expect(PermissionsDemoData.overview(.chinese).rule(id: "missing") == nil)
    }

    @Test("设置根页的副标题：开关状态和条数")
    func subtitle() {
        var overview = PermissionsOverview(autoReview: false, rules: [])
        #expect(overview.settingsSubtitle(.chinese) == "自动审查已关闭 · 0 条规则")
        #expect(overview.settingsSubtitle(.english) == "Auto-review off · 0 rules")
        overview.autoReview = true
        overview.rules = [PermissionRule(id: "a", kind: .alwaysAsk, text: "x")]
        #expect(overview.settingsSubtitle(.english) == "Auto-review on · 1 rule")
    }

    @Test("两组：标题、说明、占位都有中英文且不一样（参考 63、100 的占位不同）")
    func kinds() {
        for kind in PermissionRuleKind.allCases {
            for language in DisplayLanguage.allCases {
                #expect(!kind.title(language).isEmpty && !kind.subtitle(language).isEmpty)
            }
            #expect(kind.title(.chinese) != kind.title(.english))
        }
        #expect(
            PermissionRuleKind.alwaysAsk.placeholder(.chinese) != PermissionRuleKind.autoAllow.placeholder(.chinese))
        #expect(PermissionRuleKind.alwaysAsk.title(.chinese) == "始终询问")
        #expect(PermissionRuleKind.autoAllow.title(.chinese) == "无需询问即允许")
    }

    @Test("新建规则：写了字才能添加，超长不行")
    func newDraft() {
        var draft = PermissionRuleDraft(kind: .alwaysAsk)
        #expect(draft.isNew)
        #expect(draft.title(.chinese) == "新建规则")
        #expect(draft.saveTitle(.chinese) == "添加规则")
        #expect(!draft.canSave)
        draft.text = "   \n "
        #expect(!draft.canSave)
        draft.text = "超过 100 元的购买"
        #expect(draft.canSave)
        draft.text = String(repeating: "长", count: PermissionRuleDraft.maxLength + 1)
        #expect(draft.isTooLong)
        #expect(!draft.canSave)
    }

    @Test("修改规则：改了才能保存（参考 64）")
    func editDraft() {
        let rule = PermissionRule(id: "r", kind: .autoAllow, text: "运行测试")
        var draft = PermissionRuleDraft(editing: rule)
        #expect(!draft.isNew)
        #expect(draft.kind == .autoAllow)
        #expect(draft.title(.english) == "Edit rule")
        #expect(draft.saveTitle(.chinese) == "保存规则")
        #expect(!draft.canSave)
        draft.text = "运行测试 "
        #expect(!draft.canSave, "只多了空白不算改了")
        draft.text = "运行单元测试"
        #expect(draft.canSave)
    }
}

@MainActor
@Suite("订阅")
struct SubscriptionModelTests {
    @Test("先转圈，拿到方案后列出来；现在用的是免费版")
    func loads() async {
        let model = SubscriptionModel(loader: { SubscriptionDemoData.plans($0) })
        #expect(model.isLoading)
        #expect(model.currentPlan == nil)
        await model.load(.chinese)
        #expect(!model.isLoading)
        #expect(model.plans?.map(\.id) == [.free, .pro])
        #expect(model.currentPlan?.id == .free)
        #expect(model.currentPlan?.name == "免费版")
    }

    @Test("演示方案：每个都有权益，只有一个是当前的")
    func demoPlans() {
        for language in DisplayLanguage.allCases {
            let plans = SubscriptionDemoData.plans(language)
            #expect(plans.filter(\.isCurrent).count == 1)
            #expect(plans.allSatisfy { !$0.features.isEmpty && !$0.price.isEmpty && !$0.name.isEmpty })
        }
    }
}

@Suite("导入记忆")
struct ImportMemoryTests {
    @Test("默认选第一个还能用的 Botin（按名字排，去掉已删除的）")
    func defaultTarget() {
        let draft = ImportMemoryDraft(instances: [
            instance("c", "Charlie"), instance("a", "Alpha", state: .deleted), instance("b", "Bravo"),
        ])
        #expect(draft.instanceID == "b")
        #expect(ImportMemoryDraft(instances: []).instanceID == nil)
    }

    @Test("粘贴了内容、选了 Botin 才能添加")
    func canSubmit() {
        var draft = ImportMemoryDraft(instances: [instance("a", "周报助手")])
        #expect(!draft.canSubmit)
        draft.text = "  \n"
        #expect(!draft.canSubmit)
        draft.text = "1. 回复用中文"
        #expect(draft.canSubmit)
        draft.instanceID = nil
        #expect(!draft.canSubmit)
        draft.instanceID = "a"
        draft.text = String(repeating: "x", count: ImportMemoryDraft.maxLength + 1)
        #expect(draft.isTooLong)
        #expect(!draft.canSubmit)
    }

    @Test("导出提示词：中英文各一份，分 5 段，叮嘱别写机密")
    func prompt() {
        let zh = ImportMemoryText.exportPrompt(.chinese)
        let en = ImportMemoryText.exportPrompt(.english)
        #expect(zh != en)
        for index in 1...5 {
            #expect(zh.contains("\(index). ") && en.contains("\(index). "))
        }
        #expect(zh.contains("密码") && en.contains("passwords"))
        // 续行的反斜杠不能漏进提示词里。
        #expect(!zh.contains("\\") && !en.contains("\\"))
    }
}

@Suite("发送反馈")
struct FeedbackDraftTests {
    @Test("写了字才能发，超长不行（参考 76）")
    func canSend() {
        var draft = FeedbackDraft()
        #expect(!draft.canSend)
        draft.text = " \n"
        #expect(!draft.canSend)
        draft.text = "首页的搜索有时候没反应"
        #expect(draft.canSend)
        draft.text = String(repeating: "长", count: FeedbackDraft.maxLength + 1)
        #expect(!draft.canSend)
    }

    @Test("邮件正文：反馈、App 版本、系统、选的 Botin")
    func body() {
        let draft = FeedbackDraft(text: "  搜索没反应  ", instanceID: "a")
        let info = AppInfo(version: "0.1.0", build: "7")
        let withBotin = draft.body(
            instance: instance("a", "周报助手"), appInfo: info, system: "iOS 18.1.0", language: .chinese)
        #expect(withBotin.hasPrefix("搜索没反应\n\n"))
        #expect(withBotin.contains("App：ThinkTin 0.1.0（7）"))
        #expect(withBotin.contains("系统：iOS 18.1.0"))
        #expect(withBotin.contains("Botin：周报助手（a）"))
        let without = draft.body(instance: nil, appInfo: info, system: "iOS 18.1.0", language: .english)
        #expect(without.contains("App: ThinkTin 0.1.0 (7)"))
        #expect(!without.contains("Botin"))
    }

    @Test("mailto 链接：收件人、主题和正文都编码，能原样解出来")
    func mailto() throws {
        let info = AppInfo(version: "0.1.0", build: "7")
        #expect(FeedbackDraft().mailtoURL(instance: nil, appInfo: info, system: "iOS 18") == nil)
        let draft = FeedbackDraft(text: "第一行 & a=b+c\n第二行?", instanceID: nil)
        let url = try #require(draft.mailtoURL(instance: nil, appInfo: info, system: "iOS 18", language: .chinese))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:\(FeedbackDraft.address)?subject="))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items.count == 2, "& = + 都编码了，不会多拆出参数")
        #expect(items["subject"] == "ThinkTin 反馈")
        #expect(
            items["body"] == draft.body(instance: nil, appInfo: info, system: "iOS 18", language: .chinese))
        #expect(!url.absoluteString.contains(" "))
    }

    @Test("系统描述带系统名和三段版本号")
    func system() {
        let text = FeedbackDraft.systemDescription()
        let parts = text.split(separator: " ")
        #expect(parts.count == 2)
        #expect(parts.last?.split(separator: ".").count == 3)
    }
}

@Suite("即将推出的说明")
struct SettingsComingSoonTests {
    @Test("每一项都有中英文说明")
    func messages() {
        for item in SettingsComingSoon.allCases {
            #expect(!item.message(.chinese).isEmpty)
            #expect(!item.message(.english).isEmpty)
            #expect(item.message(.chinese) != item.message(.english))
        }
        #expect(SettingsExtrasText.comingSoonTitle(.chinese) == "即将推出")
        #expect(SettingsExtrasText.comingSoonTitle(.english) == "Coming soon")
    }

    @Test("选择器的 Botin：去掉已删除的，按名字排")
    func pickable() {
        let list = SettingsExtrasText.pickableInstances([
            instance("2", "b"), instance("1", "a"), instance("3", "c", state: .deleted), instance("0", "a"),
        ])
        #expect(list.map(\.id) == ["0", "1", "2"])
    }
}
