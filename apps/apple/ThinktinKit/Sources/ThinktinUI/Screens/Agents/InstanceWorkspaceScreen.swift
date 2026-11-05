import SwiftUI
import ThinktinKit

/// 工作区（规范 4.6.1，参考 65 的版式、27 / 28 的“?”和说明）：资料页“工作区”行压进来（本地 `NavigationLink`，不加路由）。
/// 每个 Botin 一个云端沙箱，这一页是它的状态和引擎版本（以前在资料页上的版本列表挪到这里）。
///
/// - 有新版本（或者现在的版本下架了）时最上面一组是“升级到 vX”（参考“重置电脑”那一行的样子：强调色的字 + 灰字说明），
///   脚注说这是这个 Botin 自己的沙箱；
/// - “状态”一行（状态点 + 名字），脚注是状态说明（运行中、休眠、冷存储，唤醒要多久）；
/// - “引擎”一组：引擎版本、“换到别的版本”（`Picker(.menu)`，选了先确认）、接入方式；脚注是“下次唤醒时生效、工作区保留”，
///   刚换过时写换到了哪个版本；
/// - 右上“?”弹说明（参考 28 的版式：图标 + 标题 + 多行灰字，`WorkspaceHelp`）。
///
/// 重置工作区、磁盘空间、看画面要后端（6.17、4.6.2），第 3 轮。离线时不能换版本。
struct InstanceWorkspaceScreen: View {
    let model: InstanceDetailModel

    /// 等确认要换的版本（`isConfirmingVersion` 时显示确认框）。
    @State private var pendingVersion: InstanceVersionOption?
    @State private var isConfirmingVersion = false
    @State private var isShowingHelp = false

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        Form {
            if let instance = model.instance {
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
                    } footer: {
                        Text(InstanceWorkspaceText.workspaceFooter(language))
                    }
                    .themedRow()
                }
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
                } footer: {
                    Text(statusFooter(instance))
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
                            ForEach(model.switchableVersions) { option in
                                Text(versionTitle(option)).tag(option.version)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!canChangeVersion)
                    }
                    LabeledContent(
                        zh ? "接入方式" : "Runs via", value: AgentsText.harnessName(instance.harness, language: language))
                } header: {
                    Text(zh ? "引擎" : "Engine")
                        .textCase(nil)
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
            }
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

    /// 状态一组的脚注：状态说明；没有“升级”那一组时把“这个 Botin 自己的沙箱”也写在这里。
    private func statusFooter(_ instance: Instance) -> String {
        let explanation = AgentsText.stateExplanation(instance.state, language: language)
        guard model.upgradeOption == nil else { return explanation }
        return InstanceWorkspaceText.workspaceFooter(language) + "\n" + explanation
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

/// 工作区说明（右上“?”，参考 28 的版式）：large sheet，左上 ×，分组列出每一项（图标 + 标题 + 多行灰字）。
struct WorkspaceHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let language = self.language
        NavigationStack {
            List {
                ForEach(WorkspaceHelp.sections(language) { $0.localizedName(language) }) { section in
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
                            .textCase(nil)
                    }
                    .themedRow()
                }
            }
            .insetGroupedList()
            .themedGroupedBackground()
            .inlineNavigationTitle(InstanceWorkspaceText.helpTitle(language))
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
