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
    /// 详情 sheet 的头部和工具栏的 ×、… 在同一行（参考 38、52、105：56pt 图标的上沿和 × 的圆心差不多高，名字、说明紧跟着，
    /// 没有标题）：列表顶上不留系统的边距，iOS 26 不画顶部的滚动边缘效果（不然那一行的图标被糊掉）。头部那一行再加
    /// `toolbarLevelHeader()`。macOS 原样（没有导航栏那一行）。分组之间的间距不动（参考 38 说明到“账户”约 33pt，和系统默认的一样）。
    func toolbarLevelHeaderList() -> some View {
        #if os(iOS)
            contentMargins(.top, 0, for: .scrollContent)
                .hidesScrollEdgeEffect(for: .top)
        #else
            self
        #endif
    }

    /// 头部那一行往上提到工具栏那一行（`toolbarLevelHeaderList()` 的另一半）。头部上面还有别的行（错误横幅）时传 false，
    /// 不然盖住那一行。
    func toolbarLevelHeader(_ isFirstRow: Bool = true) -> some View {
        #if os(iOS)
            padding(.top, isFirstRow ? -ListLayout.toolbarLevelHeaderLift : 0)
        #else
            self
        #endif
    }
}

enum ListLayout {
    /// 头部往上提多少：2026-11-05 截图 37 里 sheet 的 × 圆心离 sheet 顶约 36pt、图标上沿约 101pt；系统给第一组留的顶边距
    /// 去掉以后图标约在 × 圆心下面 30pt，再提 30pt 就和参考一样高。没在真机上量过，下一次截图再对。
    static let toolbarLevelHeaderLift: CGFloat = 30
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

    init(systemImage: String? = nil, title: String, detail: String? = nil, detailTone: StatusTone? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.detailTone = detailTone
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
                        .typography(.subheadline)
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
