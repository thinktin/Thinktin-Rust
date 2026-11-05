import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 应用框架（WBS 12.16）的界面：四种登录状态、首页（实例列表、工作台菜单、搜索结果）、两层 sheet、全局横幅，
/// 以及每个页面的接入点都能布局。
/// 逻辑（路由、深链、全局状态）在 ThinktinKitTests 的 Navigation、Shell 里测。
@MainActor
@Suite("应用框架的界面")
struct AppShellTests {
    /// 每个页面一个样本。
    static let routes: [AppRoute] = [
        .signIn, .account, .devices, .home, .conversation(DemoData.writerID), .run(DemoData.postRunID),
        .runTree(DemoData.postRunID), .activeRuns, .agentCatalog, .agent(DemoData.claudeAgentID),
        .instance(DemoData.writerID), .credentials, .addCredential, .credential(DemoData.claudeCredentialID),
        .modelRoutes(DemoData.writerID), .usage, .plans(instanceID: nil), .plans(instanceID: DemoData.writerID),
        .plan(DemoData.digestPlanID), .newPlan(instanceID: nil),
        .editPlan(DemoData.digestPlanID), .confirmPlan(DemoData.agentPlanID), .teams, .team(DemoData.releaseTeamID),
        .teamTemplates,
        .pipelineEditor(planID: nil, teamID: DemoData.releaseTeamID), .inbox, .inboxItem("inbox-1"), .approvals,
        .approval(DemoData.pendingApprovalID), .artifacts(instanceID: nil), .vault, .vaultItem(DemoData.githubVaultID),
        .vaultRequest(DemoData.npmVaultRequestID), .settings, .licenses, .about, .imChannels, .onboarding, .search,
        .newTask, .frozen, .upgrade, .adopt(agentID: nil), .adopt(agentID: DemoData.claudeAgentID),
    ]

    private func started(_ client: MockClient) async -> AppModel {
        let model = AppModel(client: client, defaults: nil)
        await model.start()
        return model
    }

    @Test("四种登录状态都能布局")
    func phases() async {
        let signedIn = await started(ShellPreviewClients.signedIn())
        #expect(signedIn.phase == .signedIn)
        hostAndLayout(AppShell(model: signedIn))
        hostAndLayout(AppShell(model: signedIn).environment(\.displayLanguage, .english).preferredColorScheme(.dark))

        let signedOut = await started(ShellPreviewClients.signedOut())
        #expect(signedOut.phase == .signedOut)
        hostAndLayout(AppShell(model: signedOut))

        let frozen = await started(ShellPreviewClients.frozen())
        #expect(frozen.phase == .frozen)
        hostAndLayout(AppShell(model: frozen))

        let upgrade = await started(ShellPreviewClients.upgradeRequired())
        #expect(upgrade.phase == .upgradeRequired)
        hostAndLayout(AppShell(model: upgrade).environment(\.displayLanguage, .english))
    }

    @Test("压了页面、开着 sheet 的主界面")
    func stackAndSheet() async {
        let model = await started(ShellPreviewClients.signedIn())
        model.router.open(.conversation(DemoData.writerID))
        model.router.open(.run(DemoData.postRunID))
        model.router.open(.runTree(DemoData.postRunID))
        hostAndLayout(AppShell(model: model))
        model.startNewTask()
        #expect(model.router.sheet == .newTask)
        hostAndLayout(AppShell(model: model))
    }

    @Test("设置是 sheet：里面压栈、再叠一层添加 key")
    func settingsSheet() async {
        let model = await started(ShellPreviewClients.signedIn())
        model.router.open(.settings)
        #expect(model.router.sheet == .settings)
        hostAndLayout(AppShell(model: model))
        model.router.open(.credentials)
        model.router.open(.addCredential)
        #expect(model.router.sheetPath == [.credentials])
        #expect(model.router.nestedSheet == .addCredential)
        hostAndLayout(AppShell(model: model).environment(\.displayLanguage, .english).preferredColorScheme(.dark))
        // 设置的根页面由应用框架补关闭按钮，其余 sheet 自己带（新建 Botin 的表单自己有 ×，填了名字时先确认）。
        #expect(SheetStack.addsCloseButton(to: .settings))
        #expect(!SheetStack.addsCloseButton(to: .adopt(agentID: nil)))
        #expect(!SheetStack.addsCloseButton(to: .newTask))
        #expect(!SheetStack.addsCloseButton(to: .addCredential))
    }

