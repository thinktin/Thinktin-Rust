import SwiftUI
import ThinktinKit

/// 首页的尺寸（参考 01、119、120 在 393pt 宽的屏上量的，1pt ≈ 1.525px）。
enum HomeLayout {
    /// 普通行：头像左边 22pt、时间右边 24pt；一行约 83pt 高（44pt 头像上下各留 18pt 左右）。
    static let rowInsets = EdgeInsets(top: 18, leading: 22, bottom: 18, trailing: 24)
    /// “等你处理”提示行（参考没有）：左右和普通行对齐，上下留得少一点。
    static let hintInsets = EdgeInsets(top: 8, leading: 22, bottom: 4, trailing: 24)
    /// 头像和文字之间。
    static let rowSpacing = Metrics.Spacing.m
    /// 置顶的大头像这一行：比普通行的头像往下约 18pt，名字下面留 20pt 再接普通行。
    static let pinnedInsets = EdgeInsets(top: 36, leading: 22, bottom: 20, trailing: 22)
    /// 置顶的一排最多几个（规范 4.2.1；参考只截到一个，多个时怎么排是推测的）。
    static let pinnedPerRow = 3
    /// 置顶的一格宽：80pt 头像两边各留 12pt，一排 3 个在最窄的 375pt 屏上（减去两边 22pt）也放得下。
    static let pinnedCellWidth: CGFloat = 104
    /// 长按预览卡的宽度（参考 32 约 321pt）。
    static let previewWidth: CGFloat = 320
    /// 预览卡里最后一条最多几行。
    static let previewLines = 8
}

/// 首页的一行（规范 docs/ios-ui-redesign.md 4.2.1，参考 01、119）：左边 44pt Botin 头像（新建时挑的形状和颜色，
/// 右下角状态角标；没有状态角标的主 Botin 是星标），中间第一行名字、右边最后活动的时间，第二行预览（在等你处理时用
/// 警告色；agent 写的摘要前面是“AI 生成”标识，你发的任务前面是“你：”）。外面由 `HomeInstanceList` 包按钮、长按菜单和左滑。
///
/// 读屏合成一句：“写作助手，主 Botin，2 个在等你处理，14:05”。
struct HomeInstanceRow: View {
    let row: HomeRow
    /// 头像的形状和颜色（`AppModel.appearances`）；默认的是圆形、按名字取色。
    var appearance: InstanceAppearance = .default
    /// 是不是主 Botin（`AppModel.local.primary`，参考 01 的星标）。
    var isPrimary = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        // 每分钟换一次时间（今天的显示几点几分，过了零点换成日期）。
        TimelineView(.everyMinute) { context in
            let time = HomeList.timestamp(row.lastActivityAt, now: context.date, language: language)
            let preview = row.preview.text(language)
            HStack(spacing: HomeLayout.rowSpacing) {
                InstanceAvatar(
                    row.instance.name, appearance: appearance, size: Metrics.Avatar.list,
                    badge: row.preview.avatarBadge(isPrimary: isPrimary)
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
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
                    HStack(spacing: Metrics.Spacing.xs) {
                        // 参考的预览前面有个小图标；ThinkTin 这里放“AI 生成”标识（摘要是 agent 写的，要显式标出来）。
                        if row.preview.isAIGenerated { AIGeneratedLabel() }
                        Text(verbatim: preview)
                            .typography(.subheadline)
                            .foregroundStyle(row.needsAttention ? StatusTone.waiting.color : Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityText(preview: preview, time: time)))
        }
    }

    private func accessibilityText(preview: String, time: String) -> String {
        var parts = [row.instance.name]
        if isPrimary { parts.append(ConversationText.primaryBotin(language)) }
        // 预览是最后一条时，暂停、归档只画在头像角标上（头像对读屏隐藏）：念出来。
        if let state = row.preview.spokenState(language) { parts.append(state) }
        if row.preview.isAIGenerated { parts.append(language.aiGeneratedLabel) }
        parts += [preview, time]
        return parts.joined(separator: language == .chinese ? "，" : ", ")
    }
}

extension HomeRowPreview {
    /// 第二行的字：“2 个在等你处理”“运行中”“运行中 · 共 3 个”、最后一条（单行）、“随时可以接任务”“已暂停”。
    func text(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .waiting(let count, _):
            return zh ? "\(count) 个在等你处理" : "\(count) waiting for you"
        case .active(let count, let state):
            let name = state.localizedName(language)
            guard count > 1 else { return name }
            return zh ? "\(name) · 共 \(count) 个" : "\(name) · \(count) in progress"
        case .message(let message, _):
            switch message.author {
            case .agent: return message.singleLine
            case .user: return HomeText.youPrefix(language) + message.singleLine
            }
        case .idle(let state):
            // 实例开着、没有进行中的运行：说“能接任务”，不说“运行中”（和运行的“运行中”分不清）。
            if state == .running { return zh ? "随时可以接任务" : "Ready for a task" }
            return state.localizedName(language)
        }
    }

