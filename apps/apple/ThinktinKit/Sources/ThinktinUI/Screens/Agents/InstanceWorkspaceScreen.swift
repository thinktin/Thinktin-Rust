import SwiftUI
import ThinktinKit

/// 工作区（规范 4.6.1，参考 65 的版式、27 / 28 的“?”和说明）：资料页“工作区”行压进来（本地 `NavigationLink`，不加路由）。
/// 每个 Botin 一个云端沙箱，这一页是它的状态和引擎版本（以前在资料页上的版本列表挪到这里）。
///
/// - 有新版本（或者现在的版本下架了）时下一组是“升级到 vX”（参考“重置电脑”那一行的样子：强调色的字 + 灰字说明）；
/// - “重置工作区”（参考 65“重置电脑”：红字 + 一行灰字，没有箭头），脚注说这是这个 Botin 自己的沙箱；重置要后端（6.17），
///   点了说即将推出；
/// - “状态”（状态点 + 名字）和“磁盘空间”（参考 65，还没有接口，值写“即将推出”），脚注是状态说明（运行中、休眠、冷存储，
///   唤醒要多久）；
/// - “引擎”一组：引擎版本、“换到别的版本”（`Picker(.menu)`，选了先确认）、接入方式；脚注是“下次唤醒时生效、工作区保留”，
///   刚换过时写换到了哪个版本；
/// - 右上“?”弹说明（参考 28 的版式：图标 + 标题 + 多行灰字，`WorkspaceHelp`）；
/// - 最上面一行“观看与接管”（参考 09 资料页的“电脑”行进的那一页）：压进 `InstanceScreenView`（画面接口还没有，是演示）。
///
/// 重置工作区、磁盘空间的接口要后端（6.17），第 3 轮；版式先照参考 65 排出来。离线时不能换版本。
struct InstanceWorkspaceScreen: View {
    let model: InstanceDetailModel

