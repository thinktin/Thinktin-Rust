import SwiftUI
import ThinktinKit

/// 首页一个 Botin 的长按菜单（规范 docs/ios-ui-redesign.md 4.2.2，参考 32、33、112）：系统菜单一列、不分组，顺序照
/// `HomeInstanceMenu`（置顶 / 取消置顶、替换主 Botin…、隐藏），最后“更多”在原地展开（复制 Botin ID）。隐藏系统标红。
/// 都是本机的操作，离线照样能点。普通行和置顶的头像共用。
struct HomeInstanceMenuContent: View {
    let isPinned: Bool
    let perform: (HomeInstanceMenuItem) -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        ForEach(HomeInstanceMenu.items(isPinned: isPinned), id: \.self) { item in
            button(item)
        }
        Menu {
            ForEach(HomeInstanceMenu.more, id: \.self) { item in
                button(item)
            }
        } label: {
            Label(HomeInstanceMenu.moreTitle(language), systemImage: "ellipsis")
        }
    }

    private func button(_ item: HomeInstanceMenuItem) -> some View {
        Button(role: item.isDestructive ? .destructive : nil) {
            perform(item)
        } label: {
            Label(item.title(language), systemImage: item.systemImage)
        }
    }
}

/// 左滑露出来的按钮（参考 110）：最右边红色的“隐藏”，再是灰色的“置顶”。iOS 26 上系统画成玻璃圆。
struct HomeInstanceSwipeButtons: View {
    let isPinned: Bool
    let perform: (HomeInstanceMenuItem) -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        ForEach(HomeInstanceMenu.swipeItems(isPinned: isPinned), id: \.self) { item in
            Button(role: item.isDestructive ? .destructive : nil) {
                perform(item)
            } label: {
                Label(item.title(language), systemImage: item.systemImage)
            }
            .tint(item.isDestructive ? StatusTone.failure.color : Color.gray)
        }
    }
}
