import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 连接（规范 4.8，参考 36–52、101–107）的界面：目录（全部、各分类、搜索）、已连接、完整列表、详情（已连接、没设置、演示、
/// 带技能、找不到）在浅色中文、深色英文下都能布局。逻辑在 ThinktinKitTests/Connections 里测。
@MainActor
@Suite("连接的界面")
struct ConnectionsScreensTests {
    private func layoutBoth(_ view: some View, client: (any ClientProtocol)? = nil) {
        hostAndLayout(view.previewShell(client: client))
        hostAndLayout(view.previewShell(.english, scheme: .dark, client: client))
    }

    @Test("接入点：目录、已连接、完整列表、详情")
    func destination() {
        for route in [
            AppRoute.connections(category: nil), .connections(category: .thisDevice), .connectedApps,
            .connectionList(.recommended), .connectionList(.featured), .connection(ConnectionsDemoData.vaultID),
        ] {
            layoutBoth(ConnectionsDestination(route: route))
        }
    }

    @Test("目录：每个分类都能排；没有群、key 的账号")
    func catalog() {
        for category in ConnectionCategory.allCases {
            layoutBoth(ConnectionsCatalogScreen(category: category))
        }
        let empty = ShellPreviewClients.signedIn()
        empty.update { s in
            s.imChannels = []
            s.credentials = []
            s.vaultItems = []
        }
        layoutBoth(ConnectionsCatalogScreen(), client: empty)
        layoutBoth(ConnectedAppsScreen(), client: empty)
    }

    @Test("详情：已连接、没设置、演示、带技能、手机能力、找不到；sheet 和压栈两种")
    func detail() {
        let ids: [ConnectionID] = [
            ConnectionsDemoData.computerID, ConnectionsDemoData.feishuID, ConnectionsDemoData.wecomID,
            ConnectionsDemoData.modelKeysID, ConnectionsDemoData.codeHostingID, ConnectionsDemoData.calendarID,
            "help-desk", "nope",
        ]
        for id in ids {
            layoutBoth(ConnectionDetailScreen(connectionID: id))
        }
        let model = ConnectionsModel(client: ShellPreviewClients.signedIn())
        layoutBoth(
            NavigationStack { ConnectionDetailView(model: model, connectionID: ConnectionsDemoData.vaultID) { _ in } })
    }

    @Test("组件：图标的各种底色、行、组标题")
    func components() {
        for tint in ConnectionIconTint.allCases {
            renderInBothAppearances(ConnectionIcon(systemImage: "puzzlepiece.extension", tint: tint, size: 40))
        }
        renderInBothAppearances(ConnectionSectionHeading(title: "推荐", explanation: "说明") {})
        renderInBothAppearances(ConnectionSectionHeading(title: "效率"))
    }

    @Test("详情的说明：短的不折叠，长的默认两行带“更多”")
    func description() {
        #expect(ConnectionDescription.collapsedLines == 2)
        renderInBothAppearances(ConnectionDescription(text: "短说明。"))
        renderInBothAppearances(
            ConnectionDescription(text: String(repeating: "配对以后，Botin 能借你的电脑执行命令、打开应用。", count: 6)))
    }

    @Test("版式：行、标题和胶囊左右对齐；已连接列表比目录松")
    func layout() {
        let rows = [ConnectionsLayout.rowInsets, ConnectionsLayout.installedRowInsets, ConnectionsLayout.headingInsets]
        for insets in rows {
            #expect(insets.leading == ConnectionsLayout.horizontal)
            #expect(insets.trailing == ConnectionsLayout.horizontal)
        }
        #expect(ConnectionsLayout.installedRowInsets.top > ConnectionsLayout.rowInsets.top)
        #expect(ConnectionsLayout.smallPillHeight < ConnectionsLayout.largePillHeight)
    }
}
