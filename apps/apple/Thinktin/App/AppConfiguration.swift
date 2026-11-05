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
    /// 截图、看空状态用（tools/apple/screenshots.sh，只在 Debug 构建里认）：`1` 时 Mock 从刚注册的账号开始
    /// （`DemoData.newAccountState`：还没有 Botin，首页是“还没有 Botin”的空状态）。用的是真核心时不管它。
    static let mockEmptyEnvironmentKey = "THINKTIN_MOCK_EMPTY"
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
    /// 截图用（同上，只在 Debug 构建里认）：启动后打开首页第一个实例（演示数据里是“写作助手”）的哪一页，值见 `OpenScreen`。
    /// 对话、计划、产出物这些页面没有深链，设置、新建 Botin 是 sheet，首页搜索要激活搜索栏，所以单列一个变量。
    static let openScreenEnvironmentKey = "THINKTIN_OPEN_SCREEN"

    /// `THINKTIN_OPEN_SCREEN` 认的页面（docs/ios-ui-redesign.md 7.6 的截图清单）。打开的办法在 `OpenScreen.swift`
    /// （要 ThinktinKit 的路由，这个文件只依赖 Foundation）。
    enum OpenScreen: String, CaseIterable, Equatable, Sendable {
        /// 实例的对话（首页 → 对话）。
        case conversation
        /// 实例的计划（首页 → 对话 → 计划）。
        case plans
        /// 实例的产出物（首页 → 对话 → 产出物）。
        case artifacts
        /// 设置（sheet）。
        case settings
        /// 首页搜索（激活搜索栏）。
        case search
        /// 新建 Botin（sheet，`.adopt(agentID: nil)`：在表单里选引擎）。
        case adopt
        /// 团队（工作台菜单的“团队”，首页 → 团队；参考里没有这一页，看它和改版的页面是不是一套样子）。
        case teams
        /// 新任务的 Botin 选择（sheet，参考 11 的选择器版式）。
        case newtask
        /// 上手引导（sheet）。
        case onboarding

        /// 是不是某个实例的页面（要先等实例列表拿到）。
        var needsInstance: Bool {
            switch self {
            case .conversation, .plans, .artifacts: true
            case .settings, .search, .adopt, .teams, .newtask, .onboarding: false
            }
        }
    }

    var client: ClientKind
    var baseURL: URL
    /// Mock 从刚注册、还没有 Botin 的账号开始（`THINKTIN_MOCK_EMPTY=1`，只有 Debug 构建、用 Mock 时为 true）。
    var startsWithEmptyAccount = false

    /// 按进程环境变量、Info.plist 和构建配置得出配置。
    static func resolve(
        environment: [String: String],
        infoDictionary: [String: Any]?,
        isDebugBuild: Bool
    ) -> AppConfiguration {
        let client = clientKind(environment: environment, infoDictionary: infoDictionary, isDebugBuild: isDebugBuild)
        return AppConfiguration(
            client: client,
            baseURL: baseURL(infoDictionary: infoDictionary),
            startsWithEmptyAccount: client == .mock
                && startsWithEmptyAccount(environment: environment, isDebugBuild: isDebugBuild)
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

    /// `THINKTIN_MOCK_EMPTY` 是 `1` / `true` / `yes`（不分大小写）且是 Debug 构建。
    static func startsWithEmptyAccount(environment: [String: String], isDebugBuild: Bool) -> Bool {
        guard isDebugBuild else { return false }
        switch environment[mockEmptyEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    /// 启动后要打开的深链（`THINKTIN_OPEN_URL`）；没设、不是 `thinktin://` 的为 nil。
    static func launchURL(environment: [String: String]) -> URL? {
        guard let raw = environment[launchURLEnvironmentKey]?.trimmingCharacters(in: .whitespaces),
            let url = URL(string: raw), url.scheme?.lowercased() == "thinktin"
        else { return nil }
        return url
    }

    /// 启动后要打开的页面（`THINKTIN_OPEN_SCREEN`，不分大小写）；没设、认不出的为 nil。
    static func openScreen(environment: [String: String]) -> OpenScreen? {
        guard let raw = environment[openScreenEnvironmentKey]?.trimmingCharacters(in: .whitespaces) else { return nil }
        return OpenScreen(rawValue: raw.lowercased())
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
