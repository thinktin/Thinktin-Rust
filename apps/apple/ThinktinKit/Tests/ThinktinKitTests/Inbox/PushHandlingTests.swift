import Foundation
import Testing

@testable import ThinktinKit

/// 记下通知中心收到的调用。
private actor RecordingNotifications: DeliveredNotifications {
    private(set) var removed = 0
    private(set) var badges: [Int] = []

    func removeAllDelivered() { removed += 1 }
    func setBadge(_ count: Int) { badges.append(count) }
}

@MainActor
@Suite("推送：点开标已读、通知上拒绝、令牌、角标（12.8）")
struct PushHandlingTests {
    private let approvalInbox: InboxItemID = "0192f3a0-0000-7000-8000-000000001001"

    @Test("点开推送：跳过去，对应的收件箱条目标已读，角标少一个")
    func openMarksRead() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        #expect(model.badges.inboxUnread == 3)
        let push = PushPayload(
            kind: .approval, instanceID: DemoData.writerID, approvalID: DemoData.pendingApprovalID,
            inboxItemID: approvalInbox)
        await model.open(push: push)
        #expect(model.router.path == [.approval(DemoData.pendingApprovalID)])
        #expect(model.badges.inboxUnread == 2)
        #expect(try await mock.inboxItem(approvalInbox).isRead)
    }

    @Test("通知上的拒绝：待处理的选拒绝选项；处理过的什么都不做")
    func rejectFromNotification() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        let push = PushPayload(kind: .approval, approvalID: DemoData.pendingApprovalID, inboxItemID: approvalInbox)
        #expect(await model.rejectFromNotification(push))
        #expect(try await mock.getApproval(DemoData.pendingApprovalID).state == .rejected)
        #expect(try await mock.inboxItem(approvalInbox).isRead)
        // 再点一次（通知没收起来）：已经不是待处理，不再决定。
        let calls = mock.callCount("decideApproval(_:optionID:)")
        #expect(!(await model.rejectFromNotification(push)))
        #expect(mock.callCount("decideApproval(_:optionID:)") == calls)
        // 不是审批的推送不管。
        #expect(!(await model.rejectFromNotification(PushPayload(kind: .runFinished))))
    }

    @Test("推送令牌：登录着就报，同一个不重复报；没登录时等登录后报")
    func pushToken() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        let token = PushRegistration.apns(deviceToken: Data([0xab, 0xcd]), sandbox: true)
        await model.didReceivePushToken(token)
        #expect(mock.callCount("setPushToken(_:)") == 1)
        #expect(model.pushRegistration == token)
        await model.didReceivePushToken(token)
        #expect(mock.callCount("setPushToken(_:)") == 1)

        let signedOutMock = makeShellMock(signedIn: false)
        let signedOut = AppModel(client: signedOutMock, defaults: nil)
        await signedOut.start()
        await signedOut.didReceivePushToken(token)
        #expect(signedOutMock.callCount("setPushToken(_:)") == 0)
        _ = try await signedOut.client.login(phone: "+8613800138000", code: signedOutMock.state.verificationCode)
        #expect(await eventually { signedOutMock.callCount("setPushToken(_:)") == 1 })
    }

    @Test("角标跟着未读数；退出登录清掉已送达的通知、角标设成 0")
    func notificationsAndBadge() async throws {
        let notifications = RecordingNotifications()
        let model = AppModel(client: makeShellMock(), defaults: nil, notifications: notifications)
        await model.start()
        #expect(await eventuallyAsync { await notifications.badges.last == 3 })
        model.inboxUnreadChanged(1)
        #expect(model.badges.inboxUnread == 1)
        #expect(await eventuallyAsync { await notifications.badges.last == 1 })
        try await model.signOut()
        #expect(await eventuallyAsync { await notifications.removed == 1 })
        #expect(await notifications.badges.last == 0)
        // 没登录时页面报的未读数不算。
        model.inboxUnreadChanged(5)
        #expect(model.badges.inboxUnread == 0)
    }

    @Test("通知类别：每种推送对应一类，只有云端审批有“拒绝”")
    func categories() {
        #expect(PushCategory(kind: .approval) == .approval)
        #expect(PushCategory(kind: .unknown("new_kind")) == .info)
        #expect(PushCategory.allCases.count == 7)
        #expect(PushCategory.approval.actions == [.reject])
        #expect(PushCategory.computerApproval.actions.isEmpty)
        #expect(PushCategory.allCases.filter { !$0.actions.isEmpty } == [.approval])
        for kind in PushPayload.Kind.knownCases {
            #expect(PushCategory(kind: kind).rawValue == kind.rawValue.uppercased())
        }
        #expect(PushNotificationAction.reject.title(.chinese) == "拒绝")
    }
}