    @Test("每个页面的接入点都能布局（中文浅色、英文深色）")
    func everyDestination() {
        for route in Self.routes {
            hostAndLayout(AppDestination(route: route).previewShell())
            hostAndLayout(AppDestination(route: route).previewShell(.english, scheme: .dark))
        }
    }

    @Test("跑通首页 → 对话 → 实例资料，回到首页再开设置（sheet）")
    func homeToProfileAndSettings() async throws {
        let model = await started(ShellPreviewClients.signedIn())
        let router = model.router
        let first = try #require(model.homeRows.first)
        #expect(router.isAtRoot)
        hostAndLayout(AppShell(model: model))
        // 首页的行是按钮（plain 列表里的 `NavigationLink` 会画 chevron）：`Router.open` 压进主栈、记成当前实例。
        router.open(.conversation(first.id))
        #expect(router.path == [.conversation(first.id)])
        #expect(router.currentInstanceID == first.id)
        hostAndLayout(AppShell(model: model))
        // 对话的“…”菜单 → 实例资料（旧版式）。
        router.open(.instance(first.id))
        #expect(router.path == [.conversation(first.id), .instance(first.id)])
        hostAndLayout(AppShell(model: model).environment(\.displayLanguage, .english).preferredColorScheme(.dark))
        // 系统的返回两次回到首页，左上头像弹出设置。
        router.pop()
        router.pop()
        #expect(router.isAtRoot)
        router.open(.settings)
        #expect(router.sheet == .settings)
        #expect(router.path.isEmpty)
        hostAndLayout(AppShell(model: model))
        router.dismissSheet()
        #expect(router.sheet == nil)
        // 右上“+”弹出新建 Botin 的表单；表单里“了解引擎”压进引擎目录和详情。
        router.open(.adopt(agentID: nil))
        #expect(router.sheet == .adopt(agentID: nil))
        hostAndLayout(AppShell(model: model))
        router.open(.agentCatalog)
        router.open(.agent(DemoData.codexAgentID))
        hostAndLayout(AppShell(model: model))
        // 详情上“用它新建 Botin”：回到表单、换成这个引擎。
        router.open(.adopt(agentID: DemoData.codexAgentID))
        #expect(router.sheet == .adopt(agentID: nil) && router.sheetPath.isEmpty)
        #expect(router.engineRequest == DemoData.codexAgentID)
        hostAndLayout(AppShell(model: model))
    }

