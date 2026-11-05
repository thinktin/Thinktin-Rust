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
    ///
    /// - Parameter ownsGlass: 内容自己画了玻璃底（对话页的标题胶囊）：把 iOS 26 工具栏项共用的玻璃底关掉
    ///   （`hidesSharedGlassBackground`），免得套两层。
    func inlineNavigationTitle<Principal: View>(
        _ title: String, ownsGlass: Bool = false, @ViewBuilder principal: () -> Principal
    ) -> some View {
        modifier(InlineNavigationTitle(title: title, ownsGlass: ownsGlass, principal: principal()))
    }
}

extension View {
    /// 同 `inlineNavigationTitle(_:)`，但标题放在一个玻璃胶囊里（参考 114 已隐藏页的标题）：iOS 26 是玻璃，旧系统是材质；
    /// 工具栏自己给项套的共用玻璃底去掉（`hidesSharedGlassBackground`），免得套两层。胶囊里的字是 medium 的 `.body`
    /// （参考 114 比系统标题的 semibold 轻一档）。macOS 是窗口标题。
    func capsuleNavigationTitle(_ title: String) -> some View {
        modifier(CapsuleNavigationTitle(title: title))
    }
}

private struct CapsuleNavigationTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        InlineTitleText(title: title, font: Typography.body.font.weight(.medium))
                            .padding(.horizontal, Metrics.Spacing.m)
                            .frame(minHeight: Metrics.minTapTarget)
                            .glassBackground(in: Capsule())
                            .accessibilityAddTraits(.isHeader)
                    }
                    .hidesSharedGlassBackground()
                }
        #else
            content.navigationTitle(title)
        #endif
    }
}

/// 导航栏中间的标题文字（`inlineNavigationTitle` 默认放的；自己放内容的页面没有内容可放时也用它）。
struct InlineTitleText: View {
    let title: String
    /// 系统标题的 `.headline`；玻璃胶囊里的标题轻一档（`capsuleNavigationTitle`）。
    var font: Font = .headline

    var body: some View {
        Text(title)
            .font(font)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }
}

private struct InlineNavigationTitle<Principal: View>: ViewModifier {
    let title: String
    let ownsGlass: Bool
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
                    .hidesSharedGlassBackground(ownsGlass)
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
