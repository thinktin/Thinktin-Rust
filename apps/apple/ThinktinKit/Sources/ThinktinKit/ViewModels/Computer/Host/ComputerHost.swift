import Foundation

// 电脑这一侧（macOS App，WBS 14.5、14.6、14.8）：后台进程里的工具服务（Rust 的 `desktop`，经 UniFFI 是 `DesktopService`）。
// Kit 只认 `ComputerHost` 协议，App 用 ThinktinCore 里的 `DesktopService` 接上；预览、测试用 `FakeComputerHost`。

/// 和中继的连接。
public enum HostConnection: Hashable, Sendable {
    case offline
    case connecting
    case connected
}

/// 配对进行到哪了。
public enum HostPairing: Hashable, Sendable {
    case idle
    /// 二维码在显示：内容（`thinktin-pair:v1?…`）、过期时间。
    case waiting(uri: String, expiresAt: Date)
    case paired(phoneID: DeviceID)
    /// 手机的回复验不过，或者邀请过期了：要重新出二维码。
    case failed(reason: String)
}

/// 服务为什么停了。
public enum HostStopReason: Hashable, Sendable {
    /// 用户点了停止（或者退出登录）。
    case requested
    /// 中继拒绝了这台电脑（账号被冻结，或者这台设备不是电脑）。
    case refused(String)
    /// 这台电脑在别处又连了一次（开了两个 App？）。
    case replaced
}

/// 服务发出来的变化（后台线程上产生，经 `AsyncStream` 交给界面）。
public enum ComputerHostEvent: Hashable, Sendable {
    case connection(HostConnection)
    case pairing(HostPairing)
    case stopped(HostStopReason)
    /// 正在执行的工具（`computer_*` 的全名）；都结束了是 nil。等手机批准的不算。
    case activity(String?)
}

/// 配对的手机。
public struct HostPhone: Hashable, Sendable {
    public var deviceID: DeviceID
    /// 手机的公钥（SEC1，base64url）。
    public var publicKey: String

    public init(deviceID: DeviceID, publicKey: String) {
        self.deviceID = deviceID
        self.publicKey = publicKey
    }
}

public enum ComputerHostError: Error, Hashable, Sendable {
    /// 出不了配对二维码（钥匙串里的密钥不对）。
    case pairing(String)
    /// 本地状态读写不了。
    case state(String)
}

/// 系统工具的结果：MCP 的 content 数组（JSON 文本）；工具自己出错时 `isError` 为真。
public struct NativeToolOutput: Hashable, Sendable {
    public var contentJSON: String
    public var isError: Bool

    public init(contentJSON: String, isError: Bool = false) {
        self.contentJSON = contentJSON
        self.isError = isError
    }

    /// 一段文字（`[{"type":"text","text":…}]`）。
    public static func text(_ text: String, isError: Bool = false) -> NativeToolOutput {
        let item: [String: String] = ["type": "text", "text": text]
        let data = (try? JSONSerialization.data(withJSONObject: [item])) ?? Data("[]".utf8)
        return NativeToolOutput(contentJSON: String(decoding: data, as: UTF8.self), isError: isError)
    }

    /// 一张图（`[{"type":"image","data":<base64>,"mimeType":…}]`）。
    public static func image(_ data: Data, mimeType: String) -> NativeToolOutput {
        let item: [String: String] = ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
        let json = (try? JSONSerialization.data(withJSONObject: [item])) ?? Data("[]".utf8)
        return NativeToolOutput(contentJSON: String(decoding: json, as: UTF8.self))
    }
}

/// 要用 macOS 系统接口的工具（14.3、14.4）：截图、键鼠、打开应用和网页。文件和命令由 Rust 的工具服务做。
/// 权限（手机给的授权、前台应用）在调用之前已经核对过；这里只管做。
public protocol ComputerNativeTools: Sendable {
    /// 现在能用的（`computer_*` 的全名，随系统权限变化：没给屏幕录制权限就没有截图）。
    func available() -> [String]
    /// 前台应用的 bundle id。
    func frontmostApp() -> String?
    /// `argumentsJSON` 是工具参数（JSON 对象）。
    func call(tool: String, argumentsJSON: String) async -> NativeToolOutput
}

