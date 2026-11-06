import SwiftUI
import ThinktinKit

/// 实例的对话页（`.conversation(id)`，压在首页上）= 运行时间线 + 底部浮动的输入框（WBS 12.5；版式照规范 4.3.1 和参考 02、
/// 03、07、118：agent 的回复是左边的灰气泡、用户消息是右边的气泡，运行之间居中的时间，底部玻璃胶囊输入框）。
///
/// - 打开先显示缓存，再拉运行、订阅事件流（`ConversationModel.start()`）；进后台停订阅、回前台续订（scenePhase），
///   账号解冻后重新订阅（`AppModel.resubscribeRequest`）；连接横幅由应用框架统一显示。
/// - “新任务”（`Router.newTaskRequest`）把焦点放进输入框：对话页一般在请求之后才建（首页 → 对话），出现时也看一眼
///   有没有没处理的（`hasPendingNewTaskRequest`），只认当前实例的；发出消息、事件流重置后滚到底。
/// - 长按消息是系统菜单（`MessageMenus.swift`：引用回复、复制、选择文本、复制运行 ID、分享、举报）；举报弹
///   `ContentReportSheet`，发送前拦下的密码弹 `SecretInterceptionSheet`。选了引用回复，输入框长成卡片、自动聚焦。
/// - 导航栏左边是系统的返回（回首页）；中间是能点的标题（玻璃胶囊里 Botin 的 24pt 头像 + 名字，`ConversationTitle`），点了进
///   Botin 资料；实例列表里还没有这个 Botin 时只有页面标题那一行字，不画头像、不画胶囊。右边是“…”菜单（`ConversationMenu`：
///   Botin 资料、在对话中查找；计划、新建计划、产出物、模型路由；有任务在跑时“停止当前任务”）。中间这一项由
///   `inlineNavigationTitle(_:ownsGlass:principal:)` 放，别再另加 `.principal`。
/// - 还没有任务时时间线顶上是 `ConversationWelcome`（参考 118：说明气泡 + 示例任务 / 去配模型路由的卡片）。
/// - “…”里的“在对话中查找”（规范 4.3.3，参考 04、05）：输入框换成 `ConversationFindBar`，找到的字在气泡里高亮，
///   跳到哪一处就滚到哪条消息（先滚到那一组，懒加载的时间线才有那一条，再居中）。
struct ConversationScreen: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client
    @Environment(\.biometricGate) private var gate
    @Environment(AppModel.self) private var app

    var body: some View {
        ConversationContent(
            client: client, instanceID: instanceID, gate: ConversationGate.resolve(gate, client: client),
            reactions: app.local.reactions)
    }
}

