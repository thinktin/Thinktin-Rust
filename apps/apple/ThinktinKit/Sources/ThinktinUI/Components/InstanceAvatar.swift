import SwiftUI
import ThinktinKit

/// Botin 的头像（docs/ios-ui-redesign.md 2.4、4.4.4、6.9）：形状上一张脸（`BotinFace`，两只眼睛挖空），右下角可以叠一个
/// 状态角标。脸只在有任务在跑时动（眨眼、往四处看、随机的小动作）；状态（`BotinFaceMood`）默认从角标推（`mood(for:)`），
/// 没画角标、但知道它在跑的地方（对话标题、资料页……）直接给 `mood`。形状和颜色是新建时挑的（`InstanceAppearance`，先只存在这台设备上，`AppModel.appearances`）；
/// 没挑过的是圆形，底色按名字算（同一个名字在哪儿都是同一种颜色）。引擎、模型厂商不用它：它们是圆角方块里放名字的首字
/// （`EngineIcon`、`CredentialVendorIcon`，画法是 `AvatarGlyph`）。不用 agent 的标志和图标（docs/licenses.md 第 6 节的商标要求）。
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
        /// 主 Botin（参考 01、10）：强调色的圆里一颗白星，比状态点大一点；读屏念“主 Botin”。
        case primary
    }

    private let name: String
    private let appearance: InstanceAppearance
    private let badge: Badge?
    private let mood: BotinFaceMood
    private let reactions: [BotinFaceReaction]
    /// 直径，跟着动态字体缩放。
    @ScaledMetric private var size: CGFloat

    @Environment(\.displayLanguage) private var language

    /// - Parameters:
    ///   - name: Botin 的名字：没选颜色时底色按它算，眨眼、转眼、小动作的节奏也按它定（每个 Botin 不一样，每次启动都一样）。
    ///   - appearance: 形状和颜色（`AppModel.appearances.resolved(for:)`）；nil 是圆形、按名字取色。
    ///   - size: 直径，常用的在 `Metrics.Avatar`（列表 48、资料页 120……），跟着动态字体缩放。
    ///   - badge: 右下角的状态角标；nil 不画。
    ///   - mood: 脸的状态（有任务在跑才动）；nil 时从角标推（`mood(for:)`），给了的为准（比如 `AppModel.faceMood(for:)`）。
    ///   - reactions: 用户点了头像时的反应（`BotinFaceReaction.adding`，调用方放在 `@State` 里）；平时是空的。
    public init(
        _ name: String, appearance: InstanceAppearance? = nil, size: CGFloat = Metrics.Avatar.search,
        badge: Badge? = nil, mood: BotinFaceMood? = nil, reactions: [BotinFaceReaction] = []
    ) {
        self.name = name
        self.appearance = appearance ?? .default
        self.badge = badge
        self.mood = mood ?? Self.mood(for: badge)
        self.reactions = reactions
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    public var body: some View {
        BotinFace(name: name, appearance: appearance, size: size, mood: mood, reactions: reactions)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    let inset = Self.badgeInset(
                        shape: appearance.shape, size: size, diameter: Self.badgeDiameter(size: size, badge: badge))
                    badgeDot(badge)
                        .padding(Self.badgeRing(size: size))
                        .background(Theme.paper, in: Circle())
                        .offset(x: -inset, y: -inset)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.accessibilityText(name: name, badge: badge, language: language)))
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func badgeDot(_ badge: Badge) -> some View {
        let diameter = Self.badgeDiameter(size: size, badge: badge)
        switch badge {
        case .instance(let state): StatusDot(state, size: diameter)
        case .run(let state): StatusDot(state, size: diameter)
        case .custom(let appearance, let label): StatusDot(appearance, accessibilityLabel: label, size: diameter)
        case .primary:
            Image(systemName: "star.fill")
                .font(.system(size: diameter * 0.55, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: diameter, height: diameter)
                .background(Theme.accent, in: Circle())
        }
    }
}

