import SwiftUI
import ThinktinKit

/// Botin 资料（`.instance(id)`，规范 4.4.1、4.4.2，参考 09、10）：对话页标题、深链 `thinktin://instance/{id}`、引擎详情的
/// “在用它的 Botin”进来。分组列表（insetGrouped），没有标题，和参考 09 一样只有头部和两组：
///
/// - 头部：头像（右下状态角标，主 Botin 是星标）、名字、玻璃小胶囊“编辑”（压进 `InstanceEditScreen`：名字、头像）；
/// - 第一组：计划（“N 个生效”，进这个 Botin 的计划）、产出物、工作区（值是状态，进 `InstanceWorkspaceScreen`：观看与接管、
///   重置、磁盘空间）；行首是细的中性灰图标（`RowLabel`，参考 09）；
/// - “通知”开关（参考 09 的第二组）：按 Botin 开关推送要后端（6.14 A），现在显示系统的通知权限、不能拨，脚注说即将推出；
/// - 右上只有“…”一个玻璃圆（复制 Botin ID；模型路由、新建计划；删除，`InstanceProfileMenu`）：参考旁边那个是分享，
///   ThinkTin 不做（6.21），也不拿别的按钮占那个位置（规范 4.4.1）。删除先列出会级联删掉的东西（`InstanceDeleteSheet`），
///   二次确认后再删。
///
/// 以前下面的默认模型、所在团队、信息三组 2026-11-06 照参考 09 去掉了。
///
/// 页面的离线策略是“有缓存”：离线时照样显示缓存里的 Botin，改名、删除、新建计划都禁用（头像只存在这台设备上，照样能改）。
struct InstanceDetailScreen: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app

    var body: some View {
        InstanceDetailContent(
            client: client, instanceID: instanceID, instance: app.instances.first { $0.id == instanceID },
            local: app.local)
    }
}

private struct InstanceDetailContent: View {
    @State private var model: InstanceDetailModel
    @State private var isEditing = false
    /// 工作区：行是 `NavigationLink`，这个只给 `onSubpageRequest(.workspace)` 用。
    @State private var isShowingWorkspace = false
    @State private var isConfirmingDeletion = false
    /// 复制了几次 id（成功触感的触发器）。
    @State private var copies = 0
    /// 系统的通知权限（“通知”那一行的开关跟着它）；还没读到为 nil。
    @State private var notificationPermission: NotificationPermission?

