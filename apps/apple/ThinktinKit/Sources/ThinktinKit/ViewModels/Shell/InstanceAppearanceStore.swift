import Foundation
import Observation

// Botin 的头像外观：形状 + 颜色（规范 docs/ios-ui-redesign.md 4.4.4、4.7.1、6.9）。服务端还没有头像字段，先只存在这台
// 设备上（`InstanceAppearanceStore`，6.9 A）；换手机、在安卓上看到的还是按名字取色的圆。后端加了字段（6.9 B）以后
// 从实例上读，这里的存储当本机缓存或者删掉。

/// 头像的形状（新建表单的形状网格，3 行 × 5 个，按 `allCases` 的顺序排）。都是自己设计的简单几何、有机形状，
/// 上面画一张会眨眼、往四处看的脸（两只眼睛，节奏在 `BotinFaceLife`）；画法在 ThinktinUI 的 `AvatarShapePath`、`BotinFace`。
/// 原始值存进 `UserDefaults`，不能改。
public enum AvatarShape: String, CaseIterable, Codable, Hashable, Sendable {
    case circle, squircle, arch, hexagon, octagon
    case diamond, triangle, shield, leaf, pebble
    case sparkle, star, flower, scallop, cloud

    /// 读屏念的名字。
    public func localizedName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .circle: return zh ? "圆形" : "Circle"
        case .squircle: return zh ? "圆角方形" : "Squircle"
        case .arch: return zh ? "拱形" : "Arch"
        case .hexagon: return zh ? "六边形" : "Hexagon"
        case .octagon: return zh ? "八边形" : "Octagon"
        case .diamond: return zh ? "菱形" : "Diamond"
        case .triangle: return zh ? "三角形" : "Triangle"
        case .shield: return zh ? "盾牌" : "Shield"
        case .leaf: return zh ? "叶子" : "Leaf"
        case .pebble: return zh ? "鹅卵石" : "Pebble"
        case .sparkle: return zh ? "四角星" : "Sparkle"
        case .star: return zh ? "五角星" : "Star"
        case .flower: return zh ? "花朵" : "Flower"
        case .scallop: return zh ? "花边圆" : "Scallop"
        case .cloud: return zh ? "云朵" : "Cloud"
        }
    }
}

/// 头像的颜色（新建表单的色板，2 行 × 6 个，按 `allCases` 的顺序排）。色值在 ThinktinUI 的 `InstanceAvatar.colors(of:)`
/// （浅色、深色各一套，白字对比度 4:1 以上，避开强调色和状态色）。原始值存进 `UserDefaults`，不能改。
public enum AvatarColor: String, CaseIterable, Codable, Hashable, Sendable {
    case teal, lake, blue, navy, indigo, purple
    case orchid, pink, brown, taupe, slate, graphite

    /// 没选颜色时按名字取色用的色板：第 0 轮 `InstanceAvatar` 的 8 种，**顺序不能改**（名字的散列按下标取，换了顺序
    /// 已有的 Botin 会变色）。
    public static let nameHashed: [AvatarColor] = [.blue, .indigo, .purple, .pink, .teal, .lake, .slate, .brown]

    /// 名字在 `nameHashed` 里的下标：名字去掉首尾空白、转小写后的 FNV-1a 散列（32 位，跨进程、跨设备稳定；不用
    /// `Hasher`，它每次启动的种子不一样）。
    public static func nameHashIndex(for name: String) -> Int {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt32 = 0x811C_9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % UInt32(nameHashed.count))
    }

    /// 按名字取的颜色（没选过颜色的 Botin、厂商、引擎都是它）。
    public static func forName(_ name: String) -> AvatarColor {
        nameHashed[nameHashIndex(for: name)]
    }

    /// 读屏念的名字。
    public func localizedName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .teal: return zh ? "青绿" : "Teal"
        case .lake: return zh ? "湖蓝" : "Lake blue"
        case .blue: return zh ? "蓝色" : "Blue"
        case .navy: return zh ? "藏青" : "Navy"
        case .indigo: return zh ? "靛蓝" : "Indigo"
        case .purple: return zh ? "紫色" : "Purple"
        case .orchid: return zh ? "兰紫" : "Orchid"
        case .pink: return zh ? "粉色" : "Pink"
        case .brown: return zh ? "棕色" : "Brown"
        case .taupe: return zh ? "灰褐" : "Taupe"
        case .slate: return zh ? "石板灰" : "Slate"
        case .graphite: return zh ? "石墨灰" : "Graphite"
        }
    }
}

/// 一个 Botin 的头像外观。`color` 为 nil 时按名字取色（改了名颜色跟着变，和没选过的 Botin 一样）。
public struct InstanceAppearance: Codable, Hashable, Sendable {
    public var shape: AvatarShape
    public var color: AvatarColor?

    /// 没选过：圆形、按名字取色（和第 0 轮的头像同样的形状和颜色）。
    public static let `default` = InstanceAppearance()

    public init(shape: AvatarShape = .circle, color: AvatarColor? = nil) {
        self.shape = shape
        self.color = color
    }

    /// 和没选过一样（不用存）。
    public var isDefault: Bool { self == .default }

    /// 实际画的颜色：选了的，没选按名字取。
    public func resolvedColor(name: String) -> AvatarColor {
        color ?? AvatarColor.forName(name)
    }

    private enum CodingKeys: String, CodingKey {
        case shape, color
    }

