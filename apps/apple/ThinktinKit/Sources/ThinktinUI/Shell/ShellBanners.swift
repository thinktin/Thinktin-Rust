import SwiftUI
import ThinktinKit

/// 事件流的连接横幅（docs/ios.md 第 5 节：connecting / reconnecting 在顶部显示细条）：一行小字，重连时倒数秒数。
struct ConnectionBanner: View {
    let state: ConnectionState

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            HStack(spacing: Metrics.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(state.message(language, now: context.date) ?? "")
                    .font(Typography.footnote.font.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.xs)
            .background(Theme.paperElevated)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: Metrics.hairline(scale: displayScale))
            }
            .accessibilityElement(children: .combine)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// 离线横幅：所有页面统一用它，文案按页面的离线策略（`OfflinePolicy.bannerMessage`）。右边“重试”。
struct OfflineBanner: View {
    let message: String
    let onRetry: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(StatusTone.waiting.color)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.Spacing.xs)
            Button(ErrorPresentation.title(of: .retry, language: language) ?? "", action: onRetry)
                .buttonStyle(.pill(.secondary, size: .compact))
        }
        .typography(.footnote)
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.xs)
        .background(Theme.paperElevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: Metrics.hairline(scale: displayScale))
        }
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#Preview("横幅 · 浅色中文") {
    VStack(spacing: 0) {
        ConnectionBanner(state: .connecting)
        ConnectionBanner(state: .reconnecting(retryAt: Date().addingTimeInterval(8)))
        OfflineBanner(message: OfflinePolicy.cached.bannerMessage(.chinese) ?? "") {}
        OfflineBanner(message: OfflinePolicy.unavailable.bannerMessage(.chinese) ?? "") {}
        Spacer()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .chinese)
}

#Preview("横幅 · 深色英文") {
    VStack(spacing: 0) {
        ConnectionBanner(state: .reconnecting(retryAt: Date().addingTimeInterval(3)))
        OfflineBanner(message: OfflinePolicy.cached.bannerMessage(.english) ?? "") {}
        Spacer()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
