import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// ThinktinCore 的 `ClientError` / `PairingError` → ThinktinKit 的 `ClientError`：每个 case 都有对应。
/// （`init(core:)` 里的 switch 不带 default，Rust 加了新 case 时适配层编译不过，不会漏。）
@Suite("错误转换")
struct ErrorMappingTests {
    static let clientErrors: [ThinktinCore.ClientError] = [
        .Network(detail: "connection refused"),
        .SignedOut,
        .UpgradeRequired,
        .AccountFrozen,
        .Api(status: 429, code: "rate_limited", detail: "slow down", retryAfterSecs: 30),
        .Api(status: 404, code: "not_found", detail: "no such run", retryAfterSecs: nil),
        .Api(status: 418, code: "teapot", detail: "", retryAfterSecs: UInt64.max),
        .Decode(detail: "missing field `id`"),
        .Cache(detail: "database is locked"),
        .ContainsSecrets(count: 2),
        .InvalidArgument(detail: "bad run id \"x\""),
        .Internal(detail: "task panicked"),
    ]

    static let expectedClientErrors: [ThinktinKit.ClientError] = [
        .network(message: "connection refused"),
        .signedOut,
        .upgradeRequired,
        .accountFrozen,
        .api(status: 429, code: .rateLimited, message: "slow down", retryAfterSecs: 30),
        .api(status: 404, code: .notFound, message: "no such run", retryAfterSecs: nil),
        // 不认识的错误码保留原文；超出 Int 的秒数截断。
        .api(status: 418, code: .unknown("teapot"), message: "", retryAfterSecs: Int.max),
        .decode(message: "missing field `id`"),
        .cache(message: "database is locked"),
        .containsSecrets(count: 2),
        .invalidArgument(message: "bad run id \"x\""),
        .internal(message: "task panicked"),
    ]

    @Test("ThinktinCore.ClientError 的每个 case", arguments: zip(clientErrors, expectedClientErrors))
    func clientError(core: ThinktinCore.ClientError, expected: ThinktinKit.ClientError) {
        #expect(ThinktinKit.ClientError(core: core) == expected)
        // 经 `any Error` 也一样（CoreClient 里 catch 到的是 any Error）。
        #expect(ThinktinKit.ClientError(core as any Error) == expected)
    }

    @Test(
        "ThinktinCore.PairingError 的每个 case",
        arguments: zip(
            [ThinktinCore.PairingError.Malformed(detail: "bad base64"), .Expired, .BadSignature],
            [ThinktinKit.ClientError.malformed(message: "bad base64"), .expired, .badSignature]))
    func pairingError(core: ThinktinCore.PairingError, expected: ThinktinKit.ClientError) {
        #expect(ThinktinKit.ClientError(core: core) == expected)
        #expect(ThinktinKit.ClientError(core as any Error) == expected)
    }

    @Test("已经是 ThinktinKit 的错误原样返回；其他错误算 internal")
    func otherErrors() {
        let kit = ThinktinKit.ClientError.unsupported(feature: "listDevices")
        #expect(ThinktinKit.ClientError(kit as any Error) == kit)

        struct Weird: Error, CustomStringConvertible { var description: String { "weird thing" } }
        #expect(ThinktinKit.ClientError(Weird()) == .internal(message: "weird thing"))
    }

    @Test("转换后的错误按 docs/ios.md 第 6 节决定界面怎么处理")
    func recovery() {
        #expect(ThinktinKit.ClientError(core: .SignedOut).recovery == .signIn)
        #expect(ThinktinKit.ClientError(core: .AccountFrozen).recovery == .accountFrozen)
        #expect(ThinktinKit.ClientError(core: .UpgradeRequired).recovery == .upgrade)
        #expect(ThinktinKit.ClientError(core: .Network(detail: "")).recovery == .offline)
        #expect(ThinktinKit.ClientError(core: .ContainsSecrets(count: 3)).recovery == .interceptSecrets(count: 3))
        #expect(
            ThinktinKit.ClientError(core: .Api(status: 429, code: "rate_limited", detail: "", retryAfterSecs: 30))
                .recovery == .retryLater(after: 30))
        #expect(
            ThinktinKit.ClientError(core: .Api(status: 409, code: "conflict", detail: "", retryAfterSecs: nil))
                .recovery == .refreshAndRetry)
        #expect(
            ThinktinKit.ClientError(core: .Api(status: 401, code: "session_revoked", detail: "", retryAfterSecs: nil))
                .requiresSignIn)
    }
}
