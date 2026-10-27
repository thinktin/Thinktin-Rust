#if os(macOS) || os(Linux)
    import Foundation
    import ThinktinKit

    /// macOS App 的电脑端工具服务（Rust 的 `desktop`，经 UniFFI 是 `DesktopService`）接上 Kit 的 `ComputerHost`
    /// （WBS 14.5、14.6、14.8）：菜单栏的 `ComputerHostModel` 只认 `ComputerHost`。
    ///
    /// App 交进来的是系统那一侧的东西：访问令牌（`CoreClient.accessToken(refresh:)`）、系统工具
    /// （`ComputerNativeTools`：截图、键鼠、打开应用）、配对密钥（`ComputerPairingKey`：钥匙串里的）。
    /// 服务的状态变化在 Rust 的后台线程上回调，这里转成 `events`（`AsyncStream`，只有一个读者）。
    public final class DesktopServiceHost: ComputerHost, @unchecked Sendable {
        public let events: AsyncStream<ComputerHostEvent>
        private let service: DesktopCore.Service
        private let pairingKey: any ComputerPairingKey

        /// - Parameters:
        ///   - relayURL: 设备中继，比如 `wss://relay.thinktin.cn/v1/connect`。
        ///   - desktopID: 这台电脑的设备 id（登录时拿到的，`devices()` 里 `isCurrent` 的那台）。
        ///   - dataDirectory: 本地状态和审计日志放在这里（Application Support 下）。
        ///   - homeDirectory: 用户目录：命令默认在这里跑，删除的东西挪到它下面的 `.Trash`。
        ///   - accessToken: 这台电脑的访问令牌；参数为真时先换新的。
        public init(
            relayURL: String, desktopID: DeviceID, appVersion: String, dataDirectory: URL, homeDirectory: URL,
            accessToken: @escaping @Sendable (_ refresh: Bool) async throws -> String,
            native: any ComputerNativeTools, pairingKey: any ComputerPairingKey
        ) throws(ComputerHostError) {
            let (stream, continuation) = AsyncStream.makeStream(of: ComputerHostEvent.self)
            events = stream
            self.pairingKey = pairingKey
            do {
                service = try DesktopCore.Service(
                    settings: DesktopCore.Settings(
                        relayUrl: relayURL, desktopId: desktopID.rawValue, appVersion: appVersion,
                        dataDir: dataDirectory.path, homeDir: homeDirectory.path),
                    tokens: TokenBridge(accessToken), native: NativeBridge(native),
                    observer: ObserverBridge(continuation))
            } catch {
                throw Self.map(error)
            }
        }

        public func connection() -> HostConnection { Self.map(service.status()) }

        public func start() { service.start() }

        public func stop() { service.stop() }

        public func startPairing(ttl: TimeInterval) throws(ComputerHostError) -> String {
            do {
                return try service.startPairing(signer: SignerBridge(pairingKey), ttlSecs: UInt64(max(1, ttl)))
            } catch {
                throw Self.map(error)
            }
        }

        public func cancelPairing() { service.cancelPairing() }

        public func pairedPhone() -> HostPhone? {
            service.pairedPhone().map { HostPhone(deviceID: DeviceID($0.deviceId), publicKey: $0.publicKey) }
        }

        public func unpair() throws(ComputerHostError) {
            do {
                try service.unpair()
            } catch {
                throw Self.map(error)
            }
        }

        public func grants() -> [CapabilityGrant] { service.grants().map(Self.map) }

        // MARK: 转换

        static func map(_ status: DesktopCore.ConnectionStatus) -> HostConnection {
            switch status {
            case .offline: .offline
            case .connecting: .connecting
            case .connected: .connected
            }
        }

        static func map(_ state: DesktopCore.PairingState) -> HostPairing {
            switch state {
            case .idle: .idle
            case .waiting(let uri, let expiresAt):
                .waiting(uri: uri, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt)))
            case .paired(let phoneID): .paired(phoneID: DeviceID(phoneID))
            case .failed(let reason): .failed(reason: reason)
            }
        }

        static func map(_ reason: DesktopCore.StopReason) -> HostStopReason {
            switch reason {
            case .requested: .requested
            case .refused(let detail): .refused(detail)
            case .replaced: .replaced
            }
        }

        static func map(_ grant: DesktopCore.Grant) -> CapabilityGrant {
            CapabilityGrant(
                desktopID: DeviceID(grant.desktopId), tokenID: grant.tokenId, dirs: grant.dirs, apps: grant.apps,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(grant.expiresAt)))
        }

        static func map(_ error: any Error) -> ComputerHostError {
            switch error as? DesktopCore.FfiError {
            case .Pairing(let detail)?: .pairing(detail)
            case .State(let detail)?: .state(detail)
            case .Callback(let detail)?: .state(detail)
            case nil: .state(String(describing: error))
            }
        }
    }

    // MARK: 回调桥（Rust → Swift）

    private final class TokenBridge: DesktopCore.Tokens, @unchecked Sendable {
        private let get: @Sendable (Bool) async throws -> String

        init(_ get: @escaping @Sendable (Bool) async throws -> String) {
            self.get = get
        }

        func accessToken(refresh: Bool) async throws -> String {
            do {
                return try await get(refresh)
            } catch {
                throw DesktopCore.FfiError.Callback(detail: String(describing: error))
            }
        }
    }

    private final class NativeBridge: DesktopCore.NativeTools, @unchecked Sendable {
        private let tools: any ComputerNativeTools

        init(_ tools: any ComputerNativeTools) {
            self.tools = tools
        }

        func available() -> [String] { tools.available() }

        func frontmostApp() -> String? { tools.frontmostApp() }

        func call(tool: String, argumentsJson: String) async -> DesktopCore.NativeToolResult {
            let output = await tools.call(tool: tool, argumentsJSON: argumentsJson)
            return DesktopCore.NativeToolResult(contentJson: output.contentJSON, isError: output.isError)
        }
    }

    private final class SignerBridge: DesktopCore.Signer, @unchecked Sendable {
        private let key: any ComputerPairingKey

        init(_ key: any ComputerPairingKey) {
            self.key = key
        }

        func publicKey() -> Data {
            // 拿不到公钥时给空的：Rust 那边按“不是 P-256 公钥”拒绝出二维码，错误照样回到界面。
            (try? key.publicKey()) ?? Data()
        }

        func sign(message: Data) throws -> Data {
            do {
                return try key.sign(message)
            } catch {
                throw DesktopCore.FfiError.Callback(detail: "\(error)")
            }
        }
    }

    private final class ObserverBridge: DesktopCore.Observer, @unchecked Sendable {
        private let continuation: AsyncStream<ComputerHostEvent>.Continuation

        init(_ continuation: AsyncStream<ComputerHostEvent>.Continuation) {
            self.continuation = continuation
        }

        func onStatus(status: DesktopCore.ConnectionStatus) {
            continuation.yield(.connection(DesktopServiceHost.map(status)))
        }

        func onPairing(state: DesktopCore.PairingState) {
            continuation.yield(.pairing(DesktopServiceHost.map(state)))
        }

        func onStopped(reason: DesktopCore.StopReason) {
            continuation.yield(.stopped(DesktopServiceHost.map(reason)))
        }

        func onActivity(tool: String?) {
            continuation.yield(.activity(tool))
        }
    }
#endif
