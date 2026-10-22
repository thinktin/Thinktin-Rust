import Foundation

/// 抽屉里的角标（WBS 12.16）。
public struct ShellBadges: Hashable, Sendable {
    /// 收件箱未读（先读缓存的 `cachedUnread`，同步后用服务端的数）。
    public var inboxUnread: Int
    /// 待审批（还没过期的）。
    public var pendingApprovals: Int
    /// 进行中的运行（还没结束的，含排队、等待、重试）。
    public var activeRuns: Int
    /// agent 建的、等用户确认的计划。
    public var plansAwaitingConfirmation: Int

    public init(inboxUnread: Int = 0, pendingApprovals: Int = 0, activeRuns: Int = 0, plansAwaitingConfirmation: Int = 0)
    {
        self.inboxUnread = inboxUnread
        self.pendingApprovals = pendingApprovals
        self.activeRuns = activeRuns
        self.plansAwaitingConfirmation = plansAwaitingConfirmation
    }

    public static let zero = ShellBadges()

    /// 抽屉入口上的数字；0 表示不显示角标。
    public func count(for entry: DrawerEntry) -> Int {
        switch entry {
        case .inbox: inboxUnread
        case .approvals: pendingApprovals
        case .activeRuns: activeRuns
        case .plans: plansAwaitingConfirmation
        case .teams, .artifacts: 0
        }
    }
}

/// 抽屉里的入口，从上到下（对应 Claude 侧边栏的 Chats、Projects、Artifacts、Code，见 ios-packages.md 的映射总表）。
public enum DrawerEntry: String, CaseIterable, Hashable, Sendable {
    case inbox
    case approvals
    case activeRuns
    case plans
    case teams
    case artifacts

    /// 点开去的页面（都是顶级页面，`Router.openFromDrawer`）。
    public var route: AppRoute {
        switch self {
        case .inbox: .inbox
        case .approvals: .approvals
        case .activeRuns: .activeRuns
        case .plans: .plans
        case .teams: .teams
        case .artifacts: .artifacts(instanceID: nil)
        }
    }

    public func title(_ language: DisplayLanguage = .current) -> String { route.title(language) }

    /// 角标的读屏文字（“3 条未读”）；0 时为 nil。
    public func badgeAccessibilityLabel(count: Int, language: DisplayLanguage = .current) -> String? {
        guard count > 0 else { return nil }
        let zh = language == .chinese
        switch self {
        case .inbox: return zh ? "\(count) 条未读" : "\(count) unread"
        case .approvals: return zh ? "\(count) 个待审批" : "\(count) waiting for approval"
        case .activeRuns: return zh ? "\(count) 个进行中" : "\(count) in progress"
        case .plans: return zh ? "\(count) 个待确认" : "\(count) to confirm"
        case .teams, .artifacts: return zh ? "\(count) 个" : "\(count)"
        }
    }
}

extension ShellBadges {
    /// 角标上的数字：超过 99 显示“99+”。
    public static func text(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

/// 一个实例最近的运行概况（抽屉里的实例行：在跑的点、等你处理的提示）。
public struct InstanceActivity: Hashable, Sendable {
    /// 还没结束的运行。
    public var activeRuns: Int
    /// 在等什么的运行（审批、电脑、key、子任务）：抽屉里这一行标“等你处理”。
    public var waitingRuns: Int
    /// 最近一次运行的状态和时间。
    public var latestRunState: RunState?
    public var latestRunAt: Date?

    public init(activeRuns: Int = 0, waitingRuns: Int = 0, latestRunState: RunState? = nil, latestRunAt: Date? = nil) {
        self.activeRuns = activeRuns
        self.waitingRuns = waitingRuns
        self.latestRunState = latestRunState
        self.latestRunAt = latestRunAt
    }

    /// 从实例最近的一页运行算（新的在前，顺序不对也没关系）。
    public init(runs: [Run]) {
        let latest = runs.max { $0.createdAt < $1.createdAt }
        self.init(
            activeRuns: runs.filter(\.state.isActive).count, waitingRuns: runs.filter(\.state.isWaiting).count,
            latestRunState: latest?.state, latestRunAt: latest?.createdAt)
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
