import SwiftUI

// 登录页（`SignInFlow`、`PhoneEntryView`、`CodeEntryView`）专用的胶囊按钮样式。登录页是用户自己设计的（规范 1.4、
// docs/progress/ios-ui-redesign.md 开头），改版没动它的外观；别的页面都换成了系统按钮（`glassButtonStyle`、
// `smallCapsuleButton`），这个样式不要再拿去用。等用户给了登录页的设计，换完就删掉这个文件。

/// 胶囊按钮的种类。
enum PillButtonKind: Hashable, Sendable {
    /// 主操作：强调色底、白字（每屏最多一个）。
    case primary
    /// 次要操作：卡片底色、一像素描边、主文字色。
    case secondary
    /// 危险操作（全部停止、删除）：危险色底、白字。
    case destructive
}

/// 胶囊按钮的尺寸。
enum PillButtonSize: Hashable, Sendable {
    /// 常规：最小高度 44（可点区域的下限）。
    case regular
    /// 紧凑：行内、横幅里的小按钮。
    case compact
}

/// 胶囊按钮的样式。也可以直接给系统按钮用：`Button("重试") { … }.buttonStyle(.pill(.secondary))`。
struct PillButtonStyle: ButtonStyle {
    var kind: PillButtonKind
    var size: PillButtonSize

    init(kind: PillButtonKind = .primary, size: PillButtonSize = .regular) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        PillButtonLabel(configuration: configuration, kind: kind, size: size)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// 主操作的胶囊按钮。
    static var pill: PillButtonStyle { PillButtonStyle() }

    /// 指定种类和尺寸的胶囊按钮。
    static func pill(_ kind: PillButtonKind, size: PillButtonSize = .regular) -> PillButtonStyle {
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
