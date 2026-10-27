import SwiftUI
import ThinktinKit

/// 设置里的“实时活动”一组（WBS 12.10）：自己发的任务显示在锁屏上（默认开）、计划运行时也显示（默认关，打开才把推送
/// 开启令牌报给服务端）。只在支持实时活动的设备上有（`AppModel.liveActivities` 不为 nil）。
struct LiveActivitySettingsSection: View {
    let model: LiveActivityModel
    @Environment(\.displayLanguage) private var language

    var body: some View {
        AccountSection(LiveActivityText.sectionTitle(language), footer: LiveActivityText.footer(language)) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                if model.isSystemDisabled {
                    Text(LiveActivityText.systemDisabled(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
                toggle(
                    LiveActivityText.myRuns(language),
                    isOn: Binding(get: { model.showsMyRuns }, set: { model.showsMyRuns = $0 }))
                toggle(
                    LiveActivityText.scheduledRuns(language),
                    isOn: Binding(
                        get: { model.showsScheduledRuns },
                        set: { on in Task { await model.setShowsScheduledRuns(on) } }))
            }
            .padding(Metrics.Spacing.m)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .typography(.body)
                .foregroundStyle(Theme.ink)
        }
        .tint(Theme.accent)
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
