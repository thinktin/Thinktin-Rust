import Testing
import ThinktinKit

@testable import ThinktinUI

/// 错误横幅按 `ClientError` 分类（docs/ios.md 第 6 节）。
@Suite("错误横幅的分类")
struct ErrorPresentationTests {
    @Test("网络不通、限流、服务不可用：重试")
    func retryable() {
        let offline = ErrorPresentation(ClientError.network(message: "timed out"), language: .chinese)
        #expect(offline.recovery == .offline)
        #expect(offline.action == .retry)
        #expect(offline.tone == .waiting)

        let limited = ErrorPresentation(
            ClientError.api(status: 429, code: .rateLimited, message: "slow down", retryAfterSecs: 30),
            language: .chinese)
        #expect(limited.action == .retry)
        #expect(limited.message.contains("30"))

        let unavailable = ErrorPresentation(
            ClientError.api(status: 503, code: .unavailable, message: "", retryAfterSecs: nil), language: .english)
        #expect(unavailable.action == .retry)
    }

    @Test("冲突：刷新")
    func conflict() {
        let p = ErrorPresentation(
            ClientError.api(status: 409, code: .conflict, message: "revision", retryAfterSecs: nil), language: .chinese)
        #expect(p.recovery == .refreshAndRetry)
        #expect(p.action == .refresh)
    }

    @Test("整页处理的错误和表单错误：不给按钮")
    func noAction() {
        let errors: [ClientError] = [
            .signedOut, .accountFrozen, .upgradeRequired, .containsSecrets(count: 2),
            .invalidArgument(message: "id"), .unsupported(feature: "listDevices"),
            .api(status: 404, code: .notFound, message: "", retryAfterSecs: nil),
            .api(status: 401, code: .sessionRevoked, message: "", retryAfterSecs: nil),
        ]
        for error in errors {
            #expect(ErrorPresentation(error, language: .chinese).action == .none, "\(error)")
        }
        #expect(ErrorPresentation(ClientError.unsupported(feature: "x")).tone == .muted)
        #expect(ErrorPresentation(ClientError.signedOut).recovery == .signIn)
    }

    @Test("其他错误：复制详情，详情是英文原文")
    func generic() {
        let p = ErrorPresentation(ClientError.internal(message: "boom"), language: .chinese)
        #expect(p.recovery == .generic)
        #expect(p.action == .copyDetails)
        #expect(p.tone == .failure)
        #expect(p.details == "internal: boom")
        #expect(p.message == ClientError.internal(message: "boom").localizedMessage(.chinese))
    }

    @Test("不是 ClientError 的错误按内部错误显示")
    func foreignError() {
        struct Oops: Error {}
        let p = ErrorPresentation(Oops() as any Error, language: .english)
        #expect(p.recovery == .generic)
        #expect(p.action == .copyDetails)
    }

    @Test("按钮文字", arguments: DisplayLanguage.allCases)
    func titles(_ language: DisplayLanguage) {
        for action in [ErrorPresentation.Action.retry, .refresh, .copyDetails] {
            #expect(ErrorPresentation.title(of: action, language: language)?.isEmpty == false)
        }
        #expect(ErrorPresentation.title(of: .none, language: language) == nil)
        #expect(ErrorPresentation.title(of: .retry, language: .chinese) == "重试")
        #expect(!ErrorPresentation.copiedTitle(language: language).isEmpty)
    }
}
