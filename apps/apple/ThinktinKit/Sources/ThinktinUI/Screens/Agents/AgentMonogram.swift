import SwiftUI
import ThinktinKit

// Agent 目录、详情、领养、实例详情（WBS 12.3）用的头像。别的页面共用的列表组件在 Components/ListComponents.swift。

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
