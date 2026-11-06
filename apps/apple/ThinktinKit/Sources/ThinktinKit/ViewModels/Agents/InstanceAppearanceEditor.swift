import Foundation
import Observation

/// 建好之后改头像（编辑 Botin →“头像”，规范 4.4.4，参考 18）：和新建表单同一套形状网格和色板，“重置为默认”，右上“完成”
/// 记进这台设备的 `InstanceAppearanceStore`（服务端还没有头像字段，6.9 A）。
///
/// - 打开时从记下的外观开始（没记过是默认的：圆形、按名字取色）。
/// - 没挑过颜色时色板上带环的是按名字取的那个色（`resolvedColor`），和新建表单一样。
/// - “重置为默认”回到圆形、按名字取色；“完成”时默认的外观删掉记录（和没记过一样画）。
@Observable @MainActor
public final class InstanceAppearanceEditor {
    public let instanceID: InstanceID
    /// Botin 的名字：没选颜色时按它取色，预览的脸眨眼的节奏也按它定。
    public let name: String
    public var shape: AvatarShape
    /// 挑的颜色；nil 是按名字取。
    public var color: AvatarColor?

    /// 打开时的外观（判断有没有改过）。
    public let original: InstanceAppearance

    @ObservationIgnored private let store: InstanceAppearanceStore

    public init(instanceID: InstanceID, name: String, store: InstanceAppearanceStore) {
        self.instanceID = instanceID
        self.name = name
        self.store = store
        let current = store.resolved(for: instanceID)
        original = current
        shape = current.shape
        color = current.color
    }

    /// 现在挑的外观（预览、网格按它画）。
    public var appearance: InstanceAppearance { InstanceAppearance(shape: shape, color: color) }

    /// 色板上带环的颜色：挑过的，没挑过是按名字取的。
    public var resolvedColor: AvatarColor { appearance.resolvedColor(name: name) }

    /// 和打开时不一样了。
    public var hasChanges: Bool { appearance != original }

    /// 已经是默认的了（“重置为默认”灰掉）。
    public var isDefault: Bool { appearance.isDefault }

    /// 回到默认：圆形、按名字取色。
    public func reset() {
        shape = InstanceAppearance.default.shape
        color = InstanceAppearance.default.color
    }

    /// 记下（“完成”）：默认的删掉记录。
    public func save() {
        store.set(appearance, for: instanceID)
    }
}
