import SwiftUI

/// 对话、运行详情里自己画的卡片（规范 1.1 第 2 条：系统没有的才自己画——工具调用、审批、保险箱填写、发送前的拦截、运行信息）：
/// 和 agent 气泡同一个灰（`agentBubble`）、圆角 20、不画描边（规范 2.1、2.4）。内容竖着排、撑满宽度。
/// 按钮包着的卡片用 `cardSurface()`（同一个底，不撑满）。
struct BubbleCard<Content: View>: View {
    private let fill: Color
    private let padding: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - fill: 底色；用户写的内容（运行详情里的任务）用 `userBubble`。
    ///   - padding: 内边距。
    init(fill: Color = Theme.agentBubble, padding: CGFloat = Metrics.Spacing.m, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }
}
