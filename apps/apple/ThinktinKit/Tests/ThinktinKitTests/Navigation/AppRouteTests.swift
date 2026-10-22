import Foundation
import Testing

@testable import ThinktinKit

// AppRoute：每个页面都有负责的功能、出现方式、离线策略、标题；每个功能都有接入点文件。

/// 每个 case 一个样本（有关联值的取一个代表值）。`index(of:)` 是穷举的 switch：AppRoute 加了 case 这里编译不过，
/// 提醒把新 case 加进样本。
enum RouteSamples {
    static let all: [AppRoute] = [
        .signIn, .account, .devices,
        .home, .conversation("inst-1"), .run("run-1"), .runTree("run-1"), .activeRuns,
        .agentCatalog, .agent("claude"), .instance("inst-1"),
        .credentials, .addCredential, .credential("cred-1"), .modelRoutes("inst-1"), .usage,
        .plans, .plan("plan-1"), .newPlan(instanceID: nil), .editPlan("plan-1"),
        .teams, .team("team-1"), .teamTemplates, .pipelineEditor(planID: nil, teamID: "team-1"),
        .inbox, .inboxItem("inbox-1"),
        .approvals, .approval("appr-1"),
        .artifacts(instanceID: nil),
        .vault, .vaultItem("vault-1"), .vaultRequest("vreq-1"),
        .settings, .licenses, .about,
        .imChannels,
        .onboarding,
        .search,
        .newTask, .frozen, .upgrade,
    ]

    static let caseCount = 41

    static func index(of route: AppRoute) -> Int {
        switch route {
        case .signIn: 0
        case .account: 1
        case .devices: 2
        case .home: 3
        case .conversation: 4
        case .run: 5
        case .runTree: 6
        case .activeRuns: 7
        case .agentCatalog: 8
        case .agent: 9
        case .instance: 10
        case .credentials: 11
        case .addCredential: 12
        case .credential: 13
        case .modelRoutes: 14
        case .usage: 15
        case .plans: 16
        case .plan: 17
        case .newPlan: 18
        case .editPlan: 19
        case .teams: 20
        case .team: 21
        case .teamTemplates: 22
        case .pipelineEditor: 23
        case .inbox: 24
        case .inboxItem: 25
        case .approvals: 26
        case .approval: 27
        case .artifacts: 28
        case .vault: 29
        case .vaultItem: 30
        case .vaultRequest: 31
        case .settings: 32
        case .licenses: 33
        case .about: 34
        case .imChannels: 35
        case .onboarding: 36
        case .search: 37
        case .newTask: 38
        case .frozen: 39
        case .upgrade: 40
        }
    }
}

@Suite("页面路由")
struct AppRouteTests {
    @Test("样本覆盖了每个 case")
    func samplesCoverEveryCase() {
        #expect(Set(RouteSamples.all.map(RouteSamples.index(of:))) == Set(0..<RouteSamples.caseCount))
        #expect(RouteSamples.all.count == RouteSamples.caseCount)
    }

    @Test("每个页面都有中英文标题")
    func titles() {
        for route in RouteSamples.all {
            let zh = route.title(.chinese)
            let en = route.title(.english)
            #expect(!zh.isEmpty && !en.isEmpty, "\(route)")
            #expect(zh != en, "\(route)")
        }
        #expect(AppRoute.pipelineEditor(planID: nil, teamID: nil).title(.chinese) == "新建流水线")
        #expect(AppRoute.pipelineEditor(planID: "p", teamID: nil).title(.chinese) == "编辑流水线")
    }

    @Test("页面归哪个功能（工作包）")
    func features() {
        let expected: [AppRoute: AppFeature] = [
            .signIn: .account, .devices: .account, .account: .account,
            .home: .conversation, .conversation("i"): .conversation, .run("r"): .conversation,
            .runTree("r"): .conversation, .activeRuns: .conversation,
            .agentCatalog: .agents, .agent("a"): .agents, .instance("i"): .agents,
            .credentials: .models, .addCredential: .models, .credential("c"): .models, .modelRoutes("i"): .models,
            .usage: .models,
            .plans: .plans, .plan("p"): .plans, .newPlan(instanceID: "i"): .plans, .editPlan("p"): .plans,
            .teams: .teams, .team("t"): .teams, .teamTemplates: .teams,
            .pipelineEditor(planID: "p", teamID: nil): .teams,
            .inbox: .inbox, .inboxItem("x"): .inbox,
            .approvals: .approvals, .approval("a"): .approvals,
            .artifacts(instanceID: "i"): .artifacts,
            .vault: .vault, .vaultItem("v"): .vault, .vaultRequest("v"): .vault,
            .settings: .settings, .licenses: .settings, .about: .settings,
            .imChannels: .imChannels, .onboarding: .onboarding, .search: .search,
            .newTask: .shell, .frozen: .shell, .upgrade: .shell,
        ]
        for (route, feature) in expected {
            #expect(route.feature == feature, "\(route)")
        }
        // 每个功能至少负责一个页面。
        #expect(Set(RouteSamples.all.map(\.feature)) == Set(AppFeature.allCases))
    }