    /// 等确认要换的版本（`isConfirmingVersion` 时显示确认框）。
    @State private var pendingVersion: InstanceVersionOption?
    @State private var isConfirmingVersion = false
    @State private var isShowingHelp = false
    /// 点了“重置工作区”：弹“即将推出”。
    @State private var isShowingResetComingSoon = false

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        Form {
            if let instance = model.instance {
                Section {
                    NavigationLink {
                        InstanceScreenView(instanceID: instance.id)
                    } label: {
                        LabeledRow(
                            systemImage: "display", title: InstanceScreenText.title(language),
                            detail: InstanceScreenText.entryDetail(language), detailTypography: .footnote)
                    }
                }
                .themedRow()
                if let upgrade = model.upgradeOption {
                    Section {
                        Button {
                            confirm(upgrade)
                        } label: {
                            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                                Text(upgrade.actionTitle(language))
                                    .foregroundStyle(canChangeVersion ? Theme.accent : Theme.inkTertiary)
                                Text(InstanceWorkspaceText.upgradeDetail(language))
                                    .typography(.subheadline)
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canChangeVersion)
                    }
                    .themedRow()
                }
                Section {
                    Button(role: .destructive) {
                        isShowingResetComingSoon = true
                    } label: {
                        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                            Text(InstanceWorkspaceText.reset(language))
                                .foregroundStyle(StatusTone.failure.color)
                            Text(InstanceWorkspaceText.resetDetail(language))
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(InstanceWorkspaceText.workspaceFooter(language))
                }
                .themedRow()
                Section {
                    LabeledContent {
                        HStack(spacing: Metrics.Spacing.xs) {
                            StatusDot(instance.state)
                                .accessibilityHidden(true)
                            Text(instance.state.localizedName(language))
                        }
                    } label: {
                        Text(InstanceWorkspaceText.status(language))
                    }
                    LabeledContent(
                        InstanceWorkspaceText.diskSpace(language), value: InstanceWorkspaceText.comingSoon(language))
                } footer: {
                    Text(AgentsText.stateExplanation(instance.state, language: language))
                }
                .themedRow()
                Section {
                    LabeledContent(
                        InstanceWorkspaceText.currentVersion(language),
                        value: AgentsText.versionLabel(instance.agentVersion))
                    if !model.switchableVersions.isEmpty {
                        Picker(
                            InstanceWorkspaceText.otherVersions(language),
                            selection: Binding(
                                get: { instance.agentVersion },
                                set: { version in
                                    if let option = model.switchableVersions.first(where: { $0.version == version }),
                                        !option.isCurrent
                                    {
                                        confirm(option)
                                    }
                                })
                        ) {
                            // 现在的版本下架了：补一项它自己，选中值才有对应的项（不然系统报错、右边空白）。
                            if model.needsDelistedVersionPlaceholder {
                                Text(InstanceWorkspaceText.delistedVersion(instance.agentVersion, language: language))
                                    .tag(instance.agentVersion)
                            }
                            ForEach(model.switchableVersions) { option in
                                Text(versionTitle(option)).tag(option.version)
                            }
                        }
                        .pickerStyle(.menu)
                        .menuPickerTint()
                        .disabled(!canChangeVersion)
                    }
                    LabeledContent(
                        zh ? "接入方式" : "Runs via", value: AgentsText.harnessName(instance.harness, language: language))
                } header: {
                    Text(zh ? "引擎" : "Engine")
                        .groupHeader()
                } footer: {
                    Text(versionFooter(instance))
                }
                .themedRow()
                if let error = model.versionError {
                    Section {
                        ErrorBanner(error)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .compactGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.instance == nil {
                ProgressView()
            }
        }
        .inlineNavigationTitle(InstanceProfileText.workspace(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Button {
                    isShowingHelp = true
                } label: {
                    Label(InstanceWorkspaceText.helpTitle(language), systemImage: "questionmark")
                        .labelStyle(.iconOnly)
                }
                .neutralTint()
            }
        }
        .alert(InstanceWorkspaceText.comingSoon(language), isPresented: $isShowingResetComingSoon) {
            Button(InstanceWorkspaceText.ok(language)) {}
        } message: {
            Text(InstanceWorkspaceText.resetComingSoonMessage(language))
        }
        .confirmationDialog(
            pendingVersion?.actionTitle(language) ?? "", isPresented: $isConfirmingVersion, titleVisibility: .visible
        ) {
            if let option = pendingVersion {
                Button(option.actionTitle(language)) {
                    Task { await model.setVersion(option.version) }
                }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(InstanceWorkspaceText.versionFooter(language))
        }
        .sheet(isPresented: $isShowingHelp) {
            WorkspaceHelpSheet()
                .environment(\.displayLanguage, language)
                .tint(Theme.accent)
        }
    }

    /// 离线、正在换时不能换。
    private var canChangeVersion: Bool { !app.isOffline && !model.isChangingVersion }

    private func confirm(_ option: InstanceVersionOption) {
        pendingVersion = option
        isConfirmingVersion = true
    }

    /// 版本菜单里的一项：“v2.2.2（最新）”。
    private func versionTitle(_ option: InstanceVersionOption) -> String {
        let label = AgentsText.versionLabel(option.version)
        guard option.isLatest else { return label }
        return language == .chinese ? "\(label)（最新）" : "\(label) (latest)"
    }

    /// 引擎一组的脚注：刚换过写换到了哪个；现在的版本下架了写建议；其余写换版本的规矩。
    private func versionFooter(_ instance: Instance) -> String {
        if let change = model.versionChange { return change.message(language) }
        if !model.isCurrentVersionListed, let latest = model.latestVersion {
            return InstanceWorkspaceText.unlistedVersion(
                current: instance.agentVersion, latest: latest, language: language)
        }
        return InstanceWorkspaceText.versionFooter(language)
    }
}

/// 工作区说明（右上“?”，参考 28 的版式）：状态、版本两组（`WorkspaceHelp`）。
struct WorkspaceHelpSheet: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let language = self.language
        GroupedHelpSheet(
            title: InstanceWorkspaceText.helpTitle(language),
            sections: WorkspaceHelp.sections(language) { $0.localizedName(language) })
    }
}

/// 说明 sheet（参考 28 的版式，工作区说明和观看与接管的使用说明共用）：large sheet，左上 ×，分组列出每一项（图标 + 标题 +
/// 多行灰字）；`footer` 写在最后一组下面。
struct GroupedHelpSheet: View {
    let title: String
    let sections: [WorkspaceHelpSection]
    var footer: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lastID = sections.last?.id
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            Label {
                                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                                    Text(item.title)
                                        .foregroundStyle(Theme.ink)
                                    Text(item.detail)
                                        .typography(.subheadline)
                                        .foregroundStyle(Theme.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, Metrics.Spacing.xxs)
                            } icon: {
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text(section.title)
                            .groupHeader()
                    } footer: {
                        if let footer, section.id == lastID {
                            Text(footer)
                        }
                    }
                    .themedRow()
                }
            }
            .insetGroupedList()
            .themedGroupedBackground()
            .inlineNavigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

#Preview("工作区 · 浅色中文（落后一个版本）") {
    NavigationStack {
        InstanceWorkspacePreview(instanceID: DemoData.reviewerID)
    }
    .previewShell()
}

#Preview("工作区说明 · 深色英文") {
    WorkspaceHelpSheet()
        .previewShell(.english, scheme: .dark)
}
