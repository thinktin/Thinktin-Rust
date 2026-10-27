import Foundation
import Observation

/// Mac 菜单栏里的“手机控制”（WBS 14.5、14.6、14.8）：连接状态、开始 / 停止、配对二维码、配对的手机、手机给的授权、解除配对。
///
/// - 状态跟着服务的事件变（`observe()`，界面出现时跑）；配对二维码在等手机扫的时候显示，过期了自己换成“过期了，再出一个”。
/// - 手机配好后（`paired`）记下手机，从设备列表里查它的名字（查不到就显示“手机”）。
/// - 服务被中继拒绝（账号冻结）、在别处又连了一次时停下，告诉用户为什么，不自动重启。
@Observable @MainActor
public final class ComputerHostModel {
    public private(set) var connection: HostConnection
    public private(set) var pairing: HostPairing = .idle
    public private(set) var phone: HostPhone?
    /// 配对的手机在设备列表里的名字。
    public private(set) var phoneName: String?
    public private(set) var grants: [CapabilityGrant] = []
    /// 服务停下的原因（用户自己停的不算）。
    public private(set) var stopReason: HostStopReason?
    /// agent 正在这台电脑上执行的工具（菜单栏的“正在被控制”，14.6）；没有在执行时是 nil。
    public private(set) var activeTool: String?
    /// 用户想让它连着（点了开始，没点停止）。
    public private(set) var isEnabled = false
    public var error: ComputerHostError?

    @ObservationIgnored private let host: any ComputerHost
    @ObservationIgnored private let client: (any ClientProtocol)?
    @ObservationIgnored private let now: () -> Date
    /// 用户点了开始 / 停止（`ComputerHostLifecycle` 记下来，下次登录、开机时照着开）。
    @ObservationIgnored public var onEnabledChange: (@MainActor (Bool) -> Void)?

    /// 配对二维码的有效期（client-core 最长 10 分钟）。
    public static let pairingTTL: TimeInterval = 5 * 60

    public init(host: any ComputerHost, client: (any ClientProtocol)? = nil, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.client = client
        self.now = now
        connection = host.connection()
        refresh()
    }

    // MARK: 读

    /// 配好了手机、连着中继：手机能控制这台电脑（菜单栏图标亮起来）。
    public var isControllable: Bool { connection == .connected && phone != nil }

    /// 二维码还在有效期里。
    public var pairingCode: String? {
        guard case .waiting(let uri, let expiresAt) = pairing, expiresAt > now() else { return nil }
        return uri
    }

    /// 二维码过期了（服务不会自己说，按时间算）。
    public var pairingExpired: Bool {
        guard case .waiting(_, let expiresAt) = pairing else { return false }
        return expiresAt <= now()
    }

    /// 还有效的授权，快到期的在前。
    public var activeGrants: [CapabilityGrant] {
        let now = self.now()
        return grants.filter { $0.expiresAt > now }.sorted { $0.expiresAt < $1.expiresAt }
    }

    // MARK: 事件

    /// 跟着服务的事件更新（界面的 `.task` 里跑，界面消失时取消）。
    public func observe() async {
        for await event in host.events {
            await apply(event)
        }
    }

    func apply(_ event: ComputerHostEvent) async {
        switch event {
        case .connection(let c):
            connection = c
            if c == .connected { stopReason = nil } else { activeTool = nil }
        case .pairing(let p):
            pairing = p
            if case .paired = p {
                refresh()
                await loadPhoneName()
            }
        case .stopped(let reason):
            connection = .offline
            isEnabled = false
            activeTool = nil
            stopReason = reason == .requested ? nil : reason
        case .activity(let tool):
            activeTool = tool
        }
    }

    /// 重新读配对的手机和授权（手机发来了新授权、吊销了，服务不发事件，界面出现、定时刷新时调）。
    public func refresh() {
        phone = host.pairedPhone()
        grants = host.grants()
        if phone == nil { phoneName = nil }
    }

    /// 从设备列表里查配对的手机叫什么（没联网、查不到时不显示名字）。
    public func loadPhoneName() async {
        guard let phone, let client else { return }
        phoneName = (try? await client.devices())?.first { $0.id == phone.deviceID }?.name
    }

    // MARK: 操作

    public func start() {
        isEnabled = true
        stopReason = nil
        host.start()
        onEnabledChange?(true)
    }

    public func stop() {
        isEnabled = false
        host.stop()
        onEnabledChange?(false)
    }

    /// 退出登录、账号冻结时停下：不算用户点了停止（不改记下的开关）。
    public func suspend() {
        isEnabled = false
        activeTool = nil
        host.stop()
    }

    /// 出一个新的配对二维码（之前的作废）。
    public func startPairing() {
        error = nil
        do {
            let uri = try host.startPairing(ttl: Self.pairingTTL)
            pairing = .waiting(uri: uri, expiresAt: now().addingTimeInterval(Self.pairingTTL))
        } catch {
            self.error = error
        }
    }

    public func cancelPairing() {
        host.cancelPairing()
        pairing = .idle
    }

    /// 解除配对：之后手机控制不了这台电脑（手机那边也要解除）。
    public func unpair() {
        error = nil
        do {
            try host.unpair()
        } catch {
            self.error = error
        }
        refresh()
        if case .paired = pairing { pairing = .idle }
    }
}
