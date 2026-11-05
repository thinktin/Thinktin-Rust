import SwiftUI
import ThinktinKit

/// 权限与规则（`.permissions`，参考 62；规范 4.9.8、6.15）：insetGrouped 的 `List`：
/// 1. “自动审查”开关（标题 + 一行说明）；
/// 2. “始终询问”“无需询问即允许”两组：组标题左边是名字和一句说明，右边一个小玻璃胶囊“添加规则”；规则一句一行，点了压进
///    修改页，左滑删除；没有规则时一行灰字“暂无规则”；
/// 3. ThinkTin 多一组：进审批中心（现在真正在用的逐条批准）。脚注说规则管不到电脑上的高危操作、现在是示例。
///
/// 还没有后端（6.15）：规则是本地的演示数据（`PermissionsDemoData`），开关、保存、删除都弹“即将推出”。
struct PermissionsScreen: View {
    @Environment(\.displayLanguage) private var language
    @State private var editing: PermissionRuleTarget?
    @State private var pendingDeletion: PermissionRule?
    @State private var comingSoon: SettingsComingSoon?

    var body: some View {
        let overview = PermissionsDemoData.overview(language)
        List {
            Section {
                Toggle(
                    isOn: Binding(get: { overview.autoReview }, set: { _ in comingSoon = .autoReview })
                ) {
                    Text(PermissionsText.autoReview(language))
                    Text(PermissionsText.autoReviewDetail(language))
                }
            }
            .themedRow()
            ForEach(PermissionRuleKind.allCases) { kind in
                ruleSection(kind, rules: overview.rules(of: kind))
            }
            Section {
                NavigationLink(value: AppRoute.approvals) {
                    SettingsRowLabel(
                        title: AppRoute.approvals.title(language), subtitle: PermissionsText.approvalsDetail(language))
                }
            } footer: {
                Text(PermissionsText.footer(language))
            }
            .themedRow()
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .inlineNavigationTitle(AppRoute.permissions.title(language))
        .navigationDestination(item: $editing) { target in
            PermissionRuleEditorScreen(draft: draft(for: target, in: overview))
        }
        .confirmationDialog(
            PermissionsText.deleteConfirmation(language),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion
        ) { _ in
            Button(PermissionsText.delete(language), role: .destructive) { comingSoon = .deleteRule }
            Button(SettingsExtrasText.cancel(language), role: .cancel) {}
        } message: { rule in
            Text(rule.text)
        }
        .settingsComingSoon($comingSoon)
    }

    private func ruleSection(_ kind: PermissionRuleKind, rules: [PermissionRule]) -> some View {
        Section {
            if rules.isEmpty {
                Text(PermissionsText.noRules(language))
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(rules) { rule in
                    Button {
                        editing = .edit(rule.id)
                    } label: {
                        Text(rule.text)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint(Text(language == .chinese ? "修改这条规则" : "Edits this rule"))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(PermissionsText.delete(language), role: .destructive) {
                            pendingDeletion = rule
                        }
                    }
                }
            }
        } header: {
            PermissionRuleSectionHeader(kind: kind) { editing = .new(kind) }
        }
        .themedRow()
    }

    private func draft(for target: PermissionRuleTarget, in overview: PermissionsOverview) -> PermissionRuleDraft {
        switch target {
        case .new(let kind):
            return PermissionRuleDraft(kind: kind)
        case .edit(let id):
            // 演示数据里一定有；找不到（换了语言、数据变了）就当新建一条“始终询问”的。
            return overview.rule(id: id).map(PermissionRuleDraft.init(editing:))
                ?? PermissionRuleDraft(kind: .alwaysAsk)
        }
    }
}

/// 权限页里压进去的规则表单是新建哪一组的，还是修改哪一条。
enum PermissionRuleTarget: Hashable {
    case new(PermissionRuleKind)
    case edit(String)
}

/// 规则组的标题（参考 62）：左边组名和一句说明，右边小玻璃胶囊“添加规则”。
struct PermissionRuleSectionHeader: View {
    let kind: PermissionRuleKind
    let onAdd: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.Spacing.s) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(kind.title(language))
                Text(kind.subtitle(language))
                    .font(.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Metrics.Spacing.xs)
            Button(PermissionsText.addRule(language), action: onAdd)
                .glassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .foregroundStyle(Theme.ink)
                .accessibilityLabel(
                    Text(
                        language == .chinese
                            ? "添加“\(kind.title(language))”规则" : "Add a rule to “\(kind.title(language))”"))
        }
        .textCase(nil)
    }
}

/// 新建 / 修改规则（参考 63、64、100）：标题“新建规则 / 编辑规则”；`Form` 一组“适用于”的多行输入框（占位按组不同）+ 脚注；
/// 修改时多一组红字“删除规则”；底部浮着全宽的“添加规则 / 保存规则”和一行“取消”（规范 2.7 的“只做一件事”的页）。
/// 保存、删除都弹“即将推出”。
struct PermissionRuleEditorScreen: View {
    @State private var draft: PermissionRuleDraft
    @State private var comingSoon: SettingsComingSoon?
    @State private var confirmsDeletion = false
    @FocusState private var isFocused: Bool

    @Environment(\.displayLanguage) private var language
    @Environment(\.dismiss) private var dismiss

    init(draft: PermissionRuleDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section {
                TextField(draft.kind.placeholder(language), text: $draft.text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($isFocused)
                    .accessibilityLabel(Text(PermissionsText.appliesTo(language)))
            } header: {
                Text(PermissionsText.appliesTo(language)).textCase(nil)
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    if draft.isTooLong {
                        Text(PermissionsText.tooLong(language)).foregroundStyle(Theme.danger)
                    } else {
                        Text(PermissionsText.ruleFooter(language))
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    SettingsCharacterCount(
                        count: draft.trimmed.unicodeScalars.count, limit: PermissionRuleDraft.maxLength)
                }
            }
            .themedRow()
            if !draft.isNew {
                Section {
                    Button(PermissionsText.deleteRule(language), role: .destructive) {
                        confirmsDeletion = true
                    }
                    .foregroundStyle(Theme.danger)
                }
                .themedRow()
            }
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .settingsNavigationTitle(draft.title(language))
        .floatingBar {
            SettingsBottomActions(
                title: draft.saveTitle(language), isEnabled: draft.canSave, onCancel: { dismiss() }
            ) {
                comingSoon = .saveRule
            }
        }
        .onAppear {
            // 新建时直接弹键盘（参考 63 一进来光标就在输入框里）。
            if draft.isNew { isFocused = true }
        }
        .confirmationDialog(
            PermissionsText.deleteConfirmation(language), isPresented: $confirmsDeletion, titleVisibility: .visible
        ) {
            Button(PermissionsText.delete(language), role: .destructive) { comingSoon = .deleteRule }
            Button(SettingsExtrasText.cancel(language), role: .cancel) {}
        } message: {
            Text(draft.original?.text ?? "")
        }
        .settingsComingSoon($comingSoon)
    }
}

#Preview("权限 · 浅色中文") {
    SettingsDestination(route: .permissions).previewShell()
}

#Preview("权限 · 深色英文") {
    SettingsDestination(route: .permissions).previewShell(.english, scheme: .dark)
}

#Preview("新建规则 · 深色中文") {
    PermissionRuleEditorScreen(draft: PermissionRuleDraft(kind: .alwaysAsk)).previewShell(scheme: .dark)
}

#Preview("编辑规则 · 浅色英文") {
    PermissionRuleEditorScreen(draft: PermissionRuleDraft(editing: PermissionsDemoData.overview(.english).rules[0]))
        .previewShell(.english)
}
