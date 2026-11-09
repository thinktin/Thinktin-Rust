import SwiftUI
import ThinktinKit

/// 首页的尺寸（参考 01、119、120 在 393pt 宽的屏上量的，1pt ≈ 1.525px）。
enum HomeLayout {
    /// 左右边距：和顶上两个 44pt 圆按钮的外沿对齐（`HomeTopBar`，用户 2026-11-06：头像要和左上角对齐）。
    static let edge: CGFloat = Metrics.Spacing.m
    /// 普通行：头像左边、时间右边都是 `edge`；一行约 83pt 高（44pt 头像上下各留 18pt 左右）。
    static let rowInsets = EdgeInsets(top: 18, leading: edge, bottom: 18, trailing: edge)
    /// 头像和文字之间。
    static let rowSpacing = Metrics.Spacing.m
    /// 置顶的大头像这一行：比普通行的头像往下约 18pt，名字下面留 20pt 再接普通行。
    static let pinnedInsets = EdgeInsets(top: 36, leading: edge, bottom: 20, trailing: edge)
    /// 置顶的一排最多几个（规范 4.2.1；参考只截到一个，多个时怎么排是推测的）。
    static let pinnedPerRow = 3
    /// 置顶的一格宽：80pt 头像两边各留 12pt，一排 3 个在最窄的 375pt 屏上（减去两边的 `edge`）也放得下。
    static let pinnedCellWidth: CGFloat = 104
    /// 长按预览卡的宽度（参考 32 约 321pt）。
    static let previewWidth: CGFloat = 320
    /// 预览卡里最后一条最多几行。
    static let previewLines = 8
}

/// 首页的一行（规范 docs/ios-ui-redesign.md 4.2.1，参考 01、119）：左边 44pt Botin 头像（新建时挑的形状和颜色，只有主 Botin
/// 右下角有星标），中间第一行名字、右边最后活动的时间，第二行最后一条（`HomeRow.previewText`，agent 写的前面是“AI 生成”
/// 标识，参考那个位置是个小图标）。在等你、在跑、暂停这些状态只在头像的脸上：在等你的睁大眼睛往上看、在跑的会动、暂停的闭眼
/// （`HomeRow.faceMood`）。以前的状态字、“你：”、警告色和状态角标 2026-11-06 照参考去掉了。外面由 `HomeInstanceList` 包
/// 按钮、长按菜单和左滑。
///
/// 读屏合成一句：“写作助手，主 Botin，2 个在等你处理，AI 生成，周报整理好了，14:05”（看得见的人看脸，读屏的人听这句）。
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
            HStack(spacing: HomeLayout.rowSpacing) {
                // 有任务在跑时脸是活的（用户 2026-11-06：“在会话列表里运行中也要随机展示动作”），在等你时睁大眼睛往上看、
                // 不动（2026-11-09：“不运行中的会话不用动”）。
                InstanceAvatar(
                    row.instance.name, appearance: appearance, size: Metrics.Avatar.list,
                    badge: isPrimary ? .primary : nil, mood: row.faceMood
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
                        if row.previewIsAIGenerated { AIGeneratedLabel() }
                        // 没缓存过最后一条时是空的，留一个空格占住这一行的高度（行高和别的行一样）。
                        Text(verbatim: row.previewText.isEmpty ? " " : row.previewText)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityText(time: time)))
        }
    }

    private func accessibilityText(time: String) -> String {
        var parts = [row.instance.name]
        if isPrimary { parts.append(ConversationText.primaryBotin(language)) }
        // 状态只在头像的脸上（头像对读屏隐藏）：念出来。
        if let status = row.preview.spokenStatus(language) { parts.append(status) }
        if row.previewIsAIGenerated { parts.append(language.aiGeneratedLabel) }
        if !row.previewText.isEmpty { parts.append(row.previewText) }
        parts.append(time)
        return parts.joined(separator: language == .chinese ? "，" : ", ")
    }
}

extension HomeRowPreview {
    /// 读屏念的状态（行上不写，看得见的人看头像的脸）：“2 个在等你处理”“运行中”“排队中 · 共 3 个”“已暂停”；
    /// Botin 开着、闲着的不念（没什么要说的）。
    func spokenStatus(_ language: DisplayLanguage) -> String? {
        let zh = language == .chinese
        switch self {
        case .waiting(let count, _):
            return zh ? "\(count) 个在等你处理" : "\(count) waiting for you"
        case .active(let count, let state):
            let name = state.localizedName(language)
            guard count > 1 else { return name }
            return zh ? "\(name) · 共 \(count) 个" : "\(name) · \(count) in progress"
        case .message(_, let state), .idle(let state):
            return state == .running ? nil : state.localizedName(language)
        }
    }
}

/// 长按一行时的预览卡（规范 4.2.2，参考 32）：上面小头像 + 名字，分隔线，下面是最后一条的气泡（agent 的在左边、带“AI 生成”
/// 标识，你发的在右边）；没缓存过消息时只有上面一块。以前名字下面的状态行 2026-11-06 照参考去掉了（脸照样会动）。
struct HomeInstancePreviewCard: View {
    let row: HomeRow
    var appearance: InstanceAppearance = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.Spacing.s) {
                InstanceAvatar(
                    row.instance.name, appearance: appearance, size: Metrics.Avatar.title + Metrics.Spacing.xxs,
                    mood: row.faceMood)
                Text(verbatim: row.instance.name)
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .padding(Metrics.Spacing.m)
            if let last = row.lastMessage {
                Divider()
                message(last)
                    .padding(Metrics.Spacing.m)
            }
        }
        .frame(width: HomeLayout.previewWidth, alignment: .leading)
        .background(Theme.paper)
    }

    private func message(_ last: HomeLastMessage) -> some View {
        let isAgent = last.author == .agent
        return VStack(alignment: isAgent ? .leading : .trailing, spacing: Metrics.Spacing.xs) {
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
            appearance: InstanceAppearance(shape: .flower, color: .purple))
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
