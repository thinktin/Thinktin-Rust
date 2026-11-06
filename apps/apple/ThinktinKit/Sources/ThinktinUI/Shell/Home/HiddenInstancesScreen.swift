import SwiftUI
import ThinktinKit

/// 已隐藏的 Botin（`.hiddenBotins`，规范 docs/ios-ui-redesign.md 4.2.3，参考 114、116）：首页压进主栈的页（有路由，推送、
/// 深链换掉主栈时它跟着走），标题“已隐藏的 Botin”在玻璃胶囊里（参考 114，`capsuleNavigationTitle`），右上玻璃“?”弹说明（参考 115）。plain 列表、没有分隔线，每行头像 + 名字 + 右边玻璃小胶囊“取消隐藏”（点了这一行带动画
/// 拿掉，回到首页的普通行）；点行进它的对话。都取消了以后正中一行灰字“没有隐藏的 Botin”。
///
/// 入口：首页全部隐藏时空状态的“查看藏起来的 Botin”，和列表最底下一行“已隐藏 N 个 Botin”（参考只有前一个）。
struct HiddenInstancesScreen: View {
    let model: AppModel

    @State private var isShowingHelp = false
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let rows = model.homeContent.hidden
        let preferences = model.instancePreferences
        List {
            ForEach(rows) { row in
                HiddenInstanceRow(
                    row: row, appearance: model.appearances.resolved(for: row.id),
                    open: { model.router.open(.conversation(row.id)) },
                    unhide: {
                        withAnimation { preferences.setHidden(false, for: row.id) }
                    })
            }
            .listRowInsets(HomeLayout.rowInsets)
            .listRowSeparator(.hidden)
            .themedPlainRow()
        }
        .listStyle(.plain)
        .themedGroupedBackground()
        .overlay {
            if rows.isEmpty {
                // 参考 116：正中一行灰字，没有图标。
                Text(verbatim: HomeText.hiddenEmpty(language))
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(Metrics.Spacing.m)
            }
        }
        .capsuleNavigationTitle(HomeText.hiddenTitle(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Button {
                    isShowingHelp = true
                } label: {
                    Label(HomeText.aboutHiding(language), systemImage: "questionmark")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HidingHelpSheet()
                .environment(\.displayLanguage, language)
                .tint(Theme.accent)
        }
    }
}

/// 已隐藏页的一行（参考 114）：44pt 头像（和首页的行一样大，右下角状态角标）、名字（`.body`）、右边“取消隐藏”。
/// 点名字那一块进对话；读屏把“取消隐藏”放进这一行的操作里。
///
/// “取消隐藏”是常规大小的玻璃胶囊（约 34pt 高），字是 medium 的 `.footnote`（参考 114：胶囊比小号的高，字小一号）。
struct HiddenInstanceRow: View {
    let row: HomeRow
    var appearance: InstanceAppearance = .default
    let open: @MainActor () -> Void
    let unhide: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: HomeLayout.rowSpacing) {
            Button {
                open()
            } label: {
                HStack(spacing: HomeLayout.rowSpacing) {
                    InstanceAvatar(
                        row.instance.name, appearance: appearance, size: Metrics.Avatar.list,
                        badge: row.preview.avatarBadge
                    )
                    .accessibilityHidden(true)
                    Text(verbatim: row.instance.name)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: row.instance.name))
            .accessibilityAction(named: Text(HomeText.unhide(language))) { unhide() }
            Button(HomeText.unhide(language)) { unhide() }
                .font(Typography.footnote.font.weight(.medium))
                .glassButtonStyle()
                .buttonBorderShape(.capsule)
        }
    }
}

/// “关于隐藏”（参考 115 的版式）：左上 ×，一组分组卡片三行（图标 + 标题 + 多行说明），写 ThinkTin 真实的行为
/// （`HomeText.hidingFacts`：照常干活、只是首页不显示且只在这台设备上、随时放回来）。
struct HidingHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let language = self.language
        NavigationStack {
            List {
                Section {
                    ForEach(HomeText.hidingFacts(language)) { fact in
                        Label {
                            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                                Text(verbatim: fact.title)
                                    .typography(.body)
                                    .foregroundStyle(Theme.ink)
                                Text(verbatim: fact.detail)
                                    .typography(.subheadline)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, Metrics.Spacing.xxs)
                        } icon: {
                            Image(systemName: fact.systemImage)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .themedRow()
            }
            .insetGroupedList()
            .themedGroupedBackground()
            .inlineNavigationTitle(HomeText.aboutHiding(language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

#Preview("已隐藏的 Botin · 深色") {
    let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
    NavigationStack {
        HiddenInstancesScreen(model: model)
    }
    .environment(model)
    .preferredColorScheme(.dark)
    .task {
        await model.start()
        model.instancePreferences.setHidden(true, for: DemoData.writerID)
    }
}

#Preview("关于隐藏 · 英文") {
    HidingHelpSheet()
        .environment(\.displayLanguage, .english)
}
