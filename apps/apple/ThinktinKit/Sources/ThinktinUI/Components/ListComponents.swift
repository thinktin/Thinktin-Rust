import SwiftUI
import ThinktinKit

// 各页面共用的导航标题和错误判断。以前这里还有自己画的分组卡片、行、小标签、单选行、提示条、页面大标题、加载中
// （`GroupedSection`、`ListRow`、`TagChip`、`ChoiceRow`、`InlineNotice`、`PageHeader`、`LoadingStateView`），改版后
// 各页都换成了系统的 `List` / `Form`（规范 2.5），2026-11-05 删掉；行的写法见 `ListStyles.swift`。

extension View {
    /// 页面顶部的行内标题（导航栏标题，iOS 上用小标题样式，规范 2.1：没有大标题）。
    func inlineNavigationTitle(_ title: String) -> some View {
        inlineNavigationTitle(title) { InlineTitleText(title: title) }
    }

    /// 同上，iOS 导航栏中间放自己的内容（对话页的头像 + 名字）代替那一行字：导航栏中间只有这一个 `.principal`，
    /// 别在外面再加一个（两个都会显示，读屏念两遍）。`title` 照样是导航标题（返回按钮的长按菜单、macOS 的窗口标题）。
    func inlineNavigationTitle<Principal: View>(
        _ title: String, @ViewBuilder principal: () -> Principal
    ) -> some View {
        modifier(InlineNavigationTitle(title: title, principal: principal()))
    }
}

/// 导航栏中间的标题文字（`inlineNavigationTitle` 默认放的；自己放内容的页面没有内容可放时也用它）。
struct InlineTitleText: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }
}

private struct InlineNavigationTitle<Principal: View>: ViewModifier {
    let title: String
    let principal: Principal

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        principal
                    }
                }
        #else
            content.navigationTitle(title)
        #endif
    }
}

/// 离线、出错时页面上显示的错误：网络不通由应用框架的离线横幅说明，这里不重复。
func visibleError(_ error: ClientError?) -> ClientError? {
    guard let error, !error.isOffline else { return nil }
    return error
}
