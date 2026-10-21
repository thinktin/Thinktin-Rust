import Foundation
import Testing

@testable import ThinktinKit

// ClientError → 界面怎么处理（docs/ios.md 第 6 节的表）。

private func api(_ code: APIErrorCode, status: Int = 400, retryAfter: Int? = nil) -> ClientError {
    .api(status: status, code: code, message: "dev message", retryAfterSecs: retryAfter)
}

@Suite("ClientError")
struct ClientErrorTests {
    @Test(
        "recovery：按第 6 节的表",
        arguments: [
            (ClientError.signedOut, ErrorRecovery.signIn),
            (api(.sessionRevoked, status: 401), .signIn),
            (.accountFrozen, .accountFrozen),
            (api(.accountFrozen, status: 403), .accountFrozen),
            (.upgradeRequired, .upgrade),
            (api(.upgradeRequired, status: 426), .upgrade),
            (api(.rateLimited, status: 429, retryAfter: 30), .retryLater(after: 30)),
            (api(.rateLimited, status: 429), .retryLater(after: nil)),
            (api(.unavailable, status: 503, retryAfter: 5), .retryLater(after: 5)),
            (api(.conflict, status: 409), .refreshAndRetry),
            (api(.invalid, status: 422), .showFormError),
            (.invalidArgument(message: "bad id"), .showFormError),
            (api(.notFound, status: 404), .goBack),
            (.network(message: "timed out"), .offline),
            (.containsSecrets(count: 2), .interceptSecrets(count: 2)),
            (.unsupported(feature: "listDevices"), .featureUnavailable),
            (api(.forbidden, status: 403), .generic),
            (api(.internal, status: 500), .generic),
            (api(.unknown("teapot"), status: 418), .generic),
            (.decode(message: "x"), .generic),
            (.cache(message: "x"), .generic),
            (.internal(message: "x"), .generic),
            (.malformed(message: "x"), .generic),
            (.expired, .generic),
            (.badSignature, .generic),
        ])
    func recovery(error: ClientError, expected: ErrorRecovery) {
        #expect(error.recovery == expected)
    }

    @Test("unsupported：11.7 落地前的方法")
    func unsupported() {
        let e = ClientError.unsupported(feature: "listDevices")
        #expect(e.recovery == .featureUnavailable)
        #expect(!e.isRetryable)
        #expect(e.apiCode == nil)
        #expect(e.debugDetails == "unsupported: listDevices")
        #expect(e.localizedMessage(.chinese) == "这个功能暂未开放，敬请期待。")
        #expect(e.localizedMessage(.english) == "This feature isn't available yet.")
        #expect(!e.localizedMessage(.english).contains("listDevices"), "功能名只给开发者看")
        #expect(e != .unsupported(feature: "deleteAccount"))
    }

    @Test("分类属性")
    func flags() {
        #expect(api(.sessionRevoked).requiresSignIn)
        #expect(!api(.unauthenticated).requiresSignIn, "访问令牌过期由 client-core 自己刷新")
        #expect(ClientError.accountFrozen.isAccountFrozen)
        #expect(api(.upgradeRequired).requiresUpgrade)
        #expect(ClientError.network(message: "").isRetryable)
        #expect(api(.rateLimited).isRetryable)
        #expect(api(.unavailable).isRetryable)
        #expect(api(.internal).isRetryable)
        #expect(!api(.conflict).isRetryable)
        #expect(!ClientError.signedOut.isRetryable)
        #expect(ClientError.network(message: "").isOffline)
        #expect(!api(.unavailable).isOffline)
        #expect(api(.notFound).isNotFound)
        #expect(api(.conflict).isConflict)
        #expect(api(.rateLimited).isRateLimited)
        #expect(api(.invalid).isInvalidInput)
        #expect(ClientError.invalidArgument(message: "").isInvalidInput)
        #expect(api(.rateLimited, retryAfter: 12).retryAfter == 12)
        #expect(api(.rateLimited).retryAfter == nil)
        #expect(ClientError.containsSecrets(count: 3).secretCount == 3)
        #expect(ClientError.signedOut.secretCount == nil)
    }

    @Test("给用户看的文案按错误码本地化，不用接口的英文 message")
    func localizedMessages() {
        let limited = api(.rateLimited, retryAfter: 30)
        #expect(limited.localizedMessage(.chinese) == "操作太频繁，请 30 秒后再试。")
        #expect(limited.localizedMessage(.english) == "Too many requests. Try again in 30 seconds.")
        #expect(api(.rateLimited).localizedMessage(.chinese) == "操作太频繁，请稍后再试。")
        #expect(api(.notFound).localizedMessage(.chinese) == "内容不存在或已被删除。")
        #expect(ClientError.containsSecrets(count: 2).localizedMessage(.chinese).contains("2 处"))
        let all: [ClientError] = [
            .network(message: "m"), .signedOut, .upgradeRequired, .accountFrozen, api(.forbidden), api(.conflict),
            api(.invalid), api(.unavailable), api(.unauthenticated), api(.internal), api(.unknown("x")),
            .decode(message: "m"), .cache(message: "m"), .containsSecrets(count: 1), .invalidArgument(message: "m"),
            .internal(message: "m"), .malformed(message: "m"), .expired, .badSignature, .unsupported(feature: "m"),
        ]
        for e in all {
            for language in DisplayLanguage.allCases {
                let text = e.localizedMessage(language)
                #expect(!text.isEmpty)
                #expect(!text.contains("dev message"), "\(e)")
            }
        }
    }

    @Test("开发者详情（“复制详情”）")
    func debugDetails() {
        #expect(
            api(.rateLimited, status: 429, retryAfter: 3).debugDetails
                == "api 429 rate_limited: dev message (retry after 3s)")
        #expect(api(.unknown("teapot"), status: 418).debugDetails == "api 418 teapot: dev message")
        #expect(ClientError.network(message: "dns").debugDetails == "network: dns")
        #expect(ClientError.containsSecrets(count: 2).debugDetails == "contains 2 secret(s)")
        let e: any Error = ClientError.signedOut
        #expect((e as? LocalizedError)?.failureReason == "signed out")
        #expect((e as? LocalizedError)?.errorDescription?.isEmpty == false)
    }
}
