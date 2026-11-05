import SwiftUI
import ThinktinKit

/// 新建 Botin（`.adopt(agentID:)`，large sheet；规范 docs/ios-ui-redesign.md 4.7.1、4.4.4、6.4 A）：首页右上的“+”、
/// 首页空状态的“新建 Botin”、引擎详情的“用它新建 Botin”（预选那个引擎）打开。代码里还叫领养（`AdoptionModel`、`adopt(...)`）。
///
/// 版式照参考（2026-11-05 用户对过参考图后改的，以前是分组 `Form` + 右上按钮），从上到下：
/// - 顶上左边玻璃 ×（`CloseButton`，填了东西时先确认），中间标题“新建 Botin”，右边不放按钮。
/// - 居中的大头像预览（120pt）：选的形状、选的颜色（没选按名字取）、名字的第一个字（还没输入时是占位符号）。
/// - 大号名字输入框：整宽、胶囊形的填充底、字大、居中，占位“给 Botin 取个名字”，默认空的；名字的问题或提示只在
///   有用时出现在下面（`AdoptionModel.nameNote`）。
/// - 头像的形状网格（3 × 5，自己设计的几何形状，`AvatarShape`）和色板（2 × 6，选中的带环，`AvatarColor`）。
/// - 紧凑的引擎行：“引擎”+ 系统 `Menu`（显示选的引擎，每项名字 + 一句话介绍，不能用的灰掉；默认选哪个见
///   `AdoptionModel.defaultEngine`），接入方式多于一个时下面一行 `Picker(.menu)`；下面一个小链接“了解引擎”压进引擎目录
///   （目录 → 引擎详情，详情上的“用它新建 Botin”回到这张表单、换成那个引擎，见 `Router.engineRequest`）。
/// - 底部固定的一条（键盘弹出时在键盘上面）：错误横幅（包括 Botin 数到了上限）、离线说明、一行许可小字
///   （`NewBotinText.licenseCaption`，专有许可写“新建即表示同意…”）+“查看”（小 sheet 里是全文）、整宽胶囊主按钮“新建”
///   （名字对、选了能用的引擎、在线才能点，新建中转圈）。
/// - 新建中、填了东西时不能下滑关掉（只能点 ×，先确认）。建好了：关掉表单、从首页压栈进新 Botin 的对话
///   （`AppModel.openCreatedInstance`）；头像外观由 `AdoptionModel` 记进这台设备（`AppModel.appearances`）。
struct AdoptAgentSheet: View {
    let preselectedAgentID: AgentID?

    @Environment(AppModel.self) private var app
    @Environment(\.client) private var client

    init(preselectedAgentID: AgentID? = nil) {
        self.preselectedAgentID = preselectedAgentID
    }

    var body: some View {
        AdoptAgentForm(
            model: AdoptionModel(
                client: client, instances: app.instances, preselectedAgentID: preselectedAgentID,
                appearances: app.appearances))
    }
}

