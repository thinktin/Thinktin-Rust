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
