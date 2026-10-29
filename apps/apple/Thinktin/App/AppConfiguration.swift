import Foundation

/// App 启动时定下来的配置：用哪个客户端、接口地址、缓存放哪。只依赖 Foundation，逻辑都是纯函数，
/// 方便单元测试（Tests/ThinktinTests），也能在 Linux 上 `swiftc -typecheck`。
struct AppConfiguration: Equatable, Sendable {
    enum ClientKind: String, Equatable, Sendable {
        /// ThinktinKit 的 `MockClient`：演示数据，不连网（预览、截图、界面开发、测试宿主）。
        case mock
        /// ThinktinCoreAdapter 的 `CoreClient`：经 UniFFI 调 Rust 的 client-core。
        case core
    }

    /// 环境变量：`1` 用 Mock，`0` 用真核心；不设时看 Info.plist 的 `ThinktinClient`，再不设时 Debug 用 Mock、Release 用真核心。
    static let mockEnvironmentKey = "THINKTIN_MOCK"
    /// Info.plist 里选客户端的键（project.yml 用构建设置 `THINKTIN_CLIENT` 展开进去）：`mock` 是演示版（服务器上线前
    /// 在 TestFlight 上给人看界面），`core` 连服务器，空的按构建配置定。
    static let clientInfoKey = "ThinktinClient"
    /// Info.plist 里的接口地址（project.yml 用构建设置 `THINKTIN_API_BASE_URL` 展开进去）。
    static let baseURLInfoKey = "ThinktinAPIBaseURL"
    static let defaultBaseURL = URL(string: "https://api.thinktin.cn")!
    /// 缓存数据库：Application Support/Thinktin/cache.sqlite（client-core 的 SQLite 缓存，可以随时重建）。
    static let cacheDirectoryName = "Thinktin"
    static let cacheFileName = "cache.sqlite"
    /// 截图用（tools/apple/screenshots.sh，只在 Debug 构建里认）：启动后打开这个 `thinktin://` 深链。模拟器上
    /// `simctl openurl` 每次都先弹系统的“在 ThinkTin 中打开？”确认框，挡住页面。
    static let launchURLEnvironmentKey = "THINKTIN_OPEN_URL"
    /// 截图用：`1` 时启动后打开侧边抽屉。
    static let launchDrawerEnvironmentKey = "THINKTIN_OPEN_DRAWER"

    var client: ClientKind
    var baseURL: URL

    /// 按进程环境变量、Info.plist 和构建配置得出配置。
    static func resolve(
        environment: [String: String],
        infoDictionary: [String: Any]?,
        isDebugBuild: Bool
    ) -> AppConfiguration {
        AppConfiguration(
            client: clientKind(environment: environment, infoDictionary: infoDictionary, isDebugBuild: isDebugBuild),
            baseURL: baseURL(infoDictionary: infoDictionary)
        )
    }

    /// 当前进程的配置。
    static var current: AppConfiguration {
        #if DEBUG
            let isDebugBuild = true
        #else
            let isDebugBuild = false
        #endif
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            infoDictionary: Bundle.main.infoDictionary,
            isDebugBuild: isDebugBuild
        )
    }

    /// 这个构建的 APNs 令牌是不是沙盒环境的（docs/push.md 第 1 节，按编译条件定）：Debug 构建用开发证书签名
    /// （`aps-environment` 是 development），报 `apns_sandbox`；Release（TestFlight、App Store）报 `apns`。
    /// 用法见 `PushRegistration.forThisBuild(deviceToken:)`。
    static var usesAPNsSandbox: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    static func clientKind(
        environment: [String: String], infoDictionary: [String: Any]? = nil, isDebugBuild: Bool
    ) -> ClientKind {
        switch environment[mockEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return .mock
        case "0", "false", "no": return .core
        default: break
        }
        let built = (infoDictionary?[clientInfoKey] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        return ClientKind(rawValue: built ?? "") ?? (isDebugBuild ? .mock : .core)
    }

    /// 启动后要打开的深链（`THINKTIN_OPEN_URL`）；没设、不是 `thinktin://` 的为 nil。
    static func launchURL(environment: [String: String]) -> URL? {
        guard let raw = environment[launchURLEnvironmentKey]?.trimmingCharacters(in: .whitespaces),
            let url = URL(string: raw), url.scheme?.lowercased() == "thinktin"
        else { return nil }
        return url
    }

    /// 启动后打开侧边抽屉（`THINKTIN_OPEN_DRAWER=1`）。
    static func opensDrawerAtLaunch(environment: [String: String]) -> Bool {
        let value = environment[launchDrawerEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return ["1", "true", "yes"].contains(value)
    }

    /// Info.plist 里的地址；没有、为空、没展开（`$(...)`）或不是 http(s) 的绝对地址时用默认地址。
    static func baseURL(infoDictionary: [String: Any]?) -> URL {
        guard
            let raw = (infoDictionary?[baseURLInfoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = url.host, !host.isEmpty
        else { return defaultBaseURL }
        return url
    }

    /// 缓存文件的位置；目录不存在就建，并标成不进 iCloud / iTunes 备份（缓存能从服务端重新拉）。
    static func cacheFileURL(fileManager: FileManager = .default) throws -> URL {
        var directory =
            try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent(cacheFileName, isDirectory: false)
    }
}
