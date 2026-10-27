import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// IM 渠道（WBS 12.14）的界面：列表（有渠道、发送失败、空的）、新建和修改的表单在浅色中文、深色英文下都能布局。
/// 逻辑在 ThinktinKitTests/ImChannels 里测。
@MainActor
@Suite("IM 渠道的界面")
struct ImChannelScreensTests {
    private func layoutBoth(_ view: some View, client: (any ClientProtocol)? = nil) {
        hostAndLayout(view.previewShell(client: client))
        hostAndLayout(view.previewShell(.english, scheme: .dark, client: client))
    }

    @Test("接入点和列表：有渠道、发送失败、空的")
    func list() {
        layoutBoth(ImChannelsDestination(route: .imChannels))
        let failing = ShellPreviewClients.signedIn()
        failing.update { s in
            s.imChannels[0].isEnabled = false
            s.imChannels[0].lastError = "feishu 19001: the bot's webhook token is invalid (bot removed?)"
        }
        layoutBoth(ImChannelsScreen(), client: failing)
        let empty = ShellPreviewClients.signedIn()
        empty.update { $0.imChannels = [] }
        layoutBoth(ImChannelsScreen(), client: empty)
    }

    @Test("表单：新建、修改")
    func editor() async throws {
        layoutBoth(NavigationStack { ImChannelEditorView(channel: nil) { _ in } })
        let mock = ShellPreviewClients.signedIn()
        let channel = try #require(try await mock.imChannels().first)
        layoutBoth(NavigationStack { ImChannelEditorView(channel: channel) { _ in } }, client: mock)
    }
}