    @Test("首页：有实例、没有实例、离线、拉取失败")
    func home() async {
        let model = await started(ShellPreviewClients.signedIn())
        #expect(!model.homeRows.isEmpty)
        hostAndLayout(NavigationStack { HomeScreen() }.shellEnvironment(model))
        hostAndLayout(
            NavigationStack { HomeScreen() }.shellEnvironment(model)
                .environment(\.displayLanguage, .english)
                .preferredColorScheme(.dark))

        let empty = await started(ShellPreviewClients.empty())
        #expect(empty.hasLoadedInstances)
        #expect(empty.homeRows.isEmpty)
        #expect(empty.homePlaceholder == .noBotins)
        hostAndLayout(NavigationStack { HomeScreen() }.shellEnvironment(empty))
        hostAndLayout(NavigationStack { HomeInstanceList(model: empty) }.shellEnvironment(empty))

        let offlineClient = ShellPreviewClients.signedIn()
        for _ in 0..<6 { offlineClient.failNext(with: .network(message: "offline")) }
        let offline = await started(offlineClient)
        #expect(offline.isOffline)
        hostAndLayout(AppShell(model: offline))
        // 新账号、离线：只说这台设备上没有，不引导新建。
        let offlineEmptyClient = ShellPreviewClients.empty()
        for _ in 0..<6 { offlineEmptyClient.failNext(with: .network(message: "offline")) }
        let offlineEmpty = await started(offlineEmptyClient)
        #expect(offlineEmpty.homePlaceholder == .offlineWithoutCache)
        hostAndLayout(NavigationStack { HomeInstanceList(model: offlineEmpty) }.shellEnvironment(offlineEmpty))

        let failingClient = ShellPreviewClients.signedIn()
        failingClient.failNext(
            "instances()", with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        let failing = await started(failingClient)
        hostAndLayout(NavigationStack { HomeInstanceList(model: failing) }.shellEnvironment(failing))
    }

    @Test("首页的行：预览文字和头像角标（在等你处理、进行中、闲着）")
    func homeRows() async throws {
        #expect(HomeRowPreview.waiting(count: 2, state: .waitingApproval).text(.chinese) == "2 个在等你处理")
        #expect(HomeRowPreview.waiting(count: 1, state: .waitingDevice).text(.english) == "1 waiting for you")
        #expect(HomeRowPreview.active(count: 1, state: .running).text(.chinese) == "运行中")
        #expect(HomeRowPreview.active(count: 3, state: .queued).text(.chinese) == "排队中 · 共 3 个")
        #expect(HomeRowPreview.active(count: 3, state: .running).text(.english) == "Running · 3 in progress")
        #expect(HomeRowPreview.idle(.running).text(.chinese) == "随时可以接任务")
        #expect(HomeRowPreview.idle(.running).text(.english) == "Ready for a task")
        #expect(HomeRowPreview.idle(.paused).text(.chinese) == "已暂停")
        #expect(HomeRowPreview.waiting(count: 2, state: .waitingApproval).avatarBadge == .run(.waitingApproval))
        #expect(HomeRowPreview.active(count: 1, state: .running).avatarBadge == .run(.running))
        #expect(HomeRowPreview.idle(.running).avatarBadge == nil)
        #expect(HomeRowPreview.idle(.provisioning).avatarBadge == .instance(.provisioning))
        #expect(HomeRowPreview.idle(.archived).avatarBadge == .instance(.archived))
        // 预览是最后一条时，暂停、归档只画在角标上：读屏另外念状态；开着的、别的预览不念。
        let last = HomeLastMessage(author: .agent, text: "好了", runID: "r1", at: Date())
        #expect(HomeRowPreview.message(last, state: .paused).spokenState(.chinese) == "已暂停")
        #expect(HomeRowPreview.message(last, state: .running).spokenState(.chinese) == nil)
        #expect(HomeRowPreview.idle(.paused).spokenState(.chinese) == nil)

        let model = await started(ShellPreviewClients.signedIn())
        for row in model.homeRows {
            hostAndLayout(List { HomeInstanceRow(row: row) }.shellEnvironment(model))
        }
        // 新建时挑过形状和颜色的 Botin：行上画它挑的头像（首页按 `AppModel.appearances` 传进来）。
        let first = try #require(model.homeRows.first)
        model.appearances.set(InstanceAppearance(shape: .hexagon, color: .orchid), for: first.id)
        #expect(model.appearances.resolved(for: first.id).shape == .hexagon)
        hostAndLayout(
            List { HomeInstanceRow(row: first, appearance: model.appearances.resolved(for: first.id)) }
                .shellEnvironment(model))
        hostAndLayout(NavigationStack { HomeScreen() }.shellEnvironment(model))
    }

    @Test("首页的行：最后一条的预览（AI 标识、你：），长按的预览卡")
    func homeRowMessages() async throws {
        let reply = HomeLastMessage(author: .agent, text: "周报整理好了，\n分了三组。", runID: "r1", at: Date())
        let task = HomeLastMessage(author: .user, text: "发到群里", runID: "r2", at: Date())
        #expect(HomeRowPreview.message(reply, state: .running).text(.chinese) == "周报整理好了， 分了三组。")
        #expect(HomeRowPreview.message(task, state: .running).text(.chinese) == "你：发到群里")
        #expect(HomeRowPreview.message(task, state: .running).text(.english) == "You: 发到群里")
        #expect(HomeRowPreview.message(reply, state: .running).isAIGenerated)
        #expect(!HomeRowPreview.message(task, state: .running).isAIGenerated)
        #expect(!HomeRowPreview.idle(.running).isAIGenerated)
        #expect(HomeRowPreview.message(reply, state: .running).avatarBadge == nil)
        #expect(HomeRowPreview.message(reply, state: .paused).avatarBadge == .instance(.paused))
        #expect(HomeRowPreview.waiting(count: 1, state: .waitingApproval).statusLine(.chinese) == "1 个在等你处理")
        #expect(HomeRowPreview.message(reply, state: .running).statusLine(.chinese) == nil)

        let model = await started(ShellPreviewClients.signedIn())
        #expect(!model.lastMessages.isEmpty)
        for row in model.homeRows {
            let appearance = model.appearances.resolved(for: row.id)
            hostAndLayout(List { HomeInstanceRow(row: row, appearance: appearance) }.shellEnvironment(model))
            hostAndLayout(HomeInstancePreviewCard(row: row, appearance: appearance).shellEnvironment(model))
        }
        let first = try #require(model.homeRows.first)
        var withReply = first
        withReply.lastMessage = reply
        withReply.preview = .message(reply, state: .running)
        hostAndLayout(HomeInstancePreviewCard(row: withReply).previewShell(.english, scheme: .dark))
        var withTask = first
        withTask.lastMessage = task
        hostAndLayout(HomeInstancePreviewCard(row: withTask).previewShell())
    }

    @Test("首页：置顶的大头像、隐藏、都隐藏了的空状态、已隐藏页和说明、长按菜单")
    func homePinAndHide() async throws {
        let model = await started(ShellPreviewClients.signedIn())
        let preferences = model.instancePreferences
        preferences.setPinned(true, for: DemoData.writerID)
        #expect(model.homeContent.pinned.map(\.id) == [DemoData.writerID])
        hostAndLayout(NavigationStack { HomeScreen() }.shellEnvironment(model))
        hostAndLayout(
            NavigationStack { HomeInstanceList(model: model) }.shellEnvironment(model)
                .environment(\.displayLanguage, .english)
                .preferredColorScheme(.dark))
        hostAndLayout(
            PinnedInstancesGrid(
                rows: model.homeContent.pinned, appearances: model.appearances, open: { _ in },
                menu: { _ in HomeInstanceMenuContent(isPinned: true, isOffline: false) { _ in } }
            )
            .shellEnvironment(model))
        // 一排 3 个，最后一排可以不满。
        let rows = model.homeRows
        let seven = Array(repeating: rows, count: 4).joined().prefix(7).map { $0 }
        #expect(PinnedInstancesGrid<EmptyView>.chunks(seven).map(\.count) == [3, 3, 1])
        #expect(PinnedInstancesGrid<EmptyView>.chunks([]).isEmpty)

        // 隐藏一个：首页最底下有“已隐藏 1 个 Botin”，已隐藏页有一行。
        preferences.setHidden(true, for: DemoData.reviewerID)
        #expect(model.homeContent.hidden.map(\.id) == [DemoData.reviewerID])
        hostAndLayout(NavigationStack { HomeInstanceList(model: model) }.shellEnvironment(model))
        hostAndLayout(NavigationStack { HiddenInstancesScreen(model: model) }.shellEnvironment(model))
        hostAndLayout(
            List {
                HiddenInstanceRow(row: model.homeContent.hidden[0], open: {}, unhide: {})
            }
            .previewShell(.english, scheme: .dark))

        // 都隐藏了：参考 113 的空状态。
        preferences.setHidden(true, for: DemoData.writerID)
        #expect(model.homePlaceholder == .allHidden)
        hostAndLayout(NavigationStack { HomeInstanceList(model: model) }.shellEnvironment(model))
        hostAndLayout(HomeAllHiddenView {}.previewShell(.english, scheme: .dark))

        // 都取消隐藏：已隐藏页正中一行灰字。
        preferences.setHidden(false, for: DemoData.writerID)
        preferences.setHidden(false, for: DemoData.reviewerID)
        #expect(model.homeContent.hidden.isEmpty)
        hostAndLayout(NavigationStack { HiddenInstancesScreen(model: model) }.shellEnvironment(model))
        hostAndLayout(HidingHelpSheet().previewShell())
        hostAndLayout(HidingHelpSheet().previewShell(.english, scheme: .dark))

        // 长按菜单、左滑按钮（离线时要联网的灰掉）。
        for offline in [false, true] {
            hostAndLayout(
                Menu("…") { HomeInstanceMenuContent(isPinned: offline, isOffline: offline) { _ in } }
                    .previewShell())
        }
        hostAndLayout(
            List { Text(verbatim: "行").swipeActions { HomeInstanceSwipeButtons(isPinned: false) { _ in } } }
                .previewShell())
    }

    @Test("工作台按钮的读屏：标签只是名字，要处理的数在角标的值里，合起来只念一次")
    func workbenchAccessibility() {
        for language in [DisplayLanguage.chinese, .english] {
            let label = ShellBadges.workbenchTitle(language)
            #expect(!label.contains { $0.isNumber })
            for count in [0, 5, 120] {
                let spoken = label + " " + ToolbarBadgeText.accessibilityValue(count)
                #expect(spoken.components(separatedBy: String(count)).count - 1 == (count > 0 ? 1 : 0))
            }
        }
        #expect(ToolbarBadgeText.display(0) == nil)
        #expect(ToolbarBadgeText.display(7) == "7")
        #expect(ToolbarBadgeText.display(120) == "99+")
        #expect(ToolbarBadgeText.accessibilityValue(120) == "120")
    }

    @Test("工作台菜单：总角标只算要你处理的；菜单项和抽屉原来的入口一一对应")
    func workbenchMenu() async {
        let model = await started(ShellPreviewClients.signedIn())
        let badges = model.badges
        #expect(
            badges.workbenchTotal == badges.inboxUnread + badges.pendingApprovals + badges.plansAwaitingConfirmation)
        #expect(WorkbenchEntry.allCases.allSatisfy { $0.route.isTopLevel })
        hostAndLayout(
            NavigationStack {
                Text(verbatim: "首页")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) { WorkbenchMenu(model: model) }
                    }
            }
            .shellEnvironment(model))
        hostAndLayout(
            NavigationStack {
                Text(verbatim: "Home")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) { WorkbenchMenu(model: model) }
                    }
            }
            .shellEnvironment(model)
            .environment(\.displayLanguage, .english)
            .preferredColorScheme(.dark))
    }

    @Test("首页的搜索结果：有结果、没结果；搜索请求回到首页")
    func homeSearch() async {
        let model = await started(ShellPreviewClients.signedIn())
        let search = SearchModel(client: model.client)
        search.loadCache()
        search.query = "写作"
        #expect(search.isSearching)
        #expect(!search.isEmpty)
        hostAndLayout(NavigationStack { SearchResultsView(search: search) }.shellEnvironment(model))
        search.query = "没有这个词 zzz"
        #expect(search.isEmpty)
        hostAndLayout(
            NavigationStack { SearchResultsView(search: search) }.shellEnvironment(model)
                .environment(\.displayLanguage, .english))

        model.router.open(.instance(DemoData.writerID))
        model.router.open(.search)
        #expect(model.router.isAtRoot)
        #expect(model.router.hasPendingSearchRequest)
        hostAndLayout(AppShell(model: model))
    }

    @Test("全局横幅：连接中、重连、离线（有缓存、没有缓存）")
    func banners() {
        renderInBothAppearances(ConnectionBanner(state: .connecting))
        renderInBothAppearances(ConnectionBanner(state: .reconnecting(retryAt: Date().addingTimeInterval(5))))
        for policy in OfflinePolicy.allCases {
            if let message = policy.bannerMessage(.chinese) {
                renderInBothAppearances(OfflineBanner(message: message) {})
            }
        }
    }

    @Test("冻结页、升级页（有没有 App Store 链接）")
    func accountStatePages() async {
        let frozen = await started(ShellPreviewClients.frozen())
        hostAndLayout(FrozenView(model: frozen).shellEnvironment(frozen))
        hostAndLayout(UpgradeView())
        hostAndLayout(UpgradeView(appStoreURL: URL(string: "https://apps.apple.com/")))
    }
}
