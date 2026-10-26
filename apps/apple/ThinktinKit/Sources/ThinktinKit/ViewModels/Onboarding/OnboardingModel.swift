import Foundation
import Observation

/// 请求通知权限（WBS 12.17：用到时再问）。ThinktinKit 只认 Foundation，实现在 App 里（`SystemPushRegistrar.register()`：
/// 弹系统的权限框并向 APNs 注册）；预览、测试用 `FixedNotificationAuthorizer`。
public protocol NotificationAuthorizing: Sendable {
    /// 请求通知权限（还没问过时弹系统框）。返回允许了没有。
    func requestAuthorization() async -> Bool
}

/// 不弹框，直接给定结果（预览、测试；App 外面跑时）。
public struct FixedNotificationAuthorizer: NotificationAuthorizing {
    public var granted: Bool

    public init(granted: Bool = false) {
        self.granted = granted
    }

    public func requestAuthorization() async -> Bool { granted }
}

/// 上手的几步（WBS 12.17）：领养 → 加 key → 配默认模型（`main`）→ 发第一个任务，最后打开通知（可选）。
public enum OnboardingStep: Int, CaseIterable, Hashable, Sendable {
    case adopt
    case addKey
    case routeMain
    case firstTask
    case notifications

    /// 可以跳过的（不影响用）。
    public var isOptional: Bool { self == .notifications }
}

/// 新用户引导（WBS 12.17，`.onboarding`，sheet）：按服务端的现状算每一步做没做完（实例、key、实例的 `main` 别名、运行），
/// 当前这一步给一个按钮去做。新用户登录后弹出；换了新手机（这台设备第一次登录、账号还没有实例或 key）也弹一次
/// （`OnboardingCheck`）；设置里随时能再打开。
///
/// 通知权限在这里问（“用到时再问”）：前面几步做完才到这一步；拒绝过的只能去系统设置。
@Observable @MainActor
public final class OnboardingModel {
    /// 实例，最近活跃的在前（不含已删除的）。
    public private(set) var instances: [Instance] = []
    public private(set) var hasCredentials = false
    /// 第一个实例有默认模型（`main` 别名）。
    public private(set) var hasMainRoute = false
    /// 发过任务（有运行）。
    public private(set) var hasRun = false
    public private(set) var notificationPermission: NotificationPermission?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isRequestingNotifications = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let notifications: any NotificationPermissionReading
    @ObservationIgnored private let authorizer: any NotificationAuthorizing

    public init(
        client: any ClientProtocol, notifications: any NotificationPermissionReading,
        authorizer: any NotificationAuthorizing
    ) {
        self.client = client
        self.notifications = notifications
        self.authorizer = authorizer
    }

    /// 要配置的实例（最近活跃的那个）。
    public var instance: Instance? { instances.first }

    public func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .adopt: !instances.isEmpty
        case .addKey: hasCredentials
        case .routeMain: hasMainRoute
        case .firstTask: hasRun
        case .notifications: notificationPermission == .authorized || notificationPermission == .provisional
        }
    }

    /// 现在该做的一步（必做的都做完、通知也开了时为 nil）。
    public var currentStep: OnboardingStep? {
        OnboardingStep.allCases.first { !isDone($0) }
    }

    /// 必做的都做完了。
    public var isComplete: Bool {
        OnboardingStep.allCases.filter { !$0.isOptional }.allSatisfy(isDone)
    }

    /// 通知拒绝过：系统不再弹框，只能去系统设置。
    public var notificationsDenied: Bool { notificationPermission == .denied }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        notificationPermission = await notifications.currentPermission()
        do {
            instances = try await client.instances().filter { $0.state != .deleted }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
            hasCredentials = !(try await client.credentials()).isEmpty
            if let instance {
                hasMainRoute = try await client.modelRoutes(instanceID: instance.id).contains(where: \.isMain)
                hasRun = !(try await client.runs(instanceID: instance.id, limit: 1)).isEmpty
            } else {
                hasMainRoute = false
                hasRun = false
            }
            error = nil
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
        hasLoaded = true
    }

    /// 打开通知：还没问过的弹系统框；拒绝过的页面带用户去系统设置。
    public func requestNotifications() async {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        defer { isRequestingNotifications = false }
        _ = await authorizer.requestAuthorization()
        notificationPermission = await notifications.currentPermission()
    }
}

