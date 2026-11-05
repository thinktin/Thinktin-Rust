import SwiftUI

// 改版后各页面共用的列表写法（规范 2.5、2.6）。第 1 轮 C 线写在 Screens/Agents/ 里，D 线挪到这里给计划、产出物、搜索一起用。

/// 导航栏上的位置。
enum ToolbarSlot {
    /// 导航栏右边：iOS `.topBarTrailing`；macOS 没有，放主操作的位置。
    static var trailing: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .primaryAction
        #endif
    }
}

extension View {
    /// 分组的圆角卡片列表（规范 2.5 的 insetGrouped）：iOS `.insetGrouped`；macOS 没有，用 `.inset`。
    func insetGroupedList() -> some View {
        #if os(iOS)
            listStyle(.insetGrouped)
        #else
            listStyle(.inset)
        #endif
    }

    /// 分组列表里不画卡片底的一行（头部、横幅、筛选胶囊）：透明底、贴边、不要分隔线。
    func clearListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }

    /// 分组列表收紧上下的空白（参考 09、12、18、65：导航栏下面约 25–36pt 就是第一组，分组之间约 20pt）：iOS 分组间距用
    /// `.compact`，滚动内容顶上的边距改成 `top`（系统默认的比参考多出 20pt 左右）。macOS 原样（`.inset` 列表本来就紧）。
    func compactGroupedList(top: CGFloat = Metrics.Spacing.s) -> some View {
        #if os(iOS)
            listSectionSpacing(.compact)
                .contentMargins(.top, top, for: .scrollContent)
        #else
            self
        #endif
    }
}

extension View {
    /// 分组的标题（`Section` 的 `header`）：脚注字号、次要文字色、不转大写（规范 2.5，参考 12、18、65 量出来约 13pt 浅灰）。
    /// iOS 26 的分组标题不写字号时是约 17pt 的半粗字，和行里的字一样大，所以每个 `header:` 都加这个。
    func groupHeader() -> some View {
        typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .textCase(nil)
    }
}

/// 分组列表一行开头的图标 + 标题（参考 09：细的中性灰图标，约 17pt，不用强调色）：放在 `NavigationLink` / `LabeledContent`
/// 的标签位置，代替 `Label(标题, systemImage:)`（列表行里的 `Label` 图标默认是强调色、和正文一样大）。
struct RowLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

/// 分组列表里的一行内容（规范 2.5）：左边 SF Symbol、标题、下面一行灰色说明。只是内容，不画底、不加边距：放进 `Section`，
/// 要点击就外面包 `NavigationLink` / `Button`（系统画 chevron 和按下的效果）。
struct LabeledRow: View {
    let systemImage: String?
    let title: String
    var detail: String?
    /// 说明文字的色调（要提醒用户时用 `.waiting`）；nil 用次要文字色。
    var detailTone: StatusTone?
    /// 说明文字的字号：默认 `.subheadline`；参考里一行短说明（65 的“重置电脑”、工作区的“观看与接管”）是 `.footnote`。
    var detailTypography: Typography

    init(
        systemImage: String? = nil, title: String, detail: String? = nil, detailTone: StatusTone? = nil,
        detailTypography: Typography = .subheadline
    ) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.detailTone = detailTone
        self.detailTypography = detailTypography
    }

    var body: some View {
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
                        .typography(detailTypography)
                        .foregroundStyle(detailTone?.color ?? Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 分组列表里的一句提示（等你确认、有风险、部分保存、信息没查全）：按语气上色的图标加一段话，就是一行，不画底。
struct NoticeRow: View {
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
        }
        .accessibilityElement(children: .combine)
    }
}

/// 几样东西排一行（状态和时间、几个小按钮）；字号很大时改成一列，免得挤出屏幕。
struct AdaptiveRow<Content: View>: View {
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
