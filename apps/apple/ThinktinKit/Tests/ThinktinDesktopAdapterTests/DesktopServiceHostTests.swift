#if os(macOS) || os(Linux)
    import Foundation
    import Testing
    import ThinktinCore
    import ThinktinKit

    @testable import ThinktinDesktopAdapter

    /// 拿不到令牌的服务（中继地址是关着的端口）：一直重连，直到 stop。
    private struct NoTokens: Error {}

    private struct Tools: ComputerNativeTools {
        func available() -> [String] { ["computer_screenshot"] }
        func frontmostApp() -> String? { "com.apple.Safari" }
        func call(tool: String, argumentsJSON: String) async -> NativeToolOutput { .text("ok") }
    }

    private struct BadKey: ComputerPairingKey {
        func publicKey() throws(ComputerHostError) -> Data { Data([1, 2, 3]) }
        func sign(_ message: Data) throws(ComputerHostError) -> Data { throw .pairing("no key") }
    }

    @Suite("macOS 的工具服务接上 ComputerHost（14.5）")
    struct DesktopServiceHostTests {
        private func makeHost() throws -> DesktopServiceHost {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try DesktopServiceHost(
                relayURL: "ws://127.0.0.1:9/v1/connect", desktopID: "0192f3a0-0000-7000-8000-0000000000aa",
                appVersion: "1.0", dataDirectory: dir, homeDirectory: dir,
                accessToken: { _ in throw NoTokens() }, native: Tools(), pairingKey: BadKey())
        }

        @Test("开始、停止：状态经事件流回来；没配对、没授权；坏的密钥出不了二维码")
        func lifecycle() async throws {
            let host = try makeHost()
            #expect(host.connection() == .offline)
            #expect(host.pairedPhone() == nil)
            #expect(host.grants().isEmpty)
            #expect(throws: ComputerHostError.self) { _ = try host.startPairing(ttl: 300) }
            do {
                _ = try host.startPairing(ttl: 300)
            } catch {
                guard case .pairing(let detail) = error else {
                    Issue.record("wrong error \(error)")
                    return
                }
                #expect(detail.contains("P-256"))
            }

            host.start()
            var iterator = host.events.makeAsyncIterator()
            var seen: [ComputerHostEvent] = []
            while let event = await iterator.next() {
                seen.append(event)
                if event == .connection(.connecting) { break }
            }
            host.stop()
            while let event = await iterator.next() {
                seen.append(event)
                if case .stopped = event { break }
            }
            #expect(seen.contains(.connection(.connecting)))
            #expect(seen.last == .stopped(.requested))
            try host.unpair()
        }

        @Test("菜单栏的视图模型跟着真的服务走")
        @MainActor
        func drivesTheModel() async throws {
            let host = try makeHost()
            let model = ComputerHostModel(host: host)
            let observing = Task { await model.observe() }
            model.start()
            for _ in 0..<200 where model.connection != .connecting {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(model.connection == .connecting)
            model.stop()
            for _ in 0..<200 where model.isEnabled || model.connection != .offline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(!model.isEnabled)
            #expect(model.stopReason == nil)
            model.startPairing()
            #expect(model.error != nil, "坏的密钥：界面上说出不了二维码")
            observing.cancel()
        }

        @Test("类型转换：令牌的到期时间、配对进度、停下的原因、错误")
        func conversions() {
            let grant = DesktopServiceHost.map(
                ThinktinCore.CapabilityGrant(
                    desktopId: "mac", tokenId: "t1", dirs: ["/Users/me"], apps: ["com.apple.Safari"],
                    expiresAt: 1_800_000_000))
            #expect(grant.desktopID == "mac")
            #expect(grant.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
            #expect(
                DesktopServiceHost.map(ThinktinCore.PairingState.waiting(uri: "thinktin-pair:v1?d=x", expiresAt: 100))
                    == .waiting(uri: "thinktin-pair:v1?d=x", expiresAt: Date(timeIntervalSince1970: 100)))
            #expect(DesktopServiceHost.map(ThinktinCore.PairingState.paired(phoneId: "p")) == .paired(phoneID: "p"))
            #expect(DesktopServiceHost.map(ThinktinCore.StopReason.refused(detail: "frozen")) == .refused("frozen"))
            #expect(DesktopServiceHost.map(DesktopFfiError.Pairing(detail: "x")) == .pairing("x"))
            #expect(DesktopServiceHost.map(NoTokens()) == .state("NoTokens()"))
        }
    }
#endif
