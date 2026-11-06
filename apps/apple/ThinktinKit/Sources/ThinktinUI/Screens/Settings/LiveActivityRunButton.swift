import SwiftUI
import ThinktinKit

/// 运行页上的“在锁屏上显示”（WBS 12.10）：根运行、没结束、还没开时能点；开着时显示“已在锁屏上显示”。
/// 设置根页原来有实时活动的两个开关，照参考 53、70 删了（参考没有这一组），开关先按默认走（`LiveActivityModel`）。
struct LiveActivityRunButton: View {
    let model: LiveActivityModel
    let run: Run
    let title: String
    @Environment(\.displayLanguage) private var language
    @State private var failed = false

    var body: some View {
        if model.openRunIDs.contains(run.id) {
            Label(LiveActivityText.shownOnLockScreen(language), systemImage: "checkmark.circle")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        } else if model.canStart(run) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit) {
                Button {
                    Task { failed = !(await model.start(run, title: title)) }
                } label: {
                    Label(LiveActivityText.showOnLockScreen(language), systemImage: "lock.rectangle.on.rectangle")
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                if failed {
                    Text(LiveActivityText.couldNotStart(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }
}
