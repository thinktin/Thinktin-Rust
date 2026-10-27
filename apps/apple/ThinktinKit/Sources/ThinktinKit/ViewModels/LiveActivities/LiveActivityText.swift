import Foundation

/// 实时活动上和设置里的文案、图标（WBS 12.10）。锁屏、灵动岛上只有状态、步数、耗时和实例名（推送里没有摘要和
/// agent 写的文字），文案跟着系统语言（扩展读不到 App 里选的语言）。
public enum LiveActivityText {
    /// 状态那一行：和对话里的运行状态行同一套说法（等 key 时按等待原因码分）。
    public static func headline(_ state: RunActivityContentState, language: DisplayLanguage) -> String {
        RunStatusPresentation(
            line: RunStatusLine(state: state.runState, waitCode: state.runWaitCode), language: language
        )
        .headline
    }

    public static func steps(_ count: Int, language: DisplayLanguage) -> String {
        if language == .chinese { return "\(count) 步" }
        return count == 1 ? "1 step" : "\(count) steps"
    }

    /// 结束了的运行用了多久（还在跑的用系统的计时器显示）。
    public static func elapsed(_ state: RunActivityContentState, language: DisplayLanguage) -> String? {
        guard let start = state.startDate, let end = state.endDate else { return nil }
        return Formatting.duration(max(0, end.timeIntervalSince(start)), language: language)
    }

    /// 状态的 SF Symbol。
    public static func symbol(_ state: RunState) -> String {
        switch state {
        case .queued, .starting: "clock"
        case .running: "bolt.fill"
        case .waitingApproval: "hand.raised.fill"
        case .waitingQuota: "key.fill"
        case .waitingDevice: "desktopcomputer"
        case .waitingChildren: "arrow.triangle.branch"
        case .backoff: "arrow.clockwise"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        case .unknown: "circle.dotted"
        }
    }

    /// 要用户做点什么（等审批、等 key 要处理）：灵动岛上用醒目的颜色。
    public static func needsAttention(_ state: RunActivityContentState) -> Bool {
        RunStatusLine(state: state.runState, waitCode: state.runWaitCode).nextStep.map {
            $0 == .approve || $0 == .configureKey
        } ?? false
    }

    // MARK: 设置、运行页

    public static func sectionTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "实时活动" : "Live Activities"
    }

    public static func myRuns(_ language: DisplayLanguage) -> String {
        language == .chinese ? "自己发的任务显示在锁屏上" : "Show my tasks on the Lock Screen"
    }

    public static func scheduledRuns(_ language: DisplayLanguage) -> String {
        language == .chinese ? "计划运行时也显示" : "Also show scheduled runs"
    }

    public static func footer(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "锁屏和灵动岛上只显示实例名、状态、步数和耗时，不显示任务内容和 agent 写的文字。计划运行要 iOS 17.2 以上，由服务端在到点时打开。"
            : "The Lock Screen and Dynamic Island show only the instance name, status, steps and time, never the task or what the agent wrote. Scheduled runs need iOS 17.2 or later and are opened by the server when they start."
    }

    public static func systemDisabled(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "系统设置里关掉了 ThinkTin 的实时活动：到“设置 > ThinkTin”里打开。"
            : "Live Activities are turned off for ThinkTin. Turn them on in Settings > ThinkTin."
    }

    /// 运行页上的按钮。
    public static func showOnLockScreen(_ language: DisplayLanguage) -> String {
        language == .chinese ? "在锁屏上显示" : "Show on Lock Screen"
    }

    public static func shownOnLockScreen(_ language: DisplayLanguage) -> String {
        language == .chinese ? "已在锁屏上显示" : "Showing on Lock Screen"
    }

    public static func couldNotStart(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "开不了实时活动：可能是系统设置里关掉了，或者同时开着的太多了。"
            : "Couldn't start the Live Activity. It may be turned off in Settings, or too many are running."
    }
}
