import Foundation
import OSLog
import Observation
import ThinktinCoreAdapter
import ThinktinDesktopAdapter
import ThinktinKit

/// macOS App 的依赖装配（WBS 14.5、14.6）：客户端（和 iOS 一样按 `AppConfiguration` 选 Mock 或真核心，会话存钥匙串）、
/// 全局状态（`AppModel`）、电脑端的工具服务（`ComputerHostLifecycle`：登录了才建，按设备 id 记开关）、系统权限和登录项。
///
/// 进程里唯一的一份（`shared`）：App 代理、菜单栏、主窗口都用它。启动（`start()`）时开始跟着登录状态建、停工具服务；
/// 主窗口只在要登录时自己打开，平时从菜单栏打开（`requestMainWindow()`，菜单栏图标那里接着调 `openWindow`）。
@Observable @MainActor
final class MacEnvironment {
    static let mainWindowID = "main"
    static let shared = MacEnvironment.live()

    let configuration: AppConfiguration
    let client: any ClientProtocol
    let appModel: AppModel
    let host: ComputerHostLifecycle
    let permissions = MacPermissions()
    /// 要打开主窗口的次数（菜单栏图标看着它变，调 `openWindow`）。
    private(set) var mainWindowRequests = 0

    @ObservationIgnored private let sessions: KeychainSessionStore?
    @ObservationIgnored private var following: Task<Void, Never>?

    private static let log = Logger(subsystem: "cn.thinktin.mac", category: "environment")

    init(
        configuration: AppConfiguration, client: any ClientProtocol, sessions: KeychainSessionStore?,
        makeHost: @escaping @MainActor (DeviceID) throws(ComputerHostError) -> any ComputerHost
    ) {
        self.configuration = configuration
        self.client = client
        self.sessions = sessions
        appModel = AppModel(client: client, preferences: .shared)
        host = ComputerHostLifecycle(client: client, makeHost: makeHost)
    }

    /// App 启动完（`applicationDidFinishLaunching`）调一次。
    func start() {
        guard following == nil else { return }
        let appModel = appModel
        Task { await appModel.start() }
        following = Task { [host, sessions, configuration] in
            await host.follow(appModel) {
                switch configuration.client {
                case .mock: DemoData.macDeviceID
                case .core: sessions?.load()?.deviceID
                }
            }
        }
        // 没登录时打开主窗口登录；登录了就只在菜单栏（开机由登录项拉起时也不弹窗口）。
        if appModel.phase != .signedIn { requestMainWindow() }
    }

    func requestMainWindow() {
        mainWindowRequests += 1
    }

    // MARK: 装配

    static func live(_ configuration: AppConfiguration = .current) -> MacEnvironment {
        log.info(
            "client: \(configuration.client.rawValue, privacy: .public), api: \(configuration.baseURL.absoluteString, privacy: .public)"
        )
        let info = Bundle.main.infoDictionary
        // 和 iOS 一样：界面语言打头，后面跟系统的语言偏好（`AppEnvironment.acceptLanguage`）。
        let acceptLanguage = AcceptLanguage.header(
            for: SettingsPreferences.shared.displayLanguage, systemTags: Locale.preferredLanguages)
        switch configuration.client {
        case .mock:
            let mock = MockClient(latency: 0.2)
            try? mock.setAcceptLanguage(acceptLanguage)
            return MacEnvironment(configuration: configuration, client: mock, sessions: nil) { _ in
                FakeComputerHost()
            }
        case .core:
            _ = CoreLogging.install(maxLevel: .info)
            let sessions = KeychainSessionStore()
            let core = makeCoreClient(configuration, sessions: sessions, acceptLanguage: acceptLanguage)
            let relayURL = AppConfiguration.relayURL(infoDictionary: info)
            let appVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
            let tools = MacNativeTools()
            return MacEnvironment(configuration: configuration, client: core, sessions: sessions) {
                deviceID throws(ComputerHostError) in
                let directory: URL
                do {
                    directory = try AppConfiguration.desktopDataDirectory(deviceID: deviceID)
                } catch {
                    throw .state(error.localizedDescription)
                }
                return try DesktopServiceHost(
                    relayURL: relayURL.absoluteString, desktopID: deviceID, appVersion: appVersion,
                    dataDirectory: directory, homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    accessToken: { refresh in try await core.accessToken(refresh: refresh) },
                    native: tools, pairingKey: KeychainPairingKey())
            }
        }
    }

    /// 真核心：会话存钥匙串，缓存放 Application Support（和 iOS 一样，坏了删掉重建）。设备名是“电脑名称”
    /// （系统设置 → 通用 → 关于本机），手机的设备列表、配对界面里显示它。
    private static func makeCoreClient(
        _ configuration: AppConfiguration, sessions: KeychainSessionStore, acceptLanguage: String
    ) -> CoreClient {
        let deviceName = Host.current().localizedName ?? "Mac"
        let cacheURL = try? AppConfiguration.cacheFileURL()
        func make(cacheURL: URL?) throws -> CoreClient {
            try CoreClient(
                baseURL: configuration.baseURL.absoluteString, cachePath: cacheURL?.path, platform: .macos,
                deviceName: deviceName, acceptLanguage: acceptLanguage, sessions: sessions)
        }
        if let client = try? make(cacheURL: cacheURL) { return client }
        log.error("cannot open the core with cache, retrying without the old cache")
        if let cacheURL {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: cacheURL.path + suffix))
            }
            if let client = try? make(cacheURL: cacheURL) { return client }
        }
        do {
            return try make(cacheURL: nil)
        } catch {
            fatalError("cannot create the client core: \(error)")
        }
    }
}
