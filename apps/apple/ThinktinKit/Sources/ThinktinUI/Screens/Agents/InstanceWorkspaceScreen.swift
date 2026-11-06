import SwiftUI
import ThinktinKit

/// 工作区（规范 4.6.1，参考 65 的版式）：资料页“工作区”行压进来（本地 `NavigationLink`，不加路由）。每个 Botin 一个云端沙箱。
///
/// - 最上面一行“观看与接管”（参考 09 资料页的“电脑”行进的那一页，27）：压进 `InstanceScreenView`（画面接口还没有，是演示）；
/// - “重置工作区”（参考 65“重置电脑”：红字 + 一行灰字，没有箭头），脚注说这是这个 Botin 自己的沙箱；重置要后端（6.17），
///   点了说即将推出；
/// - “磁盘空间”（参考 65，还没有接口，值写“即将推出”）。
///
/// 以前的状态行、“引擎”一组（引擎版本、换到别的版本、接入方式）、“升级到 vX”和右上“?”（状态、版本的说明）2026-11-06
/// 照参考 65 去掉了。重置工作区、磁盘空间的接口要后端（6.17），第 3 轮；版式先照参考 65 排出来。
struct InstanceWorkspaceScreen: View {
    let model: InstanceDetailModel

    /// 点了“重置工作区”：弹“即将推出”。
    @State private var isShowingResetComingSoon = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
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
                    LabeledContent(
                        InstanceWorkspaceText.diskSpace(language), value: InstanceWorkspaceText.comingSoon(language))
                }
                .themedRow()
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
        .alert(InstanceWorkspaceText.comingSoon(language), isPresented: $isShowingResetComingSoon) {
            Button(InstanceWorkspaceText.ok(language)) {}
        } message: {
            Text(InstanceWorkspaceText.resetComingSoonMessage(language))
        }
    }
}

/// 说明 sheet（参考 28 的版式，观看与接管的使用说明 `InstanceScreenHelpSheet` 用）：large sheet，左上 ×，分组列出每一项
/// （图标 + 标题 + 多行灰字）；`footer` 写在最后一组下面。
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

#Preview("工作区 · 浅色中文") {
    NavigationStack {
        InstanceWorkspacePreview(instanceID: DemoData.writerID)
    }
    .previewShell()
}

#Preview("工作区 · 深色英文") {
    NavigationStack {
        InstanceWorkspacePreview(instanceID: DemoData.reviewerID)
    }
    .previewShell(.english, scheme: .dark)
}
