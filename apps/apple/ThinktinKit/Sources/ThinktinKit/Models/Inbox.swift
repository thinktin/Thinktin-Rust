import Foundation

/// 收件箱条目（运行结束、失败、待审批、通知）。
public struct InboxItem: Identifiable, Hashable, Codable, Sendable {
    public var id: InboxItemID
    public var instanceID: InstanceID?
    public var runID: RunID?
    public var planID: PlanID?
    public var approvalID: ApprovalID?
    public var kind: InboxKind
    public var title: String
    public var body: String
    /// 正文是 agent 生成的：显示时要带“AI 生成”标识（16.3）。
    public var isAIGenerated: Bool
    public var isRead: Bool
    public var createdAt: Date

    public init(
        id: InboxItemID, instanceID: InstanceID? = nil, runID: RunID? = nil, planID: PlanID? = nil,
        approvalID: ApprovalID? = nil, kind: InboxKind, title: String, body: String, isAIGenerated: Bool = false,
        isRead: Bool = false, createdAt: Date
    ) {
        self.id = id
        self.instanceID = instanceID
        self.runID = runID
        self.planID = planID
        self.approvalID = approvalID
        self.kind = kind
        self.title = title
        self.body = body
        self.isAIGenerated = isAIGenerated
        self.isRead = isRead
        self.createdAt = createdAt
    }
}

/// 收件箱的一页（最新的在前）和未读数。
public struct InboxPage: Hashable, Codable, Sendable {
    public var items: [InboxItem]
    public var unread: Int

    public init(items: [InboxItem], unread: Int) {
        self.items = items
        self.unread = unread
    }
}
