import Foundation
import Observation

/// 一个开着的实时活动（App 里是 ActivityKit 的 `Activity<RunActivityAttributes>`，docs/live-activities.md 第 3 节）。
public struct LiveActivityRun: Hashable, Sendable {
    public var runID: RunID
    public var instanceID: InstanceID
    /// 实例名（远程开启的由后台填）。
    public var title: String
    /// 现在显示的内容（后台推送更新过的也算）。
    public var state: RunActivityContentState

    public init(runID: RunID, instanceID: InstanceID, title: String, state: RunActivityContentState) {
        self.runID = runID
        self.instanceID = instanceID
        self.title = title
        self.state = state
    }
}

/// 系统的实时活动（App 里是 ActivityKit，测试里记下来）。推送令牌、用户划掉、后台远程开启的新活动、推送开启令牌由
/// App 的平台层监听，再告诉 `LiveActivityModel`（`tokenChanged`、`dismissed`、`appeared`、`startTokenChanged`）。
public protocol LiveActivityControlling: Sendable {
    /// 用户允许显示实时活动（系统设置里没关）。
    func areActivitiesEnabled() async -> Bool
    /// 现在开着的（包括后台远程开启的）。
    func openActivities() async -> [LiveActivityRun]
    /// 开一个（要推送令牌）；开不了（系统不允许、开得太多）返回 false。
    func start(_ activity: LiveActivityRun) async -> Bool
    func update(runID: RunID, state: RunActivityContentState) async
    /// 结束。`immediately` 时马上从锁屏拿掉（换账号、登记被拒），否则按系统默认留一会儿。
    func end(runID: RunID, state: RunActivityContentState?, immediately: Bool) async
}

/// 实时活动（WBS 12.10，docs/live-activities.md）：灵动岛和锁屏上显示运行的状态、步数、耗时。
///
/// - **自己发的任务**：`AppModel` 看到 `sendMessage` 成功（`ClientActivity.runStarted`）就开（设置里能关，`showsMyRuns`）；
///   运行页上也能手动开（`start`）。只开根运行，子运行、流水线的步骤算在根运行上。
/// - **推送令牌**：平台层拿到令牌（`tokenChanged`）就登记（`registerLiveActivity`），之后 App 被挂起了后台也推送更新；
///   回到前台（`resume`）把每个开着的再报一次（同一个令牌服务端什么都不变）。运行早就结束、不是自己的（服务端拒绝）
///   就在本地马上结束。用户划掉了（`dismissed`）告诉服务端不再推送。
/// - **前台**：跟着事件流更新（状态变了马上变，步数每个工具调用加一；子运行的步数等后台推送），运行结束时在本地结束。
/// - **计划运行**（`showsScheduledRuns`，默认关）：打开才把推送开启令牌报给服务端，计划到点的根运行由后台远程开启；
///   远程开启的由平台层发现（`appeared`）后照样登记令牌。关掉时清掉服务端的令牌。
/// - **退出登录、换账号**：开着的都在本地马上结束（标题是上一个账号的实例名）。
@Observable @MainActor
public final class LiveActivityModel {
    /// 自己发的任务自动开实时活动（默认开）。
    public var showsMyRuns: Bool {
        didSet { defaults?.set(showsMyRuns, forKey: Keys.myRuns) }
    }
    /// 计划运行时显示实时活动（默认关，`setShowsScheduledRuns` 改）。
    public private(set) var showsScheduledRuns: Bool
    /// 开着实时活动的运行（运行页的按钮看它）。
    public private(set) var openRunIDs: Set<RunID> = []
    /// 系统设置里关掉了实时活动（`resume` 时更新）。
    public private(set) var isSystemDisabled = false

