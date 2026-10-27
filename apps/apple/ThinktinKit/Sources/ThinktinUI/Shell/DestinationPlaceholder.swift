import SwiftUI
import ThinktinKit

/// 还没做的页面的占位：衬线标题、“开发中”和负责的工作包。各功能的接入点在页面做好之前都显示它。
struct DestinationPlaceholder: View {
    let route: AppRoute
    /// 页面里的大标题（默认是页面标题；首页用问候语）。
    var heading: String?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        ScrollView {
            VStack(spacing: Metrics.Spacing.s) {
                Image(systemName: "hammer")
                    .font(Typography.title.font)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
                Text(heading ?? route.title(language))
                    .typography(.title)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(zh ? "开发中" : "In development")
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
                Text(verbatim: "WBS \(route.feature.workPackage)")
                    .typography(.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metrics.Spacing.xl)
            .padding(.vertical, Metrics.Spacing.xxxl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .navigationTitle(route.title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview("占位页 · 浅色中文") {
    DestinationPlaceholder(route: .plans).previewShell()
}

#Preview("占位页 · 深色英文") {
    DestinationPlaceholder(route: .usage).previewShell(.english, scheme: .dark)
}
