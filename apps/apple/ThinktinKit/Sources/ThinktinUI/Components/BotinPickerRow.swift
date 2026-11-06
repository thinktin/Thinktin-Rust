import SwiftUI
import ThinktinKit

/// 选 Botin 的 sheet 里的一行（参考 11 的版式；规范 4.4.5）：40pt 头像（右下状态角标，主 Botin 是星标）、`.headline` 名字、
/// 下面一行 `.subheadline` 灰字（状态）。选择主 Botin（`PrimaryBotinPickerScreen`，系统 `Picker(.inline)` 自己画勾）和新任务
/// （`NewTaskSheet`，行尾自己放勾）共用，两处的行长得一样。只是内容，不画底、不画勾。
struct BotinPickerRow: View {
    let name: String
    let appearance: InstanceAppearance
    let badge: InstanceAvatar.Badge?
    /// 头像的脸此刻的状态（`AppModel.faceMood(for:)`，有任务在跑时是活的）；nil 时从角标推。
    var mood: BotinFaceMood?
    let detail: String

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            InstanceAvatar(name, appearance: appearance, size: Metrics.Avatar.search, badge: badge, mood: mood)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(verbatim: name)
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
