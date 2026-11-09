import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Botin 头像（docs/ios-ui-redesign.md 2.4、4.4.4、6.9）：按名字取色稳定、12 种鲜明的颜色在浅色、深色的底上都看得出来、
/// 选中的环在哪种颜色上都看得见、15 种形状不出界、读屏文字、各种尺寸、形状和角标都画得出来（脸本身见 `BotinFaceTests`）；
/// 引擎、厂商、账号的首字图标照旧（暗一点的那套底色，白字看得清）。
@MainActor
@Suite("实例头像")
struct InstanceAvatarTests {
    @Test("同一个名字永远是同一种颜色：跨进程、跨设备稳定（FNV-1a，不用 Hasher），不分大小写、不管首尾空白；引擎、厂商的首字图标按同一个下标取自己那套")
    func stablePaletteIndex() {
        // 期望值是在别处（Python）按同样的算法独立算出来的，散列改了这里会失败。
        #expect(AvatarColor.nameHashIndex(for: "周报助手") == 4)
        #expect(AvatarColor.nameHashIndex(for: "Hermes Agent") == 2)
        #expect(AvatarColor.nameHashIndex(for: "OpenClaw") == 6)
        #expect(AvatarColor.nameHashIndex(for: "日程") == 3)
        #expect(AvatarColor.nameHashIndex(for: "Anthropic (Claude)") == 0)
        #expect(AvatarColor.nameHashIndex(for: "") == 5)
        #expect(AvatarColor.forName("Codex") == AvatarColor.forName("  codex \n"))
        // Botin 按名字取的是鲜明的那套；引擎、厂商同一个下标、暗一点的那套（色值和 2026-11-06 以前一样，图标不变色）。
        #expect(InstanceAvatar.color(of: AvatarColor.forName("周报助手")) == InstanceAvatar.color(of: .mint))
        #expect(AvatarGlyph.colors(for: "周报助手").light == 0x2B7E85)
        #expect(AvatarGlyph.colors(for: "周报助手").dark == 0x358A91)
        #expect(AvatarGlyph.colors(for: "Anthropic (Claude)").light == 0x3B6FB6)
        #expect(AvatarGlyph.colors(for: "Codex").light == AvatarGlyph.colors(for: "  codex \n").light)
    }

    @Test("不同的名字分得开")
    func namesSpreadAcrossPalette() {
        let names = [
            "周报助手", "Codex", "Hermes Agent", "OpenClaw", "Pi", "盯盘", "日程", "翻译", "Claude Agent",
            "Anthropic (Claude)", "DeepSeek",
        ]
        #expect(Set(names.map(AvatarColor.forName)).count >= 5)
        #expect(Set(names.map { AvatarGlyph.colors(for: $0).light }).count >= 5)
    }

