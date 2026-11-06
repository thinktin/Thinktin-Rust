import Foundation
import Testing

@testable import Thinktin

/// App 的冒烟测试（WBS 12.1）：跑在模拟器上，宿主是 App 本身（`Bundle.main` 就是 App 的包）。
/// 查生成的 Info.plist、打进包里的资源、启动配置；界面和视图模型的测试在 ThinktinKit 里。
@Suite("App 冒烟测试")
struct AppSmokeTests {
    @Test("Info.plist：显示名、语言、接口地址")
    func infoPlist() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["CFBundleDisplayName"] as? String == "ThinkTin")
        #expect(info["CFBundleDevelopmentRegion"] as? String == "zh-Hans")
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        // 推送不带 content-available（docs/push.md 第 3 节），用不上后台模式（12.8 去掉了）。
        #expect(info["UIBackgroundModes"] == nil)
        #expect(info["NSFaceIDUsageDescription"] as? String != nil)
        // 运行的实时活动（12.10）。
        #expect(info["NSSupportsLiveActivities"] as? Bool == true)
        // 扫电脑上的配对二维码（12.9）。
        #expect(info["NSCameraUsageDescription"] as? String != nil)
        // 产出物图片“保存到相册”（docs/ios-ui-redesign.md 4.5.3），只要“添加照片”。
        #expect(info["NSPhotoLibraryAddUsageDescription"] as? String != nil)
        #expect(info["NSPhotoLibraryUsageDescription"] == nil)
        // 启动屏（docs/ios-ui-redesign.md 4.1.1）：资源由 tools/apple/brand_assets.py 生成。
        let launch = info["UILaunchScreen"] as? [String: Any]
        #expect(launch?["UIColorName"] as? String == "LaunchBackground")
        #expect(launch?["UIImageName"] as? String == "LaunchLogo")
        // 构建设置 THINKTIN_API_BASE_URL 展开进来了，解析出来是 https 的地址。
        let raw = try #require(info[AppConfiguration.baseURLInfoKey] as? String)
        #expect(!raw.contains("$("))
        #expect(AppConfiguration.baseURL(infoDictionary: info).scheme == "https")
    }

    @Test("Info.plist 注册了深链的 URL scheme（thinktin://，docs/ios.md 第 6.1 节）")
    func urlScheme() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        #expect(schemes.contains("thinktin"))
        // 生成的 Info.plist 里构建设置已经展开。
        #expect(types.allSatisfy { ($0["CFBundleURLName"] as? String)?.contains("$(") != true })
    }

    @Test("装配好全局状态：深链交给它的 router")
    @MainActor
    func appModelWiring() throws {
        // 测试宿主用 Mock（演示数据，已登录）。
        let environment = AppEnvironment.live()
        #expect(environment.appModel.phase == .signedIn)
        let url = try #require(URL(string: "thinktin://run/0192f3a0-0000-7000-8000-000000000201"))
        #expect(environment.appModel.router.handle(url: url))
        #expect(environment.appModel.router.path == [.run("0192f3a0-0000-7000-8000-000000000201")])
    }

    @Test("隐私清单和多语言资源打进了 App")
    func bundledResources() throws {
        #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
        let en = try #require(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(en.localizedString(forKey: "取消", value: nil, table: nil) == "Cancel")
    }

    @Test("主屏小组件的扩展打进了 App，Siri 短语的英文在包里（12.20）")
    func widgetsAndShortcuts() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let widgets = try #require(Bundle(url: plugins.appendingPathComponent("ThinktinWidgets.appex")))
        let point = (widgets.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
        #expect(point as? String == "com.apple.widgetkit-extension")
        let en = try #require(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(en.localizedString(forKey: "全部停止", value: nil, table: nil) == "Stop Everything")
        #expect(ThinktinShortcuts.appShortcuts.count == 4)
    }

    @Test("测试宿主用 Mock 客户端（scheme 的测试环境变量 THINKTIN_MOCK=1）")
    func hostUsesMockClient() {
        #expect(AppConfiguration.current.client == .mock)
    }

    @Test("推送通道：测试跑的是 Debug 构建（开发证书签名），APNs 令牌报 apns_sandbox（docs/push.md 第 1 节）")
    func pushChannel() {
        #expect(AppConfiguration.usesAPNsSandbox)
    }

    @Test("客户端选择：环境变量优先，没有时 Debug 用 Mock、Release 用真核心")
    func clientKind() {
        #expect(AppConfiguration.clientKind(environment: [:], isDebugBuild: true) == .mock)
        #expect(AppConfiguration.clientKind(environment: [:], isDebugBuild: false) == .core)
        #expect(AppConfiguration.clientKind(environment: ["THINKTIN_MOCK": "1"], isDebugBuild: false) == .mock)
        #expect(AppConfiguration.clientKind(environment: ["THINKTIN_MOCK": "0"], isDebugBuild: true) == .core)
    }

    @Test("演示版：Info.plist 的 ThinktinClient 是 mock 时 Release 也用演示数据；环境变量仍然优先，空的、没展开的按构建配置")
    func clientKindFromInfoPlist() {
        let demo: [String: Any] = ["ThinktinClient": "mock"]
        #expect(AppConfiguration.clientKind(environment: [:], infoDictionary: demo, isDebugBuild: false) == .mock)
        #expect(
            AppConfiguration.clientKind(
                environment: [:], infoDictionary: ["ThinktinClient": " Core "], isDebugBuild: true)
                == .core)
        #expect(
            AppConfiguration.clientKind(environment: ["THINKTIN_MOCK": "0"], infoDictionary: demo, isDebugBuild: false)
                == .core)
        #expect(
            AppConfiguration.clientKind(environment: [:], infoDictionary: ["ThinktinClient": ""], isDebugBuild: false)
                == .core)
        #expect(
            AppConfiguration.clientKind(
                environment: [:], infoDictionary: ["ThinktinClient": "$(THINKTIN_CLIENT)"], isDebugBuild: true) == .mock
        )
        let resolved = AppConfiguration.resolve(environment: [:], infoDictionary: demo, isDebugBuild: false)
        #expect(resolved.client == .mock)
    }

    @Test("截图用的启动参数：深链只认 thinktin://")
    func launchOptions() {
        #expect(AppConfiguration.launchURL(environment: [:]) == nil)
        #expect(AppConfiguration.launchURL(environment: ["THINKTIN_OPEN_URL": "https://example.com"]) == nil)
        #expect(
            AppConfiguration.launchURL(environment: ["THINKTIN_OPEN_URL": " thinktin://approvals "])?.absoluteString
                == "thinktin://approvals")
    }

    @Test("截图用的启动参数：THINKTIN_SCREENSHOT=1 或者设了认得的深链、页面时是截图启动（Botin 的脸不动），别的不算")
    func screenshotLaunch() {
        #expect(AppConfiguration.screenshotEnvironmentKey == "THINKTIN_SCREENSHOT")
        #expect(!AppConfiguration.isScreenshotLaunch(environment: [:]))
        #expect(AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_SCREENSHOT": " Yes "]))
        #expect(!AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_SCREENSHOT": "0"]))
        // 截图脚本给首页那张传的是空的深链和页面。
        #expect(!AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_OPEN_URL": "", "THINKTIN_OPEN_SCREEN": ""]))
        #expect(AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_OPEN_URL": "thinktin://approvals"]))
        #expect(AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_OPEN_SCREEN": "botinavatar"]))
        #expect(!AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_OPEN_URL": "https://example.com"]))
        #expect(!AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_OPEN_SCREEN": "home"]))
        #expect(!AppConfiguration.isScreenshotLaunch(environment: ["THINKTIN_MOCK_EMPTY": "1"]))
    }

    @Test("截图用的启动参数：THINKTIN_MOCK_EMPTY=1 时 Mock 从还没有 Botin 的新账号开始；只有 Debug 构建、用 Mock 时认")
    func mockEmptyAccountFlag() {
        let key = AppConfiguration.mockEmptyEnvironmentKey
        #expect(key == "THINKTIN_MOCK_EMPTY")
        #expect(AppConfiguration.startsWithEmptyAccount(environment: [key: "1"], isDebugBuild: true))
        #expect(AppConfiguration.startsWithEmptyAccount(environment: [key: " True "], isDebugBuild: true))
        #expect(AppConfiguration.startsWithEmptyAccount(environment: [key: "yes"], isDebugBuild: true))
        #expect(!AppConfiguration.startsWithEmptyAccount(environment: [key: "1"], isDebugBuild: false))
        #expect(!AppConfiguration.startsWithEmptyAccount(environment: [key: ""], isDebugBuild: true))
        #expect(!AppConfiguration.startsWithEmptyAccount(environment: [key: "0"], isDebugBuild: true))
        #expect(!AppConfiguration.startsWithEmptyAccount(environment: [:], isDebugBuild: true))
        // 合起来：Debug、Mock 才认；真核心、Release 的演示版（Info.plist 的 ThinktinClient 是 mock）都不认。
        let resolve = { (environment: [String: String], info: [String: Any]?, debug: Bool) in
            AppConfiguration.resolve(environment: environment, infoDictionary: info, isDebugBuild: debug)
        }
        #expect(resolve([key: "1"], nil, true).startsWithEmptyAccount)
        #expect(resolve([key: "1", "THINKTIN_MOCK": "1"], nil, true).client == .mock)
        #expect(!resolve([key: "1", "THINKTIN_MOCK": "0"], nil, true).startsWithEmptyAccount)
        #expect(!resolve([key: "1"], ["ThinktinClient": "mock"], false).startsWithEmptyAccount)
        #expect(!resolve([:], nil, true).startsWithEmptyAccount)
    }

    @Test("截图用的启动参数：新账号的演示数据里首页是“还没有 Botin”，新建表单照样能打开")
    @MainActor
    func mockEmptyAccountInDemo() async {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.mockEmptyEnvironmentKey: "1"], infoDictionary: nil, isDebugBuild: true)
        let model = AppEnvironment.live(configuration).appModel
        await model.refresh()
        #expect(model.hasLoadedInstances && model.instances.isEmpty)
        #expect(model.homePlaceholder == .noBotins)
        // 实例的页面没有实例可开；新建表单、设置照样打开。
        #expect(await AppConfiguration.OpenScreen.conversation.open(in: model, timeout: .zero) == nil)
        #expect(await AppConfiguration.OpenScreen.adopt.open(in: model) == .adopt(agentID: nil))
        #expect(model.router.sheet == .adopt(agentID: nil))
    }

    @Test("截图用的启动参数：THINKTIN_OPEN_SCREEN 认的页面，不分大小写，别的值不认")
    func openScreenValues() {
        let key = AppConfiguration.openScreenEnvironmentKey
        #expect(key == "THINKTIN_OPEN_SCREEN")
        #expect(
            AppConfiguration.OpenScreen.allCases.map(\.rawValue)
                == [
                    "homepinned", "hiddenbotins", "homeallhidden", "conversation", "conversationfind", "search",
                    "botinedit", "botinavatar", "workspace", "instancescreen", "primarybotin", "adopt", "engines",
                    "enginedetail", "plans", "allplans", "artifacts", "artifactsmedia", "teams", "newtask",
                    "onboarding",
                    "connections", "connected", "connectiondetail", "settings", "account", "usage", "subscription",
                    "modelkeys", "vault", "vaultlogin", "vaultcard", "vaultcontact", "permissions", "permissionrule",
                    "devices", "devicedetail", "computerdetail", "appearance", "language", "haptics", "importmemory",
                    "feedback", "settingsbottom",
                ])
        for screen in AppConfiguration.OpenScreen.allCases {
            #expect(AppConfiguration.openScreen(environment: [key: screen.rawValue]) == screen)
        }
        #expect(AppConfiguration.openScreen(environment: [key: " Plans "]) == .plans)
        #expect(AppConfiguration.openScreen(environment: [key: "InstanceScreen"]) == .instancescreen)
        #expect(AppConfiguration.openScreen(environment: [:]) == nil)
        #expect(AppConfiguration.openScreen(environment: [key: ""]) == nil)
        #expect(AppConfiguration.openScreen(environment: [key: "home"]) == nil)
        // 抽屉去掉了（规范 3.3），旧的截图参数不认。
        #expect(AppConfiguration.openScreen(environment: [key: "drawer"]) == nil)
        #expect(AppConfiguration.openScreen(environment: ["THINKTIN_OPEN_DRAWER": "1"]) == nil)
    }

    @Test("截图用的启动参数：每个页面的路由、接着打开的子页、首页的摆法；Botin 的页面要有 Botin")
    func openScreenRoutes() {
        typealias Screen = AppConfiguration.OpenScreen
        // ThinktinKit 的类型这里不直接写名字（测试 target 只依赖 App），靠推断。
        let id = "0192f3a0-0000-7000-8000-000000000101"
        #expect(Screen.homepinned.route(instanceID: .init(id)) == .home)
        #expect(Screen.hiddenbotins.route(instanceID: .init(id)) == .hiddenBotins)
        #expect(Screen.homeallhidden.route(instanceID: .init(id)) == .home)
        #expect(Screen.conversation.route(instanceID: .init(id)) == .conversation(.init(id)))
        #expect(Screen.conversationfind.route(instanceID: .init(id)) == .conversation(.init(id)))
        #expect(Screen.search.route(instanceID: nil) == .search)
        for screen in [Screen.botinedit, .botinavatar, .workspace] {
            #expect(screen.route(instanceID: .init(id)) == .instance(.init(id)), "\(screen)")
        }
        #expect(Screen.instancescreen.route(instanceID: .init(id)) == .instanceScreen(.init(id)))
        #expect(Screen.primarybotin.route(instanceID: nil) == .primaryBotin)
        #expect(Screen.adopt.route(instanceID: nil) == .adopt(agentID: nil))
        #expect(Screen.engines.route(instanceID: nil) == .agentCatalog)
        #expect(Screen.enginedetail.route(instanceID: nil) == .agentCatalog)
        #expect(Screen.plans.route(instanceID: .init(id)) == .plans(instanceID: .init(id)))
        #expect(Screen.allplans.route(instanceID: nil) == .plans(instanceID: nil))
        #expect(!Screen.allplans.needsInstance)
        #expect(Screen.artifacts.route(instanceID: .init(id)) == .artifacts(instanceID: .init(id)))
        #expect(Screen.artifactsmedia.route(instanceID: .init(id)) == .artifacts(instanceID: .init(id)))
        #expect(Screen.teams.route(instanceID: nil) == .teams)
        #expect(Screen.newtask.route(instanceID: nil) == .newTask)
        #expect(Screen.onboarding.route(instanceID: nil) == .onboarding)
        #expect(Screen.connections.route(instanceID: nil) == .connections(category: nil))
        #expect(Screen.connected.route(instanceID: nil) == .connectedApps)
        #expect(Screen.connectiondetail.route(instanceID: nil) == .connectedApps)
        for screen in [Screen.settings, .appearance, .language, .haptics, .settingsbottom] {
            #expect(screen.route(instanceID: nil) == .settings, "\(screen)")
        }
        #expect(Screen.account.route(instanceID: nil) == .account)
        #expect(Screen.usage.route(instanceID: nil) == .usage)
        #expect(Screen.subscription.route(instanceID: nil) == .subscription)
        #expect(Screen.modelkeys.route(instanceID: nil) == .credentials)
        for screen in [Screen.vault, .vaultlogin, .vaultcard, .vaultcontact] {
            #expect(screen.route(instanceID: nil) == .vault, "\(screen)")
        }
        #expect(Screen.permissions.route(instanceID: nil) == .permissions)
        #expect(Screen.permissionrule.route(instanceID: nil) == .permissions)
        for screen in [Screen.devices, .devicedetail, .computerdetail] {
            #expect(screen.route(instanceID: nil) == .devices, "\(screen)")
        }
        #expect(Screen.importmemory.route(instanceID: nil) == .importMemory)
        #expect(Screen.feedback.route(instanceID: nil) == .feedback)
        for screen in Screen.allCases {
            #expect(screen.route(instanceID: .init(id)) != nil, "\(screen)")
            #expect((screen.route(instanceID: nil) == nil) == screen.needsInstance, "\(screen)")
            // 不是 Botin 的页面不管传不传 Botin 都一样。
            if !screen.needsInstance {
                #expect(screen.route(instanceID: .init(id)) == screen.route(instanceID: nil), "\(screen)")
            }
            // 压进设置的都是压栈的页面。
            if screen.isInSettings {
                #expect(screen.route(instanceID: nil)?.presentation == .push, "\(screen)")
            }
        }
        #expect(
            Screen.allCases.filter(\.isInSettings) == [
                .account, .usage, .subscription, .modelkeys, .vault, .vaultlogin, .vaultcard, .vaultcontact,
                .permissions, .permissionrule, .devices, .devicedetail, .computerdetail, .importmemory, .feedback,
            ])
        // 页面里本地打开的子页。
        #expect(Screen.conversationfind.subpages == [.conversationFind])
        #expect(Screen.botinedit.subpages == [.botinEdit])
        #expect(Screen.botinavatar.subpages == [.botinEdit, .botinAvatar])
        #expect(Screen.workspace.subpages == [.workspace])
        #expect(Screen.enginedetail.subpages == [.engineDetail])
        #expect(Screen.artifactsmedia.subpages == [.artifactsMedia])
        #expect(Screen.connectiondetail.subpages == [.connectionDetail("computer")])
        #expect(Screen.vaultlogin.subpages == [.newVaultItem(.login)])
        #expect(Screen.vaultcard.subpages == [.newVaultItem(.card)])
        #expect(Screen.vaultcontact.subpages == [.newVaultItem(.contact)])
        #expect(Screen.permissionrule.subpages == [.newPermissionRule])
        #expect(Screen.devicedetail.subpages == [.currentDevice])
        #expect(Screen.computerdetail.subpages == [.computerDevice])
        #expect(Screen.appearance.subpages == [.appearanceSettings])
        #expect(Screen.language.subpages == [.languageSettings])
        #expect(Screen.haptics.subpages == [.hapticsSettings])
        #expect(Screen.settingsbottom.subpages == [.settingsBottom])
        #expect(
            Screen.allCases.filter { !$0.subpages.isEmpty } == [
                .conversationfind, .botinedit, .botinavatar, .workspace, .enginedetail, .artifactsmedia,
                .connectiondetail, .vaultlogin, .vaultcard, .vaultcontact, .permissionrule, .devicedetail,
                .computerdetail, .appearance, .language, .haptics, .settingsbottom,
            ])
        #expect(Screen.homepinned.homeArrangement == .pinFirst)
        #expect(Screen.hiddenbotins.homeArrangement == .hideLast)
        #expect(Screen.homeallhidden.homeArrangement == .hideAll)
        #expect(Screen.allCases.filter { $0.homeArrangement != nil } == [.homepinned, .hiddenbotins, .homeallhidden])
    }

    @Test("截图用的启动参数：打开演示数据首页第一个 Botin（写作助手）的页面，返回栈和深链一样，子页排好")
    @MainActor
    func openScreenInDemo() async {
        let model = AppEnvironment.live().appModel
        let router = model.router
        let preferences = model.local.preferences
        // 置顶、隐藏记在这台设备上（UserDefaults.standard）：测完清掉，别的测试和下次运行看到的首页不受影响。
        defer { preferences.forget(preferences.pinned + Array(preferences.hidden)) }
        // 实例列表还没拿到：实例的页面等不到就不打开，别的照样打开。
        #expect(await AppConfiguration.OpenScreen.conversation.open(in: model, timeout: .zero) == nil)
        #expect(router.path.isEmpty && router.sheet == nil)
        #expect(await AppConfiguration.OpenScreen.settings.open(in: model, timeout: .zero) == .settings)
        #expect(router.sheet == .settings)

        await model.refresh()
        preferences.forget(model.instances.map(\.id))
        let rows = model.homeRows.map(\.id)
        #expect(
            rows.map(\.rawValue) == ["0192f3a0-0000-7000-8000-000000000101", "0192f3a0-0000-7000-8000-000000000102"])
        guard let writer = rows.first, let reviewer = rows.last else { return }
        #expect(await AppConfiguration.OpenScreen.conversation.open(in: model) == .conversation(writer))
        #expect(router.sheet == nil)
        #expect(router.path == [.conversation(writer)])
        #expect(router.currentInstanceID == writer)
        #expect(router.subpageRequests.isEmpty)
        await AppConfiguration.OpenScreen.plans.open(in: model)
        #expect(router.path == [.conversation(writer), .plans(instanceID: writer)])
        await AppConfiguration.OpenScreen.artifacts.open(in: model)
        #expect(router.path == [.conversation(writer), .artifacts(instanceID: writer)])
        // 页面里本地打开的子页：先开父页面，子页按顺序排好（页面出现后一层层取走）。
        await AppConfiguration.OpenScreen.conversationfind.open(in: model)
        #expect(router.path == [.conversation(writer)] && router.subpageRequests == [.conversationFind])
        await AppConfiguration.OpenScreen.botinavatar.open(in: model)
        #expect(router.path == [.conversation(writer), .instance(writer)])
        #expect(router.subpageRequests == [.botinEdit, .botinAvatar])
        await AppConfiguration.OpenScreen.artifactsmedia.open(in: model)
        #expect(router.path == [.conversation(writer), .artifacts(instanceID: writer)])
        #expect(router.subpageRequests == [.artifactsMedia])
        // sheet 开在首页上；搜索回到首页、留一个首页还没处理的搜索请求。
        await AppConfiguration.OpenScreen.adopt.open(in: model)
        #expect(router.path.isEmpty && router.sheet == .adopt(agentID: nil))
        #expect(router.subpageRequests.isEmpty)
        await AppConfiguration.OpenScreen.search.open(in: model)
        #expect(router.path.isEmpty && router.sheet == nil)
        #expect(router.hasPendingSearchRequest)
        await AppConfiguration.OpenScreen.primarybotin.open(in: model)
        #expect(router.path.isEmpty && router.sheet == .primaryBotin)
        // 团队、引擎压在首页上；新任务、引导是 sheet。
        await AppConfiguration.OpenScreen.teams.open(in: model)
        #expect(router.path == [.teams] && router.sheet == nil)
        await AppConfiguration.OpenScreen.enginedetail.open(in: model)
        #expect(router.path == [.agentCatalog] && router.subpageRequests == [.engineDetail])
        await AppConfiguration.OpenScreen.newtask.open(in: model)
        #expect(router.sheet == .newTask)
        await AppConfiguration.OpenScreen.onboarding.open(in: model)
        #expect(router.sheet == .onboarding)
        // 连接目录、已连接压在首页上（和深链一样“首页 → 目标页”）。
        await AppConfiguration.OpenScreen.connections.open(in: model)
        #expect(router.path == [.connections(category: nil)] && router.sheet == nil)
        await AppConfiguration.OpenScreen.connectiondetail.open(in: model)
        #expect(router.path == [.connectedApps])
        #expect(router.subpageRequests == [.connectionDetail("computer")])
        // 观看与接管经过对话（“首页 → 对话 → 观看与接管”）；设置里的页面压在设置 sheet 的栈里。
        await AppConfiguration.OpenScreen.instancescreen.open(in: model)
        #expect(router.path == [.conversation(writer), .instanceScreen(writer)] && router.sheet == nil)
        for screen in AppConfiguration.OpenScreen.allCases where screen.isInSettings {
            let route = screen.route(instanceID: nil)
            #expect(await screen.open(in: model) == route)
            #expect(router.path.isEmpty && router.sheet == .settings, "\(screen)")
            #expect(router.sheetPath == route.map { [$0] }, "\(screen)")
            #expect(router.subpageRequests == screen.subpages, "\(screen)")
        }
        // 外观、语言、触感反馈是设置根页本地压的子页；滚到底也是设置根页上的。
        for screen in [AppConfiguration.OpenScreen.appearance, .language, .haptics, .settingsbottom] {
            #expect(await screen.open(in: model) == .settings)
            #expect(router.sheet == .settings && router.sheetPath.isEmpty, "\(screen)")
            #expect(router.subpageRequests == screen.subpages, "\(screen)")
        }
        // 首页的置顶、隐藏：每次先清掉再摆。
        #expect(await AppConfiguration.OpenScreen.homepinned.open(in: model) == .home)
        #expect(router.path.isEmpty && router.sheet == nil)
        #expect(preferences.pinned == [writer] && preferences.hidden.isEmpty)
        #expect(await AppConfiguration.OpenScreen.hiddenbotins.open(in: model) == .hiddenBotins)
        #expect(router.path == [.hiddenBotins])
        #expect(preferences.pinned.isEmpty && preferences.hidden == [reviewer])
        #expect(await AppConfiguration.OpenScreen.homeallhidden.open(in: model) == .home)
        #expect(preferences.pinned.isEmpty && preferences.hidden == [writer, reviewer])
        #expect(model.homeRows.isEmpty)
    }

    @Test("接口地址：没有、没展开、不是 http(s) 时用默认地址")
    func baseURLFallback() {
        let fallback = AppConfiguration.defaultBaseURL
        #expect(AppConfiguration.baseURL(infoDictionary: nil) == fallback)
        #expect(
            AppConfiguration.baseURL(infoDictionary: ["ThinktinAPIBaseURL": "$(THINKTIN_API_BASE_URL)"]) == fallback)
        #expect(AppConfiguration.baseURL(infoDictionary: ["ThinktinAPIBaseURL": "ftp://example.com"]) == fallback)
        #expect(
            AppConfiguration.baseURL(infoDictionary: ["ThinktinAPIBaseURL": "https://staging.thinktin.cn"])
                .absoluteString
                == "https://staging.thinktin.cn")
    }

    @Test("缓存放在 Application Support/Thinktin 下")
    func cacheLocation() throws {
        let url = try AppConfiguration.cacheFileURL()
        #expect(url.lastPathComponent == AppConfiguration.cacheFileName)
        #expect(url.deletingLastPathComponent().lastPathComponent == AppConfiguration.cacheDirectoryName)
        #expect(url.path.contains("/Library/Application Support/"))
    }

    @Test("请求语言：界面用的语言排第一，后面跟设备的语言偏好（11.8）")
    func acceptLanguage() {
        #expect(
            AppEnvironment.acceptLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"])
                == "zh-CN, zh-Hans-CN;q=0.9, en-US;q=0.8")
        // 系统语言是日语时界面是英文，服务端也按英文（排第一的是 en）。
        #expect(
            AppEnvironment.acceptLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN"])
                == "en, ja-JP;q=0.9, zh-Hans-CN;q=0.8")
        // 没有语言偏好时和界面一样按中文。
        #expect(AppEnvironment.acceptLanguage(preferredLanguages: []) == "zh-CN")
        // 语言偏好又多又长：去掉后面的，不超过 client-core 收的 256 字节，界面语言还在第一个。
        let long = Array(repeating: "zh-Hans-CN-" + String(repeating: "x", count: 24), count: 12)
        let trimmed = AppEnvironment.acceptLanguage(preferredLanguages: long)
        #expect(trimmed.utf8.count <= 256)
        #expect(trimmed.hasPrefix("zh-CN, zh-Hans-CN-"))
        // 设备当前的值：中文或英文打头，client-core 收得下（不超过 256 字节）。
        let current = AppEnvironment.acceptLanguage()
        #expect(current.hasPrefix("zh-CN") || current.hasPrefix("en"))
        #expect(current.utf8.count <= 256)
    }

    @Test("请求语言：设置里选的界面语言打头，不管设备首选语言是什么（12.12）")
    func acceptLanguageFromSettings() {
        #expect(
            AppEnvironment.acceptLanguage(displayLanguage: .english, preferredLanguages: ["zh-Hans-CN", "en-US"])
                == "en, zh-Hans-CN;q=0.9, en-US;q=0.8")
        #expect(
            AppEnvironment.acceptLanguage(displayLanguage: .chinese, preferredLanguages: ["ja-JP"])
                == "zh-CN, ja-JP;q=0.9")
        #expect(AppEnvironment.acceptLanguage(displayLanguage: .english, preferredLanguages: []) == "en")
        let long = Array(repeating: "zh-Hans-CN-" + String(repeating: "x", count: 24), count: 12)
        let trimmed = AppEnvironment.acceptLanguage(displayLanguage: .english, preferredLanguages: long)
        #expect(trimmed.utf8.count <= 256)
        #expect(trimmed.hasPrefix("en, zh-Hans-CN-"))
    }

    @Test("client-core 的日志接进系统日志，装两次也没事（11.8）")
    @MainActor
    func coreLogging() {
        #expect(AppEnvironment.installCoreLogging())
        #expect(AppEnvironment.installCoreLogging())
    }

    @Test("刚启动不用升级：进的是主界面")
    @MainActor
    func notUpgradeRequiredAtLaunch() {
        let environment = AppEnvironment.live()
        #expect(!environment.client.upgradeRequired())
        #expect(!environment.appModel.client.upgradeRequired())
        #expect(environment.appModel.phase == .signedIn)
    }
}
