import Foundation
import ThinktinKit

/// 一个 `ClientError` 在横幅里怎么显示：图标、色调、文案、给什么按钮（docs/ios.md 第 6 节的表，按
/// `ClientError.recovery` 分类）。只依赖 Foundation，`ErrorBanner` 用它画界面。
///
/// 需要整页处理的错误（回登录页、冻结页、升级页、密码拦截弹层）由上层的导航接管，横幅里只给一句说明、不给按钮。
public struct ErrorPresentation: Hashable, Sendable {
    /// 横幅上的按钮。
    public enum Action: Hashable, Sendable {
        /// “重试”：网络不通、限流、服务暂时不可用。
        case retry
        /// “刷新”：内容被别人改了（`conflict`），刷新后再操作。
        case refresh
        /// “复制详情”：其他错误，把给开发者看的详情放进剪贴板，方便反馈。
        case copyDetails
        /// 不给按钮。
        case none
    }

    /// 界面该怎么处理（来自 `ClientError.recovery`）。
    public var recovery: ErrorRecovery
    /// SF Symbol 的名字。
    public var systemImage: String
    /// 图标的色调。
    public var tone: StatusTone
    /// 给用户看的文案（按错误码本地化，`ClientError.localizedMessage(_:)`）。
    public var message: String
    public var action: Action
    /// 给开发者看的详情（“复制详情”）：英文原文，不含用户数据。
    public var details: String

    public init(_ error: ClientError, language: DisplayLanguage = .current) {
        recovery = error.recovery
        message = error.localizedMessage(language)
        details = error.debugDetails
        switch recovery {
        case .offline:
            (systemImage, tone, action) = ("wifi.slash", .waiting, .retry)
        case .retryLater:
            (systemImage, tone, action) = ("clock.arrow.circlepath", .waiting, .retry)
        case .refreshAndRetry:
            (systemImage, tone, action) = ("arrow.triangle.2.circlepath", .waiting, .refresh)
        case .showFormError:
            (systemImage, tone, action) = ("exclamationmark.circle", .failure, .none)
        case .goBack:
            (systemImage, tone, action) = ("questionmark.circle", .neutral, .none)
        case .limitReached:
            // 数量到了上限：原样重试没用，不给按钮，文案里说先删掉一些。
            (systemImage, tone, action) = ("gauge.with.dots.needle.100percent", .waiting, .none)
        case .signIn:
            (systemImage, tone, action) = ("person.crop.circle.badge.exclamationmark", .failure, .none)
        case .accountFrozen:
            (systemImage, tone, action) = ("snowflake", .failure, .none)
        case .upgrade:
            (systemImage, tone, action) = ("arrow.up.circle", .waiting, .none)
        case .interceptSecrets:
            (systemImage, tone, action) = ("key", .waiting, .none)
        case .featureUnavailable:
            (systemImage, tone, action) = ("hourglass", .muted, .none)
        case .generic:
            (systemImage, tone, action) = ("exclamationmark.triangle", .failure, .copyDetails)
        }
    }

    /// 不是 `ClientError` 的错误（理论上到不了界面）按 client-core 内部错误处理。
    public init(_ error: any Error, language: DisplayLanguage = .current) {
        if let clientError = error as? ClientError {
            self.init(clientError, language: language)
        } else {
            self.init(ClientError.internal(message: String(describing: error)), language: language)
        }
    }

    /// 按钮的文字；`none` 没有按钮。
    public static func title(of action: Action, language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch action {
        case .retry: return zh ? "重试" : "Retry"
        case .refresh: return zh ? "刷新" : "Refresh"
        case .copyDetails: return zh ? "复制详情" : "Copy details"
        case .none: return nil
        }
    }

    /// 复制详情之后按钮上的文字。
    public static func copiedTitle(language: DisplayLanguage = .current) -> String {
        language == .chinese ? "已复制" : "Copied"
    }
}
