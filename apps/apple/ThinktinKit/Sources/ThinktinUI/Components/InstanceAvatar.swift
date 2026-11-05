import SwiftUI
import ThinktinKit

/// Botin、引擎、模型厂商的头像（docs/ios-ui-redesign.md 2.4、4.4.4、6.9）：形状里放名字的第一个字（名字是空的放一个
/// 中性的占位符号），右下角可以叠一个状态角标。Botin 的形状和颜色是新建时挑的（`InstanceAppearance`，先只存在这台
/// 设备上，`AppModel.appearances`）；没挑过的、引擎和厂商是圆形，底色按名字算（同一个名字在哪儿都是同一种颜色）。
/// 不用 agent 的标志和图标（docs/licenses.md 第 6 节的商标要求）。
///
/// 读屏把它当一张图念“名字，状态”。旁边已经写着名字的（列表的行），调用方给它加 `.accessibilityHidden(true)`，
/// 或者把整行合成一句。
///
/// ```swift
/// InstanceAvatar(
///     instance.name, appearance: app.appearances.resolved(for: instance.id), size: Metrics.Avatar.list,
///     badge: .instance(instance.state))
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
    private let appearance: InstanceAppearance
    private let badge: Badge?
    /// 直径，跟着动态字体缩放。
    @ScaledMetric private var size: CGFloat

    @Environment(\.displayLanguage) private var language

    /// - Parameters:
    ///   - name: Botin、引擎或厂商的名字：头像上的字按它取，没选颜色时底色也按它算。
    ///   - appearance: 形状和颜色（Botin 的，`AppModel.appearances.resolved(for:)`）；nil 是圆形、按名字取色。
    ///   - size: 直径，常用的在 `Metrics.Avatar`（列表 48、资料页 120……），跟着动态字体缩放。
    ///   - badge: 右下角的状态角标；nil 不画。
    public init(
        _ name: String, appearance: InstanceAppearance? = nil, size: CGFloat = Metrics.Avatar.search,
        badge: Badge? = nil
    ) {
        self.name = name
        self.appearance = appearance ?? .default
        self.badge = badge
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    public var body: some View {
        let colors = Self.colors(of: appearance.resolvedColor(name: name))
        let layout = AvatarMonogramLayout(appearance.shape)
        monogram(layout)
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .offset(y: size * layout.verticalOffset)
            .frame(width: size, height: size)
            .background(Color(light: colors.light, dark: colors.dark), in: AvatarShapePath(shape: appearance.shape))
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

    /// 名字的第一个字；名字是空的（新建表单还没输入）放一个中性的占位符号。
    @ViewBuilder
    private func monogram(_ layout: AvatarMonogramLayout) -> some View {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Image(systemName: "ellipsis")
                .font(.system(size: size * layout.textScale * 0.8, weight: .bold))
        } else {
            Text(verbatim: AgentsText.monogram(of: name))
                .font(.system(size: size * layout.textScale, weight: .semibold))
        }
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

// MARK: - 颜色、读屏文字（纯函数，测试直接调）

extension InstanceAvatar {
    /// 色板的色值（`AvatarColor`，12 种）：一套浅色、一套深色，白字放在上面对比度都在 4:1 以上。避开强调色和状态色
    /// （成功绿、警告黄、失败红），免得头像看着像状态；石板灰、石墨灰、灰褐是中性色。前 8 种（按名字取色用的，
    /// `AvatarColor.nameHashed`）是第 0 轮的那套，色值没变。
    nonisolated static func colors(of color: AvatarColor) -> (light: HexColor, dark: HexColor) {
        switch color {
        case .blue: (0x3B6FB6, 0x4A7FC4)
        case .indigo: (0x5856B8, 0x6866C6)
        case .purple: (0x8452B0, 0x9462BE)
        case .pink: (0xB24A7E, 0xC05A8C)
        case .teal: (0x2B7E85, 0x358A91)
        case .lake: (0x1F7A99, 0x2C87A6)
        case .slate: (0x5B6878, 0x6A7787)
        case .brown: (0x8B6247, 0x9A7055)
        case .navy: (0x2F4F86, 0x41639C)
        case .orchid: (0x9A4A9E, 0xA95AAD)
        case .taupe: (0x7A6A5C, 0x8A7A6C)
        case .graphite: (0x56575C, 0x6E6F75)
        }
    }

    /// 按名字取色的色板（`AvatarColor.nameHashed` 的色值，顺序不能改）。
    static let palette: [(light: HexColor, dark: HexColor)] = AvatarColor.nameHashed.map(colors(of:))

    /// 名字对应的色板下标（`AvatarColor.nameHashIndex`：FNV-1a，跨进程、跨设备稳定）。
    static func paletteIndex(for name: String) -> Int {
        AvatarColor.nameHashIndex(for: name)
    }

    /// 名字对应的底色（没选颜色时）。
    static func colors(for name: String) -> (light: HexColor, dark: HexColor) {
        colors(of: AvatarColor.forName(name))
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
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(AvatarShape.allCases, id: \.self) { shape in
                InstanceAvatar("翻译", appearance: InstanceAppearance(shape: shape, color: .navy), size: 32)
            }
        }
        InstanceAvatar("", size: Metrics.Avatar.profile)
    }
    .padding()
    .background(Theme.paper)
}
