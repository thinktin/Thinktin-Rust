import SwiftUI
import ThinktinKit

/// 实例、agent、模型厂商的头像（docs/ios-ui-redesign.md 2.4、4.4.4，用户定了 6.9 的建议 C）：圆里放名字的第一个字，
/// 底色按名字算出来（同一个名字在哪儿都是同一种颜色，实例之间好区分），右下角可以叠一个状态角标。
/// 不用 agent 的标志和图标（docs/licenses.md 第 6 节的商标要求）。后端加了头像字段（形状 + 颜色）以后在这里接。
///
/// 读屏把它当一张图念“名字，状态”。旁边已经写着名字的（列表的行），调用方给它加 `.accessibilityHidden(true)`，
/// 或者把整行合成一句。
///
/// ```swift
/// InstanceAvatar(instance.name, size: Metrics.Avatar.list, badge: .instance(instance.state))
/// ```
public struct InstanceAvatar: View {
    /// 右下角的状态角标。
    public enum Badge: Hashable, Sendable {
        /// 实例的状态（运行中会呼吸，已归档是空心）。
        case instance(InstanceState)
        /// 一次运行的状态（首页“有运行在等你处理”用 `.run(.waitingApproval)` 这类等待状态，警告色）。
        case run(RunState)
        /// 别的状态：直接给样子和读屏文字。
        case custom(StatusAppearance, accessibilityLabel: String)
    }

    private let name: String
    private let badge: Badge?
    /// 直径，跟着动态字体缩放。
    @ScaledMetric private var size: CGFloat

    @Environment(\.displayLanguage) private var language

    /// - Parameters:
    ///   - name: 实例、agent 或厂商的名字：头像上的字和底色都按它算。
    ///   - size: 直径，常用的在 `Metrics.Avatar`（列表 48、资料页 120……），跟着动态字体缩放。
    ///   - badge: 右下角的状态角标；nil 不画。
    public init(_ name: String, size: CGFloat = Metrics.Avatar.search, badge: Badge? = nil) {
        self.name = name
        self.badge = badge
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    public var body: some View {
        let colors = Self.colors(for: name)
        Text(verbatim: AgentsText.monogram(of: name))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(Color(light: colors.light, dark: colors.dark), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    badgeDot(badge)
                        .padding(max(1.5, size * 0.04))
                        .background(Theme.paper, in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.accessibilityText(name: name, badge: badge, language: language)))
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func badgeDot(_ badge: Badge) -> some View {
        let diameter = max(Metrics.statusDot, size * 0.24)
        switch badge {
        case .instance(let state): StatusDot(state, size: diameter)
        case .run(let state): StatusDot(state, size: diameter)
        case .custom(let appearance, let label): StatusDot(appearance, accessibilityLabel: label, size: diameter)
        }
    }
}

// MARK: - 按名字取色、读屏文字（纯函数，测试直接调）

extension InstanceAvatar {
    /// 头像的底色：一套浅色、一套深色，白字放在上面对比度都在 4:1 以上。避开强调色和状态色（成功绿、警告黄、失败红），
    /// 免得头像看着像状态。
    static let palette: [(light: HexColor, dark: HexColor)] = [
        (0x3B6FB6, 0x4A7FC4),  // 蓝
        (0x5856B8, 0x6866C6),  // 靛
        (0x8452B0, 0x9462BE),  // 紫
        (0xB24A7E, 0xC05A8C),  // 粉
        (0x2B7E85, 0x358A91),  // 青绿
        (0x1F7A99, 0x2C87A6),  // 湖蓝
        (0x5B6878, 0x6A7787),  // 石板灰
        (0x8B6247, 0x9A7055),  // 棕
    ]

    /// 名字对应的色板下标：名字去掉首尾空白、转小写后的 FNV-1a 散列（32 位，跨进程、跨设备稳定；不用 `Hasher`，
    /// 它每次启动的种子不一样）。
    static func paletteIndex(for name: String) -> Int {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt32 = 0x811C_9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % UInt32(palette.count))
    }

    /// 名字对应的底色。
    static func colors(for name: String) -> (light: HexColor, dark: HexColor) {
        palette[paletteIndex(for: name)]
    }

    /// 读屏念的：“周报助手，运行中”“Weekly report, Running”；没有角标时只念名字，名字是空的念“未命名”。
    static func accessibilityText(name: String, badge: Badge?, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? (zh ? "未命名" : "Untitled") : trimmed
        guard let badge else { return title }
        let status =
            switch badge {
            case .instance(let state): state.localizedName(language)
            case .run(let state): state.localizedName(language)
            case .custom(_, let label): label
            }
        return title + (zh ? "，" : ", ") + status
    }
}

#Preview("实例头像") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(["周报助手", "Codex", "Hermes Agent", "OpenClaw", "Pi", "盯盘", "日程", "翻译"], id: \.self) { name in
                InstanceAvatar(name)
            }
        }
        HStack(alignment: .bottom, spacing: Metrics.Spacing.m) {
            InstanceAvatar("周报助手", size: Metrics.Avatar.title)
            InstanceAvatar("周报助手", size: Metrics.Avatar.list, badge: .instance(.running))
            InstanceAvatar("Codex", size: Metrics.Avatar.list, badge: .run(.waitingApproval))
            InstanceAvatar("OpenClaw", size: Metrics.Avatar.pinned, badge: .instance(.archived))
        }
        InstanceAvatar("翻译", size: Metrics.Avatar.profile, badge: .instance(.paused))
    }
    .padding()
    .background(Theme.paper)
}
