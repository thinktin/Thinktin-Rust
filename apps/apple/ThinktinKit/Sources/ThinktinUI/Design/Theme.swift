import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// 颜色令牌（docs/ios.md 第 4 节；改版的方案见 docs/ios-ui-redesign.md 2.2，用户 2026-11-04 定了 6.2 C）：
// 中性灰的底和卡片（浅色正好是系统的分组色，深色比系统默认亮一档），强调色保留 ThinkTin 的橙，文字三档用系统的语义色。
// 每个令牌一套浅色、一套深色，跟着系统的外观自动切换（iOS 用 `UIColor` 的动态颜色，macOS 用 `NSColor` 的动态颜色）。
//
// 界面里一律用 `Theme.xxx`，不要直接写色值；状态色（success / warning / danger）只用于状态，不用于装饰。
// `List` / `Form` 的底色和行底用下面的 `themedGroupedBackground()`、`themedRow()` 对齐到 `paper` / `paperElevated`。

/// 不透明的 sRGB 颜色，按 `0xRRGGBB` 写（`let c: HexColor = 0xC96442`）。只依赖 Foundation，方便测试。
public struct HexColor: Hashable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    /// `0xRRGGBB`，高 8 位不用。
    public let rgb: UInt32

    public init(_ rgb: UInt32) {
        self.rgb = rgb & 0xFF_FFFF
    }

    public init(integerLiteral value: UInt32) {
        self.init(value)
    }

    /// 0...1。
    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(rgb & 0xFF) / 255 }

    /// `#C96442`（大写，和 docs/ios.md 的表一致）。
    public var description: String {
        let hex = String(rgb, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - hex.count)) + hex
    }
}

/// 设计令牌：名字和 docs/ios.md 第 4 节的表一一对应。
public enum ThemeToken: String, CaseIterable, Sendable {
    /// 全局 `.tint`：主按钮、发送、开关、链接、选中态、运行中的进度。
    case accent
    /// 页面底色（`List` / `Form` 的底色也用它）。
    case paper
    /// 分组卡片、列表行、输入卡片。卡片不画描边，靠和 `paper` 的明暗区分。
    case paperElevated
    /// agent 回复的气泡（左侧）。现在和 `paperElevated` 同值，单列一个以后好单独调。
    case agentBubble
    /// 用户消息的气泡（右侧）。
    case userBubble
    /// 主文字：系统的 `label`。
    case ink
    /// 次要文字、副标题、时间：系统的 `secondaryLabel`。
    case inkSecondary
    /// 占位、禁用：系统的 `tertiaryLabel`。
    case inkTertiary
    /// 自己画的分隔线（`List` 用系统的分隔线）。
    case hairline
    /// 成功（运行成功）。
    case success
    /// 警告（等待审批、等电脑、等 key、等子任务）。
    case warning
    /// 危险（失败、危险操作）。
    case danger

    /// 浅色外观下的颜色。文字三档（`systemLabel` 不为 nil）是系统色叠在 `paper` 上的不透明近似值，只给文档、测试和
    /// 没有系统色的地方用；界面里的 `color` 是系统色本身。
    public var light: HexColor {
        switch self {
        case .accent: 0xC96442
        case .paper: 0xF2F2F7
        case .paperElevated: 0xFFFFFF
        case .agentBubble: 0xFFFFFF
        case .userBubble: 0xE5E5EA
        case .ink: 0x000000
        case .inkSecondary: 0x85858B
        case .inkTertiary: 0xBBBBC1
        case .hairline: 0xC6C6C8
        case .success: 0x2E7D4F
        case .warning: 0xB7791F
        case .danger: 0xC0392B
        }
    }

    /// 深色外观下的颜色。状态色在深色底上“同左略亮”：提亮到和深色底色有足够对比。纯黑外观（第 2 轮）的 `paper`
    /// 另算，不在这里。
    public var dark: HexColor {
        switch self {
        case .accent: 0xD97757
        case .paper: 0x1C1C1E
        case .paperElevated: 0x2C2C2E
        case .agentBubble: 0x2C2C2E
        case .userBubble: 0x3A3A3C
        case .ink: 0xFFFFFF
        case .inkSecondary: 0x98989F
        case .inkTertiary: 0x5A5A5F
        case .hairline: 0x38383A
        case .success: 0x4A9E6E
        case .warning: 0xD4973A
        case .danger: 0xE05A4C
        }
    }

    /// 文字三档对应的系统语义色（带透明度，放在玻璃、材质上系统会自动调对比）；别的令牌为 nil。
    public var systemLabel: SystemLabelColor? {
        switch self {
        case .ink: .primary
        case .inkSecondary: .secondary
        case .inkTertiary: .tertiary
        default: nil
        }
    }

    /// 跟随系统外观的 SwiftUI 颜色。
    public var color: Color {
        if let systemLabel { return systemLabel.color }
        return Color(light: light, dark: dark)
    }
}

