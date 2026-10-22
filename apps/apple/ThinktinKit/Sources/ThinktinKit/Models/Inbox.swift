import Foundation

/// 收件箱条目（运行结束、失败、待审批、保险箱请求、计划待确认、通知）。
public struct InboxItem: Identifiable, Hashable, Codable, Sendable {
    public var id: InboxItemID
    public var instanceID: InstanceID?
    public var runID: RunID?
    public var planID: PlanID?
    public var approvalID: ApprovalID?
    /// 保险箱请求（10.7，`kind` 是 `vaultRequest` 时有，`thinktin://vault/request/{id}`）。
    public var vaultRequestID: VaultRequestID?
    public var kind: InboxKind
    /// 是哪一种提醒（10.7，和推送的 `tt.subtype` 一样，docs/push.md 第 4 节）：App 据此跳转、刷新，不用解析文字。
    /// 没有、老的服务端为 nil；不认识的按 `kind` 显示。
    public var subtype: NotificationSubtype?
    public var title: String
    public var body: String
    /// 正文是 agent 生成的：显示时要带“AI 生成”标识（16.3）。
    public var isAIGenerated: Bool
    public var isRead: Bool
    public var createdAt: Date

    public init(
        id: InboxItemID, instanceID: InstanceID? = nil, runID: RunID? = nil, planID: PlanID? = nil,
        approvalID: ApprovalID? = nil, vaultRequestID: VaultRequestID? = nil, kind: InboxKind,
        subtype: NotificationSubtype? = nil, title: String, body: String, isAIGenerated: Bool = false,
        isRead: Bool = false, createdAt: Date
    ) {
        self.id = id
        self.instanceID = instanceID
        self.runID = runID
        self.planID = planID
        self.approvalID = approvalID
        self.vaultRequestID = vaultRequestID
        self.kind = kind
        self.subtype = subtype
        self.title = title
        self.body = body
        self.isAIGenerated = isAIGenerated
        self.isRead = isRead
        self.createdAt = createdAt
    }
}

/// 提醒的子类型（10.7，推送的 `tt.subtype`、收件箱条目的 `subtype`，docs/push.md 第 4 节）。
/// 是开放的字符串：以后会加新值，不认识的（`unknown`）按 `kind` 显示。
public enum NotificationSubtype: OpenStringEnum {
    /// 账号被冻结（`info`）：显示冻结页。
    case accountFrozen
    /// 账号解冻（`info`）：重查账号、重新订阅事件流、同步收件箱。
    case accountRestored
    /// 点了“全部停止”（`info`）：刷新运行和计划。
    case stoppedAll
    /// 审批超时、按策略跳过了这一步（`info`，带审批 id）：进运行详情。
    case approvalSkipped
    /// 计划的触发规则失效、被停用（`info`，带计划 id）：进计划详情，让用户删掉重加。
    case triggerDisabled
    /// IM 群机器人失效、渠道被停用（`info`）：进 IM 渠道设置。
    case imChannelDisabled
    /// 内容举报处理完（`info`）：进举报记录。
    case reportHandled
    /// 运行进入要用户处理的等待（`run_failed`，和 `Run.waitCode` 一样）：去换 key、充值、开电脑。
    case waiting(RunWaitCode)
    case unknown(String)

    public static let knownCases: [NotificationSubtype] =
        [.accountFrozen, .accountRestored, .stoppedAll, .approvalSkipped, .triggerDisabled, .imChannelDisabled,
         .reportHandled] + RunWaitCode.knownCases.map(NotificationSubtype.waiting)

    public var rawValue: String {
        switch self {
        case .accountFrozen: "account_frozen"
        case .accountRestored: "account_restored"
        case .stoppedAll: "stopped_all"
        case .approvalSkipped: "approval_skipped"
        case .triggerDisabled: "trigger_disabled"
        case .imChannelDisabled: "im_channel_disabled"
        case .reportHandled: "report_handled"
        case .waiting(let code): code.rawValue
        case .unknown(let raw): raw
        }
    }

    /// 运行在等什么（`waiting` 时）。
    public var waitCode: RunWaitCode? {
        if case .waiting(let code) = self { return code }
        return nil
    }

    /// 账号状态变了（冻结、解冻）：`AppModel.receive(push:)` 处理。
    public var changesAccountState: Bool { self == .accountFrozen || self == .accountRestored }
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
