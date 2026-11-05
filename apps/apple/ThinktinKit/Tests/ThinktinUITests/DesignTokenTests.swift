import SwiftUI
import Testing

@testable import ThinktinUI

#if canImport(UIKit)
    import UIKit
#endif

/// 设计令牌和 docs/ios.md 第 4 节的表（改版方案 docs/ios-ui-redesign.md 2.2–2.4，6.2 C）一致。
@Suite("设计令牌")
struct DesignTokenTests {
    /// docs/ios.md 第 4 节的表（状态色的深色版是“同左略亮”，表里没写具体值，只查浅色）。文字三档是系统色，
    /// 表里的是它们叠在 `paper` 上的不透明近似值（下面 `systemLabelApproximations` 核对）。
    static let documented: [ThemeToken: (light: UInt32, dark: UInt32?)] = [
        .accent: (0xC96442, 0xD97757),
        .paper: (0xF2F2F7, 0x1C1C1E),
        .paperElevated: (0xFFFFFF, 0x2C2C2E),
        .agentBubble: (0xFFFFFF, 0x2C2C2E),
        .userBubble: (0xE5E5EA, 0x3A3A3C),
        .ink: (0x000000, 0xFFFFFF),
        .inkSecondary: (0x85858B, 0x98989F),
        .inkTertiary: (0xBBBBC1, 0x5A5A5F),
        .hairline: (0xC6C6C8, 0x38383A),
        .success: (0x2E7D4F, nil),
        .warning: (0xB7791F, nil),
        .danger: (0xC0392B, nil),
    ]

