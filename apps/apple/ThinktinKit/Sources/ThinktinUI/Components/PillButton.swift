import SwiftUI

/// 胶囊按钮的种类。
public enum PillButtonKind: Hashable, Sendable {
    /// 主操作：强调色底、白字（每屏最多一个）。
    case primary
    /// 次要操作：卡片底色、一像素描边、主文字色。
    case secondary
    /// 危险操作（全部停止、删除）：危险色底、白字。
    case destructive
}

/// 胶囊按钮的尺寸。
public enum PillButtonSize: Hashable, Sendable {
    /// 常规：最小高度 44（可点区域的下限）。
    case regular
    /// 紧凑：行内、横幅里的小按钮。
    case compact
}

/// 胶囊按钮的样式。也可以直接给系统按钮用：`Button("重试") { … }.buttonStyle(.pill(.secondary))`。
public struct PillButtonStyle: ButtonStyle {
    public var kind: PillButtonKind
    public var size: PillButtonSize

    public init(kind: PillButtonKind = .primary, size: PillButtonSize = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillButtonLabel(configuration: configuration, kind: kind, size: size)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// 主操作的胶囊按钮。
    public static var pill: PillButtonStyle { PillButtonStyle() }

    /// 指定种类和尺寸的胶囊按钮。
    public static func pill(_ kind: PillButtonKind, size: PillButtonSize = .regular) -> PillButtonStyle {
        PillButtonStyle(kind: kind, size: size)
    }
}

/// 按钮的外观。单独成一个 `View`，才能读环境里的 `isEnabled`、`displayScale`。
private struct PillButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonKind
    let size: PillButtonSize

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .regular ? Metrics.Spacing.l : Metrics.Spacing.s)
            .padding(.vertical, size == .regular ? Metrics.Spacing.s : Metrics.Spacing.xxs)
            .frame(minHeight: size == .regular ? Metrics.minTapTarget : Metrics.Spacing.xxl)
            .background(background, in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var font: Font {
        switch size {
        case .regular: Typography.body.font.weight(.semibold)
        case .compact: Typography.subheadline.font.weight(.medium)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: Theme.onAccent
        case .secondary: Theme.ink
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent
        case .secondary: Theme.paperElevated
        case .destructive: Theme.danger
        }
    }
}

/// 胶囊按钮：文字（可带 SF Symbol 图标）加 `PillButtonStyle`。
public struct PillButton: View {
    private let title: String
    private let systemImage: String?
    private let kind: PillButtonKind
    private let size: PillButtonSize
    private let action: @MainActor () -> Void

    /// - Parameters:
    ///   - title: 按钮文字（已经按界面语言取好的）。
    ///   - systemImage: SF Symbol 的名字，可选。
    public init(
        _ title: String, systemImage: String? = nil, kind: PillButtonKind = .primary, size: PillButtonSize = .regular,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(role: kind == .destructive ? .destructive : nil, action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.pill(kind, size: size))
    }
}

#Preview("胶囊按钮") {
    VStack(spacing: Metrics.Spacing.m) {
        PillButton("发送任务", systemImage: "arrow.up") {}
        PillButton("重试", kind: .secondary) {}
        PillButton("全部停止", systemImage: "stop.fill", kind: .destructive) {}
        HStack {
            PillButton("复制详情", systemImage: "doc.on.doc", kind: .secondary, size: .compact) {}
            PillButton("不可用", size: .compact) {}.disabled(true)
        }
    }
    .padding()
    .background(Theme.paper)
}

#Preview("胶囊按钮 · 深色") {
    VStack(spacing: Metrics.Spacing.m) {
        PillButton("批准") {}
        PillButton("拒绝", kind: .secondary) {}
    }
    .padding()
    .background(Theme.paper)
    .preferredColorScheme(.dark)
}
