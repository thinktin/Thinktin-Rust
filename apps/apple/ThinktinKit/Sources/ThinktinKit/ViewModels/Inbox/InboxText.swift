import Foundation

/// 收件箱、收件箱里的一条的文案（WBS 12.8）。
public enum InboxText {
    /// 条目种类的小标签。
    public static func kind(_ kind: InboxKind, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch kind {
        case .runFinished: return zh ? "运行完成" : "Run finished"
        case .runFailed: return zh ? "要你处理" : "Needs attention"
        case .approval: return zh ? "待审批" : "Approval"
        case .computerApproval: return zh ? "电脑审批" : "Computer approval"
        case .vaultRequest: return zh ? "保险箱请求" : "Vault request"
        case .planConfirm: return zh ? "计划待确认" : "Plan to confirm"
        case .info, .unknown: return zh ? "提醒" : "Notice"
        }
    }

    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "收件箱是空的" : "Your inbox is empty"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "运行完成、失败，agent 要你审批、填账号密码、确认计划时，这里和通知里都会出现。"
            : "Finished and failed runs, approvals, vault requests and plans to confirm show up here and in "
                + "notifications."
    }

    public static func markAllRead(_ language: DisplayLanguage) -> String {
        language == .chinese ? "全部已读" : "Mark all as read"
    }

    public static func markRead(_ language: DisplayLanguage) -> String {
        language == .chinese ? "标为已读" : "Mark as read"
    }

    public static func markUnread(_ language: DisplayLanguage) -> String {
        language == .chinese ? "标为未读" : "Mark as unread"
    }

    public static func delete(_ language: DisplayLanguage) -> String {
        language == .chinese ? "删除" : "Delete"
    }

    /// 未读的小圆点（读屏）。
    public static func unread(_ language: DisplayLanguage) -> String {
        language == .chinese ? "未读" : "Unread"
    }

    /// 列表顶上的未读数。
    public static func unreadCount(_ count: Int, language: DisplayLanguage) -> String {
        if count == 0 { return language == .chinese ? "都读过了" : "All caught up" }
        return language == .chinese ? "\(count) 条未读" : (count == 1 ? "1 unread" : "\(count) unread")
    }

    /// 详情页去对应页面的按钮。
    public static func open(_ route: AppRoute, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch route {
        case .approval, .approvals: return zh ? "去审批" : "Review the approval"
        case .run: return zh ? "查看这次运行" : "View the run"
        case .conversation: return zh ? "打开对话" : "Open the conversation"
        case .vaultRequest: return zh ? "去填写" : "Fill in the request"
        case .confirmPlan: return zh ? "去确认计划" : "Review the plan"
        default: return zh ? "查看" : "Open"
        }
    }

    public static func missingTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "找不到这条通知" : "Notification not found"
    }

    public static func missingMessage(_ language: DisplayLanguage) -> String {
        language == .chinese ? "可能已经在别的设备上删掉了。" : "It may have been deleted on another device."
    }

    public static func loadingOlder(_ language: DisplayLanguage) -> String {
        language == .chinese ? "正在加载更早的通知" : "Loading older notifications"
    }
}
