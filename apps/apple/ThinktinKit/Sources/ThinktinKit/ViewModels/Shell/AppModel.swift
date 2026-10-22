import Foundation
import Observation

/// 应用框架的全局状态（WBS 12.16）：登录状态、连接横幅、在线 / 离线、实例列表与当前实例、抽屉里的角标。
///
/// - 持有 `ObservedClient`（`client`）：所有页面都用它，任何调用遇到登录失效、账号冻结、要升级都会报到这里，
///   切换 `phase`（docs/ios.md 第 6 节）；`login` 成功、退出登录、注销、下线本机也会自动切换。
/// - 启动时先读缓存（实例、未读数、每个实例最近的运行）再刷新：先 `me()` 确认账号状态，再拉实例和角标
///   （ios-packages.md 12.16：先确认没冻结、不用升级，再订阅事件流）。
/// - 冻结：显示冻结页，登录状态保留；“重新检查”、回到前台时调 `me()`，解冻后照常（刷新实例和角标，对话页重新出现时
///   重新订阅事件流）。
/// - 要升级：停掉所有事件流（`ObservedClient.haltStreams()`），之后一直停在升级页（升级就是重装）。
/// - 没登录、冻结、要升级时，深链和推送由 `Router` 先记下，回到正常状态再跳。
///
/// “进行中”的数现在按实例逐个调 `runs()` 再本地过滤；11.8 的 `listRuns`（跨实例、只要进行中的）合进来后换掉。
@Observable @MainActor
public final class AppModel {
    /// 登录状态。
    public enum Phase: Hashable, Sendable {
        /// 没登录（或登录失效）：登录页。
        case signedOut
        /// 正常使用。
        case signedIn
        /// 账号被冻结（4.6）：冻结页，登录状态保留。
        case frozen
        /// 版本太老：升级页，事件流全部停掉。
        case upgradeRequired
    }

    /// 每个实例拉几条最近的运行（算“进行中”和等待提示）。
    public static let runsPerInstance = 20
    /// 收件箱同步拉几条（只为角标的未读数；收件箱页自己再拉）。
    public static let inboxSyncLimit = 20
    /// 打开抽屉、回到前台时，角标多久没刷新才刷新（秒）。
    public static let badgeMaxAge: TimeInterval = 15

    /// 所有页面用的客户端（包了一层的 `ObservedClient`）。
    public let client: any ClientProtocol
    /// 导航状态。
    public let router: Router

    public private(set) var phase: Phase
    /// 当前用户（`me()`、登录结果）；拉到之前为 nil。
    public private(set) var user: User?
    /// 实例，最近活跃的在前（不含已删除的）。
    public private(set) var instances: [Instance] = []
    /// 每个实例最近的运行概况。
    public private(set) var activity: [InstanceID: InstanceActivity] = [:]
    public private(set) var badges = ShellBadges.zero
    /// 顶部的连接横幅。
    public private(set) var connection: ConnectionState = .idle
    /// 网络不通（最近一次调用是网络错误）：页面顶部显示离线横幅。
    public private(set) var isOffline = false
    /// 实例列表拿到过（缓存或服务端）：抽屉据此区分“加载中”和“没有实例”。
    public private(set) var hasLoadedInstances = false
    public private(set) var isRefreshing = false
    /// 刷新实例列表失败（不是网络、不是全局错误）：抽屉里显示横幅，可以重试。
    public private(set) var refreshError: ClientError?
    /// 冻结页的“重新检查”正在进行。
    public private(set) var isCheckingAccount = false
    /// “重新检查”失败（比如网络不通）。
    public private(set) var accountCheckError: ClientError?

