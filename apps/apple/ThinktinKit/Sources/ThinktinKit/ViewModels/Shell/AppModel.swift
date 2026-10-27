import Foundation
import Observation

/// 应用框架的全局状态（WBS 12.16）：登录状态、连接横幅、在线 / 离线、实例列表与当前实例、抽屉里的角标。
///
/// - 持有 `ObservedClient`（`client`）：所有页面都用它，任何调用遇到登录失效、账号冻结、要升级都会报到这里，
///   切换 `phase`（docs/ios.md 第 6 节）；`login` 成功、退出登录、注销、下线本机也会自动切换。
/// - 启动时先看 `upgradeRequired()`（不联网；说过要升级就直接进升级页），再读缓存（实例、未读数、每个实例最近的运行）
///   再刷新：先 `me()` 确认账号状态，再拉实例和角标（ios-packages.md 12.16：先确认没冻结、不用升级，再订阅事件流）。
/// - 冻结：显示冻结页，登录状态保留；“重新检查”、回到前台、收到“账号已恢复”的推送时调 `me()`，解冻后照常（刷新实例和
///   角标，对话页重新出现时重新订阅事件流，一直留着的页面看 `resubscribeRequest`）。
/// - 要升级：任何调用抛 `upgradeRequired`、事件流以 `upgradeRequired` 结束（服务端回 426，339e191 起 client-core 不再用
///   `stopped` 表示它）、启动和回到前台时 `upgradeRequired()` 是 true，都停掉所有事件流（`ObservedClient.haltStreams()`），
///   之后一直停在升级页（升级就是重装）。
/// - 推送（`receive(push:)`、`open(push:)`）：子类型是账号冻结、解冻的先处理账号状态（docs/push.md 第 4 节）；点开的
///   标已读。通知上的“拒绝”（`rejectFromNotification`）不用打开 App。APNs 令牌（`didReceivePushToken`）登录着就报给
///   服务端，没登录时登录带上（`pushRegistration`）。退出登录清掉已送达的通知、角标设成 0（`notifications`，12.8）。
/// - 语言（12.12，传了 `preferences` 时）：启动时最先把请求语言换成界面语言打头的（没登录也要，新用户按它注册）；
///   确认完账号、登录成功、解冻之后比较服务端的用户语言（`me().locale`）和界面语言，不一致就调 `setLocale`
///   （`LanguageSettingsModel.syncOnLaunch(user:)`，静默进行，失败了下次启动再试）。
/// - 用户（`user`）：启动、登录时拿到，之后任何页面调 `me()`、`setLocale`、`updateProfile` 成功了都换上新的
///   （`ClientActivity.userUpdated`），设置页、账号页拿到的不是旧的（比如刚换过的语言）。
/// - 没登录、冻结、要升级时，深链和推送由 `Router` 先记下，回到正常状态再跳。
///
/// “进行中”的角标和实例行的“等你处理”用 11.8 的 `listRuns(filter: .active)`：跨实例、只要没结束的，一次请求；
/// 启动时先用每个实例缓存里最近的几条运行凑出来（`cachedRuns`，`listRuns` 成功时 client-core 顺带更新它）。
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

    /// 读缓存时每个实例看几条最近的运行（网络的结果回来之前先凑出“进行中”和等待提示）。
    public static let runsPerInstance = 20
    /// “进行中”拉一页多少个（`listRuns(filter: .active)`，服务端最多 200）。只拉一页：角标超过 99 就显示“99+”，
    /// 同时进行中的运行再多也只是实例行的等待数少算，进行中页面（12.5）自己往下翻。
    public static let activeRunsLimit = RunFilter.maxLimit
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
    /// 要重新订阅事件流的次数（账号解冻后加一）：订阅了事件流的页面（对话页、运行详情）`onChange(of:)` 时重新订阅。
    /// 从冻结页回来的页面本来就会重新出现、重新订阅；这个给一直留着的页面用（收到“账号已恢复”时还在正常状态）。
    public private(set) var resubscribeRequest = 0
    /// APNs 给的推送令牌（12.8，App 代理收到后交给 `didReceivePushToken`）：登录时带上。
    public private(set) var pushRegistration: PushRegistration?

    private let observed: ObservedClient
    /// 系统通知中心（12.8）：退出登录时清掉已送达的通知，角标跟着收件箱的未读数。nil 不管（测试、预览）。
    private let notifications: (any DeliveredNotifications)?
    private let widgets: (any WidgetSnapshotSink)?
    /// 实时活动（12.10）；没传 `liveActivities` 时为 nil（测试、预览、不支持的平台）。
    public let liveActivities: LiveActivityModel?
    /// 上次写给小组件的（数没变就不重写）。
    private var lastWidgetSnapshot: WidgetSnapshot?
    /// 上一次写快照的任务：一个接一个写，后写的不会被先写的盖掉。
    private var widgetTask: Task<Void, Never>?
    /// 界面语言和服务端、请求语言的同步（12.12）；没传 `preferences` 时为 nil，不同步。
    private let language: LanguageSettingsModel?
    private let selection: InstanceSelectionStore
    /// 换了新手机时弹一次引导（12.17）。
    private let onboardingCheck: OnboardingCheck
    /// 手机控制电脑存在本机的状态（12.9）：角标里数电脑发来的审批。
    private let computerLinks: ComputerLinkStore
    private let now: () -> Date
    private let activityContinuation: AsyncStream<(Int, ClientActivity)>.Continuation
    /// 报告的序号（`ObservedClient` 发出时编的，从 1 起）：发出过几条。
    private let reportsSent: Locked<Int>
    /// 序号不超过它的“冻结”报告已经过时：之后的一次 `me()` 说账号没冻结（报告是异步处理的，重查成功时之前排着的
    /// “冻结”可能还没处理，晚到了会把刚解冻的界面又冻上）。
    @ObservationIgnored private var staleFrozenReports = 0
    @ObservationIgnored private var started = false
    /// `start()` 正在进行（回到前台的刷新跳过，免得启动时拉两遍）。
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var lastBadgeRefresh: Date?
    /// 每个事件流最近的连接状态（汇总成 `connection`）。
    @ObservationIgnored private var streams: [UUID: StreamStatus] = [:]
    @ObservationIgnored private var streamRetryAt: [UUID: Date] = [:]
    /// 这次登录已经报给服务端的推送令牌（同一个不重复报）。
    @ObservationIgnored private var reportedPushRegistration: PushRegistration?
    /// 最近设到 App 图标上的角标（一样的不重复设）。
    @ObservationIgnored private var appBadge: Int?

    /// - Parameters:
    ///   - client: Mock 或真核心；这里会包一层 `ObservedClient`。
    ///   - router: 导航状态（测试里可以传自己的）。
    ///   - defaults: 记住上次选的实例；传 nil 不记（测试、预览）。
    ///   - preferences: 外观与语言的偏好（12.12，App 里是 `SettingsPreferences.shared`）：启动、登录后按它的界面语言
    ///     设请求语言、同步服务端的用户语言。nil 不同步（测试、预览）。
    ///   - notifications: 系统通知中心（12.8，App 里是 `UNUserNotificationCenter`）；nil 不管。
    ///   - widgets: 主屏小组件的快照（12.20，App 里写 App Group 的文件再刷新小组件）；nil 不管。
    ///   - liveActivities: 系统的实时活动（12.10，App 里是 ActivityKit）；nil 不开实时活动。
    ///   - now: 现在的时间（测试传固定值）。
    public init(
        client: any ClientProtocol, router: Router = Router(), defaults: UserDefaults? = .standard,
        preferences: SettingsPreferences? = nil, notifications: (any DeliveredNotifications)? = nil,
        widgets: (any WidgetSnapshotSink)? = nil, liveActivities: (any LiveActivityControlling)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: (Int, ClientActivity).self, bufferingPolicy: .unbounded)
        let reportsSent = Locked(0)
        // 编号和入队在同一把锁里，序号和处理的顺序一致。
        let observed = ObservedClient(client) { activity in
            reportsSent.withLock { sent in
                sent += 1
                continuation.yield((sent, activity))
            }
        }
        self.reportsSent = reportsSent
        self.observed = observed
        self.client = observed
        // 经过 ObservedClient：同步时遇到登录失效、冻结这类全局错误照样报到这里。
        self.language = preferences.map { LanguageSettingsModel(client: observed, preferences: $0) }
        self.router = router
        self.selection = InstanceSelectionStore(defaults: defaults)
        self.computerLinks = ComputerLinkStore(defaults: defaults)
        self.onboardingCheck = OnboardingCheck(defaults: defaults)
        self.notifications = notifications
        self.widgets = widgets
        self.liveActivities = liveActivities.map { LiveActivityModel(client: observed, system: $0, defaults: defaults) }
        self.now = now
        self.activityContinuation = continuation
        // 版本太老（11.8，不联网）：第一帧就是升级页，事件流一个都不连。
        if client.upgradeRequired() {
            self.phase = .upgradeRequired
            observed.haltStreams()
        } else {
            self.phase = client.signedIn() ? .signedIn : .signedOut
        }
        router.isHoldingRoutes = phase != .signedIn
        router.instanceSelectionDidChange = { [weak self] id in self?.selection.save(id) }
        // 报告按发生的顺序在主线程上处理。
        Task { [weak self] in
            for await (number, activity) in stream {
                guard let self else { return }
                self.receive(activity, number: number)
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

    /// 启动（`AppShell` 的 `.task`，只做一次）：先换请求语言，再读缓存，再确认账号状态（和服务端的用户语言），
    /// 再刷新实例和角标。
    public func start() async {
        guard !started else { return }
        started = true
        // 请求语言换成界面语言打头的（不联网）：在登录判断之前，没登录时新用户也按界面语言注册（12.12）。
        language?.applyAcceptLanguage()
        // 建好之后、启动之前就有调用说过要升级（比如 App 的平台层直接用了被包的客户端）。
        if checkUpgradeRequired() { return }
        guard phase == .signedIn else {
            // 小组件上可能还是上次登录时的数（登录在别处失效了）。
            publishWidgetSnapshot()
            return
        }
        isStarting = true
        defer { isStarting = false }
        loadCachedState()
        guard phase == .signedIn else { return }
        await verifyAccount()
        await syncLanguage()
        await refresh()
        await reportPushToken()
        await liveActivities?.resume()
        await presentOnboardingIfNeeded()
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
        async let unread = Self.attempt { try await client.syncInbox(limit: Self.inboxSyncLimit).unread }
        async let approvals = Self.attempt { try await client.approvals() }
        async let plans = Self.attempt { try await client.plans(instanceID: nil) }
        async let runs = Self.attempt { try await client.listRuns(filter: .active, limit: Self.activeRunsLimit) }
        async let deviceMessages = Self.attempt { try await client.deviceMessages() }
        let (unreadResult, approvalsResult, plansResult, runsResult) = await (unread, approvals, plans, runs)
        // 电脑发来的审批（12.9）：拉不到消息就只数存着的，不报错（审批中心打开时会再收）。
        let messages = (try? await deviceMessages.get()) ?? []
        guard phase == .signedIn else { return }

        var badges = self.badges
        switch unreadResult {
        case .success(let count): badges.inboxUnread = count
        case .failure(let error): handle(error)
        }
        switch approvalsResult {
        case .success(let list):
            let now = self.now()
            let computer =
                user.map { computerLinks.load(userID: $0.id).pendingApprovals(messages: messages, now: now) } ?? 0
            badges.pendingApprovals = list.filter { $0.isPending && !$0.isExpired(now: now) }.count + computer
        case .failure(let error): handle(error)
        }
        switch plansResult {
        case .success(let list): badges.plansAwaitingConfirmation = list.filter(\.awaitingConfirmation).count
        case .failure(let error): handle(error)
        }
        switch runsResult {
        // 整个换掉：这一页里没有的实例就是没有进行中的运行。
        case .success(let runs): setActivity(InstanceActivity.byInstance(runs), badges: &badges)
        // 拉不到就留着原来的数。
        case .failure(let error): handle(error)
        }
        self.badges = badges
        updateAppBadge()
    }

    /// 收件箱的页面标了已读 / 未读、删了之后告诉这里新的未读数（抽屉的角标、App 图标的角标马上变）。
    public func inboxUnreadChanged(_ count: Int) {
        guard phase == .signedIn else { return }
        badges.inboxUnread = max(0, count)
        updateAppBadge()
    }

    /// 角标超过 `badgeMaxAge` 没刷新就刷新（打开抽屉时）。
    public func refreshBadgesIfStale() async {
        if let last = lastBadgeRefresh, now().timeIntervalSince(last) < Self.badgeMaxAge { return }
        await refreshBadges()
    }

    /// App 回到前台：冻结时重查账号；正常时刷新（太频繁的跳过）。
    public func sceneDidBecomeActive() async {
        if checkUpgradeRequired() { return }
        switch phase {
        case .frozen:
            await recheckAccount()
        case .signedIn:
            if isStarting { return }
            await liveActivities?.resume()
            if let last = lastBadgeRefresh, now().timeIntervalSince(last) < Self.badgeMaxAge { return }
            await refresh()
        case .signedOut, .upgradeRequired:
            break
        }
    }

    /// App 进后台：实时活动不再跟前台的事件流（之后靠后台推送，12.10）。
    public func sceneDidEnterBackground() {
        liveActivities?.pause()
    }

    // MARK: 账号

    /// 冻结页的“重新检查”（也在回到前台、收到“账号已恢复”的推送时调）：`me()` 说解冻了就回到正常，
    /// 刷新实例和角标（同步收件箱）。
    public func recheckAccount() async {
        guard phase == .frozen, !isCheckingAccount else { return }
        isCheckingAccount = true
        accountCheckError = nil
        defer { isCheckingAccount = false }
        do {
            let me = try await client.me()
            user = me
            guard me.status != .frozen, phase == .frozen else { return }
            staleFrozenReports = reportsSent.withLock { $0 }
            enter(.signedIn)
            // 冻结着启动（或登录）的没同步过语言、推送令牌。
            await syncLanguage()
            await refresh()
            await reportPushToken()
            await liveActivities?.resume()
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

    // MARK: 推送

    /// 收到一条推送（App 在前台时送达，或者用户点开了它）：按子类型处理账号状态（docs/push.md 第 4 节）。
    ///
    /// - `account_frozen`：显示冻结页（回到前台、点“重新检查”时会再问服务端，晚到的旧推送不会一直卡住）；
    /// - `account_restored`：重查账号；解冻了就回到正常、重新订阅事件流（`resubscribeRequest`），刷新实例、角标，同步收件箱；
    /// - `stopped_all`：刷新角标（进行中的运行、待确认的计划）。
    ///
    /// 跳转由 `open(push:)` 做。
    public func receive(push: PushPayload) async {
        switch push.subtype {
        case .accountFrozen?:
            if phase == .signedIn, client.signedIn() { enter(.frozen) }
        case .accountRestored?:
            await accountRestored()
        case .stoppedAll?:
            await refreshBadges()
        default:
            break
        }
    }

    /// 点开推送：先按 `receive(push:)` 处理账号状态，再跳到 `push.route`（没登录、冻结、要升级时 `Router` 先记下，
    /// 回到正常状态再跳）。
    public func open(push: PushPayload) async {
        await receive(push: push)
        router.handle(push: push)
        await markRead(push)
    }

    /// 通知上的“拒绝”（审批推送的 `REJECT`，docs/push.md 第 2 节；App 可能在后台、没有界面）：拒绝不用本机验证。
    /// 先查一次审批，还待处理就选它的拒绝选项；已经处理过、过期了、没有拒绝选项的什么都不做。这条通知标已读、刷新角标。
    /// 返回拒绝了没有。
    @discardableResult
    public func rejectFromNotification(_ push: PushPayload) async -> Bool {
        guard phase == .signedIn, push.kind == .approval, let approvalID = push.approvalID else { return false }
        await markRead(push)
        defer { Task { await refreshBadges() } }
        do {
            let approval = try await client.getApproval(approvalID)
            guard approval.isPending, !approval.isExpired(now: now()),
                let reject = approval.options.first(where: { $0.kind.isReject })
            else { return false }
            _ = try await client.decideApproval(approvalID, optionID: reject.id)
            return true
        } catch {
            return false
        }
    }

    /// APNs 给了设备令牌（App 代理的 `didRegisterForRemoteNotificationsWithDeviceToken`，每次启动都有）：记下，登录着就
    /// 报给服务端（`setPushToken`，令牌会变）；没登录时登录带上（`pushRegistration`）。
    public func didReceivePushToken(_ registration: PushRegistration) async {
        pushRegistration = registration
        await reportPushToken()
    }

    /// 推送对应的收件箱条目标已读（点开、在通知上处理了）。没登录、冻结时不标（收件箱里打开时再标）。
    private func markRead(_ push: PushPayload) async {
        guard phase == .signedIn, let id = push.inboxItemID else { return }
        guard let unread = try? await client.markInboxRead(ids: [id], upTo: nil) else { return }
        inboxUnreadChanged(unread)
    }

    /// 推送令牌报给服务端：登录着、有令牌、这次登录还没报过这个。失败了下次启动、登录、收到令牌时再报。
    private func reportPushToken() async {
        guard phase == .signedIn, let registration = pushRegistration, registration != reportedPushRegistration
        else { return }
        do {
            try await client.setPushToken(registration)
            reportedPushRegistration = registration
        } catch {
            // 全局错误（登录失效、冻结）`ObservedClient` 已经报过；其余的下次再试。
        }
    }

    /// 这台设备第一次登录进来、账号还没有实例或 key（换了新手机）：弹一次引导（12.17）。新用户登录时 `SignInModel`
    /// 已经要弹了，不重复。
    private func presentOnboardingIfNeeded() async {
        guard phase == .signedIn, router.sheet != .onboarding, router.pendingRoute?.route != .onboarding else { return }
        guard await onboardingCheck.shouldPresent(client: client), phase == .signedIn else { return }
        if router.sheet == nil { router.present(.onboarding) }
    }

    /// App 图标的角标跟着收件箱的未读数（docs/push.md 第 6 节：App 在前台时自己设）；主屏小组件跟着角标（12.20）。
    private func updateAppBadge() {
        publishWidgetSnapshot()
        guard let notifications, appBadge != badges.inboxUnread else { return }
        let count = badges.inboxUnread
        appBadge = count
        Task { await notifications.setBadge(count) }
    }

    /// 把角标的数写给小组件（12.20）：登录着时是现在的数，否则是“没登录”。数没变不重写。
    private func publishWidgetSnapshot() {
        guard let widgets else { return }
        let snapshot =
            phase == .signedIn ? WidgetSnapshot(badges: badges, updatedAt: now()) : .signedOut(at: now())
        if let last = lastWidgetSnapshot, last.sameCounts(as: snapshot) { return }
        lastWidgetSnapshot = snapshot
        let previous = widgetTask
        widgetTask = Task {
            await previous?.value
            await widgets.publish(snapshot)
        }
    }

    /// 账号解冻：冻结页上就重新检查（解冻了回到正常）；已经在正常状态就确认一下账号，让页面重新订阅，再刷新。
    private func accountRestored() async {
        switch phase {
        case .frozen:
            await recheckAccount()
        case .signedIn:
            await verifyAccount()
            guard phase == .signedIn else { return }
            resubscribeRequest += 1
            await refresh()
        case .signedOut, .upgradeRequired:
            break
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

    /// `number` 是报告的序号（测试里直接喂报告）。
    func receive(_ activity: ClientActivity, number: Int) {
        switch activity {
        case .failed(let error):
            if error.isAccountFrozen, number <= staleFrozenReports { return }
            handle(error)
        case .reachable:
            isOffline = false
        case .signedIn(let result):
            didSignIn(result)
        case .userUpdated(let updated):
            userUpdated(updated)
        case .signedOut:
            enter(.signedOut)
        case .stream(let status, let instanceID, let token):
            streamChanged(status, instanceID: instanceID, token: token)
        case .streamEnded(let token):
            streams[token] = nil
            streamRetryAt[token] = nil
            updateConnection()
        case .runStarted(let run):
            runStarted(run)
        }
    }

    /// 自己发了任务：设置里开着就开实时活动（12.10），标题是实例名。
    private func runStarted(_ run: Run) {
        guard phase == .signedIn, let liveActivities else { return }
        let title = instances.first { $0.id == run.instanceID }?.name ?? "ThinkTin"
        Task { await liveActivities.runStarted(run, title: title) }
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
        Task {
            await syncLanguage()
            await refresh()
            // 登录时可能已经带上了（`SignInModel`），再报一次也没关系；令牌是登录之后才到的就靠这里。
            await reportPushToken()
            await liveActivities?.resume()
            await presentOnboardingIfNeeded()
        }
    }

    /// 别的页面拿到了最新的用户：同一个账号、还登录着（正常或冻结）才换上。冻结、解冻由 `verifyAccount`、
    /// `recheckAccount` 判断，这里只换用户。
    private func userUpdated(_ updated: User) {
        guard phase == .signedIn || phase == .frozen, user == nil || user?.id == updated.id else { return }
        user = updated
    }

    /// 客户端说过要升级（`upgradeRequired()`，不联网）就进升级页。返回进没进。
    private func checkUpgradeRequired() -> Bool {
        guard phase != .upgradeRequired else { return true }
        guard client.upgradeRequired() else { return false }
        enter(.upgradeRequired)
        return true
    }

    /// 切换全局状态。升级页是终点：之后什么都不再切换。
    private func enter(_ next: Phase) {
        guard phase != next, phase != .upgradeRequired else { return }
        let previous = phase
        phase = next
        router.isHoldingRoutes = next != .signedIn
        switch next {
        case .signedOut:
            // 清掉上一个账号的一切（缓存由 client-core 在退出登录时清）。
            user = nil
            instances = []
            activity = [:]
            badges = .zero
            publishWidgetSnapshot()
            if let liveActivities { Task { await liveActivities.signedOut() } }
            hasLoadedInstances = false
            refreshError = nil
            accountCheckError = nil
            isOffline = false
            lastBadgeRefresh = nil
            reportedPushRegistration = nil
            router.reset()
            resetStreams()
            // 推送里没有用户 id：上一个账号的通知、角标都清掉（docs/push.md 第 3 节）。
            if let notifications {
                appBadge = 0
                Task {
                    await notifications.removeAllDelivered()
                    await notifications.setBadge(0)
                }
            }
        case .upgradeRequired:
            observed.haltStreams()
            resetStreams()
        case .frozen:
            // 事件流以 4003 关闭、自己停了；连接横幅不再显示。
            resetStreams()
        case .signedIn:
            // 解冻：冻结期间事件流都停了，页面重新订阅。
            if previous == .frozen { resubscribeRequest += 1 }
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
            if me.status == .frozen {
                enter(.frozen)
            } else {
                staleFrozenReports = reportsSent.withLock { $0 }
            }
        } catch {
            handle(error)
        }
    }

    /// 服务端的用户语言和界面语言不一致就改（12.12，`LanguageSettingsModel.syncOnLaunch(user:)`）：启动时确认完账号、
    /// 登录成功、解冻之后各一次。静默进行（网络不通、服务端出错都不提示，下次启动再试）；不在正常状态（冻结了、退出了）
    /// 时不做。还不知道用户（启动时 `me()` 失败了，多半是离线）也不做：不再多等一次 `me()`，实例和角标的刷新不被它耽误。
    private func syncLanguage() async {
        guard let language, phase == .signedIn, let known = user else { return }
        let synced = await language.syncOnLaunch(user: known)
        // 等的时候退出登录、换了账号的不用。
        guard phase == .signedIn, let synced, user?.id == synced.id else { return }
        user = synced
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
        updateAppBadge()
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
        case .upgradeRequired:
            // 服务端说这个版本太老（握手或别的请求回 426）：进升级页，停掉所有事件流。
            enter(.upgradeRequired)
        case .stopped:
            // 调用方自己停的：只是这一条结束了。
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
