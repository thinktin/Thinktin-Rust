import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 云端审批（WBS 12.15）的界面：审批中心和详情在浅色中文、深色英文、大字号下都能布局；没有审批、已过期、找不到、
/// 卡片的几种状态（待处理、已批准、验证没过、接口出错）。视图模型的逻辑在 ThinktinKitTests 的 Approvals 里测。
@MainActor
@Suite("云端审批的界面")
struct ApprovalsScreensTests {
    static let routes: [AppRoute] = [.approvals, .approval(DemoData.pendingApprovalID), .approval("approval-gone")]

    private static func client(approvals: [Approval]? = nil) -> MockClient {
        var state = DemoData.state()
        if let approvals { state.approvals = approvals }
        return MockClient(state: state, stepDelay: 0)
    }

    @Test("每个页面都能布局（中文浅色、英文深色、大字号）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(ApprovalsDestination(route: route).previewShell(client: Self.client()))
            hostAndLayout(
                ApprovalsDestination(route: route).previewShell(.english, scheme: .dark, client: Self.client()))
            hostAndLayout(
                ApprovalsDestination(route: route).previewShell(client: Self.client())
                    .dynamicTypeSize(.accessibility3))
        }
    }

    @Test("没有审批、已过期的详情")
    func states() {
        hostAndLayout(ApprovalCenterScreen().previewShell(client: Self.client(approvals: [])))
        let expired = Self.client()
        _ = expired.expireApproval(DemoData.pendingApprovalID)
        hostAndLayout(
            ApprovalDetailScreen(approvalID: DemoData.pendingApprovalID).previewShell(
                .english, scheme: .dark, client: expired))
    }

    @Test("卡片：待处理、已批准、验证没过、接口出错、实例已删除")
    func cards() throws {
        let approval = try #require(DemoData.state().approvals.first)
        var approved = approval
        approved.state = .approved
        approved.decidedOption = "allow"
        approved.decidedAt = Date()
        let errors: [ConversationActionError?] = [
            nil, .verificationFailed, .client(.network(message: "offline")),
        ]
        for record in [approval, approved] {
            for error in errors {
                for name in ["写作助手", nil] as [String?] {
                    let card = ApprovalRequestCard(
                        approval: record, instanceName: name, now: Date(), isDeciding: false, error: error,
                        canWrite: true, showsDetails: name == nil, onDecide: { _ in }, onClearError: {},
                        onOpen: name == nil ? nil : {})
                    hostAndLayout(card.previewShell())
                    hostAndLayout(card.previewShell(.english, scheme: .dark))
                }
            }
        }
    }
}