    /// 读屏要另外念的 Botin 状态：预览是最后一条、Botin 不是开着的（暂停、归档、休眠……）时，状态只画在头像角标上，
    /// 看得见的人看得到，读屏的人听不到，所以名字后面念一下。别的预览自己就写着状态，不重复。
    func spokenState(_ language: DisplayLanguage) -> String? {
        guard case .message(_, let state) = self, state != .running else { return nil }
        return state.localizedName(language)
    }

    /// 预览是 agent 写的摘要：前面放“AI 生成”标识。
    var isAIGenerated: Bool {
        if case .message(let message, _) = self { return message.author == .agent }
        return false
    }

    /// 头像右下角的角标：有运行时是那个运行的状态（在等你处理的是警告色，运行中会呼吸）；没有运行时是实例的状态，
    /// 开着、闲着的实例不画（没什么要说的）。
    var avatarBadge: InstanceAvatar.Badge? {
        switch self {
        case .waiting(_, let state), .active(_, let state): .run(state)
        case .idle(let state), .message(_, let state): state == .running ? nil : .instance(state)
        }
    }

    /// 头像角标，主 Botin 没有状态角标时是星标（参考 01）：在等你处理、进行中、暂停这些状态比“主”要紧，有就先画状态。
    func avatarBadge(isPrimary: Bool) -> InstanceAvatar.Badge? {
        avatarBadge ?? (isPrimary ? .primary : nil)
    }

    /// 长按预览卡名字下面的状态（在等你处理、进行中才有）。
    func statusLine(_ language: DisplayLanguage) -> String? {
        switch self {
        case .waiting, .active: text(language)
        case .message, .idle: nil
        }
    }
}

/// 长按一行时的预览卡（规范 4.2.2，参考 32）：上面小头像 + 名字（在等你处理、进行中时下面一行状态），分隔线，
/// 下面是最后一条的气泡（agent 的在左边、带“AI 生成”标识，你发的在右边）；没缓存过消息时是一行灰字状态。
struct HomeInstancePreviewCard: View {
    let row: HomeRow
    var appearance: InstanceAppearance = .default

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.Spacing.s) {
                InstanceAvatar(
                    row.instance.name, appearance: appearance, size: Metrics.Avatar.title + Metrics.Spacing.xxs)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(verbatim: row.instance.name)
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let status = row.preview.statusLine(language) {
                        Text(verbatim: status)
                            .typography(.footnote)
                            .foregroundStyle(row.needsAttention ? StatusTone.waiting.color : Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(Metrics.Spacing.m)
            Divider()
            message
                .padding(Metrics.Spacing.m)
        }
        .frame(width: HomeLayout.previewWidth, alignment: .leading)
        .background(Theme.paper)
    }

    @ViewBuilder
    private var message: some View {
        if let last = row.lastMessage {
            let isAgent = last.author == .agent
            VStack(alignment: isAgent ? .leading : .trailing, spacing: Metrics.Spacing.xs) {
                Text(verbatim: last.text)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(HomeLayout.previewLines)
                    .padding(.horizontal, Metrics.Spacing.m)
                    .padding(.vertical, Metrics.Spacing.s)
                    .background(
                        isAgent ? Theme.agentBubble : Theme.userBubble,
                        in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
                if isAgent { AIGeneratedLabel() }
            }
            .frame(maxWidth: .infinity, alignment: isAgent ? .leading : .trailing)
        } else {
            Text(verbatim: row.preview.text(language))
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

#Preview("首页的行") {
    let now = Date()
    let instance = Instance(
        id: "preview", agentID: "claude", agentVersion: "1.0.0", harness: "claude-code", name: "写作助手",
        state: .running, createdAt: now.addingTimeInterval(-86_400), lastActiveAt: now.addingTimeInterval(-600))
    let reply = HomeLastMessage(author: .agent, text: "这周的周报要点整理好了，按项目分了三组。", runID: "r1", at: now)
    List {
        HomeInstanceRow(row: HomeRow(instance: instance, activity: .none))
        HomeInstanceRow(row: HomeRow(instance: instance, activity: .none, lastMessage: reply))
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

#Preview("长按的预览卡") {
    let now = Date()
    let instance = Instance(
        id: "preview", agentID: "claude", agentVersion: "1.0.0", harness: "claude-code", name: "写作助手",
        state: .running, createdAt: now.addingTimeInterval(-86_400), lastActiveAt: now)
    let reply = HomeLastMessage(
        author: .agent, text: "这周的周报要点整理好了，按项目分了三组：事件流续传、缓存、设置页改版。", runID: "r1", at: now)
    HomeInstancePreviewCard(row: HomeRow(instance: instance, activity: .none, lastMessage: reply))
        .preferredColorScheme(.dark)
}
