import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// 颜色令牌（docs/ios.md 第 4 节）：暖色纸张底色、极少的强调色。每个令牌一套浅色、一套深色，
// 跟着系统的外观自动切换（iOS 用 `UIColor` 的动态颜色，macOS 用 `NSColor` 的动态颜色）。
//
// 界面里一律用 `Theme.xxx`，不要直接写色值；状态色（success / warning / danger）只用于状态，不用于装饰。

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
    /// 发送按钮、选中态、链接、运行中的进度。
    case accent
    /// 页面底色。
    case paper
    /// 卡片、抽屉、输入框。
    case paperElevated
    /// 用户消息卡片。
    case userBubble
    /// 主文字。
    case ink
    /// 次要文字、时间。
    case inkSecondary
    /// 占位、禁用。
    case inkTertiary
    /// 分隔线、边框。
    case hairline
    /// 成功（运行成功）。
    case success
    /// 警告（等待审批、等电脑、等 key、等子任务）。
    case warning
    /// 危险（失败、危险操作）。
    case danger

    /// 浅色外观下的颜色。
    public var light: HexColor {
        switch self {
        case .accent: 0xC96442
        case .paper: 0xFAF9F5
        case .paperElevated: 0xFFFFFF
        case .userBubble: 0xEFEDE4
        case .ink: 0x141413
        case .inkSecondary: 0x5E5D59
        case .inkTertiary: 0x8E8D87
        case .hairline: 0xE5E3DA
        case .success: 0x2E7D4F
        case .warning: 0xB7791F
        case .danger: 0xC0392B
        }
    }

    /// 深色外观下的颜色。状态色在深色底上“同左略亮”：提亮到和深色纸张底色有足够对比。
    public var dark: HexColor {
        switch self {
        case .accent: 0xD97757
        case .paper: 0x262624
        case .paperElevated: 0x30302E
        case .userBubble: 0x3A3936
        case .ink: 0xF0EEE6
        case .inkSecondary: 0xB4B2A9
        case .inkTertiary: 0x80807A
        case .hairline: 0x3F3E3A
        case .success: 0x4A9E6E
        case .warning: 0xD4973A
        case .danger: 0xE05A4C
        }
    }

    /// 跟随系统外观的 SwiftUI 颜色。
    public var color: Color { Color(light: light, dark: dark) }
}

/// 界面用的颜色。
public enum Theme {
    public static let accent = ThemeToken.accent.color
    public static let paper = ThemeToken.paper.color
    public static let paperElevated = ThemeToken.paperElevated.color
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
