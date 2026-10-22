import Foundation
import OSLog
import ThinktinCoreAdapter
import ThinktinKit
import UIKit

/// App 的依赖装配（WBS 12.1，docs/ios.md 第 1、3 节）：启动时按 `AppConfiguration` 选客户端，
/// 建好平台层的实现（Keychain、推送、生物识别）和应用框架的全局状态（`AppModel`，12.16），交给界面。
/// 界面和视图模型只认 `ClientProtocol` 和平台层的协议，不知道背后是 Mock 还是真核心。
@MainActor
final class AppEnvironment {
    let configuration: AppConfiguration
    let client: any ClientProtocol
    let pushRegistrar: any PushRegistrar
    let biometricSigner: any BiometricSigner
    /// 全局状态和导航（登录状态、实例、角标、`router`）。深链（`onOpenURL`）、推送点开（12.8）都交给它的 `router`。
    let appModel: AppModel

    private static let log = Logger(subsystem: "cn.thinktin.app", category: "environment")

    init(
        configuration: AppConfiguration,
        client: any ClientProtocol,
        pushRegistrar: any PushRegistrar = NoopPushRegistrar(),
        biometricSigner: any BiometricSigner = UnavailableBiometricSigner()
    ) {
        self.configuration = configuration
        self.client = client
        self.pushRegistrar = pushRegistrar
        self.biometricSigner = biometricSigner
        self.appModel = AppModel(client: client)
    }

    /// 正式运行用的装配。推送（12.8）和签名（12.9）先用空实现。
    static func live(_ configuration: AppConfiguration = .current) -> AppEnvironment {
        log.info(
            "client: \(configuration.client.rawValue, privacy: .public), api: \(configuration.baseURL.absoluteString, privacy: .public)"
        )
        let acceptLanguage = acceptLanguage()
        let client: any ClientProtocol
        switch configuration.client {
        case .mock:
            // 一点延迟，界面的加载状态看得见。和真核心带一样的请求语言（agent 目录的介绍跟着变）；
            // Mock 不经过 client-core，不用接日志。
            let mock = MockClient(latency: 0.2)
            try? mock.setAcceptLanguage(acceptLanguage)
            client = mock
        case .core:
            // 建核心之前接上日志，恢复会话、刷新令牌的日志也收得到。
            installCoreLogging()
            client = makeCoreClient(configuration, acceptLanguage: acceptLanguage)
        }
        return AppEnvironment(configuration: configuration, client: client)
    }

    // MARK: 请求语言与日志（11.8）

    /// 每个请求带的 `Accept-Language`：设备的语言偏好，前面再放 App 界面用的语言（`DisplayLanguage`：系统首选语言是
    /// 中文时中文，其余英文）。服务端只认中文和英文，按排第一的定新用户推送、收件箱的语言，agent 目录的介绍也按它给，
    /// 这样和界面一致——只带设备偏好的话，系统语言是日语时界面是英文，服务端却认不出、按中文。
    ///
    /// client-core 拒收超过 256 字节的值（`CoreClient` 建不起来）：`AcceptLanguage.header` 和 client-core 的
    /// `accept_language_header` 一样，放不下的后面几个不要，界面语言总在第一个。
    nonisolated static func acceptLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let language = preferredLanguages.first.map(DisplayLanguage.init(languageTag:)) ?? .chinese
        return AcceptLanguage.header(for: language, systemTags: preferredLanguages)
    }

    /// client-core 日志的级别：调试版到 debug，发布版到 info（`CoreLogging` 的建议）。
    nonisolated static var coreLogLevel: CoreLogging.Level {
        #if DEBUG
            .debug
        #else
            .info
        #endif
    }

    /// 把 client-core 的日志接进系统日志（subsystem `cn.thinktin.core`），进程里只装一次（再调什么都不做）。
    /// 返回接上了没有：进程里已经有别的 Rust 日志订阅者时是 false（App 里不会）。
    @discardableResult
    static func installCoreLogging() -> Bool {
        let connected = CoreLogging.install(maxLevel: coreLogLevel)
        if !connected { log.error("client-core logging is not connected: another log subscriber is installed") }
        return connected
    }

    /// 真核心：会话存 Keychain，缓存放 Application Support（`AppConfiguration.cacheFileURL()`）。
    ///
    /// 设备名用 `UIDevice.current.name`：iOS 16 起没有“用户设置的设备名”权限时只返回“iPhone”，
    /// 要显示“张三的 iPhone”得申请 `com.apple.developer.device-information.user-assigned-device-name`（上架时再说）。
    private static func makeCoreClient(_ configuration: AppConfiguration, acceptLanguage: String) -> any ClientProtocol
    {
        let sessions = KeychainSessionStore()
        let deviceName = UIDevice.current.name
        let cacheURL: URL?
        do {
            cacheURL = try AppConfiguration.cacheFileURL()
        } catch {
            log.error("no cache directory, running without cache: \(error.localizedDescription, privacy: .public)")
            cacheURL = nil
        }
        func make(cacheURL: URL?) throws -> CoreClient {
            try CoreClient(
                baseURL: configuration.baseURL.absoluteString,
                cachePath: cacheURL?.path,
                deviceName: deviceName,
                acceptLanguage: acceptLanguage,
                sessions: sessions
            )
        }
        do {
            return try make(cacheURL: cacheURL)
        } catch {
            // 打不开缓存库（文件坏了、版本不兼容）：缓存可以重建，删掉再试一次，还不行就不带缓存。
            log.error("cannot open the core with cache, retrying: \(error.localizedDescription, privacy: .public)")
            if let cacheURL {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: cacheURL.path + suffix))
                }
                if let client = try? make(cacheURL: cacheURL) { return client }
            }
            do {
                return try make(cacheURL: nil)
            } catch {
                // 只有配置本身错了（平台名、接口地址）才会走到这里，是程序错误。
                fatalError("cannot create the client core: \(error)")
            }
        }
    }
}
