import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 保险箱（WBS 12.13）的界面：保险箱、条目、填写请求（等你填、已有同名、处理过、找不到），新建 / 修改条目的表单，
/// 在浅色中文、深色英文、大字号下都能布局。视图模型的逻辑在 ThinktinKitTests 的 Vault 里测。
@MainActor
@Suite("保险箱的界面")
struct VaultScreensTests {
    static let routes: [AppRoute] = [
        .vault, .vaultItem(DemoData.githubVaultID), .vaultItem(DemoData.ossVaultID), .vaultItem("gone"),
        .vaultRequest(DemoData.npmVaultRequestID), .vaultRequest("vr-gh"), .vaultRequest("vr-done"),
        .vaultRequest("vr-gone"),
    ]

    private static func client(empty: Bool = false) -> MockClient {
        var state = DemoData.state()
        if empty {
            state.vaultItems = []
            state.vaultRequests = []
        } else {
            state.vaultRequests += [
                VaultRequest(
                    id: "vr-gh", instanceID: DemoData.writerID, name: "github", purpose: "推送到另一个仓库",
                    createdAt: Date(), expiresAt: Date().addingTimeInterval(3600)),
                VaultRequest(
                    id: "vr-done", instanceID: DemoData.writerID, name: "pypi", purpose: "发布", status: .fulfilled,
                    itemID: DemoData.githubVaultID, createdAt: Date(), expiresAt: Date().addingTimeInterval(3600)),
            ]
        }
        return MockClient(state: state, stepDelay: 0)
    }

    @Test("每个页面都能布局（中文浅色、英文深色、大字号）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(VaultDestination(route: route).previewShell(client: Self.client()))
            hostAndLayout(VaultDestination(route: route).previewShell(.english, scheme: .dark, client: Self.client()))
            hostAndLayout(
                VaultDestination(route: route).previewShell(client: Self.client()).dynamicTypeSize(.accessibility3))
        }
        hostAndLayout(VaultScreen().previewShell(client: Self.client(empty: true)))
    }

    @Test("新建、修改条目的表单")
    func editor() {
        for itemID in [nil, DemoData.ossVaultID] as [VaultItemID?] {
            hostAndLayout(VaultItemEditorView(itemID: itemID) { _ in }.previewShell(client: Self.client()))
            hostAndLayout(
                VaultItemEditorView(itemID: itemID) { _ in }.previewShell(
                    .english, scheme: .dark, client: Self.client()
                )
                .dynamicTypeSize(.accessibility3))
        }
    }
}