/// 电脑的配对密钥（P-256，钥匙串 / Secure Enclave 里，14.8）。
public protocol ComputerPairingKey: Sendable {
    /// 公钥（SEC1）。
    func publicKey() throws(ComputerHostError) -> Data
    /// ECDSA P-256 + SHA-256 签名，DER 或 r‖s。
    func sign(_ message: Data) throws(ComputerHostError) -> Data
}

/// 电脑端的工具服务。
public protocol ComputerHost: AnyObject, Sendable {
    /// 状态、配对进度、停下的原因。只有一个读者（`ComputerHostModel`）。
    var events: AsyncStream<ComputerHostEvent> { get }
    func connection() -> HostConnection
    /// 连中继（一直连着，断了重连）。已经在跑时什么都不做。
    func start()
    /// 断开、不再重连。
    func stop()
    /// 出配对二维码（`thinktin-pair:v1?…`）；之前的作废。
    func startPairing(ttl: TimeInterval) throws(ComputerHostError) -> String
    func cancelPairing()
    func pairedPhone() -> HostPhone?
    func unpair() throws(ComputerHostError)
    /// 手机签发、现在还有效的能力令牌。
    func grants() -> [CapabilityGrant]
}

/// 预览、测试用：不联网，按调用改状态、发事件。
public final class FakeComputerHost: ComputerHost, @unchecked Sendable {
    private struct State {
        var connection: HostConnection = .offline
        var phone: HostPhone?
        var grants: [CapabilityGrant] = []
        var pairingCount = 0
        var failPairing: ComputerHostError?
    }

    private let state: Locked<State>
    private let continuation: AsyncStream<ComputerHostEvent>.Continuation
    public let events: AsyncStream<ComputerHostEvent>

    public init(phone: HostPhone? = nil, grants: [CapabilityGrant] = []) {
        state = Locked(State(phone: phone, grants: grants))
        (events, continuation) = AsyncStream.makeStream(of: ComputerHostEvent.self)
    }

    /// 下一次 `startPairing` 抛这个错。
    public func failNextPairing(_ error: ComputerHostError) {
        state.withLock { $0.failPairing = error }
    }

    /// 像服务那样发一个事件（测试里模拟连上、手机扫码配好、被顶掉）。
    public func send(_ event: ComputerHostEvent) {
        state.withLock { s in
            switch event {
            case .connection(let c): s.connection = c
            case .pairing(.paired(let phoneID)):
                s.phone = HostPhone(deviceID: phoneID, publicKey: "phone-key")
                s.grants = []
            case .stopped: s.connection = .offline
            case .pairing, .activity: break
            }
        }
        continuation.yield(event)
    }

    public func setGrants(_ grants: [CapabilityGrant]) {
        state.withLock { $0.grants = grants }
    }

    public var pairingCount: Int { state.withLock { $0.pairingCount } }

    public func connection() -> HostConnection { state.withLock { $0.connection } }

    public func start() {
        guard connection() == .offline else { return }
        send(.connection(.connecting))
    }

    public func stop() {
        send(.connection(.offline))
        send(.stopped(.requested))
    }

    public func startPairing(ttl: TimeInterval) throws(ComputerHostError) -> String {
        let failure = state.withLock { s -> ComputerHostError? in
            defer { s.failPairing = nil }
            if s.failPairing == nil { s.pairingCount += 1 }
            return s.failPairing
        }
        if let failure { throw failure }
        let uri = "thinktin-pair:v1?d=mac&k=key&n=nonce-\(pairingCount)&e=\(Int(Date().timeIntervalSince1970 + ttl))"
        continuation.yield(.pairing(.waiting(uri: uri, expiresAt: Date().addingTimeInterval(ttl))))
        return uri
    }

    public func cancelPairing() {
        continuation.yield(.pairing(.idle))
    }

    public func pairedPhone() -> HostPhone? { state.withLock { $0.phone } }

    public func unpair() throws(ComputerHostError) {
        state.withLock { s in
            s.phone = nil
            s.grants = []
        }
    }

    public func grants() -> [CapabilityGrant] { state.withLock { $0.grants } }
}
