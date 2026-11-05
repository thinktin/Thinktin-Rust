import SwiftUI
import ThinktinKit

/// Botin 资料（`.instance(id)`，规范 4.4.1、4.4.2，参考 09、10）：对话页标题、深链 `thinktin://instance/{id}`、引擎详情的
/// “在用它的 Botin”进来。分组列表（insetGrouped），没有标题：
///
/// - 头部：头像（右下状态角标）、名字、玻璃小胶囊“编辑”（压进 `InstanceEditScreen`：名字、头像）；
/// - 第一组：计划（“N 个生效”，进这个 Botin 的计划）、产出物、工作区（值是状态，进 `InstanceWorkspaceScreen`：状态说明、
///   升级 / 回滚）；
/// - 默认模型（main 指向的上游模型，没配时警告色“未配置”，进模型路由）；
/// - 所在团队（每个团队一行）；信息（引擎和版本、接入方式、创建于、最近活动）；
/// - 右上只有“…”一个玻璃圆（复制 Botin ID；模型路由、新建计划；删除，`InstanceProfileMenu`）：参考旁边那个是分享，
///   ThinkTin 不做（6.21），也不拿别的按钮占那个位置（规范 4.4.1）。删除先列出会级联删掉的东西（`InstanceDeleteSheet`），
///   二次确认后再删。
///
/// 页面的离线策略是“有缓存”：离线时照样显示缓存里的 Botin，改名、换版本、删除、新建计划都禁用（头像只存在这台设备上，照样能改）。
/// 参考的“通知”开关等后端（6.14）。
struct InstanceDetailScreen: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app

    var body: some View {
        InstanceDetailContent(
            client: client, instanceID: instanceID, instance: app.instances.first { $0.id == instanceID },
            appearances: app.appearances)
    }
}

private struct InstanceDetailContent: View {
    @State private var model: InstanceDetailModel
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    /// 复制了几次 id（成功触感的触发器）。
    @State private var copies = 0

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(
        client: any ClientProtocol, instanceID: InstanceID, instance: Instance?, appearances: InstanceAppearanceStore
    ) {
        _model = State(
            initialValue: InstanceDetailModel(
                client: client, instanceID: instanceID, instance: instance, appearances: appearances))
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
                        instance: instance, appearance: app.appearances.resolved(for: instance.id)
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
                modelSection(instance)
                teamSection
                infoSection(instance)
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(model.instance?.name ?? AppRoute.instance(model.instanceID).title(language)) {
            // 参考 09 没有标题（头部已经有名字），导航栏中间空着；返回按钮的长按菜单照样写名字。
            EmptyView()
        }
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
        .refreshable { await model.load() }
        .task { await model.load() }
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
                    Label(InstanceProfileText.plans(language), systemImage: "clock")
                }
            }
            NavigationLink(value: AppRoute.artifacts(instanceID: instance.id)) {
                Label(InstanceProfileText.artifacts(language), systemImage: "folder")
            }
            NavigationLink {
                InstanceWorkspaceScreen(model: model)
            } label: {
                LabeledContent {
                    Text(instance.state.localizedName(language))
                } label: {
                    Label(InstanceProfileText.workspace(language), systemImage: "desktopcomputer")
                }
            }
        }
        .themedRow()
    }

    /// 默认模型（main 指向的上游模型），没配时警告色“未配置”，脚注说怎么办。
    private func modelSection(_ instance: Instance) -> some View {
        let status = model.routeStatus
        return Section {
            NavigationLink(value: AppRoute.modelRoutes(instance.id)) {
                LabeledContent {
                    if let value = status.defaultModelValue(language) {
                        Text(value)
                            .foregroundStyle(status.needsAttention ? StatusTone.waiting.color : Theme.inkSecondary)
                            .lineLimit(1)
                    }
                } label: {
                    Label(InstanceProfileText.defaultModel(language), systemImage: "cpu")
                }
            }
        } footer: {
            if status.needsAttention {
                Text(status.summary(language))
            }
        }
        .themedRow()
    }

    @ViewBuilder
    private var teamSection: some View {
        let zh = language == .chinese
        if let teams = model.teams, !teams.isEmpty {
            Section {
                ForEach(teams) { team in
                    NavigationLink(value: AppRoute.team(team.id)) {
                        LabeledContent {
                            Text(model.role(in: team) == .lead ? (zh ? "负责人" : "Lead") : (zh ? "成员" : "Member"))
                        } label: {
                            Label(team.name, systemImage: "person.3")
                        }
                    }
                }
            } header: {
                Text(InstanceProfileText.teamsSection(language))
                    .textCase(nil)
            }
            .themedRow()
        }
    }

    private func infoSection(_ instance: Instance) -> some View {
        let zh = language == .chinese
        return Section {
            LabeledContent(
                zh ? "引擎" : "Engine",
                value: model.agentDisplayName + " · " + AgentsText.versionLabel(instance.agentVersion))
            LabeledContent(
                zh ? "接入方式" : "Runs via", value: AgentsText.harnessName(instance.harness, language: language))
            LabeledContent(zh ? "创建于" : "Created", value: Formatting.dateTime(instance.createdAt, language: language))
            LabeledContent(
                zh ? "最近活动" : "Last active", value: Formatting.relativeTime(instance.lastActiveAt, language: language))
        } header: {
            Text(InstanceProfileText.infoSection(language))
                .textCase(nil)
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
    /// 实例删掉之后：各层导航栈里从它的第一个页面（对话、实例资料、它的路由、产出物）起都拿掉，删掉首页记的置顶、隐藏，
    /// 再刷新应用框架的实例列表（当前实例被删时应用框架会换成别的实例）。资料页和首页长按的删除都走这里。
    @MainActor
    static func leaveDeletedInstance(_ id: InstanceID, app: AppModel, router: Router) async {
        router.removeRoutes(of: id)
        app.instancePreferences.forget([id])
        await app.refresh()
    }
}

/// 头部（参考 09）：居中的头像（右下状态角标）、名字、玻璃小胶囊“编辑”。
private struct ProfileHeader: View {
    let instance: Instance
    /// 新建、改头像时挑的形状和颜色（`AppModel.appearances`）。
    let appearance: InstanceAppearance
    let onEdit: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.s) {
            InstanceAvatar(
                instance.name, appearance: appearance, size: ProfileAvatarMetrics.size,
                badge: .instance(instance.state)
            )
            .dynamicTypeSize(...ProfileAvatarMetrics.maxDynamicType)
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
        .padding(.vertical, Metrics.Spacing.s)
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