/// 对话页导航栏中间（参考 02、118 的标题胶囊）：24pt 头像 + 名字，点了进 Botin 资料。玻璃胶囊是自己画的
/// （`glassBackground(in: Capsule())`，高 44，和两边的返回、“…”玻璃圆一样高）：iOS 26 的工具栏不给 `.principal` 项套共用的
/// 玻璃底（2026-11-05 的截图里只有光秃秃的头像和名字），所以放它的 `inlineNavigationTitle(_:ownsGlass:principal:)` 把共用的底
/// 关掉，免得哪个系统版本又套一层。头像离胶囊左边和上下一样远（同心），名字是胶囊标题的 medium `.body`（和
/// `capsuleNavigationTitle` 一样，参考比系统标题的 semibold 轻一档）。旧系统是材质的胶囊。读屏念名字、当标题，提示“打开 Botin 资料”。
private struct ConversationTitle: View {
    let name: String
    let appearance: InstanceAppearance
    /// 头像的脸此刻的状态：当前的任务在跑时是活的（`ConversationContent.faceMood`）。
    let mood: BotinFaceMood
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.xs) {
                InstanceAvatar(name, appearance: appearance, size: Metrics.Avatar.title, mood: mood)
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .font(Typography.body.font.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            // 头像和胶囊同心：左边留的和上下一样（(44 - 24) / 2 = 10），名字后面留 12（参考 118 量出来约 10 和 13）。
            .padding(.leading, (Metrics.minTapTarget - Metrics.Avatar.title) / 2)
            .padding(.trailing, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .glassBackground(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(Text(ConversationText.titleHint(language)))
    }
}

private struct ConversationContent: View {
    @State private var model: ConversationModel
    @State private var reportRequest: ReportRequest?
    /// 密码拦截弹层关掉之后要去的页面（“添加为模型 key”）。
    @State private var routeAfterInterception: AppRoute?
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isFindFocused: Bool

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.client) private var client
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayLanguage) private var language

    init(
        client: any ClientProtocol, instanceID: InstanceID, gate: any BiometricGate, reactions: MessageReactionStore
    ) {
        let model = ConversationModel(
            client: client, instanceID: instanceID, biometricGate: gate, reactionStore: reactions)
        // 查找按画出来的字算位置（`AttributedString(markdown:)` 的真解析），和高亮对得上。
        model.find.plainText = InlineText.plainText
        _model = State(initialValue: model)
    }

    private var instance: Instance? { app.instances.first { $0.id == model.instanceID } }

    /// 导航栏的标题：Botin 的名字（列表里还没有时是页面的标题）。
    private var title: String { instance?.name ?? AppRoute.conversation(model.instanceID).title(language) }

    /// 实例状态：事件流说的优先，其次是实例列表里的。
    private var instanceState: InstanceState? { model.instanceState ?? instance?.state }

    /// 标题上头像的脸：有没结束的运行时按它的状态（在跑的是活的，等审批、电脑、额度的睁大眼睛），没有时按实例的状态
    /// （暂停、归档闭着眼，别的不动）。都是这一页已经有的数据（`activeRunID` 就是“停止”停的那个）。
    private var faceMood: BotinFaceMood {
        if let runID = model.activeRunID, let state = model.turns.first(where: { $0.runID == runID })?.state {
            return BotinFaceMood(run: state)
        }
        return instanceState.map(BotinFaceMood.init(instance:)) ?? .resting
    }

    var body: some View {
        let model = self.model
        ScrollViewReader { proxy in
            ScrollView {
                ConversationTimeline(
                    model: model, instanceState: instanceState, proxy: proxy,
                    onReport: { reportRequest = ReportRequest(target: $0) }
                ) {
                    pageHeader
                }
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.vertical, Metrics.Spacing.l)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refresh() }
            .floatingBar(edge: .bottom, spacing: 0) {
                if model.find.isActive {
                    ConversationFindBar(model: model, isFocused: $isFindFocused)
                } else {
                    ConversationComposer(
                        model: model,
                        placeholder: ConversationText.placeholder(instanceName: instance?.name, language: language),
                        isFocused: $isComposerFocused,
                        onOpenModelRoutes: { router.open(.modelRoutes(model.instanceID)) })
                }
            }
            .onChange(of: model.find.jumpCount) {
                guard let match = model.find.currentMatch else { return }
                // 懒加载的时间线：先滚到那一组（它的视图才建出来），下一拍再把那一条滚到中间。
                proxy.scrollTo(match.turnID, anchor: .center)
                Task { @MainActor in
                    await Task.yield()
                    withAnimation { proxy.scrollTo(match.targetID, anchor: .center) }
                }
            }
            .onChange(of: model.lastSentRunID) {
                withAnimation { proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom) }
            }
            .onChange(of: model.resetCount) {
                proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom)
            }
        }
        .background(Theme.paper)
        .inlineNavigationTitle(title, ownsGlass: true) {
            if let instance {
                ConversationTitle(
                    name: instance.name, appearance: app.appearances.resolved(for: instance.id), mood: faceMood
                ) {
                    router.open(.instance(instance.id))
                }
            } else {
                InlineTitleText(title: title)
            }
        }
        .toolbar {
            ToolbarItem(placement: ConversationMoreMenu.placement) {
                ConversationMoreMenu(model: model, onFind: beginFind)
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: model.pause()
            case .active: Task { await model.resume() }
            default: break
            }
        }
        .onChange(of: app.resubscribeRequest) { model.resubscribe() }
        .onAppear(perform: focusComposerIfRequested)
        // 截图（参考 04）：查找栏开着、不聚焦。
        .onSubpageRequest(.conversationFind) { model.beginFind() }
        .onChange(of: router.newTaskRequest, focusComposerIfRequested)
        .onChange(of: model.quotedText) {
            // 选了“引用回复”：输入框长成卡片，焦点放进去（参考 07）。
            if model.quotedText != nil { isComposerFocused = true }
        }
        .sheet(item: $reportRequest) { request in
            ContentReportSheet(client: client, target: request.target)
        }
        .sheet(
            isPresented: Binding(
                get: { model.interception != nil }, set: { if !$0 { model.dismissInterception() } }),
            onDismiss: openRouteAfterInterception
        ) {
            SecretInterceptionSheet(model: model, onOpenRoute: { routeAfterInterception = $0 })
                .environment(\.displayLanguage, language)
        }
    }

    /// “在对话中查找”：收起键盘、换成查找栏、查找框聚焦。
    private func beginFind() {
        isComposerFocused = false
        model.beginFind()
        isFindFocused = true
    }

    /// 有没处理的新任务请求、又是给这个实例的：把焦点放进输入框，记成处理过（对话页重建时不再聚焦）。
    private func focusComposerIfRequested() {
        guard router.hasPendingNewTaskRequest, router.currentInstanceID == model.instanceID else { return }
        router.newTaskRequestHandled()
        isComposerFocused = true
    }

    /// 密码拦截弹层关掉之后，去用户在弹层里选的页面（弹层还在时弹不出另一个 sheet）。
    private func openRouteAfterInterception() {
        guard let route = routeAfterInterception else { return }
        routeAfterInterception = nil
        router.open(route)
    }

    /// 时间线最上面：实例状态（正在唤醒、正在创建）、找不到实例、还没有任务、加载中、拉不到运行的错误。
    @ViewBuilder
    private var pageHeader: some View {
        let starting = model.turns.contains { $0.state == .starting || $0.state == .queued }
        if let banner = ConversationText.instanceBanner(instanceState, isStarting: starting, language: language) {
            NoticeText(text: banner, tone: .neutral)
        }
        if let error = model.loadError, !error.isOffline {
            ErrorBanner(error) { Task { await model.load() } }
        }
        if model.isMissing {
            ContentUnavailableView {
                Label(ConversationText.instanceMissing(language), systemImage: "questionmark.square.dashed")
            } actions: {
                Button(AppRoute.adopt(agentID: nil).title(language)) {
                    router.open(.adopt(agentID: nil))
                }
                .glassButtonStyle(.prominent)
            }
            .padding(.top, Metrics.Spacing.xxxl)
        } else if model.isEmpty && model.hasLoaded {
            ConversationWelcome(
                instanceName: instance?.name, createdAt: instance?.createdAt, starter: model.starter,
                onSuggestion: { text in
                    model.useSuggestion(text)
                    isComposerFocused = true
                },
                onSetUp: { router.open(.modelRoutes(model.instanceID)) })
        } else if model.isEmpty {
            ConversationLoadingView()
        }
    }
}