/// 系统的三档文字色（iOS 的 `label` / `secondaryLabel` / `tertiaryLabel`，macOS 的 `labelColor` 那三个）。
public enum SystemLabelColor: CaseIterable, Sendable {
    case primary
    case secondary
    case tertiary

    /// 对应的 SwiftUI 颜色（动态，跟着外观和所在的底色变）。
    public var color: Color {
        #if canImport(UIKit)
            return Color(uiColor: uiColor)
        #elseif canImport(AppKit)
            return Color(nsColor: nsColor)
        #else
            let token: ThemeToken =
                switch self {
                case .primary: .ink
                case .secondary: .inkSecondary
                case .tertiary: .inkTertiary
                }
            return Color(light: token.light, dark: token.dark)
        #endif
    }

    #if canImport(UIKit)
        public var uiColor: UIColor {
            switch self {
            case .primary: .label
            case .secondary: .secondaryLabel
            case .tertiary: .tertiaryLabel
            }
        }
    #elseif canImport(AppKit)
        public var nsColor: NSColor {
            switch self {
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            case .tertiary: .tertiaryLabelColor
            }
        }
    #endif
}

/// 界面用的颜色。
public enum Theme {
    public static let accent = ThemeToken.accent.color
    public static let paper = ThemeToken.paper.color
    public static let paperElevated = ThemeToken.paperElevated.color
    public static let agentBubble = ThemeToken.agentBubble.color
    public static let userBubble = ThemeToken.userBubble.color
    public static let ink = ThemeToken.ink.color
    public static let inkSecondary = ThemeToken.inkSecondary.color
    public static let inkTertiary = ThemeToken.inkTertiary.color
    public static let hairline = ThemeToken.hairline.color
    public static let success = ThemeToken.success.color
    public static let warning = ThemeToken.warning.color
    public static let danger = ThemeToken.danger.color

    /// 强调色、状态色底上的文字（发送按钮的箭头、主按钮的文字）。
    public static let onAccent = Color.white
}

extension StatusTone {
    /// 状态对应的颜色（docs/ios.md 第 4 节的规则）。
    public var color: Color {
        switch self {
        case .neutral: Theme.inkSecondary
        case .active: Theme.accent
        case .waiting: Theme.warning
        case .success: Theme.success
        case .failure: Theme.danger
        case .muted: Theme.inkTertiary
        }
    }
}

// MARK: - 列表、表单的底色

extension View {
    /// `List` / `Form` 的底色换成 `paper`（加在 `List` / `Form` 上）。浅色和系统的分组底色一样；深色系统默认是纯黑，
    /// 比 `paper` 暗一档，所以要藏起系统的底色自己铺。它只藏列表自己的底，不管行：分组列表的行配 `themedRow()`，
    /// plain 列表的行配 `themedPlainRow()`。
    public func themedGroupedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.paper)
    }

    /// 分组列表（`insetGrouped`、`Form`）行的底色换成 `paperElevated`。这个修饰符只对行生效：加在 `Section` 的内容或
    /// `ForEach` 上，加在 `List` 本身上没用。
    public func themedRow() -> some View {
        listRowBackground(Theme.paperElevated)
    }

    /// plain 列表（首页、搜索结果）的行底透明，露出页面的 `paper`。不加的话系统给 plain 列表的每一行铺
    /// `systemBackground`（浅色纯白、深色纯黑），和行之间、列表下面的 `paper` 不一样。和 `themedRow()` 一样只对行生效。
    public func themedPlainRow() -> some View {
        listRowBackground(Color.clear)
    }
}

// MARK: - 浅色 / 深色的动态颜色

extension Color {
    /// 跟着系统外观切换的颜色：浅色外观用 `light`，深色外观用 `dark`。
    public init(light: HexColor, dark: HexColor) {
        #if canImport(UIKit)
            self.init(uiColor: UIColor(light: light, dark: dark))
        #elseif canImport(AppKit)
            self.init(nsColor: NSColor(light: light, dark: dark))
        #else
            self.init(red: light.red, green: light.green, blue: light.blue)
        #endif
    }
}

#if canImport(UIKit)
    extension HexColor {
        /// 对应的 `UIColor`（sRGB，不透明）。
        public var uiColor: UIColor {
            UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
        }
    }

    extension UIColor {
        /// 动态颜色：系统在解析颜色时按当前的 trait collection 取浅色或深色。
        /// 闭包只捕获 `HexColor`（值类型、`Sendable`），在哪个线程上解析都安全。
        public convenience init(light: HexColor, dark: HexColor) {
            self.init(dynamicProvider: { traits in
                traits.userInterfaceStyle == .dark ? dark.uiColor : light.uiColor
            })
        }
    }
#elseif canImport(AppKit)
    extension HexColor {
        /// 对应的 `NSColor`（sRGB，不透明）。
        public var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
        }
    }

    extension NSColor {
        /// 动态颜色：按绘制时的外观（`NSAppearance`）取浅色或深色；高对比度的深色外观也算深色。
        public convenience init(light: HexColor, dark: HexColor) {
            self.init(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
                })
        }
    }
#endif
