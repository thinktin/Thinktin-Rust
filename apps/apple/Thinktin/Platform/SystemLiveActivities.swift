import ActivityKit
import Foundation
import OSLog
import ThinktinKit

/// ActivityKit 的实时活动（WBS 12.10）：`LiveActivityModel` 通过它开、改、结束（`LiveActivityControlling`）；
/// `observe(_:)` 之后把系统给的东西转给模型——每个实时活动的推送令牌（`pushTokenUpdates`）、用户划掉 / 结束了
/// （`activityStateUpdates`）、后台远程开启的新实时活动（`activityUpdates`）、推送开启令牌（iOS 17.2 起，
/// `pushToStartTokenUpdates`）。都在主线程上做。
@MainActor
final class SystemLiveActivities: LiveActivityControlling {
    private static let log = Logger(subsystem: "cn.thinktin.app", category: "live-activities")

    private weak var model: LiveActivityModel?
    /// 已经在听的实时活动（`Activity.id`），不重复听。
    private var observed: Set<String> = []

    /// 开始把系统的变化转给模型（`AppEnvironment` 建好 `AppModel` 后调一次）。App 重新启动时还开着的实时活动
    /// 也在这里接上（令牌会再给一次）。
    func observe(_ model: LiveActivityModel) {
        self.model = model
        for activity in Activity<RunActivityAttributes>.activities { watch(activity) }
        Task { [weak self] in
            for await activity in Activity<RunActivityAttributes>.activityUpdates {
                self?.watch(activity)
            }
        }
        if #available(iOS 17.2, *) {
            Task { [weak self] in
                for await token in Activity<RunActivityAttributes>.pushToStartTokenUpdates {
                    await self?.model?.startTokenChanged(token)
                }
            }
        }
    }

    // MARK: LiveActivityControlling

    func areActivitiesEnabled() async -> Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func openActivities() async -> [LiveActivityRun] {
        Activity<RunActivityAttributes>.activities.filter(Self.isOpen).map(Self.run)
    }

    func start(_ activity: LiveActivityRun) async -> Bool {
        let attributes = RunActivityAttributes(
            runId: activity.runID.rawValue, instanceId: activity.instanceID.rawValue, title: activity.title)
        do {
            let started = try Activity.request(
                attributes: attributes, content: ActivityContent(state: activity.state, staleDate: nil),
                pushType: .token)
            watch(started)
            return true
        } catch {
            Self.log.error("cannot start a live activity: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func update(runID: RunID, state: RunActivityContentState) async {
        guard let activity = Self.find(runID) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end(runID: RunID, state: RunActivityContentState?, immediately: Bool) async {
        guard let activity = Self.find(runID) else { return }
        await activity.end(
            state.map { ActivityContent(state: $0, staleDate: nil) },
            dismissalPolicy: immediately ? .immediate : .default)
    }

    // MARK: 内部

    private func watch(_ activity: Activity<RunActivityAttributes>) {
        guard Self.isOpen(activity), observed.insert(activity.id).inserted else { return }
        let runID = RunID(activity.attributes.runId)
        model?.appeared(Self.run(activity))
        Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                await self?.model?.tokenChanged(runID: runID, token: token)
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                await self?.model?.dismissed(runID: runID)
                break
            }
        }
    }

    nonisolated private static func isOpen(_ activity: Activity<RunActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    /// 每次现找（`nonisolated`：找到的活动不属于主线程，可以交给 ActivityKit 的异步方法）。
    nonisolated private static func find(_ runID: RunID) -> Activity<RunActivityAttributes>? {
        Activity<RunActivityAttributes>.activities.first { $0.attributes.runId == runID.rawValue }
    }

    nonisolated private static func run(_ activity: Activity<RunActivityAttributes>) -> LiveActivityRun {
        LiveActivityRun(
            runID: RunID(activity.attributes.runId), instanceID: InstanceID(activity.attributes.instanceId),
            title: activity.attributes.title, state: activity.content.state)
    }
}
