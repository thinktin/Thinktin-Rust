import SwiftUI
import ThinktinKit

/// 实例的对话页（`.conversation(id)`，压在首页上）= 运行时间线 + 底部输入框（WBS 12.5，参考 Claude iOS App 的版式：
/// 回复不带气泡、用户消息是靠右的浅色卡片、底部胶囊输入框）。
///
/// - 打开先显示缓存，再拉运行、订阅事件流（`ConversationModel.start()`）；进后台停订阅、回前台续订（scenePhase），
///   账号解冻后重新订阅（`AppModel.resubscribeRequest`）；连接横幅由应用框架统一显示。
/// - “新任务”（`Router.newTaskRequest`）把焦点放进输入框：对话页一般在请求之后才建（首页 → 对话），出现时也看一眼
///   有没有没处理的（`hasPendingNewTaskRequest`），只认当前实例的；发出消息、事件流重置后滚到底。
/// - 长按 agent 的回复、产出物举报（`ContentReportSheet`）；发送前拦下的密码弹 `SecretInterceptionSheet`。
/// - 导航栏左边是系统的返回（回首页），中间是 Botin 的小头像（新建时挑的形状和颜色）和名字（第 1 轮换成规范 4.3.1
///   能点的标题胶囊），右边是菜单（实例详情、模型路由、计划、产出物）。
struct ConversationScreen: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client
    @Environment(\.biometricGate) private var gate

    var body: some View {
        ConversationContent(
            client: client, instanceID: instanceID, gate: ConversationGate.resolve(gate, client: client))
    }
}

/// 对话页导航栏中间：24pt 头像 + 名字，读屏念名字、当标题。
private struct ConversationTitle: View {
    let name: String
    let appearance: InstanceAppearance

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            InstanceAvatar(name, appearance: appearance, size: Metrics.Avatar.title)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ConversationContent: View {
    @State private var model: ConversationModel
    @State private var reportRequest: ReportRequest?
    /// 密码拦截弹层关掉之后要去的页面（“添加为模型 key”）。
    @State private var routeAfterInterception: AppRoute?
    @FocusState private var isComposerFocused: Bool

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.client) private var client
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, instanceID: InstanceID, gate: any BiometricGate) {
        _model = State(initialValue: ConversationModel(client: client, instanceID: instanceID, biometricGate: gate))
    }

    private var instance: Instance? { app.instances.first { $0.id == model.instanceID } }

    /// 导航栏的标题：Botin 的名字（列表里还没有时是页面的标题）。
    private var title: String { instance?.name ?? AppRoute.conversation(model.instanceID).title(language) }

    /// 实例状态：事件流说的优先，其次是实例列表里的。
    private var instanceState: InstanceState? { model.instanceState ?? instance?.state }

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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConversationComposer(
                    model: model,
                    placeholder: ConversationText.placeholder(instanceName: instance?.name, language: language),
                    isFocused: $isComposerFocused, onOpenModelRoutes: { router.open(.modelRoutes(model.instanceID)) })
            }
            .onChange(of: model.lastSentRunID) {
                withAnimation { proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom) }
            }
            .onChange(of: model.resetCount) {
                proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom)
            }
        }
        .background(Theme.paper)
        .inlineNavigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConversationTitle(name: title, appearance: app.appearances.resolved(for: model.instanceID))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        router.open(.instance(model.instanceID))
                    } label: {
                        Label(AppRoute.instance(model.instanceID).title(language), systemImage: "info.circle")
                    }
                    Button {
                        router.open(.modelRoutes(model.instanceID))
                    } label: {
                        Label(AppRoute.modelRoutes(model.instanceID).title(language), systemImage: "cpu")
                    }
                    Button {
                        router.open(.newPlan(instanceID: model.instanceID))
                    } label: {
                        Label(
                            AppRoute.newPlan(instanceID: model.instanceID).title(language),
                            systemImage: "calendar.badge.plus")
                    }
                    Button {
                        router.open(.artifacts(instanceID: model.instanceID))
                    } label: {
                        Label(
                            AppRoute.artifacts(instanceID: model.instanceID).title(language),
                            systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.ink)
                        .accessibilityLabel(Text(language == .chinese ? "更多操作" : "More"))
                }
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
        .onChange(of: router.newTaskRequest, focusComposerIfRequested)
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
            EmptyStateView(
                systemImage: "questionmark.square.dashed", title: ConversationText.instanceMissing(language),
                actionTitle: AppRoute.adopt(agentID: nil).title(language)
            ) {
                router.open(.adopt(agentID: nil))
            }
        } else if model.isEmpty && model.hasLoaded {
            EmptyStateView(
                systemImage: "text.bubble",
                title: ConversationText.emptyTitle(instanceName: instance?.name, language: language),
                message: ConversationText.emptyMessage(language))
            if model.needsSetupNote {
                ConversationSetupNote { router.open(.modelRoutes(model.instanceID)) }
            }
        } else if model.isEmpty {
            ConversationLoadingView()
        }
    }
}

/// 刚新建的 Botin（还没有任务、没配默认模型）：空状态下面一句“还差一步”和去配模型路由的按钮（规范 4.7.1；第 2 轮换成
/// 6.18 的首次引导卡片）。没有能用的 key 时路由页上再引导加 key。
struct ConversationSetupNote: View {
    let onSetUp: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.s) {
            Text(ConversationText.setupNote(language))
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(ConversationText.setupAction(language), action: onSetUp)
                .glassButtonStyle(.prominent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.Spacing.m)
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
