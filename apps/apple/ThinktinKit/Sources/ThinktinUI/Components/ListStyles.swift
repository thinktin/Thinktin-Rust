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