    @Test("Botin 的色板：12 种鲜明的颜色，浅色、深色同一个值，互不相同，不和强调色、状态色撞；在深色的底上亮度对比 3:1 以上，在浅色的底上色差 35 以上（最淡的琥珀黄、薄荷绿也看得出身体和透出底色的眼睛）")
    func vividPaletteReads() {
        let palette = AvatarColor.allCases.map(InstanceAvatar.color(of:))
        #expect(palette.count == 12)
        #expect(Set(palette).count == palette.count)
        // 是我们自己挑的那 12 个值（按色板的顺序）。
        #expect(
            palette == [
                0xF04E4E, 0xFF7A2F, 0xFFB21F, 0x34C46A, 0x22C3B0, 0x38B2F5, 0x3D7BFF, 0x7A5CFF, 0xB15CF5, 0xFF5CA8,
                0xA8693C, 0x8E8E93,
            ])
        let reserved: Set<HexColor> = Set(
            [ThemeToken.accent, .success, .warning, .danger].flatMap { [$0.light, $0.dark] })
        let lightBackgrounds = [ThemeToken.paper.light, ThemeToken.paperElevated.light]
        let darkBackgrounds = [ThemeToken.paper.dark, ThemeToken.paperElevated.dark]
        for (color, hex) in zip(AvatarColor.allCases, palette) {
            #expect(!reserved.contains(hex), "\(color)")
            for background in darkBackgrounds {
                #expect(contrast(hex, background) >= 3, "\(color) on \(background): \(contrast(hex, background))")
            }
            for background in lightBackgrounds {
                #expect(deltaE(hex, background) >= 35, "\(color) on \(background): \(deltaE(hex, background))")
            }
        }
        // 浅色的底上最淡的琥珀黄亮度对比不到 2:1（所以靠色差查）。
        #expect(contrast(InstanceAvatar.color(of: .amber), ThemeToken.paper.light) < 2)
    }

    @Test("首字图标（引擎、厂商）的底色：8 种，白字对比度 4:1 以上，浅深各一套；色值和顺序没变")
    func monogramPaletteIsReadable() {
        let palette = AvatarGlyph.palette
        #expect(palette.count == 8 && palette.count == AvatarColor.nameHashed.count)
        #expect(palette[0].light == 0x3B6FB6 && palette[0].dark == 0x4A7FC4)
        #expect(palette[4].light == 0x2B7E85 && palette[7].dark == 0x9A7055)
        #expect(Set(palette.map { $0.light }).count == palette.count)
        #expect(Set(palette.map { $0.dark }).count == palette.count)
        for colors in palette {
            #expect(colors.light != colors.dark)
            #expect(contrast(colors.light, 0xFFFFFF) >= 4, "\(colors.light)")
            #expect(contrast(colors.dark, 0xFFFFFF) >= 4, "\(colors.dark)")
        }
    }

    @Test("头像选择里选中的环：中性灰，和浅色、深色的底对比度都在 3:1 以上（隔着一圈底色画，灰色、琥珀黄的色点上也看得见）")
    func selectionRingIsVisible() {
        let ring = AvatarPickerStyle.ring
        #expect(ring == .inkSecondary && AvatarPickerStyle.ringWidth >= 2)
        for background in [ThemeToken.paper, .paperElevated] {
            #expect(contrast(ring.light, background.light) >= 3, "\(background) light")
            #expect(contrast(ring.dark, background.dark) >= 3, "\(background) dark")
        }
    }

    @Test("形状：15 种都画在单位正方形里、不太小；云朵的三个圆相交")
    func shapesFit() {
        for shape in AvatarShape.allCases {
            var builder = AvatarPathBuilder()
            AvatarShapeGeometry.draw(shape, into: &builder)
            let bounds = builder.unitBounds
            // 控制点可能比曲线略往外一点。
            #expect(bounds.minX >= -0.02 && bounds.minY >= -0.02, "\(shape)")
            #expect(bounds.maxX <= 1.02 && bounds.maxY <= 1.02, "\(shape)")
            #expect(bounds.maxX - bounds.minX >= 0.6 && bounds.maxY - bounds.minY >= 0.6, "\(shape)")
            let layout = AvatarMonogramLayout(shape)
            #expect(layout.textScale > 0.2 && layout.textScale <= 0.42 && abs(layout.verticalOffset) < 0.15)
        }
        let circles = AvatarShapeGeometry.cloudCircles
        #expect(AvatarShapeGeometry.upperIntersection(circles.right, circles.top) != nil)
        #expect(AvatarShapeGeometry.upperIntersection(circles.top, circles.left) != nil)
        // 圆的边上的点都在半径 0.5 上；超椭圆填满正方形。
        let ring = AvatarShapeGeometry.polar(samples: 8) { _ in 0.5 }
        #expect(ring.allSatisfy { abs(hypot($0.x - 0.5, $0.y - 0.5) - 0.5) < 1e-9 })
        let squircle = AvatarShapeGeometry.superellipse(exponent: 4.5, samples: 8)
        #expect(squircle.contains { abs($0.x - 1) < 1e-9 } && squircle.contains { abs($0.y) < 1e-9 })
    }

    @Test("角标落在形状右下方的轮廓上：圆形、伸到角上的不挪（和以前一样），四角星、叶子、菱形往里挪")
    func badgeAnchors() {
        let anchors = AvatarShapeGeometry.badgeAnchors
        #expect(anchors.count == AvatarShape.allCases.count)
        // 和手算的对得上：圆 0.5 + 0.5 / √2，四角星 0.5 + 0.24 / √2，菱形的边 x + y = 1.48，叶子右下那条曲线的中点。
        #expect(abs((anchors[.circle] ?? 0) - 0.8536) < 0.005)
        #expect(abs((anchors[.sparkle] ?? 0) - 0.6697) < 0.005)
        #expect(abs((anchors[.diamond] ?? 0) - 0.74) < 0.005)
        #expect(abs((anchors[.leaf] ?? 0) - 0.695) < 0.005)
        for shape in AvatarShape.allCases {
            let anchor = anchors[shape] ?? 0
            #expect(anchor > 0.6 && anchor <= 1, "\(shape)")
        }
        // 圆形各种尺寸都不挪（角标在方框的右下角，和改之前一样）；伸到角上的圆角方形也不挪、不出方框。
        for size in [Metrics.Avatar.title, Metrics.Avatar.list, Metrics.Avatar.profile] {
            #expect(InstanceAvatar.badgeInset(shape: .circle, size: size) == 0)
            #expect(InstanceAvatar.badgeInset(shape: .squircle, size: size) == 0)
        }
        // 48pt 的行上：四角星、叶子的角标挪到轮廓上（圆心正好在轮廓上）。
        let size = Metrics.Avatar.list
        let radius = InstanceAvatar.badgeDiameter(size: size) / 2 + InstanceAvatar.badgeRing(size: size)
        for shape in [AvatarShape.sparkle, .leaf, .diamond] {
            let inset = InstanceAvatar.badgeInset(shape: shape, size: size)
            #expect(inset > 0, "\(shape)")
            #expect(abs(size - radius - inset - (anchors[shape] ?? 0) * size) < 1e-9, "\(shape)")
        }
    }

    @Test("主 Botin 的星标比状态点大一点、最小 14pt；挪的距离按它自己的直径算")
    func primaryBadge() {
        #expect(InstanceAvatar.badgeDiameter(size: Metrics.Avatar.title, badge: .primary) == 14)
        #expect(abs(InstanceAvatar.badgeDiameter(size: 80, badge: .primary) - 22.4) < 1e-9)
        for size in [Metrics.Avatar.list, Metrics.Avatar.profile] {
            #expect(
                InstanceAvatar.badgeDiameter(size: size, badge: .primary)
                    > InstanceAvatar.badgeDiameter(size: size, badge: .instance(.running)))
            #expect(
                InstanceAvatar.badgeDiameter(size: size, badge: .run(.running))
                    == InstanceAvatar.badgeDiameter(size: size))
            // 圆形不挪；四角星按星标的直径挪（比状态点挪得少）。
            let star = InstanceAvatar.badgeDiameter(size: size, badge: .primary)
            #expect(InstanceAvatar.badgeInset(shape: .circle, size: size, diameter: star) == 0)
            #expect(
                InstanceAvatar.badgeInset(shape: .sparkle, size: size, diameter: star)
                    < InstanceAvatar.badgeInset(shape: .sparkle, size: size))
        }
    }

    @Test("首字（引擎、厂商的图标）的字号：窄的形状在 24pt 上也不小于 9pt，不超过圆形的比例；大头像照形状的比例")
    func monogramFontSize() {
        for shape in AvatarShape.allCases {
            let layout = AvatarMonogramLayout(shape)
            let small = layout.fontSize(for: Metrics.Avatar.title)
            #expect(small >= AvatarMonogramLayout.minimumFontSize, "\(shape)")
            #expect(small <= Metrics.Avatar.title * AvatarMonogramLayout.maximumTextScale + 1e-9, "\(shape)")
            #expect(
                abs(layout.fontSize(for: Metrics.Avatar.profile) - Metrics.Avatar.profile * layout.textScale) < 1e-9)
        }
        #expect(AvatarMonogramLayout(.sparkle).fontSize(for: Metrics.Avatar.title) == 9)
        #expect(abs(AvatarMonogramLayout(.circle).fontSize(for: Metrics.Avatar.title) - 24 * 0.42) < 1e-9)
        // 很小的头像（比 9pt 的字还窄的比例）不比圆形的字大。
        #expect(abs(AvatarMonogramLayout(.sparkle).fontSize(for: 16) - 16 * 0.42) < 1e-9)
    }

    @Test("读屏：名字加状态，名字空的念“未命名”")
    func accessibilityText() {
        #expect(InstanceAvatar.accessibilityText(name: "周报助手", badge: nil, language: .chinese) == "周报助手")
        #expect(
            InstanceAvatar.accessibilityText(name: " 周报助手 ", badge: .instance(.running), language: .chinese)
                == "周报助手，" + InstanceState.running.localizedName(.chinese))
        #expect(
            InstanceAvatar.accessibilityText(name: "Codex", badge: .run(.waitingApproval), language: .english)
                == "Codex, " + RunState.waitingApproval.localizedName(.english))
        #expect(
            InstanceAvatar.accessibilityText(
                name: "Pi", badge: .custom(StatusAppearance(tone: .success), accessibilityLabel: "Online"),
                language: .english) == "Pi, Online")
        #expect(InstanceAvatar.accessibilityText(name: "写作助手", badge: .primary, language: .chinese) == "写作助手，主 Botin")
        #expect(InstanceAvatar.accessibilityText(name: "Ko", badge: .primary, language: .english) == "Ko, Main Botin")
        #expect(InstanceAvatar.accessibilityText(name: "  ", badge: nil, language: .chinese) == "未命名")
        #expect(InstanceAvatar.accessibilityText(name: "", badge: nil, language: .english) == "Untitled")
    }

    @Test("各种尺寸、角标都画得出来（浅色中文、深色英文）")
    func renders() {
        let sizes = [
            Metrics.Avatar.title, Metrics.Avatar.search, Metrics.Avatar.list, Metrics.Avatar.pinned,
            Metrics.Avatar.edit, Metrics.Avatar.profile,
        ]
        for size in sizes {
            renderInBothAppearances(InstanceAvatar("周报助手", size: size))
        }
        for state in InstanceState.knownCases + [.unknown("new_state")] {
            renderInBothAppearances(InstanceAvatar("Codex", size: Metrics.Avatar.list, badge: .instance(state)))
        }
        renderInBothAppearances(InstanceAvatar("OpenClaw", badge: .run(.waitingApproval)))
        renderInBothAppearances(
            InstanceAvatar(
                "盯盘", appearance: InstanceAppearance(color: .amber), size: Metrics.Avatar.list,
                badge: .run(.waitingDevice)))
        for size in [Metrics.Avatar.list, Metrics.Avatar.profile] {
            renderInBothAppearances(InstanceAvatar("写作助手", size: size, badge: .primary))
        }
        renderInBothAppearances(
            InstanceAvatar("", badge: .custom(StatusAppearance(tone: .success), accessibilityLabel: "在线")))
        for shape in AvatarShape.allCases {
            renderInBothAppearances(
                InstanceAvatar(
                    "周报助手", appearance: InstanceAppearance(shape: shape, color: .grey), size: Metrics.Avatar.list,
                    badge: .instance(.running)))
        }
        for color in AvatarColor.allCases {
            renderInBothAppearances(InstanceAvatar("Pi", appearance: InstanceAppearance(color: color)))
        }
        // 名字是空的（新建表单还没输入）：照样画脸，底色按空名字取。
        renderInBothAppearances(InstanceAvatar("  ", appearance: InstanceAppearance(shape: .cloud), size: 120))
    }

    @Test("引擎、模型厂商、账号还是首字（不画脸）：各种尺寸画得出来，名字是空的放占位符号")
    func monogramIconsRender() {
        for size in [EngineIcon.rowSize, EngineIcon.detailSize] {
            renderInBothAppearances(EngineIcon(name: "Codex", size: size))
        }
        for size in [CredentialVendorIcon.rowSize, CredentialVendorIcon.detailSize] {
            renderInBothAppearances(CredentialVendorIcon(name: "DeepSeek", size: size))
        }
        renderInBothAppearances(AccountAvatar("林", size: Metrics.Avatar.account))
        renderInBothAppearances(AccountAvatar("", size: Metrics.Avatar.title))
        renderInBothAppearances(AvatarGlyph(name: " ", size: 40))
    }

    /// sRGB 分量换成线性的（WCAG、CIELAB 都先这么换）。
    private func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG 的相对亮度。
    private func luminance(_ color: HexColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG 的对比度：亮的和暗的相对亮度之比（1 到 21）。
    private func contrast(_ a: HexColor, _ b: HexColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// CIELAB 里两种颜色差多远（CIE76，D65 白点）：亮度对比低的两种颜色色相差得远时也一眼分得开（10 以上就很明显）。
    private func deltaE(_ a: HexColor, _ b: HexColor) -> Double {
        func lab(_ color: HexColor) -> (l: Double, a: Double, b: Double) {
            let (red, green, blue) = (linear(color.red), linear(color.green), linear(color.blue))
            let x = (0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.950_47
            let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let z = (0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.088_83
            func f(_ t: Double) -> Double {
                t > pow(6.0 / 29, 3) ? pow(t, 1.0 / 3) : t / (3 * pow(6.0 / 29, 2)) + 4.0 / 29
            }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (p, q) = (lab(a), lab(b))
        return ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }
}
