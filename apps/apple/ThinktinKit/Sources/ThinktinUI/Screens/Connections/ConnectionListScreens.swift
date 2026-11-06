import SwiftUI
import ThinktinKit

/// 已连接（`.connectedApps`；规范 4.8.2，参考 37）：目录右上“已连接 N 个”压进来。
///
/// - plain 列表：灰色小标题“ThinkTin 自带”（参考 37 这里是“已安装”；ThinkTin 的这几项不是装上去的），下面是自带的几项
///   （电脑、飞书、企业微信、钉钉、模型 key、保险箱）；连上的写账户数（参考“2 个连接器”的位置）、右边灰底的“已连接”，没设置的
///   写说明、右边突出的“添加”“配对”（参考“授权”的位置）。行比目录松（参考 37 一行约 78pt，`ConnectionsLayout`）。
/// - 点行弹详情 sheet（账户、管理）；底部搜索框（参考“搜索插件”）。最后一段灰字说第三方应用即将推出。
struct ConnectedAppsScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        ConnectedAppsContent(client: client)
    }
}

private struct ConnectedAppsContent: View {
    @State private var model: ConnectionsModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: ConnectionsModel(client: client, onPhone: ConnectionsPlatform.isPhone))
    }

    var body: some View {
        let model = self.model
        ConnectionsHost(model: model) { actions in
            let rows = model.installedRows(language)
            List {
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                        .connectionListRow()
                }
                if !rows.isEmpty {
                    Text(ConnectionsText.installedHeader(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .connectionListRow(insets: ConnectionsLayout.installedHeaderInsets)
                }
                ForEach(rows) { row in
                    ConnectionRowView(row: row, actions: actions)
                        .connectionListRow(insets: ConnectionsLayout.installedRowInsets)
                }
                if model.query.isEmpty {
                    Text(ConnectionsText.installedFootnote(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .connectionListRow(insets: ConnectionsLayout.footnoteInsets)
                }
            }
            .listStyle(.plain)
            .themedGroupedBackground()
            .overlay {
                if rows.isEmpty, !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .inlineNavigationTitle(AppRoute.connectedApps.title(language))
            .searchable(text: $model.query, prompt: Text(ConnectionsText.installedSearchPrompt(language)))
            .refreshable { await model.load() }
            .task { await model.load() }
            .onChange(of: app.isOffline) {
                if !app.isOffline { Task { await model.load() } }
            }
            .onChange(of: router.visibleRoute) {
                // 从 IM 渠道、模型 key 这些页面回来时重新数一遍。
                if router.visibleRoute == .connectedApps { Task { await model.load() } }
            }
        }
    }
}

/// 目录里一组的完整列表（`.connectionList(_:)`；规范 4.8.4，参考 101–104）：“推荐 >”“精选 >”压进来。
/// plain 列表，行同目录（推荐的行写推荐理由），一次显示完、不分页；点行弹详情 sheet。
struct ConnectionListScreen: View {
    let list: ConnectionList

    @Environment(\.client) private var client

    var body: some View {
        ConnectionListContent(client: client, list: list)
    }
}

private struct ConnectionListContent: View {
    let list: ConnectionList
    @State private var model: ConnectionsModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, list: ConnectionList) {
        self.list = list
        _model = State(initialValue: ConnectionsModel(client: client, onPhone: ConnectionsPlatform.isPhone))
    }

    var body: some View {
        let model = self.model
        ConnectionsHost(model: model) { actions in
            List {
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                        .connectionListRow()
                }
                ForEach(model.listRows(list, language: language)) { row in
                    ConnectionRowView(row: row, actions: actions)
                        .connectionListRow(insets: ConnectionsLayout.rowInsets)
                }
            }
            .listStyle(.plain)
            .themedGroupedBackground()
            .inlineNavigationTitle(AppRoute.connectionList(list).title(language))
            .refreshable { await model.load() }
            .task { await model.load() }
            .onChange(of: app.isOffline) {
                if !app.isOffline { Task { await model.load() } }
            }
        }
    }
}

#Preview("已连接 · 浅色中文") {
    ConnectedAppsScreen().previewShell()
}

#Preview("已连接 · 深色英文") {
    ConnectedAppsScreen().previewShell(.english, scheme: .dark)
}

#Preview("推荐 · 浅色中文") {
    ConnectionListScreen(list: .recommended).previewShell()
}

#Preview("精选 · 深色英文") {
    ConnectionListScreen(list: .featured).previewShell(.english, scheme: .dark)
}