    @Test("出现方式：根、压栈、sheet、整页")
    func presentation() {
        #expect(AppRoute.home.presentation == .root)
        #expect(AppRoute.conversation("i").presentation == .root)
        for route in [AppRoute.signIn, .frozen, .upgrade] {
            #expect(route.presentation == .global)
        }
        for route in [AppRoute.newTask, .addCredential, .newPlan(instanceID: nil), .editPlan("p"), .onboarding] {
            #expect(route.presentation == .sheet, "\(route)")
        }
        for route in [
            AppRoute.run("r"), .inbox, .settings, .vaultRequest("v"), .pipelineEditor(planID: nil, teamID: nil),
        ] {
            #expect(route.presentation == .push, "\(route)")
        }
    }

    @Test("抽屉直达的顶级页面")
    func topLevel() {
        for route in [AppRoute.inbox, .approvals, .activeRuns, .plans, .teams, .settings, .search, .agentCatalog] {
            #expect(route.isTopLevel, "\(route)")
        }
        #expect(AppRoute.artifacts(instanceID: nil).isTopLevel)
        #expect(!AppRoute.artifacts(instanceID: "i").isTopLevel)
        #expect(!AppRoute.run("r").isTopLevel)
        #expect(!AppRoute.conversation("i").isTopLevel)
        // 抽屉入口都是顶级页面。
        for entry in DrawerEntry.allCases {
            #expect(entry.route.isTopLevel, "\(entry)")
        }
    }

    @Test("页面所属的实例")
    func owningInstance() {
        #expect(AppRoute.conversation("a").instanceID == "a")
        #expect(AppRoute.instance("b").instanceID == "b")
        #expect(AppRoute.modelRoutes("c").instanceID == "c")
        #expect(AppRoute.newPlan(instanceID: "d").instanceID == "d")
        #expect(AppRoute.artifacts(instanceID: "e").instanceID == "e")
        #expect(AppRoute.newPlan(instanceID: nil).instanceID == nil)
        #expect(AppRoute.run("r").instanceID == nil)
    }

    @Test("离线策略：只有实例、运行、事件、收件箱有缓存")
    func offlinePolicy() {
        for route in [
            AppRoute.home, .conversation("i"), .run("r"), .runTree("r"), .activeRuns, .instance("i"), .inbox,
            .inboxItem("x"),
        ] {
            #expect(route.offlinePolicy == .cached, "\(route)")
        }
        for route in [
            AppRoute.plans, .plan("p"), .approvals, .credentials, .modelRoutes("i"), .usage, .vault, .teams,
            .agentCatalog, .imChannels, .devices, .artifacts(instanceID: nil),
        ] {
            #expect(route.offlinePolicy == .unavailable, "\(route)")
        }
        for route in [AppRoute.licenses, .about, .search, .settings] {
            #expect(route.offlinePolicy == .local, "\(route)")
        }
        #expect(OfflinePolicy.local.bannerMessage(.chinese) == nil)
        #expect(OfflinePolicy.cached.bannerMessage(.chinese) == "离线，显示的是缓存内容")
        #expect(OfflinePolicy.unavailable.bannerMessage(.english)?.hasPrefix("Offline") == true)
        // 离线时只有收件箱能写（标已读）。
        #expect(RouteSamples.all.filter(\.allowsWritesOffline) == [.inbox, .inboxItem("inbox-1")])
    }

    @Test("能编解码（恢复导航栈用）")
    func codable() throws {
        let data = try JSONEncoder().encode(RouteSamples.all)
        #expect(try JSONDecoder().decode([AppRoute].self, from: data) == RouteSamples.all)
    }

    @Test("功能：工作包编号、目录名、接入点类型名")
    func featureMetadata() {
        #expect(AppFeature.account.directory == "Account")
        #expect(AppFeature.imChannels.directory == "ImChannels")
        #expect(AppFeature.conversation.destinationTypeName == "ConversationDestination")
        #expect(AppFeature.shell.workPackage == "12.16")
        #expect(Set(AppFeature.allCases.map(\.workPackage)).count == AppFeature.allCases.count)
        #expect(Set(AppFeature.allCases.map(\.directory)).count == AppFeature.allCases.count)
    }

    @Test("每个功能都有接入点文件（Screens/<目录>/<目录>Destination.swift，shell 在 Shell/）")
    func destinationFilesExist() throws {
        // 从这个测试文件的位置找到 ThinktinUI 的源码（Linux 上不编译它，但文件在）。
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Navigation
            .deletingLastPathComponent()  // ThinktinKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ThinktinKit
            .appendingPathComponent("Sources/ThinktinUI")
        for feature in AppFeature.allCases {
            let path =
                feature == .shell
                ? ui.appendingPathComponent("Shell/ShellDestination.swift")
                : ui.appendingPathComponent("Screens/\(feature.directory)/\(feature.destinationTypeName).swift")
            #expect(FileManager.default.fileExists(atPath: path.path), "\(path.path)")
            let source = try String(contentsOf: path, encoding: .utf8)
            #expect(source.contains("struct \(feature.destinationTypeName): View"), "\(feature)")
            #expect(source.contains("let route: AppRoute"), "\(feature)")
        }
    }
}
