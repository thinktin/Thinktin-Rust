import SwiftUI
import ThinktinKit

// 计划管理（WBS 12.6）几个页面共用的小组件。名字都带 Plan / Plans 前缀，不和别的功能重名。
//
// 分组的卡片、行、小标题、提示、加载中、页面版式沿用 12.3 的 `GroupedSection`、`ListRow`、`SectionHeader`、
// `InlineNotice`、`LoadingStateView`、`pageLayout()`（同一个模块里的通用写法，不另造一套）。

extension PlanStatus {
    /// 状态的色调：待确认 `warning`，暂停 `inkTertiary`，规则失效 `danger`，按时运行 `accent`，不会再运行 `inkSecondary`。
    var tone: StatusTone {
        switch self {
        case .awaitingConfirmation: .waiting
        case .paused: .muted
        case .invalidRule: .failure
        case .scheduled: .active
        case .idle: .neutral
        }
    }
}

/// 计划的状态：状态点加状态名（读屏读状态名）。
struct PlanStatusLabel: View {
    let status: PlanStatus

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let name = status.localizedName(language)
        HStack(spacing: Metrics.Spacing.xxs) {
            StatusDot(StatusAppearance(tone: status.tone), accessibilityLabel: name)
                .accessibilityHidden(true)
            Text(name)
                .typography(.footnote)
                .foregroundStyle(status.tone.color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 数字角标（待确认的计划数）：状态色底、白字。
struct PlansCountBadge: View {
    let count: Int

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .typography(.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Metrics.Spacing.xs)
            .padding(.vertical, Metrics.Spacing.unit / 2)
            .background(StatusTone.waiting.color, in: Capsule())
            .accessibilityLabel(Text(language == .chinese ? "\(count) 个待确认" : "\(count) to review"))
    }
}

/// 筛选、单选用的胶囊按钮（全部、各个实例；规则的写法）。选中的用强调色描边。`count` 是后面的小数字（可以没有）。
struct PlansFilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: @MainActor () -> Void

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.xxs) {
                Text(title)
                    .lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.accent : Theme.inkTertiary)
                }
            }
            .typography(.subheadline)
            .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .background(isSelected ? Theme.paperElevated : Theme.paper, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Theme.accent : Theme.hairline,
                    lineWidth: isSelected ? 1 : Metrics.hairline(scale: displayScale))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 几个按钮排一行；字号很大时改成一列。
struct PlansButtonRow<Content: View>: View {
    private let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) { content }
        } else {
            HStack(spacing: Metrics.Spacing.xs) { content }
        }
    }
}

/// 计划的标题（agent 写的带 AI 生成标识）。
struct PlanTitleText: View {
    let plan: Plan
    var style: Typography = .headline

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(plan.title)
                .typography(style)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if PlansText.isAIGenerated(.title, in: plan) { AIGeneratedLabel() }
        }
    }
}

