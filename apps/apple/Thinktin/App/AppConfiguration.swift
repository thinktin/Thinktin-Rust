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
    /// 截图用（同上，只在 Debug 构建里认）：启动后打开哪一页，值见 `OpenScreen`；Botin 的页面是首页第一个 Botin（演示数据里
    /// 是“写作助手”）的。对话、计划、产出物这些页面没有深链，设置、新建 Botin 是 sheet，首页搜索要激活搜索栏，编辑 Botin、
    /// 保险箱的新建表单这些是页面里本地打开的，所以单列一个变量。
    static let openScreenEnvironmentKey = "THINKTIN_OPEN_SCREEN"
    /// 截图用（同上，只在 Debug 构建里认）：截图脚本每次启动都设成 `1`，Botin 的脸不动（`isScreenshotLaunch`）。首页那两张
    /// 既不设深链也不设页面，单看上面两个变量认不出是截图。
    static let screenshotEnvironmentKey = "THINKTIN_SCREENSHOT"

    /// `THINKTIN_OPEN_SCREEN` 认的页面（tools/apple/screenshots.sh 的截图清单，和参考截图的对照见
    /// docs/ios-ui-redesign-shots.md）。打开的办法在 `OpenScreen.swift`（要 ThinktinKit 的路由，这个文件只依赖 Foundation）：
    /// 有路由的页面按深链的规矩打开，页面里本地打开的子页（编辑 Botin、保险箱的新建表单、设备详情……）先开父页面、
    /// 再用 `Subpage` 一层层打开。
    enum OpenScreen: String, CaseIterable, Equatable, Sendable {
        // MARK: 首页和对话

        /// 首页第一个 Botin 置顶（参考 111、120：顶上一排大头像）。置顶只记在这台设备上：截图脚本每次启动都用启动参数清空。
        case homepinned
        /// 首页最后一个 Botin 隐藏，打开“已隐藏的 Botin”（`.hiddenBotins`，参考 114）。
        case hiddenbotins
        /// 首页的 Botin 全部隐藏：首页是“都隐藏了”的空状态（参考 113）。
        case homeallhidden
        /// 实例的对话（首页 → 对话）。
        case conversation
        /// 对话里的查找栏（“…”的“在对话中查找”，参考 04）。
        case conversationfind
        /// 首页搜索（激活搜索栏）。
        case search

        // MARK: Botin

        /// Botin 资料 → 编辑 Botin（首页 → 对话 → 资料 → 编辑，参考 12；语音、速度、语言三行在这页上）。
        case botinedit
        /// Botin 资料 → 编辑 → 头像（参考 18）。
        case botinavatar
        /// Botin 资料 → 工作区（参考 65）。
        case workspace
        /// 实例的观看与接管（首页 → 对话 → 观看与接管，`.instanceScreen`；规范 4.6.2，演示画面）。
        case instancescreen
        /// 选择主 Botin（sheet，`.primaryBotin`，参考 11）。
        case primarybotin
        /// 新建 Botin（sheet，`.adopt(agentID: nil)`：在表单里选引擎）。
        case adopt
        /// 引擎目录（`.agentCatalog`，新建表单的“了解引擎”）。
        case engines
        /// 引擎目录 → 第一个引擎的详情 sheet。
        case enginedetail

        // MARK: 任务与资料

        /// 实例的计划（首页 → 对话 → 计划）。
        case plans
        /// 全部 Botin 的计划（工作台菜单的“计划”，首页 → 计划，`.plans(instanceID: nil)`）。截图配 `THINKTIN_MOCK_EMPTY=1`：
        /// 新账号一个计划也没有，看空状态（参考 21：正中一段灰字）。
        case allplans
        /// 实例的产出物（首页 → 对话 → 产出物）。
        case artifacts
        /// 实例的产出物，选中“媒体”（参考 23）。
        case artifactsmedia
        /// 团队（工作台菜单的“团队”，首页 → 团队；参考里没有这一页，看它和改版的页面是不是一套样子）。
        case teams
        /// 新任务的 Botin 选择（sheet，参考 11 的选择器版式）。
        case newtask
        /// 上手引导（sheet）。
        case onboarding

        // MARK: 连接

        /// 连接目录（首页 → 连接，`.connections(category: nil)`；规范 4.8）。
        case connections
        /// 已连接（首页 → 已连接，`.connectedApps`，参考 37）。
        case connected
        /// 已连接 → “电脑”的详情 sheet（参考 38 的位置）。
        case connectiondetail

        // MARK: 设置（sheet）

        /// 设置（sheet）。
        case settings
        /// 设置里的账号（设置 sheet 里压一页；参考 54）。
        case account
        /// 设置里的用量（参考 55）。
        case usage
        /// 设置里的订阅（参考 56；规范 4.9.4）。
        case subscription
        /// 设置里的模型 key（参考里没有，看它和改版的页面是不是一套样子）。
        case modelkeys
        /// 设置里的保险箱（参考 57）。
        case vault
        /// 保险箱 → 新建登录信息（参考 59）。
        case vaultlogin
        /// 保险箱 → 新建卡片（参考 60）。
        case vaultcard
        /// 保险箱 → 新建联系信息（参考 61）。
        case vaultcontact
        /// 设置里的权限与规则（规范 4.9.8，参考 62）。
        case permissions
        /// 权限与规则 → 新建一条“始终询问”的规则（参考 63）。
        case permissionrule
        /// 设置里的登录设备（参考 66）。
        case devices
        /// 登录设备 → 这台 iPhone 的详情（参考 67）。
        case devicedetail
        /// 登录设备 → 第一台电脑的详情（参考 69）。
        case computerdetail
        /// 设置 → 外观（参考 72）。
        case appearance
        /// 设置 → 语言（参考 73）。
        case language
        /// 设置 → 触感反馈（参考 74）。
        case haptics
        /// 设置里的导入记忆（规范 4.9.10，参考 71）。
        case importmemory
        /// 设置里的发送反馈（规范 4.9.14，参考 76）。
        case feedback
        /// 设置根页滚到最底下（参考 70、75：通知、链接、发送反馈、退出登录、版本区）。
        case settingsbottom

        /// 是不是某个 Botin 的页面，或者要摆首页的置顶、隐藏（要先等实例列表拿到，取首页第一行）。
        var needsInstance: Bool {
            switch self {
            case .homepinned, .hiddenbotins, .homeallhidden, .conversation, .conversationfind, .botinedit,
                .botinavatar, .workspace, .instancescreen, .plans, .artifacts, .artifactsmedia:
                true
            default: false
            }
        }

        /// 是不是设置里压进去的页面（先弹设置，再压进设置 sheet 的栈，和用户点进去一样）。外观、语言、触感反馈是设置根页
        /// 本地压的子页，不算。
        var isInSettings: Bool {
            switch self {
            case .account, .usage, .subscription, .modelkeys, .vault, .vaultlogin, .vaultcard, .vaultcontact,
                .permissions, .permissionrule, .devices, .devicedetail, .computerdetail, .importmemory, .feedback:
                true
            default: false
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

    /// 是不是截图脚本启动的（`THINKTIN_SCREENSHOT` 是 `1` / `true` / `yes`，或者设了认得的 `THINKTIN_OPEN_URL`、
    /// `THINKTIN_OPEN_SCREEN`）：是的话 Botin 的脸不眨眼、不转眼，换形状也不做动画（ThinktinUI 的 `\.botinFaceMotion`），
    /// 每次截出来的一样。只在 Debug 构建里用。
    static func isScreenshotLaunch(environment: [String: String]) -> Bool {
        switch environment[screenshotEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return true
        default: return launchURL(environment: environment) != nil || openScreen(environment: environment) != nil
        }
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
