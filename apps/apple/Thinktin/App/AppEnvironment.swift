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
        let client: any ClientProtocol
        switch configuration.client {
        case .mock:
            // 一点延迟，界面的加载状态看得见。
            client = MockClient(latency: 0.2)
        case .core:
            client = makeCoreClient(configuration)
        }
        return AppEnvironment(configuration: configuration, client: client)
    }

    /// 真核心：会话存 Keychain，缓存放 Application Support（`AppConfiguration.cacheFileURL()`）。
    ///
    /// 设备名用 `UIDevice.current.name`：iOS 16 起没有“用户设置的设备名”权限时只返回“iPhone”，
    /// 要显示“张三的 iPhone”得申请 `com.apple.developer.device-information.user-assigned-device-name`（上架时再说）。
    private static func makeCoreClient(_ configuration: AppConfiguration) -> any ClientProtocol {
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
