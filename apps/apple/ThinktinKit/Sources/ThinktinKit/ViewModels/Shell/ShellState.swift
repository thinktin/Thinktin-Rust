import Foundation

/// 首页左下“工作台”菜单（原来的抽屉入口，规范 docs/ios-ui-redesign.md 6.1 A1）上的数（WBS 12.16）。
public struct ShellBadges: Hashable, Sendable {
    /// 收件箱未读（先读缓存的 `cachedUnread`，同步后用服务端的数）。
    public var inboxUnread: Int
    /// 待审批（还没过期的）。
    public var pendingApprovals: Int
    /// 进行中的运行（还没结束的，含排队、等待、重试）：实例列表里各实例的数加起来（`listRuns(filter: .active)`）。
    public var activeRuns: Int
    /// agent 建的、等用户确认的计划。
    public var plansAwaitingConfirmation: Int

    public init(
        inboxUnread: Int = 0, pendingApprovals: Int = 0, activeRuns: Int = 0, plansAwaitingConfirmation: Int = 0
    ) {
        self.inboxUnread = inboxUnread
        self.pendingApprovals = pendingApprovals
        self.activeRuns = activeRuns
        self.plansAwaitingConfirmation = plansAwaitingConfirmation
    }

    public static let zero = ShellBadges()

    /// 菜单项上的数（副标题“3 条未读”）；0 表示不显示。
    public func count(for entry: WorkbenchEntry) -> Int {
        switch entry {
        case .inbox: inboxUnread
        case .approvals: pendingApprovals
        case .activeRuns: activeRuns
        case .plans: plansAwaitingConfirmation
        case .teams, .artifacts: 0
        }
    }

    /// 工作台按钮上的总角标：要你处理的事（收件箱未读、待审批、待确认的计划）加起来。进行中的运行是状态、不是待办，
    /// 不算进总数，只在菜单项“进行中”的副标题上显示。0 表示不显示角标。
    public var workbenchTotal: Int {
        WorkbenchEntry.allCases.filter(\.countsTowardTotal).reduce(0) { $0 + count(for: $1) }
    }
}

/// 工作台菜单里的入口，从上到下（原来在抽屉里；规范 docs/ios-ui-redesign.md 3.1、4.2.1、6.1 A1）。点开都是顶级页面：
/// `Router.openTopLevel(entry.route)`，先关掉 sheet、回到首页再压它。
public enum WorkbenchEntry: String, CaseIterable, Hashable, Sendable {
    case inbox
    case approvals
    case activeRuns
    case plans
    case teams
    case artifacts

    /// 点开去的页面（都是顶级页面，`AppRoute.isTopLevel`）。
    public var route: AppRoute {
        switch self {
        case .inbox: .inbox
        case .approvals: .approvals
        case .activeRuns: .activeRuns
        case .plans: .plans(instanceID: nil)
        case .teams: .teams
        case .artifacts: .artifacts(instanceID: nil)
        }
    }

    public func title(_ language: DisplayLanguage = .current) -> String { route.title(language) }

    /// SF Symbol。
    public var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .approvals: "checkmark.shield"
        case .activeRuns: "bolt"
        case .plans: "calendar"
        case .teams: "person.3"
        case .artifacts: "doc.text"
        }
    }

    /// 算不算进工作台按钮的总角标（`ShellBadges.workbenchTotal`）：要你处理的才算。
    public var countsTowardTotal: Bool {
        switch self {
        case .inbox, .approvals, .plans: true
        case .activeRuns, .teams, .artifacts: false
        }
    }

    /// 菜单项的副标题（“3 条未读”），读屏也念它；0 时为 nil，菜单项只有标题。
    public func subtitle(count: Int, language: DisplayLanguage = .current) -> String? {
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

    /// 工作台按钮的名字，也是它的读屏标签。要处理的数不放进标签：按钮上的角标（`toolbarBadge`）把它当按钮的值念，
    /// 放进标签就念两遍。
    public static func workbenchTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "工作台" : "Workbench"
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
