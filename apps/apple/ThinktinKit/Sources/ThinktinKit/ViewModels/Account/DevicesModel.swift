import Foundation
import Observation

/// 登录设备页（WBS 12.2）：设备列表（本机在最前、电脑是否在线）、单台下线、下线其他设备（可以顺带全部停止）。
///
/// - 下线本机等于退出登录：`revokeDevice` 之后本地会话没了，`ObservedClient` 报给 `AppModel` 回到登录页，这里不用管。
/// - 设备不缓存（docs/ios.md 6.2）：离线时列表是空的，页面顶部的离线横幅由 `AppShell` 放；写操作在界面上禁用。
@Observable @MainActor
public final class DevicesModel {
    /// 本机在最前，其余按最近活跃（服务端的顺序）。
    public private(set) var devices: [DeviceInfo] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 拉列表失败。
    public private(set) var loadError: ClientError?
    /// 下线、下线其他设备失败。
    public private(set) var actionError: ClientError?
    /// 正在下线的设备。
    public private(set) var revoking: Set<DeviceID> = []
    public private(set) var isSigningOutOthers = false
    /// 最近一次下线其他设备的结果（界面弹出数字）。
    public var signOutOthersResult: SignOutOthersResult?
    /// 最近一次下线的那一台（界面提示“已下线”）。
    public private(set) var lastRevoked: DeviceInfo?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    /// 这台。
    public var currentDevice: DeviceInfo? { devices.first(where: \.isCurrent) }
    /// 别的设备。
    public var otherDevices: [DeviceInfo] { devices.filter { !$0.isCurrent } }

    /// 第一次打开时拉（已经拉过的不重复拉）。
    public func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    /// 拉设备列表（下拉刷新）。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            devices = Self.ordered(try await client.devices())
            hasLoaded = true
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = Self.clientError(error)
        }
    }

    /// 下线一台。本机的话等于退出登录（应用框架自己回登录页）。返回成功没有。
    @discardableResult
    public func revoke(_ device: DeviceInfo) async -> Bool {
        guard !revoking.contains(device.id) else { return false }
        revoking.insert(device.id)
        actionError = nil
        defer { revoking.remove(device.id) }
        do {
            try await client.revokeDevice(device.id)
            devices.removeAll { $0.id == device.id }
            lastRevoked = device
            return true
        } catch is CancellationError {
            return false
        } catch {
            let clientError = Self.clientError(error)
            // 已经不在了（别处下线过）：从列表里拿掉就是了。
            if clientError.isNotFound {
                devices.removeAll { $0.id == device.id }
                return true
            }
            actionError = clientError
            return false
        }
    }

    /// 下线其他设备；`stopAgents` 时顺带全部停止（怀疑账号被盗时）。成功后刷新列表，结果放进 `signOutOthersResult`。
    @discardableResult
    public func signOutOthers(stopAgents: Bool) async -> SignOutOthersResult? {
        guard !isSigningOutOthers else { return nil }
        isSigningOutOthers = true
        actionError = nil
        defer { isSigningOutOthers = false }
        do {
            let result = try await client.signOutOtherDevices(stopAgents: stopAgents)
            signOutOthersResult = result
            devices.removeAll { !$0.isCurrent }
            await load()
            return result
        } catch is CancellationError {
            return nil
        } catch {
            actionError = Self.clientError(error)
            return nil
        }
    }

    public func dismissActionError() {
        actionError = nil
    }

    public func dismissLastRevoked() {
        lastRevoked = nil
    }

    /// 本机在最前，其余保持服务端的顺序（最近活跃的在前）。
    nonisolated static func ordered(_ list: [DeviceInfo]) -> [DeviceInfo] {
        list.filter(\.isCurrent) + list.filter { !$0.isCurrent }
    }

    nonisolated static func clientError(_ error: any Error) -> ClientError {
        (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}

/// 全部停止（4.6，WBS 12.2）：取消所有运行、吊销全部运行授权、暂停全部计划。危险操作，界面先二次确认，做完显示数字。
@Observable @MainActor
public final class StopAllModel {
    public private(set) var isStopping = false
    /// 做完的结果（界面弹出“取消了几个运行、吊销几个授权、暂停几个计划”）。
    public var result: StopAllResult?
    public private(set) var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    /// 停。返回结果（失败时为 nil，错误在 `error`）。
    @discardableResult
    public func stopAll() async -> StopAllResult? {
        guard !isStopping else { return nil }
        isStopping = true
        error = nil
        defer { isStopping = false }
        do {
            let result = try await client.stopAll()
            self.result = result
            return result
        } catch is CancellationError {
            return nil
        } catch {
            self.error = DevicesModel.clientError(error)
            return nil
        }
    }

    public func dismissError() {
        error = nil
    }

    /// 确认框里的说明（停什么、不停什么）。
    public nonisolated static func confirmationMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "会取消所有正在跑和排队的任务、吊销 agent 的全部运行授权、暂停所有计划。实例和数据都保留，之后可以逐个恢复计划。"
            : "This cancels every running and queued task, revokes all of the agents' run grants and pauses every plan. "
                + "Instances and data are kept, and you can resume plans one by one later."
    }
}