/// 列表里的一行：标题、规则摘要、状态 · 实例 · 下一次；右边的“更多”菜单里暂停 / 恢复、删除。
struct PlanListRow: View {
    let plan: Plan
    let instanceName: String
    let isBusy: Bool
    let canWrite: Bool
    let onOpen: @MainActor () -> Void
    let onSetPaused: @MainActor (Bool) -> Void
    let onDelete: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        HStack(alignment: .top, spacing: Metrics.Spacing.xs) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    PlanTitleText(plan: plan)
                    Text(PlansText.scheduleSummary(plan, language: language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PlanMetaLine(plan: plan, instanceName: instanceName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            if isBusy {
                ProgressView()
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            } else {
                Menu {
                    if plan.isPaused && !plan.awaitingConfirmation {
                        Button {
                            onSetPaused(false)
                        } label: {
                            Label(zh ? "恢复" : "Resume", systemImage: "play")
                        }
                        .disabled(!canWrite)
                    } else if !plan.awaitingConfirmation {
                        Button {
                            onSetPaused(true)
                        } label: {
                            Label(zh ? "暂停" : "Pause", systemImage: "pause")
                        }
                        .disabled(!canWrite)
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(zh ? "删除" : "Delete", systemImage: "trash")
                    }
                    .disabled(!canWrite)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(zh ? "“\(plan.title)”的更多操作" : "More for “\(plan.title)”"))
            }
        }
        .padding(.leading, Metrics.Spacing.m)
        .padding(.trailing, Metrics.Spacing.xxs)
        .padding(.vertical, Metrics.Spacing.s)
    }
}

/// 一行小字：状态 · 实例 · 下一次（按时运行的）。
struct PlanMetaLine: View {
    let plan: Plan
    let instanceName: String

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let status = plan.status
        TagChipRow {
            PlanStatusLabel(status: status)
            Text(instanceName)
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            if case .scheduled(let next) = status {
                Text(PlansText.nextFire(next, language: language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            if plan.hasInvalidTriggers && status != .invalidRule {
                Text(language == .chinese ? "有规则已失效" : "A rule is no longer valid")
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
            }
        }
    }
}

/// 一条触发规则：描述、状态（下一次 / 规则失效 / 已停用）、上一次；规则失效的给“修改规则”“删除”。
struct PlanTriggerRow: View {
    let trigger: Trigger
    let plan: Plan
    var canEdit = false
    var onFix: (@MainActor () -> Void)?
    var onDelete: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Label {
                Text(ScheduleDescription.describe(trigger.schedule, language: language))
                    .typography(.body)
                    .foregroundStyle(trigger.isEnabled ? Theme.ink : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: trigger.isInvalid ? "exclamationmark.triangle" : "clock")
                    .foregroundStyle(trigger.isInvalid ? StatusTone.failure.color : Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            Text(PlansText.triggerState(trigger, plan: plan, language: language))
                .typography(.subheadline)
                .foregroundStyle(trigger.isInvalid ? StatusTone.failure.color : Theme.inkSecondary)
            if let last = trigger.lastFireAt {
                Text(PlansText.lastFire(last, language: language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkTertiary)
            }
            if trigger.isInvalid {
                Text(
                    zh
                        ? "这条规则解析不了了（比如时区不存在了），已经停用、不会再触发。改一下规则就能恢复。"
                        : "This rule can no longer be read (for example its time zone is gone), so it was turned off. "
                            + "Change the rule to bring it back."
                )
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                PlansButtonRow {
                    if let onFix {
                        PillButton(zh ? "修改规则" : "Change rule", systemImage: "pencil", size: .compact, action: onFix)
                            .disabled(!canEdit)
                    }
                    if let onDelete {
                        PillButton(zh ? "删除" : "Delete", kind: .secondary, size: .compact, action: onDelete)
                            .disabled(!canEdit)
                    }
                }
                .padding(.top, Metrics.Spacing.xxs)
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// 策略的几行（详情、确认页）。
struct PlanPolicyRows: View {
    let plan: Plan

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let policy = plan.policy
        GroupedSection {
            ListRow(
                systemImage: "checkmark.shield", title: zh ? "预授权的工具" : "Pre-approved tools",
                detail: PlansText.toolsSummary(policy.preauthorizedTools, language: language),
                detailTone: policy.preauthorizedTools.contains(where: PlansText.isRiskyTool) ? .waiting : nil)
            Divider()
            ListRow(
                systemImage: "hand.raised", title: zh ? "审批" : "Approvals",
                detail: PlansText.approvalSummary(policy, language: language))
            Divider()
            ListRow(
                systemImage: "gauge.with.dots.needle.33percent", title: zh ? "每次运行的上限" : "Per-run limits",
                detail: PlansText.budgetSummary(policy.budget, language: language))
            Divider()
            ListRow(
                systemImage: "calendar.day.timeline.left", title: zh ? "每日 token 上限" : "Daily token limit",
                detail: PlansText.dailyLimitSummary(policy.dailyTokenLimit, language: language))
            Divider()
            ListRow(
                systemImage: "hourglass", title: zh ? "等待" : "Waiting",
                detail: PlansText.waitSummary(policy, language: language))
            Divider()
            ListRow(
                systemImage: "arrow.uturn.backward.circle", title: zh ? "错过的怎么补" : "Missed runs",
                detail: PlansText.catchUpName(plan.catchUp, language: language)
                    + (PlansText.catchUpDetail(plan.catchUp, language: language).map { (zh ? "：" : ": ") + $0 } ?? ""))
        }
    }
}

/// 流水线的步骤（只读）：按依赖分层，每一步写在哪个实例上跑、提示词、依赖谁。
struct PlanStepsView: View {
    let plan: Plan
    let instanceName: (InstanceID) -> String

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let stages = PipelineLayout.stages(plan.steps)
        let ai = PlansText.isAIGenerated(.stepPrompt, in: plan)
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    Text(stageTitle(index: index, parallel: stage.count > 1))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(stage) { step in
                        Card(padding: Metrics.Spacing.s) {
                            HStack(spacing: Metrics.Spacing.xs) {
                                Text(verbatim: step.key)
                                    .font(Typography.subheadline.monospacedFont)
                                    .foregroundStyle(Theme.ink)
                                Text(instanceName(step.instanceID))
                                    .typography(.subheadline)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                            }
                            Text(step.prompt)
                                .typography(.body)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(4)
                            if ai { AIGeneratedLabel() }
                            if !step.dependsOn.isEmpty {
                                Text(
                                    (zh ? "等这几步做完：" : "After: ")
                                        + step.dependsOn.joined(separator: zh ? "、" : ", ")
                                )
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkTertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

extension PlanStepsView {
    /// “第 1 批（同时跑）” / “Stage 1 (in parallel)”。
    func stageTitle(index: Int, parallel: Bool) -> String {
        if language == .chinese { return "第 \(index + 1) 批" + (parallel ? "（同时跑）" : "") }
        return "Stage \(index + 1)" + (parallel ? " (in parallel)" : "")
    }
}

/// 运行历史的一行：状态、什么时候、多久、用了多少 token、摘要（agent 写的，带 AI 生成标识）。点开去运行详情。
struct PlanRunRow: View {
    let run: Run
    let onOpen: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                StatusDot(run.state)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    TagChipRow {
                        Text(run.state.localizedName(language))
                            .typography(.subheadline)
                            .foregroundStyle(Theme.ink)
                        Text(Formatting.relativeTime(run.createdAt, language: language))
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                        if let duration = run.duration() {
                            Text(Formatting.duration(duration, language: language))
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        if run.tokensUsed > 0 {
                            Text(
                                zh
                                    ? "\(Formatting.tokens(run.tokensUsed, language: language)) token"
                                    : "\(Formatting.tokens(run.tokensUsed, language: language)) tokens"
                            )
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    if let summary = run.summary, !summary.isEmpty {
                        Text(summary)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                        AIGeneratedLabel()
                    } else if run.state == .failed {
                        // 失败原因是平台的英文诊断：这里只说失败了，详情在运行详情里。
                        Text(zh ? "这次没有完成，点开看详情。" : "This run didn't finish. Open it for details.")
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 一段文字（目标），可以带“改过”标记和 AI 生成标识。
struct PlanTextBlock: View {
    let text: String
    var isAIGenerated = false
    var isChanged = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Card {
            if isChanged { PlanChangedTag() }
            Text(text)
                .typography(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if isAIGenerated { AIGeneratedLabel() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// “改过”小标签（确认页上标出 agent 改了的地方）。是状态（要用户注意），用等待色。
struct PlanChangedTag: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        Label(language == .chinese ? "改过" : "Changed", systemImage: "pencil.line")
            .typography(.caption)
            .foregroundStyle(StatusTone.waiting.color)
    }
}

/// 输入框（单行或多行）加字数和问题提示：标题、目标、数字框都用它。
struct PlansTextField: View {
    let title: String
    let text: Binding<String>
    var prompt: String?
    var multiline = false
    /// 字数上限（显示“12/100”）；nil 不显示。
    var limit: Int?
    var count: Int = 0
    var problem: String?
    var hint: String?
    var numeric = false
    /// 等宽字体（cron、RRULE）。
    var monospaced = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(title)
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .font(monospaced ? Typography.body.monospacedFont : Typography.body.font)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Metrics.Spacing.s)
                .padding(.vertical, multiline ? Metrics.Spacing.s : 0)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Theme.paperElevated, in: shape)
                .overlay {
                    shape.strokeBorder(
                        problem == nil ? Theme.hairline : StatusTone.failure.color,
                        lineWidth: Metrics.hairline(scale: displayScale))
                }
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(problem ?? hint ?? ""))
            HStack(alignment: .firstTextBaseline) {
                if let message = problem ?? hint {
                    Text(message)
                        .typography(.footnote)
                        .foregroundStyle(problem == nil ? Theme.inkSecondary : StatusTone.failure.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.Spacing.xs)
                if let limit {
                    Text(verbatim: "\(count)/\(limit)")
                        .typography(.caption)
                        .monospacedDigit()
                        .foregroundStyle(count > limit ? StatusTone.failure.color : Theme.inkTertiary)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var field: some View {
        if multiline {
            TextField(title, text: text, prompt: prompt.map { Text($0) }, axis: .vertical)
                .lineLimit(3...12)
                .plansCodeInput(monospaced)
        } else if numeric {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .plansNumberInput()
        } else if monospaced {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .plansCodeInput()
        } else {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
        }
    }
}

/// 在几个选项里选一个（超时时长、超时后的动作、补跑方式）：一行标题和当前值，点开是菜单。
struct PlansMenuRow<Value: Hashable>: View {
    let systemImage: String
    let title: String
    let options: [Value]
    let selection: Binding<Value>
    let name: (Value) -> String
    var detail: String?

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if option == selection.wrappedValue {
                        Label(name(option), systemImage: "checkmark")
                    } else {
                        Text(name(option))
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minWidth: Metrics.Spacing.xl)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(title)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail)
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Text(name(selection.wrappedValue))
                    .typography(.body)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typography.footnote.font)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(name(selection.wrappedValue)))
    }
}

extension View {
    /// 数字输入框：iOS 上是数字键盘。
    func plansNumberInput() -> some View {
        #if canImport(UIKit)
            self.keyboardType(.numberPad)
        #else
            self
        #endif
    }

    /// 代码一类的输入（cron、RRULE）：iOS 上用英文键盘（不出中文输入法）。`enabled` 为 false 时不变。
    @ViewBuilder
    func plansCodeInput(_ enabled: Bool = true) -> some View {
        #if canImport(UIKit)
            if enabled {
                self.keyboardType(.asciiCapable)
            } else {
                self
            }
        #else
            self
        #endif
    }
}

/// 时区的显示名：“中国标准时间（Asia/Shanghai）” / “China Standard Time (Asia/Shanghai)”；认不出的原样。
func plansTimeZoneName(_ identifier: String, language: DisplayLanguage) -> String {
    guard let zone = TimeZone(identifier: identifier) else { return identifier }
    if ["GMT", "UTC"].contains(zone.identifier) { return "UTC" }
    let name = zone.localizedName(for: .generic, locale: language.locale) ?? identifier
    if name == identifier { return identifier }
    return language == .chinese ? "\(name)（\(identifier)）" : "\(name) (\(identifier))"
}
