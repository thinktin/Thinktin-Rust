import SwiftUI
import ThinktinKit

/// 领养表单（Agent 详情的“领养”弹出，自带导航栈）：起名字，接入方式多于一个时选一个，专有许可的先看许可说明。
///
/// 领养好之后同一张表单换成“领养好了”：说明下一步（配模型路由；没有能用的 key 时先加 key），按钮通过 `onExit`
/// 告诉详情页去哪，详情页等表单关掉再跳（不在表单还开着的时候弹别的 sheet）。
struct AdoptAgentSheet: View {
    @State private var model: AdoptionModel
    /// 领养成功了（详情页据此在表单关掉后刷新实例列表，用户直接划走表单也算）。
    private let onAdopted: @MainActor () -> Void
    private let onExit: @MainActor (AdoptionExit) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(
        agent: AgentInfo, existingNames: [String], client: any ClientProtocol,
        onAdopted: @escaping @MainActor () -> Void = {}, onExit: @escaping @MainActor (AdoptionExit) -> Void
    ) {
        _model = State(initialValue: AdoptionModel(client: client, agent: agent, existingNames: existingNames))
        self.onAdopted = onAdopted
        self.onExit = onExit
    }

    var body: some View {
        let zh = language == .chinese
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let instance = model.adopted {
                    AdoptionDoneView(model: model, instance: instance, onExit: onExit)
                } else {
                    form
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(
            model.adopted == nil
                ? (zh
                    ? "领养 \(AgentsText.displayName(of: model.agent))"
                    : "Adopt \(AgentsText.displayName(of: model.agent))")
                : (zh ? "领养好了" : "Adopted")
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.adopted == nil {
                    Button(zh ? "取消" : "Cancel") { onExit(.stay) }
                        .disabled(model.isAdopting)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.adopted != nil {
                    // 留在 Agent 详情页（实例列表照样刷新）。
                    Button(zh ? "完成" : "Done") { onExit(.stay) }
                }
            }
        }
        .interactiveDismissDisabled(model.isAdopting)
        .presentationDetents([.large])
    }

    private func adopt() {
        let model = self.model
        let onAdopted = self.onAdopted
        Task {
            if await model.adopt() != nil { onAdopted() }
        }
    }

    @ViewBuilder
    private var form: some View {
        let zh = language == .chinese
        let model = self.model
        // 名字。
        AgentsSectionHeader(title: zh ? "名字" : "Name")
        AgentsNameField(
            title: zh ? "实例的名字" : "Instance name",
            text: Binding(get: { model.name }, set: { model.name = $0 }),
            problem: model.nameProblem,
            hint: zh
                ? "最多 \(InstanceNameRule.maxLength) 个字，之后可以改。"
                : "Up to \(InstanceNameRule.maxLength) characters. You can change it later.")

        // 接入方式（多于一个时）。
        if model.showsHarnessChoice {
            AgentsSectionHeader(title: zh ? "接入方式" : "How it runs")
            AgentsGroup {
                ForEach(model.harnessOptions, id: \.self) { harness in
                    if harness != model.harnessOptions.first { Divider() }
                    AgentsChoiceRow(
                        title: AgentsText.harnessName(harness, language: language),
                        detail: AgentsText.harnessDetail(harness, language: language),
                        tag: harness == model.agent.defaultHarness ? (zh ? "默认" : "Default") : nil,
                        isSelected: model.harness == harness
                    ) {
                        model.harness = harness
                    }
                }
            }
        }

        // 许可说明（专有许可证必有）：领养前要给用户看。
        if let note = model.agent.licenseNote {
            AgentsSectionHeader(title: zh ? "许可说明" : "License terms")
            Card {
                Text(AgentsText.licenseName(model.agent.license, language: language))
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                Text(note)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(zh ? "领养即表示你同意按上面的条款使用。" : "By adopting, you agree to use it under these terms.")
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }

        if let error = model.error {
            ErrorBanner(error) { adopt() }
        }

        PillButton(
            model.isAdopting ? (zh ? "正在领养…" : "Adopting…") : (zh ? "领养" : "Adopt"),
            systemImage: model.isAdopting ? nil : "plus"
        ) {
            adopt()
        }
        .disabled(!model.canSubmit || app.isOffline)
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.s)
        if app.isOffline {
            VStack(spacing: Metrics.Spacing.xs) {
                Text(zh ? "离线时不能领养，联网后再试。" : "You can't adopt while offline. Try again once you're back online.")
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                PillButton(zh ? "重新检查网络" : "Check again", kind: .secondary, size: .compact) {
                    let app = self.app
                    Task { await app.refresh() }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// 领养好之后：说明下一步，给“配模型路由”“先加 key”“稍后再配”。
private struct AdoptionDoneView: View {
    let model: AdoptionModel
    let instance: Instance
    let onExit: @MainActor (AdoptionExit) -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                Image(systemName: "checkmark.circle")
                    .font(Typography.largeTitle.font)
                    .foregroundStyle(StatusTone.success.color)
                    .accessibilityHidden(true)
                Text(zh ? "领养好了" : "All set")
                    .typography(.title)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    zh
                        ? "“\(instance.name)”已经建好，沙箱正在准备。"
                        : "“\(instance.name)” has been created and its sandbox is getting ready."
                )
                .typography(.body)
                .foregroundStyle(Theme.inkSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            Card {
                Label {
                    Text(model.nextStepMessage(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(StatusTone.waiting.color)
                        .accessibilityHidden(true)
                }
            }

            VStack(spacing: Metrics.Spacing.s) {
                switch model.nextStep {
                case .configureRoutes:
                    PillButton(zh ? "配置模型路由" : "Set up model routes", systemImage: "slider.horizontal.3") {
                        onExit(.configureRoutes(instance.id))
                    }
                case .addCredentialFirst:
                    PillButton(zh ? "添加模型 key" : "Add a model key", systemImage: "key") {
                        onExit(.addCredential(instance.id))
                    }
                    PillButton(zh ? "直接配置模型路由" : "Set up model routes", kind: .secondary) {
                        onExit(.configureRoutes(instance.id))
                    }
                }
                PillButton(zh ? "稍后再配，先去对话" : "Later, go to the chat", kind: .secondary) {
                    onExit(.openConversation(instance.id))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// 名字输入框：圆角描边的单行输入，下面是问题（危险色）或提示。
struct AgentsNameField: View {
    let title: String
    let text: Binding<String>
    let problem: InstanceNameProblem?
    let hint: String

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .typography(.body)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Metrics.Spacing.s)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Theme.paperElevated, in: shape)
                .overlay {
                    shape.strokeBorder(
                        problem == nil ? Theme.hairline : StatusTone.failure.color,
                        lineWidth: Metrics.hairline(scale: displayScale))
                }
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(problem?.message(language) ?? hint))
            Text(problem?.message(language) ?? hint)
                .typography(.footnote)
                .foregroundStyle(problem == nil ? Theme.inkSecondary : StatusTone.failure.color)
                .accessibilityHidden(true)
        }
    }
}

/// 单选的一行：左边圆圈（选中时实心对勾），标题、说明、标签。
struct AgentsChoiceRow: View {
    let title: String
    var detail: String?
    var tag: String?
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(title)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                        if let tag { AgentsTag(text: tag) }
                    }
                    if let detail {
                        Text(detail)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("领养表单 · 浅色中文") {
    AdoptAgentSheet(agent: DemoData.agents[0], existingNames: ["写作助手"], client: MockClient(autoReply: false)) { _ in }
        .previewShell()
}

#Preview("领养表单 · 深色英文") {
    AdoptAgentSheet(agent: DemoData.agents[1], existingNames: [], client: MockClient(autoReply: false)) { _ in }
        .previewShell(.english, scheme: .dark)
}
