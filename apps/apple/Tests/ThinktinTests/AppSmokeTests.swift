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
        #expect((info["UIBackgroundModes"] as? [String])?.contains("remote-notification") == true)
        #expect(info["NSFaceIDUsageDescription"] as? String != nil)
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

    @Test("测试宿主用 Mock 客户端（scheme 的测试环境变量 THINKTIN_MOCK=1）")
    func hostUsesMockClient() {
        #expect(AppConfiguration.current.client == .mock)
    }

    @Test("客户端选择：环境变量优先，没有时 Debug 用 Mock、Release 用真核心")
    func clientKind() {
        #expect(AppConfiguration.clientKind(environment: [:], isDebugBuild: true) == .mock)
        #expect(AppConfiguration.clientKind(environment: [:], isDebugBuild: false) == .core)
        #expect(AppConfiguration.clientKind(environment: ["THINKTIN_MOCK": "1"], isDebugBuild: false) == .mock)
        #expect(AppConfiguration.clientKind(environment: ["THINKTIN_MOCK": "0"], isDebugBuild: true) == .core)
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
}
