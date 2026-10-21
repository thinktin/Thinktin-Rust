import SwiftUI
import ThinktinKit

/// 行内的错误横幅：按 `ClientError` 的分类（`ErrorPresentation`）显示图标、文案和按钮——网络不通、限流给“重试”，
/// 冲突给“刷新”，其他错误给“复制详情”；回登录页、冻结、升级这类整页处理的错误只给一句说明。
///
/// “重试”“刷新”只在传了 `onRetry` 时显示；传了 `onDismiss` 时右边有关闭按钮。
public struct ErrorBanner: View {
    private let error: ClientError
    private let onRetry: (@MainActor () -> Void)?
    private let onDismiss: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale
    @State private var copied = false

    /// - Parameters:
    ///   - onRetry: 点“重试” / “刷新”时调用。
    ///   - onDismiss: 点关闭按钮时调用。
    public init(
        _ error: ClientError, onRetry: (@MainActor () -> Void)? = nil, onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.error = error
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    /// 任意错误（不是 `ClientError` 的按内部错误显示）。
    public init(
        error: any Error, onRetry: (@MainActor () -> Void)? = nil, onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            (error as? ClientError) ?? .internal(message: String(describing: error)), onRetry: onRetry,
            onDismiss: onDismiss)
    }

    public var body: some View {
        let presentation = ErrorPresentation(error, language: language)
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            Image(systemName: presentation.systemImage)
                .typography(.body)
                .foregroundStyle(presentation.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                Text(presentation.message)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton(presentation)
            }
            // 有关闭按钮时给它让出右上角。
            Spacer(minLength: onDismiss == nil ? 0 : Metrics.minTapTarget - Metrics.Spacing.m)
        }
        .padding(Metrics.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperElevated, in: shape)
        .overlay {
            shape.strokeBorder(presentation.tone.color.opacity(0.4), lineWidth: Metrics.hairline(scale: displayScale))
        }
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Typography.footnote.font.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(language == .chinese ? "关闭" : "Dismiss"))
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: error) { copied = false }
    }

    @ViewBuilder
    private func actionButton(_ presentation: ErrorPresentation) -> some View {
        switch presentation.action {
        case .retry, .refresh:
            if let onRetry, let title = ErrorPresentation.title(of: presentation.action, language: language) {
                let icon = presentation.action == .retry ? "arrow.clockwise" : "arrow.triangle.2.circlepath"
                PillButton(title, systemImage: icon, kind: .secondary, size: .compact, action: onRetry)
            }
        case .copyDetails:
            PillButton(
                copied
                    ? ErrorPresentation.copiedTitle(language: language)
                    : ErrorPresentation.title(of: .copyDetails, language: language) ?? "",
                systemImage: copied ? "checkmark" : "doc.on.doc", kind: .secondary, size: .compact
            ) {
                Pasteboard.copy(presentation.details)
                copied = true
            }
        case .none:
            EmptyView()
        }
    }
}

#Preview("错误横幅") {
    ScrollView {
        VStack(spacing: Metrics.Spacing.s) {
            ErrorBanner(.network(message: "timed out"), onRetry: {}, onDismiss: {})
            ErrorBanner(
                .api(status: 429, code: .rateLimited, message: "slow down", retryAfterSecs: 30), onRetry: {})
            ErrorBanner(
                .api(status: 409, code: .conflict, message: "revision mismatch", retryAfterSecs: nil), onRetry: {})
            ErrorBanner(.api(status: 422, code: .invalid, message: "bad name", retryAfterSecs: nil))
            ErrorBanner(.unsupported(feature: "listDevices"))
            ErrorBanner(.internal(message: "boom"), onDismiss: {})
        }
        .padding()
    }
    .background(Theme.paper)
}

#Preview("错误横幅 · 深色、英文") {
    VStack(spacing: Metrics.Spacing.s) {
        ErrorBanner(.network(message: "timed out"), onRetry: {})
        ErrorBanner(.decode(message: "missing field"))
    }
    .padding()
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
