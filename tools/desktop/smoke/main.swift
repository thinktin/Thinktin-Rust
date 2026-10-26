// `desktop` 的 UniFFI 接口在 Swift 里的冒烟测试（tools/desktop/swift-smoke.sh 编、跑）：Swift 实现令牌、系统工具、
// 观察者、配对密钥，Rust 的服务回调它们；错误两个方向都能过；开始、停止、状态回调都对。中继地址是关着的端口，
// 拿令牌也会失败：服务一直重连，直到 stop。
import Foundation
import ThinktinCore

final class Tokens: DesktopTokens, @unchecked Sendable {
    func accessToken(refresh: Bool) async throws -> String { throw DesktopFfiError.Callback(detail: "signed out") }
}
final class Native: NativeTools, @unchecked Sendable {
    func available() -> [String] { ["computer_screenshot"] }
    func frontmostApp() -> String? { "com.apple.Safari" }
    func call(tool: String, argumentsJson: String) async -> NativeToolResult {
        NativeToolResult(contentJson: "[]", isError: false)
    }
}
final class Observer: DesktopObserver, @unchecked Sendable {
    let lock = NSLock()
    var events: [String] = []
    func onStatus(status: ConnectionStatus) { lock.withLock { events.append("status \(status)") } }
    func onPairing(state: PairingState) { lock.withLock { events.append("pairing \(state)") } }
    func onStopped(reason: StopReason) { lock.withLock { events.append("stopped \(reason)") } }
    var snapshot: [String] { lock.withLock { events } }
}
final class BadKey: PairingSigner, @unchecked Sendable {
    func publicKey() -> Data { Data([1, 2, 3]) }
    func sign(message: Data) throws -> Data { throw DesktopFfiError.Callback(detail: "no key") }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let observer = Observer()
let service = try DesktopService(
    settings: DesktopSettings(
        relayUrl: "ws://127.0.0.1:9/v1/connect", desktopId: "0192f3a0-0000-7000-8000-0000000000aa", appVersion: "1.0",
        dataDir: dir.path, homeDir: dir.path),
    tokens: Tokens(), native: Native(), observer: observer)
precondition(service.status() == .offline)
precondition(service.pairedPhone() == nil)
precondition(service.grants().isEmpty)
do {
    _ = try service.startPairing(signer: BadKey(), ttlSecs: 300)
    preconditionFailure("a bad key cannot make a pairing code")
} catch DesktopFfiError.Pairing(let detail) {
    print("pairing refused: \(detail)")
}
service.start()
Thread.sleep(forTimeInterval: 1.5)
service.stop()
Thread.sleep(forTimeInterval: 1.5)
let events = observer.snapshot
print(events)
precondition(events.contains("status connecting"), "\(events)")
precondition(events.contains("stopped requested"), "\(events)")
print("ok")