    enum Keys {
        static let myRuns = "liveActivities.myRuns"
        static let scheduledRuns = "liveActivities.scheduledRuns"
        /// 服务端现在有的推送开启令牌（报成功了才记）。
        static let reportedStartToken = "liveActivities.reportedStartToken"
    }

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let system: any LiveActivityControlling
    @ObservationIgnored private let defaults: UserDefaults?
    /// 每个实时活动最新的推送令牌（十六进制）。
    @ObservationIgnored private var tokens: [RunID: String] = [:]
    /// 开着的实时活动属于哪个实例（前台跟哪些事件流）。
    @ObservationIgnored private var instances: [RunID: InstanceID] = [:]
    /// ActivityKit 给的推送开启令牌（每次启动都会再给一次，只放内存）。
    @ObservationIgnored private var startToken: String?
    @ObservationIgnored private var streams: [InstanceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isForeground = false

    public init(client: any ClientProtocol, system: any LiveActivityControlling, defaults: UserDefaults? = .standard) {
        self.client = client
        self.system = system
        self.defaults = defaults
        showsMyRuns = defaults?.object(forKey: Keys.myRuns) as? Bool ?? true
        showsScheduledRuns = defaults?.bool(forKey: Keys.scheduledRuns) ?? false
    }

    /// 这个运行能手动开实时活动（根运行、没结束、还没开）。
    public func canStart(_ run: Run) -> Bool {
        run.parentRunID == nil && !run.state.isTerminal && !openRunIDs.contains(run.id)
    }

    // MARK: 开、结束

    /// 自己发了一个任务（`AppModel` 调）：设置里开着就开实时活动。
    public func runStarted(_ run: Run, title: String) async {
        guard showsMyRuns else { return }
        await start(run, title: title)
    }

    /// 开实时活动（运行页上的按钮、自己发的任务）。开不了（系统设置里关了、已经开着、运行结束了、开得太多）返回 false。
    @discardableResult
    public func start(_ run: Run, title: String) async -> Bool {
        guard canStart(run), openRunIDs.count < LiveActivityLimits.maxOpenPerDevice else { return false }
        guard await system.areActivitiesEnabled() else {
            isSystemDisabled = true
            return false
        }
        let activity = LiveActivityRun(
            runID: run.id, instanceID: run.instanceID, title: title, state: RunActivityContentState(run: run))
        guard await system.start(activity) else { return false }
        track(activity)
        return true
    }

    /// 平台层发现了一个开着的实时活动（后台远程开启的、App 重新启动后还开着的）。
    public func appeared(_ activity: LiveActivityRun) {
        track(activity)
    }

    /// 实时活动的推送令牌（平台层的 `pushTokenUpdates`）：登记给服务端，后台才推送更新。
    public func tokenChanged(runID: RunID, token: Data) async {
        let hex = LiveActivityToken.hex(token)
        guard LiveActivityToken.isValid(hex), tokens[runID] != hex else { return }
        tokens[runID] = hex
        await register(runID, token: hex)
    }

    /// 用户划掉了、系统结束了：服务端不再推送。
    public func dismissed(runID: RunID) async {
        let wasOpen = forget(runID)
        guard wasOpen else { return }
        try? await client.endLiveActivity(runID: runID)
    }

    // MARK: 计划运行

    /// ActivityKit 的推送开启令牌（iOS 17.2 起，`pushToStartTokenUpdates`）。
    public func startTokenChanged(_ token: Data) async {
        let hex = LiveActivityToken.hex(token)
        guard LiveActivityToken.isValid(hex) else { return }
        startToken = hex
        await syncStartToken()
    }

    /// 设置里的“计划运行时显示实时活动”：打开才把推送开启令牌报给服务端，关掉时清掉。
    public func setShowsScheduledRuns(_ on: Bool) async {
        showsScheduledRuns = on
        defaults?.set(on, forKey: Keys.scheduledRuns)
        await syncStartToken()
    }

    /// 服务端该有的推送开启令牌和报过的不一样时报一次（失败了下次 `resume` 再来）。
    private func syncStartToken() async {
        let wanted = showsScheduledRuns ? startToken : nil
        // 打开了但 ActivityKit 还没给令牌：等它给了再报。
        if showsScheduledRuns, wanted == nil { return }
        let reported = defaults?.string(forKey: Keys.reportedStartToken)
        guard wanted != reported else { return }
        do {
            try await client.setLiveActivityStartToken(wanted)
            defaults?.set(wanted, forKey: Keys.reportedStartToken)
        } catch {
            // 网络不通、没登录：下次回到前台、登录后再报。
        }
    }

    // MARK: 前后台、登录状态

    /// 启动、回到前台、登录之后（`AppModel` 调）：对一遍开着的实时活动，把令牌再报一次，跟上事件流。
    public func resume() async {
        isForeground = true
        isSystemDisabled = !(await system.areActivitiesEnabled())
        let open = await system.openActivities()
        let openIDs = Set(open.map(\.runID))
        for runID in openRunIDs.subtracting(openIDs) { forget(runID) }
        for activity in open { track(activity) }
        for (runID, token) in tokens where openIDs.contains(runID) {
            await register(runID, token: token)
        }
        await syncStartToken()
    }

    /// 进后台：停掉前台的事件流（之后靠后台推送）。
    public func pause() {
        isForeground = false
        for task in streams.values { task.cancel() }
        streams = [:]
    }

    /// 退出登录、换账号：开着的都在本地马上结束（标题是上一个账号的实例名，不能留在锁屏上）。服务端的令牌随登录状态清掉。
    public func signedOut() async {
        pause()
        let open = Set(await system.openActivities().map(\.runID)).union(openRunIDs)
        for runID in open {
            await system.end(runID: runID, state: nil, immediately: true)
        }
        openRunIDs = []
        tokens = [:]
        instances = [:]
        defaults?.removeObject(forKey: Keys.reportedStartToken)
    }

    // MARK: 内部

    private func track(_ activity: LiveActivityRun) {
        openRunIDs.insert(activity.runID)
        instances[activity.runID] = activity.instanceID
        follow(activity.instanceID)
    }

    /// 不再管这个实时活动；返回之前是不是开着。
    @discardableResult
    private func forget(_ runID: RunID) -> Bool {
        let wasOpen = openRunIDs.remove(runID) != nil
        tokens[runID] = nil
        if let instanceID = instances.removeValue(forKey: runID), !instances.values.contains(instanceID) {
            streams.removeValue(forKey: instanceID)?.cancel()
        }
        return wasOpen
    }

    private func register(_ runID: RunID, token: String) async {
        do {
            try await client.registerLiveActivity(runID: runID, token: token)
        } catch let error as ClientError where error.isInvalidInput || error.isNotFound {
            // 运行结束 10 分钟以上、不是自己的运行：后台不会推送，在本地马上结束。
            await system.end(runID: runID, state: nil, immediately: true)
            forget(runID)
        } catch {
            // 网络不通等：留着令牌，下次回到前台再报。
        }
    }

    /// 前台跟着实例的事件流（每个实例一条，只看新来的事件）。
    private func follow(_ instanceID: InstanceID) {
        guard isForeground, streams[instanceID] == nil else { return }
        let latest = (try? client.cachedEventsBefore(instanceID: instanceID, beforeSeq: nil, limit: 1))?.last?.seq
        guard let stream = try? client.events(instanceID: instanceID, afterSeq: latest) else { return }
        streams[instanceID] = Task { [weak self] in
            for await element in stream {
                // 取消前已经进了缓冲的事件也不要（进后台之后靠后台推送）。
                if Task.isCancelled { return }
                guard case .event(let event) = element else { continue }
                await self?.received(event)
            }
        }
    }

    private func received(_ event: InstanceEvent) async {
        guard isForeground, let runID = event.runID, openRunIDs.contains(runID) else { return }
        let current = await system.openActivities().first { $0.runID == runID }?.state
        guard var state = current else { return }
        switch event.kind {
        case .toolCall:
            // 子运行的步数等后台推送（它的数是准的，推过来会盖掉这里的）。
            state.steps += 1
        case .runState:
            guard let payload = event.runStatePayload else { return }
            state.state = payload.state.rawValue
            state.waitCode = RunWaitCode.applies(to: payload.state) ? payload.waitCode?.rawValue : nil
            let at = RunActivityContentState.unixSeconds(event.createdAt)
            if state.startedAt == nil, payload.state == .running { state.startedAt = at }
            if payload.state.isTerminal {
                state.endedAt = state.endedAt ?? at
                await system.end(runID: runID, state: state, immediately: false)
                forget(runID)
                try? await client.endLiveActivity(runID: runID)
                return
            }
        default:
            return
        }
        guard state != current else { return }
        await system.update(runID: runID, state: state)
    }
}
