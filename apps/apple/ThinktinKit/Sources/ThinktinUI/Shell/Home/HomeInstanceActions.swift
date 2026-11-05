import SwiftUI
import ThinktinKit

/// 首页一个 Botin 的长按菜单（规范 docs/ios-ui-redesign.md 4.2.2，参考 32、33、112）：系统菜单一列、不分组，顺序照
/// ThinkTin 的 `HomeInstanceMenu`（Botin 资料、置顶 / 取消置顶、新建计划、改名…、隐藏），最后“更多”在原地展开
/// （复制 Botin ID、删除）。隐藏、删除系统标红；离线时要联网的（新建计划、改名、删除）灰掉。普通行和置顶的头像共用。
struct HomeInstanceMenuContent: View {
    let isPinned: Bool
    let isOffline: Bool
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
        .disabled(item.needsConnection && isOffline)
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

/// 首页长按“删除”要删的 Botin：确认页（`InstanceDeleteSheet`）用的视图模型。
struct HomeDeletion: Identifiable {
    let id: InstanceID
    let model: InstanceDetailModel
}

/// 首页长按“改名”的弹窗（参考 68 的版式：标题、输入框、取消 / 保存）：按 `InstanceNameRule` 校验，不合规时“保存”灰着；
/// 改不成弹第二个提示。Shell 自己调 `AppModel.renameInstance`，不依赖 Agents 的页面。`name` 由打开的地方先填好原名再设
/// `target`（弹窗出来时输入框里就是原名）。
struct HomeRenameAlert: ViewModifier {
    let model: AppModel
    @Binding var target: Instance?
    @Binding var name: String

    @State private var failure: ClientError?
    @Environment(\.displayLanguage) private var language

    func body(content: Content) -> some View {
        let zh = language == .chinese
        content
            .alert(
                HomeText.renameTitle(language), isPresented: isRenaming, presenting: target,
                actions: { instance in
                    TextField(instance.name, text: $name)
                    Button(zh ? "取消" : "Cancel", role: .cancel) {}
                    Button(HomeText.renameSave(language)) { save(instance) }
                        .disabled(InstanceNameRule.problem(name) != nil)
                },
                message: { _ in
                    Text(
                        verbatim: zh
                            ? "最多 \(InstanceNameRule.maxLength) 个字。" : "Up to \(InstanceNameRule.maxLength) characters."
                    )
                }
            )
            .alert(
                HomeText.renameFailed(language), isPresented: isShowingFailure, presenting: failure,
                actions: { _ in
                    Button(zh ? "好" : "OK", role: .cancel) {}
                },
                message: { error in
                    Text(verbatim: error.localizedMessage(language))
                }
            )
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private var isShowingFailure: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private func save(_ instance: Instance) {
        let newName = name
        let model = self.model
        Task {
            failure = await model.renameInstance(instance.id, to: newName)
        }
    }
}