    @Environment(\.notificationPermissionReader) private var notificationReader
    @Environment(\.scenePhase) private var scenePhase

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, instanceID: InstanceID, instance: Instance?, local: BotinLocalData) {
        _model = State(
            initialValue: InstanceDetailModel(client: client, instanceID: instanceID, instance: instance, local: local))
    }

    var body: some View {
        let model = self.model
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let instance = model.instance, !model.isMissing {
                Section {
                    ProfileHeader(
                        instance: instance, appearance: app.appearances.resolved(for: instance.id),
                        isPrimary: app.local.primary.isPrimary(instance.id),
                        mood: BotinFaceMood(state: instance.state, activity: app.activity(for: instance.id))
                    ) {
                        isEditing = true
                    }
                    .clearListRow()
                }
                if let error = visibleError(model.detailsError) {
                    Section {
                        ErrorBanner(error) { Task { await model.load() } }
                            .clearListRow()
                    }
                }
                workSection(instance)
                notificationSection
            }
        }
        .insetGroupedList()
        .compactGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        // 参考 09 没有标题（头部已经有名字），导航栏中间空着；返回按钮的长按菜单照样写名字。
        .hiddenInlineNavigationTitle(model.instance?.name ?? AppRoute.instance(model.instanceID).title(language))
        .toolbar {
            if model.instance != nil && !model.isMissing {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    moreMenu
                }
            }
        }
        .appFeedback(.success, trigger: copies)
        .navigationDestination(isPresented: $isEditing) {
            InstanceEditScreen(model: model)
        }
        .navigationDestination(isPresented: $isShowingWorkspace) {
            InstanceWorkspaceScreen(model: model)
        }
        .onSubpageRequest(.botinEdit, when: model.instance != nil) { isEditing = true }
        .onSubpageRequest(.workspace, when: model.instance != nil) { isShowingWorkspace = true }
        .refreshable { await model.load() }
        .task { await model.load() }
        .task { notificationPermission = await notificationReader.currentPermission() }
        .onChange(of: scenePhase) {
            // 从系统设置回来：通知权限可能改了。
            if scenePhase == .active {
                let reader = notificationReader
                Task { notificationPermission = await reader.currentPermission() }
            }
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .sheet(
            isPresented: $isConfirmingDeletion, onDismiss: { finishDeletion() },
            content: {
                NavigationStack {
                    InstanceDeleteSheet(model: model) { isConfirmingDeletion = false }
                }
                .shellEnvironment(app)
                .tint(Theme.accent)
            }
        )
    }

    /// 离线时不能改（只读看缓存）。
    private var canWrite: Bool { !app.isOffline }

    /// 还没有 Botin 可显示时：加载中、找不到、拉不到。
    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        if model.isMissing {
            ContentUnavailableView {
                Label(zh ? "找不到这个 Botin" : "Botin not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text(zh ? "它可能已经被删除了。" : "It may have been deleted.")
            } actions: {
                Button(zh ? "返回" : "Go back") { router.pop() }
                    .glassButtonStyle()
            }
        } else if model.instance == nil {
            if model.isLoading || model.error == nil {
                ProgressView()
            } else {
                ContentUnavailableView(
                    zh ? "暂时拉不到这个 Botin" : "Couldn't load this Botin",
                    systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle")
            }
        }
    }

    // MARK: 右上“…”

    private var moreMenu: some View {
        Menu {
            ForEach(Array(InstanceProfileMenu.sections(instanceID: model.instanceID).enumerated()), id: \.offset) {
                _, items in
                Section {
                    ForEach(items, id: \.self) { item in
                        Button(role: item.isDestructive ? .destructive : nil) {
                            perform(item)
                        } label: {
                            Label(item.title(language), systemImage: item.systemImage)
                        }
                        .disabled(item.needsConnection && !canWrite)
                    }
                }
            }
        } label: {
            Label(language == .chinese ? "更多操作" : "More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .neutralTint()
    }

    private func perform(_ item: InstanceProfileMenuItem) {
        switch item {
        case .copyID:
            Pasteboard.copy(model.instanceID.rawValue)
            copies += 1
        case .open(let route):
            router.open(route)
        case .delete:
            isConfirmingDeletion = true
        }
    }

    // MARK: 各组

    /// 计划、产出物、工作区（参考 09 的第一组：定时任务、资料库、电脑）。
    private func workSection(_ instance: Instance) -> some View {
        Section {
            NavigationLink(value: AppRoute.plans(instanceID: instance.id)) {
                LabeledContent {
                    if let active = model.activePlanCount {
                        Text(
                            InstanceProfileText.plansValue(
                                active: active, awaiting: model.plansAwaitingConfirmation, language: language))
                    }
                } label: {
                    RowLabel(InstanceProfileText.plans(language), systemImage: "clock")
                }
            }
            NavigationLink(value: AppRoute.artifacts(instanceID: instance.id)) {
                RowLabel(InstanceProfileText.artifacts(language), systemImage: "folder")
            }
            NavigationLink {
                InstanceWorkspaceScreen(model: model)
            } label: {
                LabeledContent {
                    Text(instance.state.localizedName(language))
                } label: {
                    // 空心的显示器（参考 09）；`desktopcomputer` 画出来是实心的一体机，比别的图标重。
                    RowLabel(InstanceProfileText.workspace(language), systemImage: "display")
                }
            }
        }
        .themedRow()
    }

    /// “通知”（参考 09 的第二组）：开关显示系统的通知权限能不能送到，不能拨（按 Botin 开关要后端，6.14 A）。
    private var notificationSection: some View {
        Section {
            Toggle(
                InstanceProfileText.notifications(language),
                isOn: .constant(notificationPermission?.canDeliver ?? false)
            )
            .disabled(true)
        } footer: {
            Text(InstanceProfileText.notificationsFooter(language))
        }
        .themedRow()
    }

    /// 删除确认页关掉了：删掉了就离开这个 Botin 的页面、刷新 Botin 列表。
    private func finishDeletion() {
        guard model.isDeleted else { return }
        let id = model.instanceID
        let app = self.app
        let router = self.router
        Task { await InstanceDetailScreen.leaveDeletedInstance(id, app: app, router: router) }
    }
}

extension InstanceDetailScreen {
    /// 实例删掉之后：各层导航栈里从它的第一个页面（对话、实例资料、它的路由、产出物）起都拿掉，删掉这台设备上按它记的东西
    /// （`AppModel.local`：头像外观、置顶和隐藏、语音、表情回应、主 Botin；`InstanceDetailModel.delete()` 已经删过一遍，
    /// 这里再删一遍不怕漏），再刷新应用框架的实例列表（当前实例被删时应用框架会换成别的实例）。资料页和首页长按的删除都走这里。
    @MainActor
    static func leaveDeletedInstance(_ id: InstanceID, app: AppModel, router: Router) async {
        router.removeRoutes(of: id)
        app.local.forget([id])
        await app.refresh()
    }
}

/// 头部（参考 09、10）：居中的头像（右下状态角标，主 Botin 是星标）、名字、玻璃小胶囊“编辑”（次按钮，中性色的字）。
/// 下面留 16pt：这一行贴边（`clearListRow`），“编辑”的玻璃阴影要画在行里面，不然被行的下边切掉一截；上面同样留出头像
/// 跳起来冒出的那一截（`ProfileAvatarHeadroom`，默认字号 8pt）。
/// 有任务在跑时头像的脸是活的（`mood`，角标画的是实例的状态，所以另外给）；点一下头像跳一下、笑一下（`tap` 反应），
/// 轻轻震一下（设置里关了触感就不震）。读屏照旧（头像念“名字，状态”）。
private struct ProfileHeader: View {
    let instance: Instance
    /// 新建、改头像时挑的形状和颜色（`AppModel.appearances`）。
    let appearance: InstanceAppearance
    /// 是不是主 Botin（`AppModel.local.primary`）：头像右下角换成星标（参考 10），状态在“工作区”那一行照样看得到。
    let isPrimary: Bool
    /// 头像的脸此刻的状态（按实例的状态和运行概况，和首页那一行一样）。
    let mood: BotinFaceMood
    let onEdit: @MainActor () -> Void

    /// 点头像的反应、点了几次（触感的触发器）。
    @State private var reactions: [BotinFaceReaction] = []
    @State private var taps = 0
    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.s) {
            InstanceAvatar(
                instance.name, appearance: appearance, size: ProfileAvatarMetrics.size,
                badge: isPrimary ? .primary : .instance(instance.state), mood: mood, reactions: reactions
            )
            .modifier(ProfileAvatarHeadroom())
            .dynamicTypeSize(...ProfileAvatarMetrics.maxDynamicType)
            .onTapGesture {
                let now = Date().timeIntervalSinceReferenceDate
                reactions = BotinFaceReaction.adding(BotinFaceReaction(.tap, start: now), to: reactions, now: now)
                taps += 1
            }
            .appFeedback(.impact(weight: .light), trigger: taps)
            Text(instance.name)
                .font(Font.title2.bold())
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button(InstanceProfileText.edit(language), action: onEdit)
                .glassButtonStyle()
                .buttonBorderShape(.capsule)
                .accessibilityHint(Text(language == .chinese ? "改名字和头像" : "Change the name and avatar"))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Metrics.Spacing.m)
    }
}

// MARK: - 这个目录共用的小帮手（列表样式、导航栏右边的位置挪到了 Components/ListStyles.swift）

/// 直接显示一个 Botin 的工作区页（预览和界面测试用：用环境里的客户端建资料页的视图模型、拉一次）。
struct InstanceWorkspacePreview: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client

    var body: some View {
        Content(client: client, instanceID: instanceID)
    }

    private struct Content: View {
        @State private var model: InstanceDetailModel

        init(client: any ClientProtocol, instanceID: InstanceID) {
            _model = State(initialValue: InstanceDetailModel(client: client, instanceID: instanceID))
        }

        var body: some View {
            let model = self.model
            InstanceWorkspaceScreen(model: model)
                .task { await model.load() }
        }
    }
}

#Preview("Botin 资料 · 浅色中文") {
    InstanceDetailScreen(instanceID: DemoData.writerID).previewShell()
}

#Preview("Botin 资料 · 深色英文") {
    InstanceDetailScreen(instanceID: DemoData.reviewerID).previewShell(.english, scheme: .dark)
}

#Preview("Botin 资料 · 找不到") {
    InstanceDetailScreen(instanceID: "gone").previewShell()
}
