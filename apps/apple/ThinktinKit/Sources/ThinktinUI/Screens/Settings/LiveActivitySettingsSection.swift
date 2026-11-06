import SwiftUI
import ThinktinKit

/// 设置里实时活动的两行开关（WBS 12.10）：自己发的任务显示在锁屏上（默认开）、计划运行时也显示（默认关，打开才把推送
/// 开启令牌报给服务端）。只在支持实时活动的设备上有（`AppModel.liveActivities` 不为 nil）。改版后是设置根页“Botin”组里
/// 审批后面的两行（参考 53 那组里的“自动设置时区”开关），说明（`LiveActivityText.footer`）是那组的脚注；没有单独的组和标题。
/// 系统关掉了实时活动时前面多一行灰字。
struct LiveActivitySettingsRows: View {
    let model: LiveActivityModel
    @Environment(\.displayLanguage) private var language

    var body: some View {
        if model.isSystemDisabled {
            Text(LiveActivityText.systemDisabled(language))
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        }
        Toggle(
            LiveActivityText.myRuns(language),
            isOn: Binding(get: { model.showsMyRuns }, set: { model.showsMyRuns = $0 }))
        Toggle(
            LiveActivityText.scheduledRuns(language),
            isOn: Binding(
                get: { model.showsScheduledRuns },
                set: { on in Task { await model.setShowsScheduledRuns(on) } }))
    }
}

/// 运行页上的“在锁屏上显示”（WBS 12.10）：根运行、没结束、还没开时能点；开着时显示“已在锁屏上显示”。
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
