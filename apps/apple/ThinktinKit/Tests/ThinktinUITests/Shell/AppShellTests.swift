import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 应用框架（WBS 12.16）的界面：四种登录状态、抽屉、实例切换、全局横幅，以及每个页面的接入点都能布局。
/// 逻辑（路由、深链、全局状态）在 ThinktinKitTests 的 Navigation、Shell 里测。
@MainActor
@Suite("应用框架的界面")
struct AppShellTests {
    /// 每个页面一个样本。
    static let routes: [AppRoute] = [
        .signIn, .account, .devices, .home, .conversation(DemoData.writerID), .run(DemoData.postRunID),
        .runTree(DemoData.postRunID), .activeRuns, .agentCatalog, .agent(DemoData.claudeAgentID),
        .instance(DemoData.writerID), .credentials, .addCredential, .credential(DemoData.claudeCredentialID),
        .modelRoutes(DemoData.writerID), .usage, .plans, .plan(DemoData.digestPlanID), .newPlan(instanceID: nil),
        .editPlan(DemoData.digestPlanID), .confirmPlan(DemoData.agentPlanID), .teams, .team(DemoData.releaseTeamID),
        .teamTemplates,
        .pipelineEditor(planID: nil, teamID: DemoData.releaseTeamID), .inbox, .inboxItem("inbox-1"), .approvals,
        .approval(DemoData.pendingApprovalID), .artifacts(instanceID: nil), .vault, .vaultItem(DemoData.githubVaultID),
        .vaultRequest(DemoData.npmVaultRequestID), .settings, .licenses, .about, .imChannels, .onboarding, .search,
        .newTask, .frozen, .upgrade,
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
        model.router.open(.run(DemoData.postRunID))
        model.router.open(.runTree(DemoData.postRunID))
        hostAndLayout(AppShell(model: model))
        model.startNewTask()
        #expect(model.router.sheet == .newTask)
        hostAndLayout(AppShell(model: model))
    }

    @Test("每个页面的接入点都能布局（中文浅色、英文深色）")
    func everyDestination() {
        for route in Self.routes {
            hostAndLayout(AppDestination(route: route).previewShell())
            hostAndLayout(AppDestination(route: route).previewShell(.english, scheme: .dark))
        }
    }

    @Test("抽屉：有实例、没有实例、离线")
    func drawer() async {
        let model = await started(ShellPreviewClients.signedIn())
        model.router.openDrawer()
        hostAndLayout(ShellDrawer(model: model).shellEnvironment(model))
        hostAndLayout(
            ShellDrawer(model: model).shellEnvironment(model).environment(\.displayLanguage, .english)
                .preferredColorScheme(.dark))

        let empty = await started(ShellPreviewClients.empty())
        empty.router.openDrawer()
        #expect(empty.instances.isEmpty)
        hostAndLayout(ShellDrawer(model: empty).shellEnvironment(empty))

        model.router.closeDrawer()
        hostAndLayout(ShellDrawer(model: model).shellEnvironment(model), expectContent: false)
    }

    @Test("实例切换菜单：有实例、没有实例")
    func instanceSwitcher() async {
        let model = await started(ShellPreviewClients.signedIn())
        #expect(model.currentInstance != nil)
        hostAndLayout(InstanceSwitcher(model: model))
        let empty = await started(ShellPreviewClients.empty())
        hostAndLayout(InstanceSwitcher(model: empty))
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
