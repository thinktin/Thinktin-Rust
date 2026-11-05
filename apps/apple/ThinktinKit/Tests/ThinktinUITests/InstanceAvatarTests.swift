import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Botin 头像（docs/ios-ui-redesign.md 2.4、4.4.4、6.9）：按名字取色稳定、12 种颜色都看得清、15 种形状不出界、读屏文字、
/// 各种尺寸、形状和角标都画得出来。
@MainActor
@Suite("实例头像")
struct InstanceAvatarTests {
    @Test("同一个名字永远是同一种颜色：跨进程、跨设备稳定（FNV-1a，不用 Hasher），不分大小写、不管首尾空白")
    func stablePaletteIndex() {
        // 期望值是在别处（Python）按同样的算法独立算出来的，散列改了这里会失败。
        #expect(InstanceAvatar.paletteIndex(for: "周报助手") == 4)
        #expect(InstanceAvatar.paletteIndex(for: "Hermes Agent") == 2)
        #expect(InstanceAvatar.paletteIndex(for: "OpenClaw") == 6)
        #expect(InstanceAvatar.paletteIndex(for: "日程") == 3)
        #expect(InstanceAvatar.paletteIndex(for: "Anthropic (Claude)") == 0)
        #expect(InstanceAvatar.paletteIndex(for: "") == 5)
        #expect(InstanceAvatar.paletteIndex(for: "Codex") == InstanceAvatar.paletteIndex(for: "  codex \n"))
        #expect(InstanceAvatar.colors(for: "周报助手").light == InstanceAvatar.palette[4].light)
        #expect(InstanceAvatar.colors(for: "周报助手").dark == InstanceAvatar.palette[4].dark)
    }

    @Test("不同的名字分得开")
    func namesSpreadAcrossPalette() {
        let names = [
            "周报助手", "Codex", "Hermes Agent", "OpenClaw", "Pi", "盯盘", "日程", "翻译", "Claude Agent",
            "Anthropic (Claude)", "DeepSeek",
        ]
        let indices = Set(names.map(InstanceAvatar.paletteIndex(for:)))
        #expect(indices.count >= 5)
        #expect(indices.allSatisfy { InstanceAvatar.palette.indices.contains($0) })
    }

    @Test("色板：12 种颜色白字看得清（对比度 4:1 以上），浅深各一套，不和强调色、状态色撞；按名字取的 8 种色值没变")
    func paletteIsReadable() {
        // 第 0 轮的 8 种（已有的 Botin 的颜色不能变）。
        #expect(InstanceAvatar.palette.count == 8)
        #expect(InstanceAvatar.palette[0].light == 0x3B6FB6 && InstanceAvatar.palette[7].dark == 0x9A7055)
        let palette = AvatarColor.allCases.map(InstanceAvatar.colors(of:))
        #expect(palette.count == 12)
        #expect(Set(palette.map { $0.light }).count == palette.count)
        #expect(Set(palette.map { $0.dark }).count == palette.count)
        let reserved: Set<HexColor> = Set(
            [ThemeToken.accent, .success, .warning, .danger].flatMap { [$0.light, $0.dark] })
        for colors in palette {
            #expect(colors.light != colors.dark)
            #expect(!reserved.contains(colors.light) && !reserved.contains(colors.dark))
            #expect(contrastWithWhite(colors.light) >= 4, "\(colors.light)")
            #expect(contrastWithWhite(colors.dark) >= 4, "\(colors.dark)")
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
            InstanceAvatar("", badge: .custom(StatusAppearance(tone: .success), accessibilityLabel: "在线")))
        for shape in AvatarShape.allCases {
            renderInBothAppearances(
                InstanceAvatar(
                    "周报助手", appearance: InstanceAppearance(shape: shape, color: .graphite), size: Metrics.Avatar.list,
                    badge: .instance(.running)))
        }
        for color in AvatarColor.allCases {
            renderInBothAppearances(InstanceAvatar("Pi", appearance: InstanceAppearance(color: color)))
        }
        // 名字是空的：占位符号（新建表单还没输入）。
        renderInBothAppearances(InstanceAvatar("  ", appearance: InstanceAppearance(shape: .cloud), size: 120))
    }

    /// WCAG 的对比度：白色和 `color` 的相对亮度之比。
    private func contrastWithWhite(_ color: HexColor) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        return 1.05 / (luminance + 0.05)
    }
}