    /// 宽松地读：认不出的形状（以后的版本加的）当圆形，认不出的颜色当没选（按名字取），不让一条坏记录拖垮整张表。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shape = try container.decodeIfPresent(String.self, forKey: .shape)
        let color = try container.decodeIfPresent(String.self, forKey: .color)
        self.shape = shape.flatMap(AvatarShape.init(rawValue:)) ?? .circle
        self.color = color.flatMap(AvatarColor.init(rawValue:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shape.rawValue, forKey: .shape)
        try container.encodeIfPresent(color?.rawValue, forKey: .color)
    }
}

/// 这台设备上记的 Botin 头像外观（按实例 id），新建表单建好之后写（`AdoptionModel.adopt()`）；首页的行、搜索结果、
/// 对话页的标题、Botin 资料按它画头像，没有记录的是 `InstanceAppearance.default`（圆形、按名字取色）。
///
/// 存在 `UserDefaults` 里（一个键，JSON：`{实例 id: {shape, color}}`），只是本机的显示偏好，不上传。退出登录不清
/// （同一个账号再登录时还在，别的账号的实例 id 对不上，用不到）；删了 Botin、注销账号时删掉对应的记录（`forget(_:)`，
/// 由 `BotinLocalData` 调）。以后的版本加的形状、颜色这个版本认不出：画的时候当圆形、当没选，存回去时原样留着
/// （装回旧版本再新建一个 Botin 不会把它们抹掉），只有那个 Botin 自己改外观或删掉时才换掉。`defaults` 为 nil 时只记在内存里
/// （测试、预览）。
@Observable @MainActor
public final class InstanceAppearanceStore {
    static let storageKey = "cn.thinktin.shell.instanceAppearance"

    /// 记下的外观（不含默认的）。
    public private(set) var appearances: [InstanceID: InstanceAppearance]

    /// 存着的记录里形状或颜色这个版本认不出的那些（按实例 id 的原始值），存回去时原样写回。
    @ObservationIgnored private var unrecognized: [String: StoredAppearance]
    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults)
        self.appearances = stored.appearances
        self.unrecognized = stored.unrecognized
    }

    /// 这个 Botin 记下的外观；没记过为 nil。
    public func appearance(for id: InstanceID) -> InstanceAppearance? {
        appearances[id]
    }

    /// 画头像用的：记下的，没记过是默认的（圆形、按名字取色）。
    public func resolved(for id: InstanceID) -> InstanceAppearance {
        appearances[id] ?? .default
    }

    /// 记下外观（这个 Botin 原来存着的、认不出的值一起换掉）。nil 或默认的外观删掉记录（和没记过一样画）。
    public func set(_ appearance: InstanceAppearance?, for id: InstanceID) {
        guard let appearance, !appearance.isDefault else {
            forget([id])
            return
        }
        let hadUnrecognized = unrecognized.removeValue(forKey: id.rawValue) != nil
        guard appearances[id] != appearance || hadUnrecognized else { return }
        appearances[id] = appearance
        save()
    }

    /// 删掉这些 Botin 的记录（删了 Botin、注销账号）。
    public func forget(_ ids: [InstanceID]) {
        var changed = false
        for id in ids {
            if appearances.removeValue(forKey: id) != nil { changed = true }
            if unrecognized.removeValue(forKey: id.rawValue) != nil { changed = true }
        }
        if changed { save() }
    }

    private func save() {
        guard let defaults else { return }
        var table = unrecognized
        for (id, appearance) in appearances where table[id.rawValue] == nil {
            table[id.rawValue] = StoredAppearance(appearance)
        }
        if table.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// 读出来的表：坏了（不是 JSON）就当没有；默认的外观不留（以前的版本可能写过），认不出的值另外记下、原样存回去。
    private static func load(
        from defaults: UserDefaults?
    ) -> (appearances: [InstanceID: InstanceAppearance], unrecognized: [String: StoredAppearance]) {
        guard let data = defaults?.data(forKey: storageKey),
            let table = try? JSONDecoder().decode([String: StoredAppearance].self, from: data)
        else { return ([:], [:]) }
        var appearances: [InstanceID: InstanceAppearance] = [:]
        var unrecognized: [String: StoredAppearance] = [:]
        for (key, record) in table where !key.isEmpty {
            let appearance = record.appearance
            if !appearance.isDefault { appearances[InstanceID(key)] = appearance }
            if record.hasUnrecognizedValues { unrecognized[key] = record }
        }
        return (appearances, unrecognized)
    }
}

/// `UserDefaults` 里的一条记录：形状、颜色的原始值原样留着（以后的版本加的这个版本也不丢）。
private struct StoredAppearance: Codable, Hashable, Sendable {
    var shape: String?
    var color: String?

    init(_ appearance: InstanceAppearance) {
        shape = appearance.shape.rawValue
        color = appearance.color?.rawValue
    }

    /// 画的时候用的：认不出的形状当圆形，认不出的颜色当没选（同 `InstanceAppearance` 的宽松解码）。
    var appearance: InstanceAppearance {
        InstanceAppearance(
            shape: shape.flatMap(AvatarShape.init(rawValue:)) ?? .circle,
            color: color.flatMap(AvatarColor.init(rawValue:)))
    }

    /// 有这个版本认不出的形状或颜色。
    var hasUnrecognizedValues: Bool {
        (shape.map { AvatarShape(rawValue: $0) == nil } ?? false)
            || (color.map { AvatarColor(rawValue: $0) == nil } ?? false)
    }
}
