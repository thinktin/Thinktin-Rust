import SwiftUI
import ThinktinKit

// 各页面共用的列表版式（最早随 12.3 的 agent 目录做的）：分组小标题、卡片分组、行、标签、单选行、提示、页面标题、
// 加载中、页面版式。

/// 分组的小标题（读屏当标题）。
struct SectionHeader: View {
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
struct GroupedSection<Content: View>: View {
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
struct ListRow<Accessory: View>: View {
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
struct TagChip: View {
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
struct TagChipRow<Content: View>: View {
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

/// 单选的一行：左边圆圈（选中时实心对勾），标题、说明、标签。
struct ChoiceRow: View {
    let title: String
    var detail: String?
    var tag: String?
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(title)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                        if let tag { TagChip(text: tag) }
                    }
                    if let detail {
                        Text(detail)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 页面里的一条提示：图标（按语气上色）加一段话，浅底圆角。
struct InlineNotice: View {
    let systemImage: String
    let tone: StatusTone
    let text: String

    var body: some View {
        Label {
            Text(text)
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
        }
        .padding(Metrics.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperElevated, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 页面的大标题（衬线）和一句说明。
struct PageHeader: View {
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
struct LoadingStateView: View {
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
    func pageLayout() -> some View {
        padding(Metrics.Spacing.m)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
    }

    /// 页面顶部的行内标题（导航栏标题，iOS 上用小标题样式）。
    func inlineNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
            navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
            navigationTitle(title)
        #endif
    }
}

/// 离线、出错时页面上显示的错误：网络不通由应用框架的离线横幅说明，这里不重复。
func visibleError(_ error: ClientError?) -> ClientError? {
    guard let error, !error.isOffline else { return nil }
    return error
}