/// 对话页右上的“…”（规范 4.3.2，参考 03）：系统 `Menu`，分组照 `ConversationMenu`；iOS 26 上按钮是玻璃圆，菜单从按钮
/// 变形展开。图标用 `ellipsis`（玻璃圆由系统画，不用 `ellipsis.circle`）。
private struct ConversationMoreMenu: View {
    /// iOS 放导航栏右边；macOS 没有 `.topBarTrailing`，放主操作的位置。
    static var placement: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .primaryAction
        #endif
    }

    let model: ConversationModel
    /// 点了“在对话中查找”。
    let onFind: @MainActor () -> Void

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        Menu {
            ForEach(Array(model.menuSections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section, id: \.self) { item in
                        Button(role: item.isDestructive ? .destructive : nil) {
                            perform(item)
                        } label: {
                            Label(item.title(language), systemImage: item.systemImage)
                        }
                    }
                }
            }
        } label: {
            Label(ConversationText.moreActions(language), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }

    private func perform(_ item: ConversationMenuItem) {
        switch item {
        case .open(let route): router.open(route)
        case .find: onFind()
        case .stop: Task { await model.stop() }
        }
    }
}

/// 加载中。
struct ConversationLoadingView: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            ProgressView()
            Text(language == .chinese ? "正在加载…" : "Loading…")
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

#Preview("实例对话 · 浅色中文") {
    ConversationScreen(instanceID: DemoData.writerID).previewShell()
}

#Preview("实例对话 · 深色英文") {
    ConversationScreen(instanceID: DemoData.reviewerID).previewShell(.english, scheme: .dark)
}

#Preview("流式输出中 · 浅色中文") {
    ConversationScreen(instanceID: DemoData.writerID)
        .previewShell(client: ConversationPreviewClients.streaming())
}

#Preview("等 key、空对话 · 深色英文") {
    ConversationScreen(instanceID: DemoData.reviewerID)
        .previewShell(.english, scheme: .dark, client: ConversationPreviewClients.waitingForKey())
}
