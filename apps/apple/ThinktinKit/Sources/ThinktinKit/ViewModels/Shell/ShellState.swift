import Foundation

/// 全局的几个数（WBS 12.16）：App 图标的角标（收件箱未读）、主屏小组件（未读、待审批、进行中，12.20）、设置里“审批”
/// 一行的副标题（待审批）。`AppModel.refreshBadges()` 拉，回到首页、回到前台时太久没刷新就再拉。
public struct ShellBadges: Hashable, Sendable {
    /// 收件箱未读（先读缓存的 `cachedUnread`，同步后用服务端的数）。
    public var inboxUnread: Int
    /// 待审批（还没过期的）。
    public var pendingApprovals: Int
    /// 进行中的运行（还没结束的，含排队、等待、重试）：实例列表里各实例的数加起来（`listRuns(filter: .active)`）。
    public var activeRuns: Int

    public init(inboxUnread: Int = 0, pendingApprovals: Int = 0, activeRuns: Int = 0) {
        self.inboxUnread = inboxUnread
        self.pendingApprovals = pendingApprovals
        self.activeRuns = activeRuns
    }

    public static let zero = ShellBadges()
}

extension ShellBadges {
    /// 小组件上的数字：超过 99 显示“99+”。
    public static func text(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

/// 一个实例进行中的运行概况（首页实例行的预览：等你处理的提示；“进行中”的数是各实例的 `activeRuns` 加起来）。
public struct InstanceActivity: Hashable, Sendable {
    /// 还没结束的运行。
    public var activeRuns: Int
    /// 在等什么的运行（审批、电脑、key、子任务）：首页这一行的预览换成“N 个在等你处理”。
    public var waitingRuns: Int
    /// 最近一个还没结束的运行的状态和创建时间；都结束了时为 nil。
    public var latestRunState: RunState?
    public var latestRunAt: Date?
    /// 最近一个在等你处理的运行的状态（等审批、等电脑、等 key、等子任务）：首页行的状态角标用；没有在等的时为 nil。
    public var latestWaitingState: RunState?

    public init(
        activeRuns: Int = 0, waitingRuns: Int = 0, latestRunState: RunState? = nil, latestRunAt: Date? = nil,
        latestWaitingState: RunState? = nil
    ) {
        self.activeRuns = activeRuns
        self.waitingRuns = waitingRuns
        self.latestRunState = latestRunState
        self.latestRunAt = latestRunAt
        self.latestWaitingState = latestWaitingState
    }

    /// 从一个实例的运行算，只看没结束的（`RunFilter.active`）：传 `listRuns(filter: .active)` 里这个实例的、缓存里最近的
    /// 一页（含已结束的）都行，顺序不对也没关系。
    public init(runs: [Run]) {
        let active = runs.filter(RunFilter.active.matches)
        let latest = active.max { $0.createdAt < $1.createdAt }
        let waiting = active.filter(\.state.isWaiting)
        self.init(
            activeRuns: active.count, waitingRuns: waiting.count, latestRunState: latest?.state,
            latestRunAt: latest?.createdAt, latestWaitingState: waiting.max { $0.createdAt < $1.createdAt }?.state)
    }

    /// 跨实例的一页运行（`listRuns(filter: .active)`）按实例分开算。没有进行中运行的实例不在结果里（就是 `.none`）。
    public static func byInstance(_ runs: [Run]) -> [InstanceID: InstanceActivity] {
        Dictionary(grouping: runs, by: \.instanceID).mapValues(InstanceActivity.init(runs:))
    }

    public static let none = InstanceActivity()

    /// 有运行在等用户处理。
    public var needsAttention: Bool { waitingRuns > 0 }
}

/// 顶部的连接横幅（事件流的连接状态汇总，docs/ios.md 第 5 节：connecting / reconnecting 在顶部显示细条）。
public enum ConnectionState: Hashable, Sendable {
    /// 都连着（或没有事件流）：不显示。
    case idle
    /// 正在连。
    case connecting
    /// 断开了，`retryAt` 重连。
    case reconnecting(retryAt: Date)

    public var isVisible: Bool { self != .idle }

    /// 横幅的文案（`now` 用来算还有几秒重连）；`idle` 为 nil。
    public func message(_ language: DisplayLanguage = .current, now: Date = Date()) -> String? {
        let zh = language == .chinese
        switch self {
        case .idle:
            return nil
        case .connecting:
            return zh ? "正在连接…" : "Connecting…"
        case .reconnecting(let retryAt):
            let seconds = Int(retryAt.timeIntervalSince(now).rounded(.up))
            if seconds <= 0 { return zh ? "正在重新连接…" : "Reconnecting…" }
            return zh ? "连接已断开，\(seconds) 秒后重连" : "Connection lost. Retrying in \(seconds)s"
        }
    }
}
