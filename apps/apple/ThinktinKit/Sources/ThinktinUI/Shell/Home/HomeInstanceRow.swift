import SwiftUI
import ThinktinKit

/// 首页的一行（规范 docs/ios-ui-redesign.md 4.2.1 第 0 轮的最小版）：左边 48pt Botin 头像（新建时挑的形状和颜色，
/// 右下角状态角标），中间第一行名字、
/// 右边最后活动的时间，第二行预览（在等你处理时用警告色）。外面由 `HomeScreen` 包 `NavigationLink(value: .conversation)`。
///
/// 读屏合成一句：“写作助手，2 个在等你处理，14:05”。
struct HomeInstanceRow: View {
    let row: HomeRow
    /// 头像的形状和颜色（`AppModel.appearances`）；默认的是圆形、按名字取色。
    var appearance: InstanceAppearance = .default

    @Environment(\.displayLanguage) private var language

    var body: some View {
        // 每分钟换一次时间（今天的显示几点几分，过了零点换成日期）。
        TimelineView(.everyMinute) { context in
            let time = HomeList.timestamp(row.lastActivityAt, now: context.date, language: language)
            let preview = row.preview.text(language)
            HStack(spacing: Metrics.Spacing.s) {
                InstanceAvatar(
                    row.instance.name, appearance: appearance, size: Metrics.Avatar.list,
                    badge: row.preview.avatarBadge
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                        Text(verbatim: row.instance.name)
                            .typography(.headline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: Metrics.Spacing.xs)
                        Text(verbatim: time)
                            .typography(.caption)
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                    Text(verbatim: preview)
                        .typography(.subheadline)
                        .foregroundStyle(row.needsAttention ? StatusTone.waiting.color : Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Metrics.Spacing.xxs)
            .frame(minHeight: Metrics.Avatar.list + Metrics.Spacing.xs)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(verbatim: [row.instance.name, preview, time].joined(separator: language == .chinese ? "，" : ", ")))
        }
    }
}

extension HomeRowPreview {
    /// 第二行的字：“2 个在等你处理”“运行中”“运行中 · 共 3 个”“随时可以接任务”“已暂停”。
    func text(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .waiting(let count, _):
            return zh ? "\(count) 个在等你处理" : "\(count) waiting for you"
        case .active(let count, let state):
            let name = state.localizedName(language)
            guard count > 1 else { return name }
            return zh ? "\(name) · 共 \(count) 个" : "\(name) · \(count) in progress"
        case .idle(let state):
            // 实例开着、没有进行中的运行：说“能接任务”，不说“运行中”（和运行的“运行中”分不清）。
            if state == .running { return zh ? "随时可以接任务" : "Ready for a task" }
            return state.localizedName(language)
        }
    }

    /// 头像右下角的角标：有运行时是那个运行的状态（在等你处理的是警告色，运行中会呼吸）；没有运行时是实例的状态，
    /// 开着、闲着的实例不画（没什么要说的）。
    var avatarBadge: InstanceAvatar.Badge? {
        switch self {
        case .waiting(_, let state), .active(_, let state): .run(state)
        case .idle(let state): state == .running ? nil : .instance(state)
        }
    }
}

#Preview("首页的行") {
    let now = Date()
    let instance = Instance(
        id: "preview", agentID: "claude", agentVersion: "1.0.0", harness: "claude-code", name: "写作助手",
        state: .running, createdAt: now.addingTimeInterval(-86_400), lastActiveAt: now.addingTimeInterval(-600))
    List {
        HomeInstanceRow(row: HomeRow(instance: instance, activity: .none))
        HomeInstanceRow(
            row: HomeRow(
                instance: instance,
                activity: InstanceActivity(
                    activeRuns: 2, waitingRuns: 1, latestRunState: .running, latestRunAt: now,
                    latestWaitingState: .waitingApproval)))
        HomeInstanceRow(
            row: HomeRow(
                instance: instance,
                activity: InstanceActivity(activeRuns: 3, latestRunState: .running, latestRunAt: now)),
            appearance: InstanceAppearance(shape: .flower, color: .orchid))
    }
    .listStyle(.plain)
}