    /// 系统文字色的 sRGB 分量（0...255）和不透明度，照 iOS 17 SDK：浅色、深色。
    static let systemLabelRGBA: [SystemLabelColor: (light: [Double], dark: [Double], alpha: Double)] = [
        .primary: ([0, 0, 0], [255, 255, 255], 1),
        .secondary: ([60, 60, 67], [235, 235, 245], 0.6),
        .tertiary: ([60, 60, 67], [235, 235, 245], 0.3),
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

    @Test("文字三档用系统色，其余令牌用自己的色值")
    func systemLabels() {
        #expect(ThemeToken.ink.systemLabel == .primary)
        #expect(ThemeToken.inkSecondary.systemLabel == .secondary)
        #expect(ThemeToken.inkTertiary.systemLabel == .tertiary)
        let custom = ThemeToken.allCases.filter { $0.systemLabel == nil }
        #expect(Set(custom) == Set(ThemeToken.allCases).subtracting([.ink, .inkSecondary, .inkTertiary]))
        #expect(Set(ThemeToken.allCases.compactMap(\.systemLabel)) == Set(SystemLabelColor.allCases))
    }

    @Test("文字三档的近似值是系统色叠在 paper 上", arguments: SystemLabelColor.allCases)
    func systemLabelApproximations(_ level: SystemLabelColor) throws {
        let token = try #require(ThemeToken.allCases.first { $0.systemLabel == level })
        let system = try #require(Self.systemLabelRGBA[level])
        for (approximation, foreground, background) in [
            (token.light, system.light, ThemeToken.paper.light), (token.dark, system.dark, ThemeToken.paper.dark),
        ] {
            let paper = [background.red, background.green, background.blue].map { $0 * 255 }
            let blended = zip(foreground, paper).map { system.alpha * $0 + (1 - system.alpha) * $1 }
            let actual = [approximation.red, approximation.green, approximation.blue].map { $0 * 255 }
            for (want, got) in zip(blended, actual) {
                #expect(abs(want - got) <= 1, "\(token) \(approximation)")
            }
        }
    }

    @Test("agent 回复的气泡和卡片同值；浅色的底和卡片正好是系统的分组色")
    func neutralSurfaces() {
        #expect(ThemeToken.agentBubble.light == ThemeToken.paperElevated.light)
        #expect(ThemeToken.agentBubble.dark == ThemeToken.paperElevated.dark)
        #expect(ThemeToken.paper.light == HexColor(0xF2F2F7))
        #expect(ThemeToken.paperElevated.light == HexColor(0xFFFFFF))
        // 深色：卡片、用户气泡依次比底色亮一档。
        let brightness = { (c: HexColor) in c.red + c.green + c.blue }
        #expect(brightness(ThemeToken.paper.dark) < brightness(ThemeToken.paperElevated.dark))
        #expect(brightness(ThemeToken.paperElevated.dark) < brightness(ThemeToken.userBubble.dark))
        // 中性灰：底色、卡片、气泡、分隔线的红绿两个分量相同，没有暖色偏。
        for token in [ThemeToken.paper, .paperElevated, .agentBubble, .userBubble, .hairline] {
            #expect(token.light.red == token.light.green, "\(token)")
            #expect(token.dark.red == token.dark.green, "\(token)")
        }
    }

    @Test("启动屏：底色 LaunchBackground 和 paper 同值，Logo 深浅两版、保留矢量（tools/apple/brand_assets.py 生成，改令牌后重跑）")
    func launchScreenAssets() throws {
        // 从这个文件往上找仓库根（uicheck 把测试复制到 tools/apple/uicheck/Gen/ 下，层数不固定）。
        let relative = "apps/apple/Thinktin/Resources/Assets.xcassets"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path),
            directory.pathComponents.count > 1
        {
            directory.deleteLastPathComponent()
        }
        let assets = directory.appendingPathComponent(relative)
        func json(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: assets.appendingPathComponent(path))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func isDark(_ entry: [String: Any]) -> Bool {
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            return appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" }
        }

        let colors = try #require(try json("LaunchBackground.colorset/Contents.json")["colors"] as? [[String: Any]])
        var found: [Bool: HexColor] = [:]
        for entry in colors {
            let color = try #require(entry["color"] as? [String: Any])
            #expect(color["color-space"] as? String == "srgb")
            let components = try #require(color["components"] as? [String: String])
            #expect(components["alpha"] == "1.000")
            let channels = try ["red", "green", "blue"].map { name in
                let text = try #require(components[name])
                return try #require(UInt32(text.dropFirst(2), radix: 16))
            }
            found[isDark(entry)] = HexColor(channels[0] << 16 | channels[1] << 8 | channels[2])
        }
        #expect(found[false] == ThemeToken.paper.light)
        #expect(found[true] == ThemeToken.paper.dark)

        let logo = try json("LaunchLogo.imageset/Contents.json")
        let images = try #require(logo["images"] as? [[String: Any]])
        #expect(images.map { $0["filename"] as? String } == ["LaunchLogo.pdf", "LaunchLogo-dark.pdf"])
        #expect(images.map(isDark) == [false, true])
        #expect((logo["properties"] as? [String: Any])?["preserves-vector-representation"] as? Bool == true)
        for image in images {
            let name = try #require(image["filename"] as? String)
            let pdf = try Data(contentsOf: assets.appendingPathComponent("LaunchLogo.imageset/\(name)"))
            #expect(pdf.starts(with: Data("%PDF-".utf8)), "\(name)")
        }
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

    @Test("字体：全部系统字体（标题也不用衬线），覆盖全部 Dynamic Type 语义字号")
    func typography() {
        let headings: Set<Typography> = [.largeTitle, .title, .title2, .title3]
        for style in Typography.allCases {
            #expect(style.isHeading == headings.contains(style))
            #expect(style.design == .default)
        }
        // iOS 上的全部语义字号（visionOS 独有的 extraLargeTitle 不算）。
        let iOSStyles: [Font.TextStyle] = [
            .largeTitle, .title, .title2, .title3, .headline, .subheadline, .body, .callout, .footnote, .caption,
            .caption2,
        ]
        #expect(Typography.allCases.map(\.textStyle) == iOSStyles)
    }

    @Test("圆角、头像和间距")
    func metrics() {
        #expect(Metrics.Radius.card == 20)
        #expect(Metrics.Radius.composerCard == 28)
        #expect(Metrics.Radius.input == 24)
        #expect(Metrics.Radius.control == 10)
        let avatars = [
            Metrics.Avatar.title, Metrics.Avatar.search, Metrics.Avatar.list, Metrics.Avatar.pinned,
            Metrics.Avatar.edit, Metrics.Avatar.profile,
        ]
        #expect(avatars == [24, 40, 48, 80, 100, 120])
        for size in avatars {
            #expect(size.truncatingRemainder(dividingBy: 4) == 0, "\(size)")
        }
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

        @Test("文字三档解析出来是系统的文字色")
        func systemLabelsResolve() {
            let traits = [
                UITraitCollection(userInterfaceStyle: .light), UITraitCollection(userInterfaceStyle: .dark),
            ]
            for level in SystemLabelColor.allCases {
                guard let system = Self.systemLabelRGBA[level] else {
                    Issue.record("\(level) 没有系统色的分量")
                    continue
                }
                for (traits, rgb) in zip(traits, [system.light, system.dark]) {
                    let resolved = components(level.uiColor.resolvedColor(with: traits))
                    #expect(Array(resolved.prefix(3)) == rgb.map { Int($0) }, "\(level)")
                    // 不透明度按 0...255 取整时可能差一（0.3 × 255 = 76.5）。
                    #expect(abs(Double(resolved[3]) - system.alpha * 255) <= 1, "\(level)")
                }
            }
        }

        /// 0...255 的整数分量（避开浮点误差）。
        private func components(_ color: UIColor) -> [Int] {
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a].map { Int(($0 * 255).rounded()) }
        }
    #endif
}
