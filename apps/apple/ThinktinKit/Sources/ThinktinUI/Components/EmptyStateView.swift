import SwiftUI

/// 空状态：图标、衬线标题、一句说明，可选一个操作按钮（“去领养”“新建计划”）。各页面的空列表都用它（12.17）。
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let action: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - systemImage: SF Symbol 的名字。
    ///   - title: 标题（已经按界面语言取好的）。
    ///   - message: 说明，可选。
    ///   - actionTitle: 按钮文字；和 `action` 都给了才显示按钮。
    public init(
        systemImage: String, title: String, message: String? = nil, actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Metrics.Spacing.s) {
            VStack(spacing: Metrics.Spacing.s) {
                Image(systemName: systemImage)
                    .font(Typography.largeTitle.font)
                    .imageScale(.large)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .typography(.title3)
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            if let actionTitle, let action {
                PillButton(actionTitle, kind: .secondary, action: action)
                    .padding(.top, Metrics.Spacing.xs)
            }
        }
        .padding(Metrics.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("空状态") {
    EmptyStateView(
        systemImage: "square.stack.3d.up",
        title: "还没有实例",
        message: "从 agent 目录领养一个，就可以给它布置任务了。",
        actionTitle: "去领养"
    ) {}
    .background(Theme.paper)
}

#Preview("空状态 · 深色、无按钮") {
    EmptyStateView(systemImage: "tray", title: "Inbox zero", message: "Nothing needs your attention.")
        .background(Theme.paper)
        .preferredColorScheme(.dark)
}
