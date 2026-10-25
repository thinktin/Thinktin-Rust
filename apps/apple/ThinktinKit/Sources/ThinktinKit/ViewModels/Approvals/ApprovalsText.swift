import Foundation

/// 审批中心、审批详情的文案（WBS 12.15）。对话里审批卡片的文案在 `ConversationText`（结论、选项名、剩余时间、本机验证），
/// 这里只放两个页面自己的。
public enum ApprovalsText {
    public static func intro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "agent 要做的事超出了预授权的范围，要你决定。没人处理的到期后按计划的策略办（默认暂停计划）。"
            : "These actions are outside what you pre-approved. Unanswered ones follow the plan's rule when they "
                + "expire (by default the plan pauses)."
    }

    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "没有等你处理的审批" : "Nothing to approve"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "agent 需要你批准时，这里和通知里都会出现。" : "When an agent needs your OK, it shows up here and in notifications."
    }

    /// 实例已经删除（列表里找不到名字）。
    public static func deletedInstance(_ language: DisplayLanguage) -> String {
        language == .chinese ? "已删除的实例" : "Deleted instance"
    }

    public static func requestedAt(_ date: Date, language: DisplayLanguage) -> String {
        let text = Formatting.dateTime(date, language: language)
        return language == .chinese ? "请求于 \(text)" : "Requested \(text)"
    }

    public static func decidedAt(_ date: Date, language: DisplayLanguage) -> String {
        let text = Formatting.dateTime(date, language: language)
        return language == .chinese ? "处理于 \(text)" : "Decided \(text)"
    }

    public static func toolCallTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "要执行的操作" : "What the agent wants to do"
    }

    public static func rawDetails(_ language: DisplayLanguage) -> String {
        language == .chinese ? "原始内容" : "Raw details"
    }

    public static func openRun(_ language: DisplayLanguage) -> String {
        language == .chinese ? "查看这次运行" : "View the run"
    }

    public static func openConversation(_ language: DisplayLanguage) -> String {
        language == .chinese ? "打开对话" : "Open the conversation"
    }

    public static func viewDetails(_ language: DisplayLanguage) -> String {
        language == .chinese ? "详情" : "Details"
    }

    /// 处理完一条之后的提示。
    public static func notice(_ notice: ApprovalNotice, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch notice {
        case .decided(_, let option):
            let name =
                option.name.isEmpty ? ConversationText.approvalOptionName(option.kind, language: language) : option.name
            if option.kind.isReject { return zh ? "已拒绝（\(name)）" : "Declined (\(name))" }
            return zh ? "已批准（\(name)），agent 会接着做" : "Approved (\(name)). The agent carries on."
        case .alreadyHandled(let approval):
            if approval.isExpired() || approval.state == .expired {
                return zh ? "这条审批已经过期了" : "This approval has expired"
            }
            return zh ? "这条审批已经在别处处理过了" : "This approval was already handled elsewhere"
        }
    }

    public static func handledElsewhere(_ language: DisplayLanguage) -> String {
        language == .chinese ? "这条审批已经在别处处理过了，下面是结果。" : "This approval was already handled. Here's the result."
    }

    public static func missingTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "找不到这条审批" : "Approval not found"
    }

    public static func missingMessage(_ language: DisplayLanguage) -> String {
        language == .chinese ? "它可能已经被清理了。" : "It may have been cleaned up."
    }
}
