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
        // 设置、领养的根页面由应用框架补关闭按钮，其余 sheet 自己带“取消 / 完成”。
        #expect(SheetStack.addsCloseButton(to: .settings))
        #expect(SheetStack.addsCloseButton(to: .adopt(agentID: nil)))
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
        // 首页的行是 `NavigationLink(value: .conversation(id))`：系统直接往主栈里压，`Router` 记成当前实例。
        router.path.append(.conversation(first.id))
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
        // 右上“+”弹出领养。
        router.open(.adopt(agentID: nil))
        #expect(router.sheet == .adopt(agentID: nil))
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
        hostAndLayout(NavigationStack { HomeScreen() }.shellEnvironment(empty))
        hostAndLayout(NavigationStack { HomeInstanceList(model: empty) }.shellEnvironment(empty))

        let offlineClient = ShellPreviewClients.signedIn()
        for _ in 0..<6 { offlineClient.failNext(with: .network(message: "offline")) }
        let offline = await started(offlineClient)
        #expect(offline.isOffline)
        hostAndLayout(AppShell(model: offline))

        let failingClient = ShellPreviewClients.signedIn()
        failingClient.failNext(
            "instances()", with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        let failing = await started(failingClient)
        hostAndLayout(NavigationStack { HomeInstanceList(model: failing) }.shellEnvironment(failing))
    }

    @Test("首页的行：预览文字和头像角标（在等你处理、进行中、闲着）")
    func homeRows() async {
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

        let model = await started(ShellPreviewClients.signedIn())
        for row in model.homeRows {
            hostAndLayout(List { HomeInstanceRow(row: row) }.shellEnvironment(model))
        }
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
        hostAndLayout(NavigationStack { HomeSearchResults(search: search) }.shellEnvironment(model))
        search.query = "没有这个词 zzz"
        #expect(search.isEmpty)
        hostAndLayout(
            NavigationStack { HomeSearchResults(search: search) }.shellEnvironment(model)
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
