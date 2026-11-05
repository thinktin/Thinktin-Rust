import Foundation

/// 首页实例列表的一行（WBS 12.16，规范 docs/ios-ui-redesign.md 4.2.1 第 0 轮的最小版）：头像（右下角状态角标）、名字、
/// 右边的时间、下面一行预览。点开压栈进它的对话。
public struct HomeRow: Identifiable, Hashable, Sendable {
    public var instance: Instance
    public var activity: InstanceActivity
    /// 最后活动：实例的 `lastActiveAt` 和最近一个没结束的运行的创建时间里晚的那个（缓存里的实例可能比运行旧）。
    /// 排序和右边的时间都用它。
    public var lastActivityAt: Date
    public var preview: HomeRowPreview

    public var id: InstanceID { instance.id }

    /// 有运行在等你处理：预览和角标用警告色。
    public var needsAttention: Bool {
        if case .waiting = preview { return true }
        return false
    }

    public init(instance: Instance, activity: InstanceActivity) {
        self.instance = instance
        self.activity = activity
        lastActivityAt = max(instance.lastActiveAt, activity.latestRunAt ?? .distantPast)
        preview = HomeRowPreview(state: instance.state, activity: activity)
    }
}

/// 第二行的预览（规范 6.7 的建议：先显示状态；没有状态时显示最近一次运行的摘要或任务，那一半第 1 轮做）。
public enum HomeRowPreview: Hashable, Sendable {
    /// 有运行在等你处理（审批、电脑、key、子任务）：“N 个在等你处理”，警告色。`state` 是最近在等的那个。
    case waiting(count: Int, state: RunState)
    /// 有没结束的运行（排队、启动、运行中、重试等待）：最近那个的状态，不止一个时带个数。
    case active(count: Int, state: RunState)
    /// 没有进行中的运行：实例自己的状态（创建中、随时可以接任务、休眠……）。
    case idle(InstanceState)

    public init(state: InstanceState, activity: InstanceActivity) {
        if activity.waitingRuns > 0 {
            self = .waiting(count: activity.waitingRuns, state: activity.latestWaitingState ?? .waitingApproval)
        } else if activity.activeRuns > 0, let latest = activity.latestRunState {
            self = .active(count: activity.activeRuns, state: latest)
        } else {
            self = .idle(state)
        }
    }
}

/// 首页的实例列表怎么排、每行显示什么（纯函数，Linux 上测）。置顶、隐藏（规范 4.2.1、6.10）第 2 轮加在这里。
public enum HomeList {
    /// 列表的行：去掉已删除的，最后活动新的在前；一样新的按名字、再按 id，顺序稳定（刷新时行不乱跳）。
    public static func rows(instances: [Instance], activity: [InstanceID: InstanceActivity]) -> [HomeRow] {
        instances
            .filter { $0.state != .deleted }
            .map { HomeRow(instance: $0, activity: activity[$0.id] ?? .none) }
            .sorted { a, b in
                if a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
                if a.instance.name != b.instance.name { return a.instance.name < b.instance.name }
                return a.id.rawValue < b.id.rawValue
            }
    }

    /// 行右边的时间：今天的“14:05”，更早的显示日期（“10月21日”，往年的带年份）。
    public static func timestamp(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return Formatting.clockTime(date, calendar: calendar) }
        return Formatting.shortDate(date, now: now, language: language, calendar: calendar)
    }
}

/// 首页列表空着时显示什么（`HomeList.placeholder`）；列表有行、或者拉取失败（横幅说了怎么回事、可以重试）时不显示。
public enum HomePlaceholder: Hashable, Sendable {
    /// 第一次在拉、这台设备上没有缓存：转圈。
    case loading
    /// 离线、这台设备上没有 Botin 可显示（第 0 轮的离线文案，`HomeText.offlineEmptyMessage`）。
    case offlineWithoutCache
    /// 联网拉到了，账号里还没有 Botin（第一次登录就是这样）：“还没有 Botin”和“新建 Botin”按钮。
    case noBotins
}

extension HomeList {
    /// 列表空着时显示什么（规范 4.2.1 的状态）。`hasLoaded` 是实例列表拿到过（缓存或服务端，`AppModel.hasLoadedInstances`），
    /// `hasError` 是刷新失败了（不是网络问题，`AppModel.refreshError`）。离线时不引导新建（表单离线不能提交），
    /// 只说这台设备上没有。
    public static func placeholder(isEmpty: Bool, hasLoaded: Bool, isOffline: Bool, hasError: Bool) -> HomePlaceholder?
    {
        guard isEmpty else { return nil }
        if isOffline { return .offlineWithoutCache }
        if hasError { return nil }
        return hasLoaded ? .noBotins : .loading
    }
}

/// 首页空状态的文案（用户 2026-11-05 定的：第一次登录首页是空的，引导新建 Botin）。按钮文字用 `AppRoute.adopt` 的标题“新建 Botin”。
public enum HomeText {
    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "还没有 Botin" : "No Botins yet"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "Botin 是替你干活的助手。起个名字、选一个引擎，它就能帮你写东西、查资料、跑任务。"
            : "A Botin is an assistant that works for you. Give it a name and pick an engine, and it can write, "
                + "look things up and run tasks for you."
    }

    /// 离线、这台设备上又没有缓存时（顶部横幅已经说了“显示的是缓存内容”，这里只说缓存是空的）。
    public static func offlineEmptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "这台设备上还没有保存的 Botin，联网后会自动刷新。"
            : "No Botins are saved on this device yet. They'll appear when you're back online."
    }
}