/// 首字头像：形状填上颜色，里面放名字的第一个字（名字是空的放一个中性的占位符号）。引擎、模型厂商的图标用
/// （`EngineIcon`、`CredentialVendorIcon`，圆角方形）；Botin 画脸（`BotinFace`），不用它。按给的边长画，不跟动态字体缩放。
/// 读屏由调用方处理。
struct AvatarGlyph: View {
    let name: String
    let appearance: InstanceAppearance
    let size: CGFloat

    var body: some View {
        let colors = InstanceAvatar.colors(of: appearance.resolvedColor(name: name))
        let layout = AvatarMonogramLayout(appearance.shape)
        monogram(layout)
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .offset(y: size * layout.verticalOffset)
            .frame(width: size, height: size)
            .background(Color(light: colors.light, dark: colors.dark), in: AvatarShapePath(shape: appearance.shape))
    }

    /// 名字的第一个字；名字是空的放一个中性的占位符号。
    @ViewBuilder
    private func monogram(_ layout: AvatarMonogramLayout) -> some View {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Image(systemName: "ellipsis")
                .font(.system(size: layout.fontSize(for: size) * 0.8, weight: .bold))
        } else {
            Text(verbatim: AgentsText.monogram(of: name))
                .font(.system(size: layout.fontSize(for: size), weight: .semibold))
        }
    }
}

// MARK: - 脸的状态、颜色、角标位置、读屏文字（纯函数，测试直接调）

extension InstanceAvatar {
    /// 角标对应的脸的状态（docs/ios-ui-redesign.md 4.4.4）：运行的状态按 `BotinFaceMood(run:)`（在跑的会动，等审批、
    /// 电脑、额度的睁大眼睛）；实例的状态按 `BotinFaceMood(instance:)`（暂停、归档、删除了闭着眼）；主 Botin 的星标、
    /// 别的角标、没有角标都是不动的 `resting`。
    nonisolated static func mood(for badge: Badge?) -> BotinFaceMood {
        switch badge {
        case .run(let state): BotinFaceMood(run: state)
        case .instance(let state): BotinFaceMood(instance: state)
        case .primary, .custom, nil: .resting
        }
    }

    /// 角标圆点的直径。
    nonisolated static func badgeDiameter(size: CGFloat) -> CGFloat {
        max(Metrics.statusDot, size * 0.24)
    }

    /// 这种角标的直径：主 Botin 的星标里有个符号，比状态点大一点（最小 14pt，参考 01、10 量的约 0.28 倍）。
    nonisolated static func badgeDiameter(size: CGFloat, badge: Badge) -> CGFloat {
        switch badge {
        case .primary: max(14, size * 0.28)
        case .instance, .run, .custom: badgeDiameter(size: size)
        }
    }

    /// 角标外面那圈纸色的环（把角标和头像的边分开）。
    nonisolated static func badgeRing(size: CGFloat) -> CGFloat {
        max(1.5, size * 0.04)
    }

    /// 角标从方框的右下角往左上挪多少：圆心落在形状右下方的轮廓上（`AvatarShapeGeometry.badgeAnchors`），四角星、叶子、
    /// 菱形这类右下角是空的，不挪就浮在形状外面；轮廓伸到角上的（圆形、圆角方形……）不挪，角标不出方框（和以前一样）。
    nonisolated static func badgeInset(shape: AvatarShape, size: CGFloat, diameter: CGFloat? = nil) -> CGFloat {
        let radius = (diameter ?? badgeDiameter(size: size)) / 2 + badgeRing(size: size)
        let anchor = (AvatarShapeGeometry.badgeAnchors[shape] ?? 1) * size
        return max(0, size - radius - anchor)
    }

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
            case .primary: ConversationText.primaryBotin(language)
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
            InstanceAvatar("周报助手", size: Metrics.Avatar.list, badge: .run(.running))
            InstanceAvatar("Codex", size: Metrics.Avatar.list, badge: .run(.waitingApproval))
            InstanceAvatar("OpenClaw", size: Metrics.Avatar.pinned, badge: .instance(.archived))
        }
        InstanceAvatar("翻译", size: Metrics.Avatar.profile, badge: .instance(.paused))
        InstanceAvatar("写作助手", size: Metrics.Avatar.profile, badge: .primary)
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
