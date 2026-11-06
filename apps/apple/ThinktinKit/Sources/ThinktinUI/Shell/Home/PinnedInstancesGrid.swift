import SwiftUI
import ThinktinKit

/// 首页最上面置顶的 Botin（规范 docs/ios-ui-redesign.md 4.2.1，参考 111、120）：居中的 80pt 大头像（右下角状态角标），
/// 下面一行名字；一排最多 3 个，每排居中（只有一两个时也在正中间）。中间没有分区标题，下面直接接普通行。
///
/// 放在首页 `List` 的第一行；每个头像是自己的按钮（`.plain`，一行里有几个按钮时不会点一下全触发），长按是和普通行
/// 一样的菜单（参考 112，“置顶”换成“取消置顶”）。没有左滑（左滑在一排上，分不出是哪一个）。
struct PinnedInstancesGrid<MenuItems: View>: View {
    let rows: [HomeRow]
    let appearances: InstanceAppearanceStore
    /// 主 Botin（头像上的星标）；nil 是没有。
    var primaryID: InstanceID? = nil
    let open: (InstanceID) -> Void
    /// 每个头像的长按菜单（由 `HomeInstanceList` 给，和普通行共用一套）。
    @ViewBuilder let menu: (HomeRow) -> MenuItems

    var body: some View {
        VStack(spacing: Metrics.Spacing.l) {
            ForEach(Self.chunks(rows), id: \.self) { chunk in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(chunk) { row in
                        cell(row)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func cell(_ row: HomeRow) -> some View {
        Button {
            open(row.id)
        } label: {
            PinnedInstanceCell(
                row: row, appearance: appearances.resolved(for: row.id), isPrimary: row.id == primaryID)
        }
        .buttonStyle(.plain)
        .frame(width: HomeLayout.pinnedCellWidth)
        .contextMenu {
            menu(row)
        } preview: {
            HomeInstancePreviewCard(row: row, appearance: appearances.resolved(for: row.id))
        }
    }

    /// 按一排 3 个切开（最后一排可能不满，居中放）。
    static func chunks(_ rows: [HomeRow]) -> [[HomeRow]] {
        stride(from: 0, to: rows.count, by: HomeLayout.pinnedPerRow).map {
            Array(rows[$0..<min($0 + HomeLayout.pinnedPerRow, rows.count)])
        }
    }
}

/// 一个置顶的 Botin：80pt 头像 + 名字（`.footnote`，单行）。读屏念“写作助手，已置顶，2 个在等你处理”。
struct PinnedInstanceCell: View {
    let row: HomeRow
    var appearance: InstanceAppearance = .default
    /// 是不是主 Botin（没有状态角标时画星标）。
    var isPrimary = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            InstanceAvatar(
                row.instance.name, appearance: appearance, size: Metrics.Avatar.pinned,
                badge: row.preview.avatarBadge(isPrimary: isPrimary))
            Text(verbatim: row.instance.name)
                .typography(.footnote)
                .foregroundStyle(row.needsAttention ? StatusTone.waiting.color : Theme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var accessibilityText: String {
        let zh = language == .chinese
        var parts = [row.instance.name, zh ? "已置顶" : "Pinned"]
        if isPrimary { parts.append(ConversationText.primaryBotin(language)) }
        if row.needsAttention {
            parts.append(row.preview.text(language))
        } else if let state = row.preview.spokenState(language) {
            // 暂停、归档只画在头像角标上：念出来。
            parts.append(state)
        }
        return parts.joined(separator: zh ? "，" : ", ")
    }
}
