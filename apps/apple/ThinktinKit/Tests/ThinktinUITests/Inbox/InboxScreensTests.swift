import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 推送与收件箱（WBS 12.8）的界面：收件箱和一条通知在浅色中文、深色英文、大字号下都能布局；空的收件箱、找不到的通知、
/// 每种条目的行（已读、未读、正在处理）。视图模型的逻辑在 ThinktinKitTests 的 Inbox 里测。
@MainActor
@Suite("推送与收件箱的界面")
struct InboxScreensTests {
    static let routes: [AppRoute] = [
        .inbox, .inboxItem("0192f3a0-0000-7000-8000-000000001001"), .inboxItem("0192f3a0-0000-7000-8000-000000001099"),
    ]

    private static func client(inbox: [InboxItem]? = nil) -> MockClient {
        var state = DemoData.state()
        if let inbox { state.inbox = inbox }
        return MockClient(state: state, stepDelay: 0)
    }

    @Test("每个页面都能布局（中文浅色、英文深色、大字号）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(InboxDestination(route: route).previewShell(client: Self.client()))
            hostAndLayout(InboxDestination(route: route).previewShell(.english, scheme: .dark, client: Self.client()))
            hostAndLayout(
                InboxDestination(route: route).previewShell(client: Self.client())
                    .dynamicTypeSize(.accessibility3))
        }
    }

    @Test("空的收件箱")
    func empty() {
        hostAndLayout(InboxScreen().previewShell(client: Self.client(inbox: [])))
    }

    @Test("每种条目的行和全文")
    func rows() {
        for item in DemoData.state().inbox {
            for busy in [false, true] {
                let row = InboxRow(
                    item: item, isBusy: busy, canWrite: !busy, onOpen: {}, onToggleRead: {}, onDelete: {})
                hostAndLayout(row.previewShell())
                hostAndLayout(row.previewShell(.english, scheme: .dark))
            }
            hostAndLayout(InboxItemCard(item: item).previewShell())
        }
        for kind in InboxKind.knownCases + [.unknown("new")] {
            #expect(!InboxKindIcon.systemImage(kind).isEmpty)
        }
    }
}
