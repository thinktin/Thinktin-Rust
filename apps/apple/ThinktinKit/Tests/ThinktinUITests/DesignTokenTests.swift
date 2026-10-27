import SwiftUI
import Testing

@testable import ThinktinUI

#if canImport(UIKit)
    import UIKit
#endif

/// 设计令牌和 docs/ios.md 第 4 节的表一致。
@Suite("设计令牌")
struct DesignTokenTests {
    /// docs/ios.md 第 4 节的表（状态色的深色版是“同左略亮”，表里没写具体值，只查浅色）。
    static let documented: [ThemeToken: (light: UInt32, dark: UInt32?)] = [
        .accent: (0xC96442, 0xD97757),
        .paper: (0xFAF9F5, 0x262624),
        .paperElevated: (0xFFFFFF, 0x30302E),
        .userBubble: (0xEFEDE4, 0x3A3936),
        .ink: (0x141413, 0xF0EEE6),
        .inkSecondary: (0x5E5D59, 0xB4B2A9),
        .inkTertiary: (0x8E8D87, 0x80807A),
        .hairline: (0xE5E3DA, 0x3F3E3A),
        .success: (0x2E7D4F, nil),
        .warning: (0xB7791F, nil),
        .danger: (0xC0392B, nil),
    ]

    @Test("每个令牌的色值和文档一致", arguments: ThemeToken.allCases)
    func matchesDocumentation(_ token: ThemeToken) throws {
        let expected = try #require(Self.documented[token])
        #expect(token.light == HexColor(expected.light))
        if let dark = expected.dark {
            #expect(token.dark == HexColor(dark))
        }
        // 浅色、深色各一套，不能是同一个颜色。
        #expect(token.light != token.dark)
    }

    @Test("状态色的深色版比浅色版亮")
    func darkStatusColorsAreBrighter() {
        for token in [ThemeToken.success, .warning, .danger] {
            let light = token.light.red + token.light.green + token.light.blue
            let dark = token.dark.red + token.dark.green + token.dark.blue
            #expect(dark > light, "\(token)")
        }
    }

    @Test("HexColor：分量和文字形式")
    func hexColor() {
        let c: HexColor = 0xC96442
        #expect(c.red == 201.0 / 255)
        #expect(c.green == 100.0 / 255)
        #expect(c.blue == 66.0 / 255)
        #expect(c.description == "#C96442")
        #expect(HexColor(0x00000A).description == "#00000A")
        #expect(HexColor(0xFF12_3456) == HexColor(0x123456))
    }

    @Test("字体：标题衬线，正文系统字体，覆盖全部 Dynamic Type 语义字号")
    func typography() {
        let headings: Set<Typography> = [.largeTitle, .title, .title2, .title3]
        for style in Typography.allCases {
            #expect(style.isHeading == headings.contains(style))
            #expect(style.design == (headings.contains(style) ? .serif : .default))
        }
        // iOS 上的全部语义字号（visionOS 独有的 extraLargeTitle 不算）。
        let iOSStyles: [Font.TextStyle] = [
            .largeTitle, .title, .title2, .title3, .headline, .subheadline, .body, .callout, .footnote, .caption,
            .caption2,
        ]
        #expect(Typography.allCases.map(\.textStyle) == iOSStyles)
    }

    @Test("圆角和间距")
    func metrics() {
        #expect(Metrics.Radius.card == 16)
        #expect(Metrics.Radius.input == 24)
        #expect(Metrics.Radius.control == 10)
        let spacings = [
            Metrics.Spacing.xxs, Metrics.Spacing.xs, Metrics.Spacing.s, Metrics.Spacing.m, Metrics.Spacing.l,
            Metrics.Spacing.xl, Metrics.Spacing.xxl, Metrics.Spacing.xxxl, Metrics.Spacing.units(7),
        ]
        for spacing in spacings {
            #expect(spacing.truncatingRemainder(dividingBy: 4) == 0, "\(spacing)")
        }
        #expect(Metrics.hairline(scale: 3) == 1.0 / 3)
        #expect(Metrics.hairline(scale: 0) == 1)
    }

    #if canImport(UIKit)
        @Test("动态颜色按外观取浅色或深色", arguments: ThemeToken.allCases)
        func resolvesPerAppearance(_ token: ThemeToken) {
            let color = UIColor(light: token.light, dark: token.dark)
            let light = components(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
            let dark = components(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
            #expect(light == components(token.light.uiColor))
            #expect(dark == components(token.dark.uiColor))
        }

        /// 0...255 的整数分量（避开浮点误差）。
        private func components(_ color: UIColor) -> [Int] {
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a].map { Int(($0 * 255).rounded()) }
        }
    #endif
}
