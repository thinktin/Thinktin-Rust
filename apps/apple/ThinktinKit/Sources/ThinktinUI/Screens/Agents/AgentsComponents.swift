import SwiftUI
import ThinktinKit

// Agent 目录、详情、领养、实例详情（WBS 12.3）共用的小组件。名字都带 Agents / Agent 前缀，不和别的功能重名。

/// agent、实例的头像：名字的第一个字放在圆里。不用 agent 的标志和图标（docs/licenses.md 第 6 节的商标要求）。
/// 是装饰，读屏跳过（名字就在旁边）。
struct AgentMonogram: View {
    let text: String
    /// 字的样式（衬线标题）；圆的直径跟着同一个字号缩放。
    let style: Typography
    /// 直径，跟着动态字体缩放。
    @ScaledMetric private var size: CGFloat

    @Environment(\.displayScale) private var displayScale

    init(_ text: String, style: Typography = .title3, size: CGFloat = 40) {
        self.text = text
        self.style = style
        _size = ScaledMetric(wrappedValue: size, relativeTo: style.textStyle)
    }

    var body: some View {
        Text(verbatim: text)
            .typography(style)
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.userBubble, in: Circle())
            .overlay {
                Circle().strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
            }
            .accessibilityHidden(true)
    }
}

/// 分组的小标题（读屏当标题）。
struct AgentsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Metrics.Spacing.xs)
            .padding(.top, Metrics.Spacing.s)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 一组行：卡片底色、圆角 16、一像素描边（行之间用 `Divider()` 隔开）。
struct AgentsGroup<Content: View>: View {
    private let content: Content

    @Environment(\.displayScale) private var displayScale

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperElevated, in: shape)
        .overlay {
            shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
        }
    }
}

/// 组里的一行：图标、标题、说明，右边可以有箭头。给了 `action` 时整行是按钮（读屏合成一句、带按钮特征）。
struct AgentsRow<Accessory: View>: View {
    let systemImage: String?
    let title: String
    var detail: String?
    /// 说明文字的色调（要提醒用户时用 `.waiting`）；nil 用次要文字色。
    var detailTone: StatusTone?
    var showsChevron: Bool
    var action: (@MainActor () -> Void)?
    private let accessory: Accessory

    init(
        systemImage: String? = nil, title: String, detail: String? = nil, detailTone: StatusTone? = nil,
        showsChevron: Bool = true, action: (@MainActor () -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.detailTone = detailTone
        self.showsChevron = showsChevron
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minWidth: Metrics.Spacing.xl)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(title)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .typography(.subheadline)
                        .foregroundStyle(detailTone?.color ?? Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            Spacer(minLength: Metrics.Spacing.xs)
            if showsChevron && action != nil {
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(minHeight: Metrics.minTapTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 小标签（版本、许可证、“默认”“最新”“正在使用”）：一个点宽的胶囊描边。不是状态，不用状态色。
struct AgentsTag: View {
    let text: String

    var body: some View {
        Text(text)
            .typography(.caption)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .padding(.horizontal, Metrics.Spacing.xs)
            .padding(.vertical, Metrics.Spacing.unit / 2)
            .overlay {
                Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
            }
    }
}

/// 几个小标签排一行；字号很大时改成一列，免得挤出屏幕。
struct AgentsTagRow<Content: View>: View {
    private let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) { content }
        } else {
            HStack(spacing: Metrics.Spacing.xs) { content }
        }
    }
}

/// 页面的大标题（衬线）和一句说明。
struct AgentsPageHeader: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Text(title)
                .typography(.title)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Metrics.Spacing.xs)
        .padding(.bottom, Metrics.Spacing.xs)
    }
}

/// 加载中：一个转圈加一句话（第一次拉、还没有可显示的时候）。
struct AgentsLoadingView: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            ProgressView()
            Text(language == .chinese ? "正在加载…" : "Loading…")
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 页面内容的统一版式：页边距 16、最大可读宽度居中、纸张底色。
    func agentsPageLayout() -> some View {
        padding(Metrics.Spacing.m)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
    }

    /// 页面顶部的行内标题（导航栏标题，iOS 上用小标题样式）。
    func agentsNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
            navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
            navigationTitle(title)
        #endif
    }
}

/// 离线、出错时页面上显示的错误：网络不通由应用框架的离线横幅说明，这里不重复。
func agentsVisibleError(_ error: ClientError?) -> ClientError? {
    guard let error, !error.isOffline else { return nil }
    return error
}