    private let observed: ObservedClient
    private let selection: InstanceSelectionStore
    private let now: () -> Date
    private let activityContinuation: AsyncStream<ClientActivity>.Continuation
    @ObservationIgnored private var started = false
    /// `start()` 正在进行（回到前台的刷新跳过，免得启动时拉两遍）。
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var lastBadgeRefresh: Date?
    /// 每个事件流最近的连接状态（汇总成 `connection`）。
    @ObservationIgnored private var streams: [UUID: StreamStatus] = [:]
    @ObservationIgnored private var streamRetryAt: [UUID: Date] = [:]

    /// - Parameters:
    ///   - client: Mock 或真核心；这里会包一层 `ObservedClient`。
    ///   - router: 导航状态（测试里可以传自己的）。
    ///   - defaults: 记住上次选的实例；传 nil 不记（测试、预览）。
    ///   - now: 现在的时间（测试传固定值）。
    public init(
        client: any ClientProtocol, router: Router = Router(), defaults: UserDefaults? = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: ClientActivity.self, bufferingPolicy: .unbounded)
        let observed = ObservedClient(client) { activity in continuation.yield(activity) }
        self.observed = observed
        self.client = observed
        self.router = router
        self.selection = InstanceSelectionStore(defaults: defaults)
        self.now = now
        self.activityContinuation = continuation
        self.phase = client.signedIn() ? .signedIn : .signedOut
        router.isHoldingRoutes = phase != .signedIn
        router.instanceSelectionDidChange = { [weak self] id in self?.selection.save(id) }
        // 报告按发生的顺序在主线程上处理。
        Task { [weak self] in
            for await activity in stream {
                guard let self else { return }
                self.receive(activity)
            }
        }
    }

    deinit {
        activityContinuation.finish()
    }

    // MARK: 派生状态

    /// 当前实例（`router.currentInstanceID` 对应的那个）。
    public var currentInstance: Instance? {
        guard let id = router.currentInstanceID else { return nil }
        return instances.first { $0.id == id }
    }

    /// 实例的运行概况（没拉到时是空的）。
    public func activity(for instanceID: InstanceID) -> InstanceActivity {
        activity[instanceID] ?? .none
    }

    // MARK: 启动与刷新

    /// 启动（`AppShell` 的 `.task`，只做一次）：先读缓存，再确认账号状态，再刷新实例和角标。
    public func start() async {
        guard !started else { return }
        started = true
        guard phase == .signedIn else { return }
        isStarting = true
        defer { isStarting = false }
        loadCachedState()
        guard phase == .signedIn else { return }
        await verifyAccount()
        await refresh()
    }

    /// 刷新实例列表和角标（下拉、回到前台、解冻后）。
    public func refresh() async {
        guard phase == .signedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshInstances()
        await refreshBadges()
    }

    /// 只刷新角标（审批、确认计划、标已读之后，各功能可以调一次让抽屉马上变）。
    public func refreshBadges() async {
        guard phase == .signedIn else { return }
        lastBadgeRefresh = now()
        let client = self.client
        let ids = instances.map(\.id)
        async let unread = Self.attempt { try await client.syncInbox(limit: Self.inboxSyncLimit).unread }
        async let approvals = Self.attempt { try await client.approvals() }
        async let plans = Self.attempt { try await client.plans(instanceID: nil) }
        async let runs = Self.recentRuns(of: ids, client: client)
        let (unreadResult, approvalsResult, plansResult, runsResults) = await (unread, approvals, plans, runs)
        guard phase == .signedIn else { return }

        var badges = self.badges
        switch unreadResult {
        case .success(let count): badges.inboxUnread = count
        case .failure(let error): handle(error)
        }
        switch approvalsResult {
        case .success(let list):
            let now = self.now()
            badges.pendingApprovals = list.filter { $0.isPending && !$0.isExpired(now: now) }.count
        case .failure(let error): handle(error)
        }
        switch plansResult {
        case .success(let list): badges.plansAwaitingConfirmation = list.filter(\.awaitingConfirmation).count
        case .failure(let error): handle(error)
        }
        var activity = self.activity
        for (id, result) in runsResults {
            switch result {
            case .success(let runs): activity[id] = InstanceActivity(runs: runs)
            case .failure(let error): handle(error)
            }
        }
        setActivity(activity, badges: &badges)
        self.badges = badges
    }

    /// 角标超过 `badgeMaxAge` 没刷新就刷新（打开抽屉时）。
    public func refreshBadgesIfStale() async {
        if let last = lastBadgeRefresh, now().timeIntervalSince(last) < Self.badgeMaxAge { return }
        await refreshBadges()
    }

    /// App 回到前台：冻结时重查账号；正常时刷新（太频繁的跳过）。
    public func sceneDidBecomeActive() async {
        switch phase {
        case .frozen:
            await recheckAccount()
        case .signedIn:
            if isStarting { return }
            if let last = lastBadgeRefresh, now().timeIntervalSince(last) < Self.badgeMaxAge { return }
            await refresh()
        case .signedOut, .upgradeRequired:
            break
        }
    }

    // MARK: 账号

    /// 冻结页的“重新检查”（也在回到前台、收到“账号已恢复”的推送时调）：`me()` 说解冻了就回到正常，
    /// 刷新实例和角标。
    public func recheckAccount() async {
        guard phase == .frozen, !isCheckingAccount else { return }
        isCheckingAccount = true
        accountCheckError = nil
        defer { isCheckingAccount = false }
        do {
            let me = try await client.me()
            user = me
            guard me.status != .frozen, phase == .frozen else { return }
            enter(.signedIn)
            await refresh()
        } catch {
            if error is CancellationError { return }
            if !handle(error) { accountCheckError = Self.clientError(error) }
        }
    }

    /// 退出登录。网络不通时本地照样清掉（client-core 本地会话没了就算退出）；本地会话还在时把错误抛出去。
    public func signOut() async throws {
        do {
            try await client.logout()
        } catch {
            if client.signedIn() { throw error }
        }
        enter(.signedOut)
    }

    /// 切换当前实例并回到它的对话。
    public func selectInstance(_ instanceID: InstanceID) {
        router.selectInstance(instanceID)
    }

    /// 抽屉里的“新任务”：只有一个实例时直接回到它的对话、把焦点放进输入框；有好几个时弹出选择（`.newTask`）；
    /// 还没有实例时去 agent 目录领养。
    public func startNewTask() {
        switch instances.count {
        case 0: router.openFromDrawer(.agentCatalog)
        case 1: router.requestNewTask(in: instances[0].id)
        default: router.present(.newTask)
        }
    }

    // MARK: 错误

    /// 处理一个错误：登录失效、冻结、要升级时切换全局状态，网络不通时标离线。返回 true 表示已经整页处理了
    /// （调用方不用再显示行内错误）。所有经过 `client` 的调用都会自动走到这里，各功能一般不用自己调。
    @discardableResult
    public func handle(_ error: any Error) -> Bool {
        guard let error = error as? ClientError else { return false }
        if error.requiresUpgrade {
            enter(.upgradeRequired)
            return true
        }
        if phase == .upgradeRequired { return true }
        if error.requiresSignIn {
            enter(.signedOut)
            return true
        }
        if error.isAccountFrozen {
            // 没有会话（登录时就被拒了）时冻结页没法“重新检查”，留给登录页行内提示。
            guard client.signedIn() else { return false }
            if phase == .signedIn { enter(.frozen) }
            return true
        }
        if error.isOffline { isOffline = true }
        return false
    }

    // MARK: 内部

    private func receive(_ activity: ClientActivity) {
        switch activity {
        case .failed(let error):
            handle(error)
        case .reachable:
            isOffline = false
        case .signedIn(let result):
            didSignIn(result)
        case .signedOut:
            enter(.signedOut)
        case .stream(let status, let instanceID, let token):
            streamChanged(status, instanceID: instanceID, token: token)
        case .streamEnded(let token):
            streams[token] = nil
            streamRetryAt[token] = nil
            updateConnection()
        }
    }

    private func didSignIn(_ result: LoginResult) {
        guard phase == .signedOut else { return }
        user = result.user
        instances = []
        activity = [:]
        badges = .zero
        hasLoadedInstances = false
        refreshError = nil
        if result.user.status == .frozen {
            enter(.frozen)
            return
        }
        enter(.signedIn)
        loadCachedState()
        Task { await refresh() }
    }

    /// 切换全局状态。升级页是终点：之后什么都不再切换。
    private func enter(_ next: Phase) {
        guard phase != next, phase != .upgradeRequired else { return }
        phase = next
        router.isHoldingRoutes = next != .signedIn
        switch next {
        case .signedOut:
            // 清掉上一个账号的一切（缓存由 client-core 在退出登录时清）。
            user = nil
            instances = []
            activity = [:]
            badges = .zero
            hasLoadedInstances = false
            refreshError = nil
            accountCheckError = nil
            isOffline = false
            lastBadgeRefresh = nil
            router.reset()
            resetStreams()
        case .upgradeRequired:
            observed.haltStreams()
            resetStreams()
        case .frozen:
            // 事件流以 4003 关闭、自己停了；连接横幅不再显示。
            resetStreams()
        case .signedIn:
            break
        }
    }

    private func resetStreams() {
        streams = [:]
        streamRetryAt = [:]
        connection = .idle
    }

    /// 确认账号状态（启动时）：冻结了就进冻结页。网络不通就先用缓存。
    private func verifyAccount() async {
        do {
            let me = try await client.me()
            user = me
            if me.status == .frozen { enter(.frozen) }
        } catch {
            handle(error)
        }
    }

    private func refreshInstances() async {
        do {
            let list = try await client.instances()
            guard phase == .signedIn else { return }
            apply(instances: list)
            hasLoadedInstances = true
            refreshError = nil
            isOffline = false
        } catch {
            // 页面关了（任务被取消）不算出错。
            if error is CancellationError || handle(error) { return }
            let clientError = Self.clientError(error)
            if !clientError.isOffline { refreshError = clientError }
        }
    }

    /// 读缓存：实例、未读数、每个实例最近的运行（离线、启动时先显示）。读缓存出错（缓存坏了）就当没有缓存；
    /// 全局错误当场切换。
    private func loadCachedState() {
        if let cached = cached({ try client.cachedInstances() }), !cached.isEmpty {
            apply(instances: cached)
            hasLoadedInstances = true
        }
        var badges = self.badges
        if let unread = cached({ try client.cachedUnread() }) { badges.inboxUnread = unread }
        var activity: [InstanceID: InstanceActivity] = [:]
        for instance in instances {
            if let runs = cached({ try client.cachedRuns(instanceID: instance.id, limit: Self.runsPerInstance) }) {
                activity[instance.id] = InstanceActivity(runs: runs)
            }
        }
        setActivity(activity, badges: &badges)
        self.badges = badges
    }

    private func cached<T>(_ body: () throws -> T) -> T? {
        guard phase == .signedIn else { return nil }
        do {
            return try body()
        } catch {
            handle(error)
            return nil
        }
    }

    private func setActivity(_ activity: [InstanceID: InstanceActivity], badges: inout ShellBadges) {
        let ids = Set(instances.map(\.id))
        let kept = activity.filter { ids.contains($0.key) }
        self.activity = kept
        badges.activeRuns = kept.values.reduce(0) { $0 + $1.activeRuns }
    }

    /// 换上新的实例列表（最近活跃的在前，去掉已删除的），校正当前实例。
    private func apply(instances list: [Instance]) {
        instances = list.filter { $0.state != .deleted }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        let ids = Set(instances.map(\.id))
        activity = activity.filter { ids.contains($0.key) }
        badges.activeRuns = activity.values.reduce(0) { $0 + $1.activeRuns }
        reconcileSelection()
    }

    /// 当前实例不在列表里（被删了）或还没选：换成上次选的，再不行就是最近活跃的；没有实例时回到首页。
    /// 原来选着的实例没了，导航栈回到根（它的页面都没意义了）。
    private func reconcileSelection() {
        let ids = Set(instances.map(\.id))
        if let current = router.currentInstanceID, ids.contains(current) { return }
        let stored = selection.load().flatMap { ids.contains($0) ? $0 : nil }
        let next = stored ?? instances.first?.id
        if router.currentInstanceID == nil {
            router.currentInstanceID = next
        } else {
            router.selectInstance(next)
        }
    }

    private func streamChanged(_ status: StreamStatus, instanceID: InstanceID, token: UUID) {
        switch status {
        case .connecting:
            streams[token] = status
        case .reconnecting(let retryIn):
            streams[token] = status
            streamRetryAt[token] = now().addingTimeInterval(retryIn)
        case .live:
            streams[token] = status
            streamRetryAt[token] = nil
            isOffline = false
        case .signedOut:
            enter(.signedOut)
        case .accountFrozen:
            if client.signedIn(), phase == .signedIn { enter(.frozen) }
        case .notFound:
            // 实例被删了（或不属于这个账号）：从列表里拿掉，回到别的实例，再刷新一次。
            instanceDisappeared(instanceID)
        case .stopped:
            // 11.8 合进来后：client-core 说要升级时事件流以 stopped 结束，这里查 `upgradeRequired()`。
            break
        }
        if status.isFinal {
            streams[token] = nil
            streamRetryAt[token] = nil
        }
        updateConnection()
    }

    private func instanceDisappeared(_ instanceID: InstanceID) {
        guard phase == .signedIn, instances.contains(where: { $0.id == instanceID }) else { return }
        apply(instances: instances.filter { $0.id != instanceID })
        Task { await refresh() }
    }

    /// 汇总所有事件流：有在重连的显示最早的重连时间，有在连的显示“正在连接”，否则不显示。
    private func updateConnection() {
        let retries = streams.compactMap { token, status -> Date? in
            if case .reconnecting = status { return streamRetryAt[token] ?? now() }
            return nil
        }
        if let earliest = retries.min() {
            connection = .reconnecting(retryAt: earliest)
        } else if streams.values.contains(.connecting) {
            connection = .connecting
        } else {
            connection = .idle
        }
    }

    // MARK: 并发拉取

    private nonisolated static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<
        T, any Error
    > {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// 每个实例最近的一页运行（并发拉）。
    private nonisolated static func recentRuns(of ids: [InstanceID], client: any ClientProtocol) async
        -> [InstanceID: Result<[Run], any Error>]
    {
        await withTaskGroup(of: (InstanceID, Result<[Run], any Error>).self) { group in
            for id in ids {
                group.addTask {
                    (id, await attempt { try await client.runs(instanceID: id, limit: runsPerInstance) })
                }
            }
            var results: [InstanceID: Result<[Run], any Error>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
    }
}

extension AppModel {
    /// 任意错误转成 `ClientError`（不是的按内部错误）。
    private static func clientError(_ error: any Error) -> ClientError {
        (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}

/// 记住上次选的实例（下次启动先打开它）。退出登录时清掉。
@MainActor
struct InstanceSelectionStore {
    static let key = "cn.thinktin.shell.currentInstanceID"
    let defaults: UserDefaults?

    func load() -> InstanceID? {
        guard let raw = defaults?.string(forKey: Self.key), !raw.isEmpty else { return nil }
        return InstanceID(raw)
    }

    func save(_ instanceID: InstanceID?) {
        if let instanceID {
            defaults?.set(instanceID.rawValue, forKey: Self.key)
        } else {
            defaults?.removeObject(forKey: Self.key)
        }
    }
}
