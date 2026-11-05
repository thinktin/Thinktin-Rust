import SwiftUI
import ThinktinKit

/// 首页列表最上面的“等你处理”提示行（规范 4.2.1、6.1 A1；参考里没有）：有待审批或收件箱未读时一个玻璃胶囊
/// “2 个审批在等你 · 3 条未读”（`HomeAttentionHint`），点了进审批中心（有待审批时）或收件箱，和工作台菜单一样是顶级页面。
/// 胶囊是有边框的按钮样式，在 `List` 的行里只有它自己能点。
struct HomeAttentionRow: View {
    let hint: HomeAttentionHint
    let open: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button(action: open) {
            Label {
                Text(verbatim: hint.text(language))
                    .lineLimit(1)
            } icon: {
                Image(systemName: hint.pendingApprovals > 0 ? "checkmark.shield" : "tray")
                    .foregroundStyle(StatusTone.waiting.color)
            }
            .typography(.subheadline)
            .foregroundStyle(Theme.ink)
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
        .accessibilityHint(Text(hint.accessibilityHint(language)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("等你处理") {
    List {
        if let hint = HomeAttentionHint(badges: ShellBadges(inboxUnread: 3, pendingApprovals: 2)) {
            HomeAttentionRow(hint: hint) {}
        }
        if let hint = HomeAttentionHint(badges: ShellBadges(inboxUnread: 5)) {
            HomeAttentionRow(hint: hint) {}
        }
    }
    .listStyle(.plain)
}
