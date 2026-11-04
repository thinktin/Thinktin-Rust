import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 实例头像（docs/ios-ui-redesign.md 2.4、6.9 C）：按名字取色稳定、颜色看得清、读屏文字、各种尺寸和角标都画得出来。
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

    @Test("色板：白字看得清（对比度 4:1 以上），浅深各一套，不和强调色、状态色撞")
    func paletteIsReadable() {
        let palette = InstanceAvatar.palette
        #expect(palette.count == 8)
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
    }

    /// WCAG 的对比度：白色和 `color` 的相对亮度之比。
    private func contrastWithWhite(_ color: HexColor) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        return 1.05 / (luminance + 0.05)
    }
}