/// 换新手机时检查一次（WBS 12.17）：这台设备上第一次登录进来，账号还没有实例或 key，就弹出引导。每台设备只看一次
/// （`UserDefaults`），之后从设置里打开。
public struct OnboardingCheck {
    static let key = "cn.thinktin.onboarding.checked"

    /// 为 nil 时不记（测试、预览）。
    public let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    public var hasChecked: Bool { defaults?.bool(forKey: Self.key) ?? false }

    public func markChecked() {
        defaults?.set(true, forKey: Self.key)
    }

    /// 要不要弹：没看过，且还没有实例或 key。看过了就记下（不管弹没弹）。不记的（测试、预览）不弹。
    @MainActor
    public func shouldPresent(client: any ClientProtocol) async -> Bool {
        guard defaults != nil, !hasChecked else { return false }
        do {
            let instances = try await client.instances().filter { $0.state != .deleted }
            let credentials = try await client.credentials()
            markChecked()
            return instances.isEmpty || credentials.isEmpty
        } catch {
            // 拉不到（离线）：下次启动再看。
            return false
        }
    }
}

/// 引导的文案（WBS 12.17）。
public enum OnboardingText {
    public static func title(_ language: DisplayLanguage) -> String {
        language == .chinese ? "四步开始用 ThinkTin" : "Get started in four steps"
    }

    public static func intro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "agent 跑在云端，用你自己的模型 key。领养一个、配好 key，就能把任务交给它。"
            : "Agents run in the cloud on your own model keys. Adopt one, set up a key, and hand it a task."
    }

    public static func stepTitle(_ step: OnboardingStep, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch step {
        case .adopt: return zh ? "领养一个 agent" : "Adopt an agent"
        case .addKey: return zh ? "添加模型 key" : "Add a model key"
        case .routeMain: return zh ? "选默认模型" : "Pick the default model"
        case .firstTask: return zh ? "发第一个任务" : "Send your first task"
        case .notifications: return zh ? "打开通知（可选）" : "Turn on notifications (optional)"
        }
    }

    public static func stepDetail(_ step: OnboardingStep, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch step {
        case .adopt:
            return zh ? "从 agent 目录里挑一个，它会有自己的云端工作区。" : "Pick one from the catalog. It gets its own cloud workspace."
        case .addKey:
            return zh
                ? "agent 调模型用你的 key，费用直接走你的账户。" : "Agents call models with your key, billed to your own account."
        case .routeMain:
            return zh ? "告诉 agent 默认用哪个模型（`main`）。" : "Tell the agent which model to use by default (`main`)."
        case .firstTask:
            return zh
                ? "用一句话说要做什么，过程和结果都在对话里。" : "Describe the job in a sentence. Progress and results show up in the chat."
        case .notifications:
            return zh
                ? "agent 要你批准、运行完成时提醒你。" : "Get alerted when an agent needs your OK or a run finishes."
        }
    }

    public static func action(_ step: OnboardingStep, denied: Bool, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch step {
        case .adopt: return zh ? "去 agent 目录" : "Browse agents"
        case .addKey: return zh ? "添加 key" : "Add a key"
        case .routeMain: return zh ? "设置模型" : "Set up models"
        case .firstTask: return zh ? "去发任务" : "Start a task"
        case .notifications:
            if denied { return zh ? "去系统设置打开" : "Open system settings" }
            return zh ? "打开通知" : "Turn on"
        }
    }

    public static func done(_ language: DisplayLanguage) -> String {
        language == .chinese ? "已完成" : "Done"
    }

    public static func later(_ language: DisplayLanguage) -> String {
        language == .chinese ? "稍后再说" : "Later"
    }

    public static func allSet(_ language: DisplayLanguage) -> String {
        language == .chinese ? "都准备好了，开始吧。" : "You're all set."
    }

    /// 设置里再打开引导的那一行。
    public static func settingsRow(_ language: DisplayLanguage) -> String {
        language == .chinese ? "上手引导" : "Getting started"
    }
}
