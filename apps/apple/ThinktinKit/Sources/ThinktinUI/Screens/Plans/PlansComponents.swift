import SwiftUI
import ThinktinKit

// 计划管理（WBS 12.6）几个页面共用的小组件。名字都带 Plan / Plans 前缀，不和别的功能重名。
//
// 改版后（规范 2.5）各页都是系统的 `List` / `Form`：这里的组件只是行的内容或几行（放进调用方的 `Section`），不画卡片底和描边。
// 输入框用 `Components/FormFields.swift` 的 `FormTextField`，图标 + 标题 + 说明的行用 `LabeledRow`。

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

    /// 列表一行左边的图标（颜色用 `tone`）：待确认、暂停、规则失效、按时运行、不会再运行。
    var systemImage: String {
        switch self {
        case .awaitingConfirmation: "checkmark.seal"
        case .paused: "pause.circle"
        case .invalidRule: "exclamationmark.triangle"
        case .scheduled: "clock"
        case .idle: "clock.badge.xmark"
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

/// 一行小字：状态 · 实例（可以没有）· 下一次（按时运行的）。
struct PlanMetaLine: View {
    let plan: Plan
    /// nil 不显示（计划列表的一行把 Botin 名放在副标题里）。
    let instanceName: String?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let status = plan.status
        TagChipRow {
            PlanStatusLabel(status: status)
            if let instanceName {
                Text(instanceName)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
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
                        Button(zh ? "修改规则" : "Change rule", systemImage: "pencil", action: onFix)
                            .smallCapsuleButton(.prominent)
                            .disabled(!canEdit)
                    }
                    if let onDelete {
                        Button(zh ? "删除" : "Delete", role: .destructive, action: onDelete)
                            .smallCapsuleButton()
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

/// 策略的几行（详情、确认页）：`LabeledContent`，放进调用方的 `Section`（组标题、“错过的怎么补”的说明由调用方给）。
struct PlanPolicyRows: View {
    let plan: Plan

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let policy = plan.policy
        let risky = policy.preauthorizedTools.contains(where: PlansText.isRiskyTool)
        LabeledContent {
            Text(PlansText.toolsSummary(policy.preauthorizedTools, language: language))
                .foregroundStyle(risky ? StatusTone.waiting.color : Theme.inkSecondary)
        } label: {
            Label(zh ? "预授权的工具" : "Pre-approved tools", systemImage: "checkmark.shield")
        }
        LabeledContent {
            Text(PlansText.approvalSummary(policy, language: language))
        } label: {
            Label(zh ? "审批" : "Approvals", systemImage: "hand.raised")
        }
        LabeledContent {
            Text(PlansText.budgetSummary(policy.budget, language: language))
        } label: {
            Label(zh ? "每次运行的上限" : "Per-run limits", systemImage: "gauge.with.dots.needle.33percent")
        }
        LabeledContent {
            Text(PlansText.dailyLimitSummary(policy.dailyTokenLimit, language: language))
        } label: {
            Label(zh ? "每日 token 上限" : "Daily token limit", systemImage: "calendar.day.timeline.left")
        }
        LabeledContent {
            Text(PlansText.waitSummary(policy, language: language))
        } label: {
            Label(zh ? "等待" : "Waiting", systemImage: "hourglass")
        }
        LabeledContent {
            Text(PlansText.catchUpName(plan.catchUp, language: language))
        } label: {
            Label(zh ? "错过的怎么补" : "Missed runs", systemImage: "arrow.uturn.backward.circle")
        }
    }
}

/// 流水线的步骤（只读，详情、确认页）：按依赖分层，一步一行（第几批、键名和执行的 Botin、提示词、依赖谁），放进调用方的 `Section`。
struct PlanStepsView: View {
    let plan: Plan
    let instanceName: (InstanceID) -> String

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let stages = PipelineLayout.stages(plan.steps)
        let ai = PlansText.isAIGenerated(.stepPrompt, in: plan)
        ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
            ForEach(stage) { step in
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(Self.stageTitle(index: index, parallel: stage.count > 1, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkTertiary)
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
                        Text((zh ? "等这几步做完：" : "After: ") + step.dependsOn.joined(separator: zh ? "、" : ", "))
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension PlanStepsView {
    /// “第 1 批（同时跑）” / “Stage 1 (in parallel)”。
    static func stageTitle(index: Int, parallel: Bool, language: DisplayLanguage) -> String {
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

/// 一段文字（目标），是分组列表里一行的内容，可以带“改过”标记和 AI 生成标识。
struct PlanTextBlock: View {
    let text: String
    var isAIGenerated = false
    var isChanged = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if isChanged { PlanChangedTag() }
            Text(text)
                .typography(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if isAIGenerated { AIGeneratedLabel() }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
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

/// 在几个选项里选一个（超时时长、超时后的动作、补跑方式）：系统的 `Picker(.menu)`，左边图标、标题和一行说明，右边当前值。
struct PlansMenuRow<Value: Hashable>: View {
    let systemImage: String
    let title: String
    let options: [Value]
    let selection: Binding<Value>
    let name: (Value) -> String
    var detail: String?

    var body: some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(name(option)).tag(option)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(title)
                        .foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .pickerStyle(.menu)
    }
}

/// 行内单选（`Picker(.inline)`）的一项：标题和一行灰色说明，是一个视图（`.tag` 要加在它上面，不能拆成两个 `Text`）。
struct PlansOptionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
            Text(title)
                .foregroundStyle(Theme.ink)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 分组列表里的一句提示（等你确认、有风险、流水线、部分保存）：按语气上色的图标加一段话，就是一行，不画底。
struct PlansNoticeRow: View {
    let systemImage: String
    let tone: StatusTone
    let text: String

    var body: some View {
        Label {
            Text(text)
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
        }
        .accessibilityElement(children: .combine)
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
