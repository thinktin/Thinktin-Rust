import Foundation

/// 运行状态行上的一键跳转。
public enum RunStatusAction: Hashable, Sendable {
    /// 等审批：滚到这一组里的待处理审批卡片（找不到时去审批中心）。
    case scrollToApproval
    /// 等 key、key 要处理：去这个实例的模型路由。
    case openModelRoutes
    /// 等子任务：去运行树。
    case openRunTree
}

/// 运行状态行怎么显示（docs/ios-packages.md 12.5 第一条“运行状态文案按 state 在本地生成”）：
///
/// - 主文案按状态本地化（等你审批、等 key、等电脑上线、等子任务、第 N 次尝试、成功、失败、已取消）；
/// - 等 key 时按等待原因码分（11.8）：key 无效、欠费、没有能用的 key 要去处理（`openModelRoutes`），限流、服务繁忙
///   几分钟后自己继续（没有按钮）；服务端按用户语言写的说明（`reason`）当正文显示；
/// - 等审批时 `reason` 是 agent 写的审批标题：放进详情、带 AI 生成标识；
/// - 失败、退避的 `reason` / `error` 是平台的英文诊断：正文只说“任务失败”，英文原文放进可以展开的详情。
public struct RunStatusPresentation: Hashable, Sendable {
    public var headline: String
    /// 可以当正文显示的说明（已经本地化的）。
    public var detail: String?
    /// 放进详情的原文（agent 写的审批标题、英文诊断）；没有为 nil。
    public var reason: String?
    /// `reason` 是 agent 写的（要带 AI 生成标识）。
    public var reasonIsAIGenerated: Bool
    public var action: RunStatusAction?
    public var actionTitle: String?

    public init(line: RunStatusLine, instanceState: InstanceState? = nil, language: DisplayLanguage) {
        let zh = language == .chinese
        var detail: String?
        var reason: String?
        var action: RunStatusAction?
        var actionTitle: String?
        let attempt = line.attempt ?? 1
        let headline: String
        switch line.state {
        case .queued:
            headline = zh ? "排队中" : "Queued"
            detail = zh ? "前面的任务完成后开始" : "Starts when the task ahead finishes"
        case .starting:
            headline = zh ? "正在启动" : "Starting"
            detail = ConversationText.instanceBanner(instanceState, isStarting: true, language: language)
        case .running:
            headline = zh ? "正在进行" : "Working"
            if attempt > 1 {
                detail = zh ? "第 \(attempt) 次尝试，已从断点接着跑" : "Attempt \(attempt), resumed where it left off"
            }
        case .waitingApproval:
            headline = zh ? "等你审批" : "Waiting for your approval"
            reason = line.reason
            action = .scrollToApproval
            actionTitle = zh ? "去审批" : "Review"
        case .waitingQuota:
            switch line.waitCode {
            case .invalid?:
                headline = zh ? "模型 key 无效或没有权限" : "The model key is invalid or lacks access"
            case .noBalance?:
                headline = zh ? "模型 key 欠费或额度用完了" : "The model key is out of credit"
            case .unavailable?:
                headline = zh ? "没有能用的模型 key" : "No usable model key"
            case .rateLimited?:
                headline = zh ? "模型服务限流，稍后自动继续" : "Rate limited by the model provider. It will continue shortly."
            case .overloaded?:
                headline = zh ? "模型服务繁忙，稍后自动继续" : "The model provider is busy. It will continue shortly."
            default:
                headline = zh ? "等待模型 key" : "Waiting for a model key"
            }
            // 服务端按用户语言写的说明，可以当正文。
            detail = line.reason
            if line.waitCode?.isTransient != true {
                action = .openModelRoutes
                actionTitle = zh ? "去处理" : "Fix it"
                if line.waitCode?.needsKeyAction == true, detail == nil {
                    detail = zh ? "处理好之后会接着跑（每小时也会自己再试一次）。" : "It picks up again once fixed (and retries every hour)."
                }
            }
        case .waitingDevice:
            headline = zh ? "等电脑上线" : "Waiting for your computer"
            detail = zh ? "电脑上线后会自动继续。" : "It continues automatically once your computer is online."
        case .waitingChildren:
            headline = zh ? "等子任务完成" : "Waiting for subtasks"
            action = .openRunTree
            actionTitle = ConversationText.openRunTree(language)
        case .backoff:
            headline = zh ? "出了点问题，稍后重试" : "Hit a problem. Retrying soon."
            detail = ConversationText.attempt(attempt, language: language)
            reason = line.reason
        case .succeeded:
            headline = zh ? "已完成" : "Done"
            detail = Self.stats(line, language: language)
        case .failed:
            headline = zh ? "任务失败" : "The task failed"
            detail = Self.stats(line, language: language)
            reason = line.error ?? line.reason
        case .cancelled:
            headline = zh ? "已取消" : "Cancelled"
        case .unknown:
            headline = zh ? "未知状态" : "Unknown state"
        }
        self.headline = headline
        self.detail = detail
        self.reason = reason?.isEmpty == true ? nil : reason
        self.reasonIsAIGenerated = AIGeneratedField.stateReason(for: line.state).isAIGenerated
        self.action = action
        self.actionTitle = actionTitle
    }

    /// “用时 1 分 30 秒 · 1.8 万 token”。
    static func stats(_ line: RunStatusLine, language: DisplayLanguage) -> String? {
        var parts: [String] = []
        if let start = line.startedAt, let end = line.finishedAt {
            let label = language == .chinese ? "用时 " : ""
            parts.append(label + Formatting.duration(end.timeIntervalSince(start), language: language))
        }
        if let tokens = line.tokensUsed, tokens > 0 {
            parts.append(ConversationText.tokens(tokens, language: language))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
