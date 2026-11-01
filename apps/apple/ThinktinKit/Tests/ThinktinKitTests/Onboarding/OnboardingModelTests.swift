import Foundation
import Testing

@testable import ThinktinKit

/// 权限先是 `initial`，请求之后变成 `afterRequest`。
private final class ScriptedPermission: NotificationPermissionReading, NotificationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NotificationPermission
    private let afterRequest: NotificationPermission
    private(set) var requests = 0

    init(_ initial: NotificationPermission, afterRequest: NotificationPermission) {
        current = initial
        self.afterRequest = afterRequest
    }

    func currentPermission() async -> NotificationPermission { lock.withLock { current } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            requests += 1
            current = afterRequest
            return afterRequest == .authorized
        }
    }
}

@MainActor
@Suite("上手引导（12.17）")
struct OnboardingModelTests {
    private func model(_ state: MockState, permission: ScriptedPermission) -> OnboardingModel {
        OnboardingModel(
            client: MockClient(state: state, stepDelay: 0, autoReply: false), notifications: permission,
            authorizer: permission)
    }

    @Test("新账号：从领养开始，一步步往后")
    func freshAccount() async {
        var state = DemoData.state()
        state.instances = []
        state.credentials = []
        let permission = ScriptedPermission(.notDetermined, afterRequest: .authorized)
        let model = model(state, permission: permission)
        await model.load()
        #expect(model.currentStep == .adopt)
        #expect(!model.isComplete)
        #expect(OnboardingStep.allCases.allSatisfy { !model.isDone($0) })
    }

    @Test("演示账号：前四步都做完了，只差打开通知；打开后全部完成")
    func demoAccount() async {
        let permission = ScriptedPermission(.notDetermined, afterRequest: .authorized)
        let model = model(DemoData.state(), permission: permission)
        await model.load()
        #expect(model.isDone(.adopt) && model.isDone(.addKey) && model.isDone(.routeMain) && model.isDone(.firstTask))
        #expect(model.isComplete)
        #expect(model.currentStep == .notifications)
        await model.requestNotifications()
        #expect(permission.requests == 1)
        #expect(model.currentStep == nil)
    }

    @Test("有实例、有 key，没配 main、没发过任务")
    func partway() async throws {
        var state = DemoData.state()
        let instance = try #require(state.instances.max { $0.lastActiveAt < $1.lastActiveAt })
        state.routes[instance.id] = []
        state.runs.removeAll { $0.instanceID == instance.id }
        let model = model(state, permission: ScriptedPermission(.denied, afterRequest: .denied))
        await model.load()
        #expect(model.instance?.id == instance.id)
        #expect(model.currentStep == .routeMain)
        #expect(!model.isDone(.firstTask))
        #expect(model.notificationsDenied)
    }

    @Test("实例切换后刷新中断，保留上次完整检查的实例和步骤")
    func interruptedRefresh() async throws {
        let client = MockClient(state: DemoData.state(), stepDelay: 0)
        let permission = ScriptedPermission(.authorized, afterRequest: .authorized)
        let model = OnboardingModel(client: client, notifications: permission, authorizer: permission)
        await model.load()
        let previous = try #require(model.instance?.id)
        client.update { $0.instances.removeAll { $0.id == previous } }
        client.failNext("credentials()", with: .network(message: "offline"))
        await model.load()
        #expect(model.error?.isOffline == true)
        #expect(model.instance?.id == previous)
        await model.load()
        #expect(model.error == nil)
        #expect(model.instance?.id != previous)
    }

    @Test("换新机检查：不记的不弹；没有 key 的弹一次")
    func newDeviceCheck() async throws {
        #expect(
            !(await OnboardingCheck(defaults: nil).shouldPresent(
                client: MockClient(state: DemoData.state(), stepDelay: 0))))
        let suite = "onboarding-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = DemoData.state()
        state.credentials = []
        let client = MockClient(state: state, stepDelay: 0)
        let check = OnboardingCheck(defaults: defaults)
        #expect(await check.shouldPresent(client: client))
        #expect(check.hasChecked)
        #expect(!(await check.shouldPresent(client: client)))
    }
}