private struct AdoptAgentForm: View {
    @State private var model: AdoptionModel
    @State private var isConfirmingDiscard = false
    @State private var licenseAgent: AgentInfo?
    @FocusState private var isNameFocused: Bool

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: AdoptionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(spacing: Metrics.Spacing.l) {
                InstanceAvatar(model.name, appearance: model.appearance, size: Metrics.Avatar.profile)
                    .accessibilityHidden(true)
                    .animation(.snappy, value: model.appearance)
                nameField
                AvatarPicker(model: model)
                engineSection
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.top, Metrics.Spacing.s)
            .padding(.bottom, Metrics.Spacing.l)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .floatingBar(edge: .bottom, spacing: 0) { bottomBar }
        .inlineNavigationTitle(AppRoute.adopt(agentID: nil).title(language))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton(action: close)
                    .disabled(model.isAdopting)
            }
        }
        .interactiveDismissDisabled(model.isAdopting || model.hasUserInput)
        .confirmationDialog(
            NewBotinText.discardTitle(language), isPresented: $isConfirmingDiscard, titleVisibility: .visible
        ) {
            Button(NewBotinText.discard(language), role: .destructive) { router.dismissSheet() }
            Button(NewBotinText.keepEditing(language), role: .cancel) {}
        }
        .sheet(item: $licenseAgent) { agent in
            LicenseTermsSheet(agent: agent)
                .environment(\.displayLanguage, language)
        }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            // 联网后补拉目录（离线时拉不到）。
            if !app.isOffline && !model.hasLoadedAgents { Task { await model.load() } }
        }
        .onAppear(perform: applyEngineRequest)
        .onChange(of: router.engineRequest) { applyEngineRequest() }
    }

    // MARK: 名字

    /// 大号输入框（胶囊形的填充底，字大、居中），下面一行小字只在有用时出现。
    private var nameField: some View {
        let model = self.model
        let note = model.nameNote(language)
        return VStack(spacing: Metrics.Spacing.xs) {
            TextField(
                NewBotinText.nameTitle(language), text: Binding(get: { model.name }, set: { model.name = $0 }),
                prompt: Text(NewBotinText.namePrompt(language))
            )
            .font(Font.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .focused($isNameFocused)
            .submitLabel(.done)
            .onSubmit { isNameFocused = false }
            .autocorrectionDisabled()
            .disabled(model.isAdopting)
            .padding(.horizontal, Metrics.Spacing.l)
            .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.s)
            .background(Theme.paperElevated, in: Capsule())
            .contentShape(Capsule())
            if let note {
                Text(verbatim: note.text)
                    .typography(.footnote)
                    .foregroundStyle(note.isProblem ? StatusTone.failure.color : Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: 引擎

    /// “引擎”+ 菜单（接入方式多于一个时再一行），下面“了解引擎”。
    private var engineSection: some View {
        let model = self.model
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            VStack(spacing: 0) {
                EngineRow(title: NewBotinText.engineTitle(language)) {
                    engineControl
                }
                if model.showsHarnessChoice {
                    Divider()
                        .padding(.leading, Metrics.Spacing.m)
                    EngineRow(title: NewBotinText.harnessTitle(language)) {
                        Picker(
                            NewBotinText.harnessTitle(language),
                            selection: Binding(get: { model.harness }, set: { model.harness = $0 })
                        ) {
                            ForEach(model.harnessOptions, id: \.self) { harness in
                                Text(AgentsText.harnessName(harness, language: language)).tag(harness)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(model.isAdopting)
                    }
                }
            }
            .background(
                Theme.paperElevated, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
            if let status = engineStatusNote {
                Text(verbatim: status)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, Metrics.Spacing.m)
            }
            NavigationLink(value: AppRoute.agentCatalog) {
                HStack(spacing: Metrics.Spacing.xxs) {
                    Text(NewBotinText.aboutEngines(language))
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .typography(.footnote)
            }
            .padding(.horizontal, Metrics.Spacing.m)
        }
    }

    /// 引擎那一行右边：目录拉到了是菜单；在拉转圈；拉不到给重试（离线时等联网自己补拉）。
    @ViewBuilder
    private var engineControl: some View {
        let zh = language == .chinese
        let model = self.model
        if !model.agents.isEmpty {
            EngineMenu(model: model)
        } else if model.hasLoadedAgents {
            EmptyView()
        } else if let error = model.loadError, !model.isLoadingAgents {
            if !error.isOffline {
                Button(zh ? "重试" : "Retry") { Task { await model.load() } }
            }
        } else {
            ProgressView()
        }
    }

    /// 目录还没拉到时引擎卡片下面的一句：拉不到、目录是空的。
    private var engineStatusNote: String? {
        guard model.agents.isEmpty else { return nil }
        if model.hasLoadedAgents { return NewBotinText.noEngines(language) }
        if model.loadError != nil && !model.isLoadingAgents { return NewBotinText.enginesUnavailable(language) }
        return nil
    }

    // MARK: 底部

    /// 底部固定的一条：错误、离线、许可小字、“新建”。
    private var bottomBar: some View {
        let zh = language == .chinese
        let model = self.model
        let app = self.app
        return VStack(spacing: Metrics.Spacing.s) {
            if let error = model.error {
                ErrorBanner(error) { create() }
            }
            if app.isOffline {
                VStack(spacing: Metrics.Spacing.xxs) {
                    Text(NewBotinText.offlineNote(language))
                        .foregroundStyle(Theme.inkSecondary)
                    Button(zh ? "重新检查网络" : "Check again") { Task { await app.refresh() } }
                }
                .typography(.footnote)
                .multilineTextAlignment(.center)
            }
            if let agent = model.selectedAgent {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: NewBotinText.licenseCaption(agent, language: language))
                        .foregroundStyle(Theme.inkSecondary)
                    Button(NewBotinText.viewLicense(language)) { licenseAgent = agent }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(NewBotinText.licenseTitle(language)))
                }
                .typography(.caption)
                .multilineTextAlignment(.center)
            }
            Button(action: create) {
                ZStack {
                    Text(NewBotinText.create(language))
                        .opacity(model.isAdopting ? 0 : 1)
                    if model.isAdopting {
                        ProgressView()
                    }
                }
                .font(Font.headline)
                .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(.prominent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!model.canCreate(isOffline: app.isOffline))
            .accessibilityLabel(
                Text(model.isAdopting ? NewBotinText.creating(language) : NewBotinText.create(language)))
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(maxWidth: Metrics.readableWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
    }

    // MARK: 操作

    private func create() {
        guard model.canCreate(isOffline: app.isOffline) else { return }
        isNameFocused = false
        let model = self.model
        let app = self.app
        Task {
            guard let instance = await model.adopt() else { return }
            await app.openCreatedInstance(instance)
        }
    }

    /// ×：填了东西（名字、挑过的形状或颜色）时先确认，否则直接关掉。
    private func close() {
        if model.hasUserInput {
            isConfirmingDiscard = true
        } else {
            router.dismissSheet()
        }
    }

    /// 引擎详情上点了“用它新建 Botin”（详情是从这张表单压进去的，`Router` 已经退回表单）：换成那个引擎。表单的目录
    /// 还没拉到时模型先记下，拉到后再换（`AdoptionModel.requestEngine`），所以路由上的请求这里就可以清掉。
    private func applyEngineRequest() {
        guard let id = router.engineRequest else { return }
        router.engineRequestHandled()
        model.requestEngine(id)
    }
}

// MARK: - 头像的形状、颜色

/// 头像选择：形状网格（3 × 5）和色板（2 × 6，选中的带环），放在一张卡片里。每一格都用现在选的颜色和名字画。
private struct AvatarPicker: View {
    let model: AdoptionModel

    @Environment(\.displayLanguage) private var language

    private static let shapeColumns = Array(repeating: GridItem(.flexible(), spacing: Metrics.Spacing.xs), count: 5)
    private static let colorColumns = Array(repeating: GridItem(.flexible(), spacing: Metrics.Spacing.xs), count: 6)

    var body: some View {
        let model = self.model
        VStack(spacing: Metrics.Spacing.m) {
            LazyVGrid(columns: Self.shapeColumns, spacing: Metrics.Spacing.xs) {
                ForEach(AvatarShape.allCases, id: \.self) { shape in
                    AvatarShapeCell(
                        shape: shape, name: model.name, color: model.color, isSelected: model.shape == shape
                    ) {
                        model.shape = shape
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NewBotinText.shapeTitle(language)))
            Divider()
            LazyVGrid(columns: Self.colorColumns, spacing: Metrics.Spacing.xs) {
                ForEach(AvatarColor.allCases, id: \.self) { color in
                    AvatarColorDot(color: color, isSelected: model.resolvedColor == color) {
                        model.color = color
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NewBotinText.colorTitle(language)))
        }
        .padding(Metrics.Spacing.m)
        .background(Theme.paperElevated, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .disabled(model.isAdopting)
        .sensoryFeedback(.selection, trigger: model.appearance)
    }
}

/// 形状网格的一格：这个形状、现在的颜色和名字；选中的有强调色的圆角框。
private struct AvatarShapeCell: View {
    let shape: AvatarShape
    let name: String
    let color: AvatarColor?
    let isSelected: Bool
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    private static let side: CGFloat = 44

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: Metrics.Radius.control + Metrics.Spacing.xxs, style: .continuous)
        Button(action: action) {
            InstanceAvatar(name, appearance: InstanceAppearance(shape: shape, color: color), size: Self.side)
                .padding(Metrics.Spacing.xs)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear, in: frame)
                .overlay {
                    if isSelected {
                        frame.strokeBorder(Theme.accent, lineWidth: 2)
                    }
                }
                .contentShape(frame)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(shape.localizedName(language)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 色板的一个点；选中的外面一圈同色的环。
private struct AvatarColorDot: View {
    let color: AvatarColor
    let isSelected: Bool
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    private static let dot: CGFloat = 30

    var body: some View {
        let hex = InstanceAvatar.colors(of: color)
        let fill = Color(light: hex.light, dark: hex.dark)
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: Self.dot, height: Self.dot)
                .padding(Metrics.Spacing.xxs + 1)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(fill, lineWidth: 2.5)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(color.localizedName(language)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 引擎

/// 引擎卡片里的一行：左边标题，右边控件。
private struct EngineRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            Text(verbatim: title)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: Metrics.Spacing.s)
            control()
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.xs)
    }
}

/// 选引擎的系统菜单：按钮上是选的引擎；每项名字 + 一句话介绍（菜单里的副标题），选中的打勾，不能用的灰掉、点不了。
/// 读屏：按钮念“引擎，Claude Agent”，每项念 `EngineOption.accessibilityLabel`（多念几个 Botin 在用）。
private struct EngineMenu: View {
    let model: AdoptionModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let model = self.model
        let selectedName = model.selectedAgent.map { AgentsText.displayName(of: $0) } ?? ""
        Menu {
            ForEach(model.engineOptions(language)) { option in
                let detail = option.detail(language)
                Button {
                    model.selectEngine(option.id)
                } label: {
                    // 第二个 `Text` 在系统菜单里显示成副标题。
                    if option.id == model.selectedAgentID {
                        Label {
                            Text(verbatim: option.name)
                            if !detail.isEmpty { Text(verbatim: detail) }
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(verbatim: option.name)
                        if !detail.isEmpty { Text(verbatim: detail) }
                    }
                }
                .disabled(!option.isAvailable)
                .accessibilityLabel(Text(option.accessibilityLabel(language)))
            }
        } label: {
            HStack(spacing: Metrics.Spacing.xxs) {
                Text(verbatim: selectedName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .disabled(model.isAdopting)
        .accessibilityLabel(Text(NewBotinText.engineTitle(language)))
        .accessibilityValue(Text(verbatim: selectedName))
    }
}

/// 点“查看”看到的许可条款全文（小 sheet）：引擎名、许可证、专有许可的说明和“新建即表示同意”，或者在沙箱里运行的说明；
/// 有上游仓库时给链接。
private struct LicenseTermsSheet: View {
    let agent: AgentInfo

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                    Text(verbatim: AgentsText.displayName(of: agent))
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: NewBotinText.licenseDetails(agent, language: language))
                        .typography(.body)
                        .foregroundStyle(Theme.inkSecondary)
                    if let url = agent.upstreamURL {
                        Link(destination: url) {
                            Label(zh ? "上游仓库" : "Upstream repository", systemImage: "arrow.up.right.square")
                        }
                        .typography(.subheadline)
                        .accessibilityHint(Text(zh ? "在浏览器里打开" : "Opens in your browser"))
                    }
                }
                .padding(Metrics.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.paper)
            .inlineNavigationTitle(NewBotinText.licenseTitle(language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview("新建 Botin · 浅色中文") {
    NavigationStack {
        AdoptAgentSheet()
    }
    .previewShell()
}

#Preview("新建 Botin · 深色英文、预选 Codex") {
    NavigationStack {
        AdoptAgentSheet(preselectedAgentID: DemoData.codexAgentID)
    }
    .previewShell(.english, scheme: .dark)
}
