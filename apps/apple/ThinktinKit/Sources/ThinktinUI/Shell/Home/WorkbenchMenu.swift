import SwiftUI
import ThinktinKit

/// 首页左下的“工作台”菜单（原来抽屉里的 6 个入口，加上参考 01 左下“应用”按钮进的“连接”，规范 docs/ios-ui-redesign.md
/// 4.2.1、4.8.1、6.1 A1）：系统的 `Menu`，按钮上是要你处理的事的总数（`ShellBadges.workbenchTotal`），每一项带副标题
/// （“3 条未读”）。点了都是顶级页面（`Router.openTopLevel`：关掉 sheet、回到首页再压它）。
///
/// 角标由按钮自己的 `toolbarBadge` 叠上去，各个系统都是（真 SDK 的工具栏项没有角标接口，`toolbarItemBadge` 现在原样返回）。
struct WorkbenchMenu: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let badges = model.badges
        Menu {
            ForEach(WorkbenchEntry.allCases, id: \.self) { entry in
                Button {
                    model.router.openTopLevel(entry.route)
                } label: {
                    // 第二个 `Text` 在系统菜单里显示成副标题。
                    Label {
                        Text(verbatim: entry.title(language))
                        if let subtitle = entry.subtitle(count: badges.count(for: entry), language: language) {
                            Text(verbatim: subtitle)
                        }
                    } icon: {
                        Image(systemName: entry.systemImage)
                    }
                }
            }
        } label: {
            // 读屏标签是 `Label` 的名字“工作台”，要处理的数由角标当按钮的值念（“工作台，5，弹出按钮”），只念一次。
            Label(ShellBadges.workbenchTitle(language), systemImage: "square.grid.2x2")
                .labelStyle(.iconOnly)
        }
        .toolbarBadge(badges.workbenchTotal)
    }
}

#Preview("工作台菜单") {
    let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
    NavigationStack {
        Text(verbatim: "首页")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { WorkbenchMenu(model: model) }
                    .toolbarItemBadge(model.badges.workbenchTotal)
            }
    }
    .task { await model.start() }
}
