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

    @Test("截图用的启动参数：深链只认 thinktin://，抽屉认 1/true/yes")
    func launchOptions() {
        #expect(AppConfiguration.launchURL(environment: [:]) == nil)
        #expect(AppConfiguration.launchURL(environment: ["THINKTIN_OPEN_URL": "https://example.com"]) == nil)
        #expect(
            AppConfiguration.launchURL(environment: ["THINKTIN_OPEN_URL": " thinktin://approvals "])?.absoluteString
                == "thinktin://approvals")
        #expect(!AppConfiguration.opensDrawerAtLaunch(environment: [:]))
        #expect(!AppConfiguration.opensDrawerAtLaunch(environment: ["THINKTIN_OPEN_DRAWER": "0"]))
        #expect(AppConfiguration.opensDrawerAtLaunch(environment: ["THINKTIN_OPEN_DRAWER": "1"]))
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
