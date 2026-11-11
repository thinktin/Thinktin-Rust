import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 设置里还没有后端的几页（改版第 2 轮 r2/settings；参考 56、58、60–64、68、71、76、77、94–100）：权限与规则、订阅、
/// 导入记忆、发送反馈、保险箱的卡片和联系信息、登录信息的网站。每页在浅色中文、深色英文下都能布局；演示数据、校验在
/// ThinktinKitTests 的 `SettingsExtrasTests`、`VaultExtraFormsTests` 里测。
@MainActor
@Suite("设置补充页的界面")
struct SettingsExtrasScreensTests {
    private func layoutBoth(_ view: some View, client: (any ClientProtocol)? = nil) {
        hostAndLayout(view.settingsPreviewEnvironment().previewShell(client: client))
        hostAndLayout(view.settingsPreviewEnvironment().previewShell(.english, scheme: .dark, client: client))
    }

    @Test("接入点：权限、订阅、导入记忆、发送反馈")
    func destinations() {
        let mock = ShellPreviewClients.signedIn()
        for route in [AppRoute.permissions, .subscription, .importMemory, .feedback] {
            #expect(route.feature == .settings)
            layoutBoth(SettingsDestination(route: route), client: mock)
        }
    }

    @Test("规则表单：新建两组、修改一条")
    func ruleEditor() {
        for kind in PermissionRuleKind.allCases {
            layoutBoth(PermissionRuleEditorScreen(draft: PermissionRuleDraft(kind: kind)))
            layoutBoth(
                List {
                    Section {
                        EmptyView()
                    } header: {
                        PermissionRuleSectionHeader(kind: kind, onAdd: {})
                    }
                })
        }
        let rule = PermissionsDemoData.overview(.chinese).rules[0]
        layoutBoth(PermissionRuleEditorScreen(draft: PermissionRuleDraft(editing: rule)))
    }

    @Test("保险箱：卡片、联系信息、网站一组")
    func vaultForms() {
        layoutBoth(VaultCardFormView())
        layoutBoth(VaultContactFormView())
        var websites = VaultFieldList(values: ["example.com", "bad"])
        websites.add()
        layoutBoth(Form { VaultWebsitesSection(websites: .constant(websites)) })
        layoutBoth(Form { VaultWebsitesSection(websites: .constant(VaultFieldList())) })
        layoutBoth(Form { VaultInlineField(title: "卡号", labelWidth: VaultFormMetrics.labelWidth) { Text("4242") } })
    }

    @Test("共用的小组件：底部按钮、多行输入、字数、Botin 选择器")
    func components() {
        layoutBoth(SettingsBottomActions(title: "添加规则", isEnabled: false, onCancel: {}, action: {}))
        layoutBoth(SettingsBottomActions(title: "发送反馈", isWorking: true, action: {}))
        layoutBoth(SettingsBottomActions(title: "添加到记忆", isEditing: false, action: {}))
        // 按钮下面：有“取消”不留；没有“取消”时键盘开着（或者页面没说）留 12pt，收起来不留。
        #expect(SettingsBottomActions.bottomPadding(hasCancel: true, isEditing: true) == 0)
        #expect(SettingsBottomActions.bottomPadding(hasCancel: false, isEditing: nil) == Metrics.Spacing.s)
        #expect(SettingsBottomActions.bottomPadding(hasCancel: false, isEditing: true) == Metrics.Spacing.s)
        #expect(SettingsBottomActions.bottomPadding(hasCancel: false, isEditing: false) == 0)
        layoutBoth(Form { SettingsMultilineField(title: "提示", placeholder: "", text: .constant("")) })
        layoutBoth(SettingsCharacterCount(count: 501, limit: 500))
        let mock = ShellPreviewClients.signedIn()
        layoutBoth(
            Form {
                SettingsBotinPicker(title: "Botin", selection: .constant(nil), instances: mock.state.instances)
            }, client: mock)
    }
}
