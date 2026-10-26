import Foundation
import Observation

/// Mac App 里电脑端工具服务跟着登录状态走（WBS 14.5、14.6）：
///
/// - 登录了才建服务（要这台电脑的设备 id 和访问令牌）；退出登录、账号冻结、要升级时停下、丢掉，菜单栏里说为什么用不了。
/// - 用户点开始 / 停止时按设备 id 记下来（`UserDefaults`）：下次开机（登录项拉起 App）、重新登录、解冻后照着开，
///   不用再点一次。每次登录是一台新设备（新的设备 id），之前的配对和授权不带过来，开关也从“关”开始。
@Observable @MainActor
public final class ComputerHostLifecycle {
    /// 现在的服务（没登录时是 nil）。
    public private(set) var model: ComputerHostModel?
    /// 建不起服务（本地状态目录读写不了）。
    public private(set) var error: ComputerHostError?

    @ObservationIgnored private let client: (any ClientProtocol)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeHost: @MainActor (DeviceID) throws(ComputerHostError) -> any ComputerHost
    @ObservationIgnored private var deviceID: DeviceID?
    @ObservationIgnored private var observing: Task<Void, Never>?

    /// - Parameters:
    ///   - client: 查配对的手机叫什么。
    ///   - makeHost: 给这台电脑（设备 id）建服务。
    public init(
        client: (any ClientProtocol)?, defaults: UserDefaults = .standard,
        makeHost: @escaping @MainActor (DeviceID) throws(ComputerHostError) -> any ComputerHost
    ) {
        self.client = client
        self.defaults = defaults
        self.makeHost = makeHost
    }

    static func enabledKey(_ deviceID: DeviceID) -> String { "computerHost.enabled.\(deviceID.rawValue)" }

    /// 用户上次让这台电脑的服务开着。
    public func wantsEnabled(_ deviceID: DeviceID) -> Bool {
        defaults.bool(forKey: Self.enabledKey(deviceID))
    }

    /// 登录状态变了（App 启动时也调一次）。`deviceID` 是这台电脑登录后的设备 id。
    public func update(signedIn: Bool, deviceID: DeviceID?) {
        guard signedIn, let deviceID else {
            close()
            return
        }
        guard deviceID != self.deviceID || model == nil else { return }
        close()
        let host: any ComputerHost
        do {
            host = try makeHost(deviceID)
        } catch {
            self.error = error
            return
        }
        error = nil
        let model = ComputerHostModel(host: host, client: client)
        model.onEnabledChange = { [defaults] enabled in
            defaults.set(enabled, forKey: Self.enabledKey(deviceID))
        }
        observing = Task { await model.observe() }
        self.model = model
        self.deviceID = deviceID
        if wantsEnabled(deviceID) { model.start() }
    }

    /// 跟着 `AppModel` 的登录状态走，直到任务取消（App 的整个生命周期）。`deviceID` 读这台电脑现在的设备 id
    /// （钥匙串里的会话）。
    public func follow(_ app: AppModel, deviceID: @escaping @MainActor () -> DeviceID?) async {
        while !Task.isCancelled {
            update(signedIn: app.phase == .signedIn, deviceID: app.phase == .signedIn ? deviceID() : nil)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = app.phase
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    private func close() {
        observing?.cancel()
        observing = nil
        model?.suspend()
        model = nil
        deviceID = nil
    }
}
