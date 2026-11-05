import Foundation
import Observation

/// 这台设备上记的首页偏好：哪些 Botin 置顶（按置顶的先后）、哪些隐藏（规范 docs/ios-ui-redesign.md 4.2.1–4.2.3、6.10 A）。
/// 服务端没有对应的字段，只存在这台设备上，别的设备、安卓上看不到。
///
/// - 置顶和隐藏互斥：隐藏时顺带取消置顶，置顶时顺带取消隐藏。
/// - 隐藏只是首页不显示：计划照常跑、审批和推送照常来，搜索、深链照样能打开它。
/// - 和头像外观（`InstanceAppearanceStore`）一样按实例 id 记、不分账号：退出登录不清（同一个账号再登录时还在，
///   别的账号的实例 id 对不上，用不到）；删掉 Botin 时（`forget(_:)`）删掉它的记录。
/// - 存在 `UserDefaults` 的一个键里（JSON：`{"pinned": [id…], "hidden": [id…]}`）；`defaults` 为 nil 时只记在内存里
///   （测试、预览）。
@Observable @MainActor
public final class InstancePreferencesStore {
    static let storageKey = "cn.thinktin.shell.instancePreferences"

    /// 置顶的 Botin，先置顶的在前（首页顶上的大头像按这个顺序排）。
    public private(set) var pinned: [InstanceID]
    /// 隐藏的 Botin（首页不显示，在“已隐藏的 Botin”里）。
    public private(set) var hidden: Set<InstanceID>

    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults)
        self.pinned = stored.pinned
        self.hidden = stored.hidden
    }

    public func isPinned(_ id: InstanceID) -> Bool {
        pinned.contains(id)
    }

    public func isHidden(_ id: InstanceID) -> Bool {
        hidden.contains(id)
    }

    /// 置顶（排到置顶的最后，同时取消隐藏）或取消置顶。
    public func setPinned(_ isPinned: Bool, for id: InstanceID) {
        var pinned = self.pinned
        var hidden = self.hidden
        if isPinned {
            if !pinned.contains(id) { pinned.append(id) }
            hidden.remove(id)
        } else {
            pinned.removeAll { $0 == id }
        }
        update(pinned: pinned, hidden: hidden)
    }

    /// 隐藏（同时取消置顶）或取消隐藏（回到首页的普通行）。
    public func setHidden(_ isHidden: Bool, for id: InstanceID) {
        var pinned = self.pinned
        var hidden = self.hidden
        if isHidden {
            hidden.insert(id)
            pinned.removeAll { $0 == id }
        } else {
            hidden.remove(id)
        }
        update(pinned: pinned, hidden: hidden)
    }

    /// 删掉这些 Botin 的记录（删了 Botin、它在服务端没了）。
    public func forget(_ ids: [InstanceID]) {
        let gone = Set(ids)
        update(pinned: pinned.filter { !gone.contains($0) }, hidden: hidden.subtracting(gone))
    }

    /// 有变化才换上、才写盘（不触发没必要的界面刷新）。
    private func update(pinned: [InstanceID], hidden: Set<InstanceID>) {
        guard pinned != self.pinned || hidden != self.hidden else { return }
        if pinned != self.pinned { self.pinned = pinned }
        if hidden != self.hidden { self.hidden = hidden }
        save()
    }

    private func save() {
        guard let defaults else { return }
        if pinned.isEmpty, hidden.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        // 隐藏的按 id 排好再存：同样的内容写出同样的字节。
        let stored = StoredPreferences(
            pinned: pinned.map(\.rawValue), hidden: hidden.map(\.rawValue).sorted())
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// 读出来的偏好：坏了（不是 JSON）就当没有；空的 id、重复的去掉；又置顶又隐藏的（不该有）按隐藏算。
    private static func load(from defaults: UserDefaults?) -> (pinned: [InstanceID], hidden: Set<InstanceID>) {
        guard let data = defaults?.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode(StoredPreferences.self, from: data)
        else { return ([], []) }
        let hidden = Set(stored.hidden.filter { !$0.isEmpty }.map(InstanceID.init(rawValue:)))
        var pinned: [InstanceID] = []
        for raw in stored.pinned where !raw.isEmpty {
            let id = InstanceID(rawValue: raw)
            if !hidden.contains(id), !pinned.contains(id) { pinned.append(id) }
        }
        return (pinned, hidden)
    }
}

/// `UserDefaults` 里的记录。缺了哪一项当空的。
private struct StoredPreferences: Codable, Hashable, Sendable {
    var pinned: [String]
    var hidden: [String]

    init(pinned: [String], hidden: [String]) {
        self.pinned = pinned
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case pinned, hidden
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
    }
}
