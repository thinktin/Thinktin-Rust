import Foundation
import Observation

/// 一个应用连没连（决定列表行和详情底部的按钮）。
public enum ConnectionStatus: Hashable, Sendable {
    /// 第三方应用，还没连（演示数据：即将推出）。按钮“连接”（参考 36）。
    case available
    /// 这台手机上的能力，还没允许（演示数据）。按钮“允许”（参考 40，突出的）。
    case needsPermission
    /// ThinkTin 自带的接入，还没设置（一个群、一把 key 都没有）。按钮“添加”“配对”（参考 37“授权”的位置，突出的）。
    case needsSetup
    /// 已连接：`count` 个账户（群、key、电脑、条目）。按钮灰掉的“已连接”（参考 36、37）。
    case connected(count: Int)
    /// ThinkTin 自带的接入，没拉到（离线、出错）：不放按钮。
    case unknown

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// 点了按钮做什么。
public enum ConnectionAction: Hashable, Sendable {
    /// 打开现有的页面（ThinkTin 自带的接入：IM 渠道、添加 key、登录设备、保险箱）。
    case open(AppRoute)
    /// ThinkTin 还没有：弹“即将推出”。
    case comingSoon(ConnectionID)
}

/// 列表行右边、详情底部的按钮。
public struct ConnectionButton: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// 灰底小胶囊（参考的“连接”“已连接”）。
        case regular
        /// 突出的（参考的“授权”“允许”）。
        case prominent
    }

    public var title: String
    public var style: Style
    /// nil：灰掉、不能点（“已连接”）。
    public var action: ConnectionAction?
    /// 读屏念的（“连接 在线文档”）。
    public var accessibilityLabel: String

    public var isEnabled: Bool { action != nil }
}

/// 目录、完整列表、已连接列表里的一行（参考 36、37、40–51、101–104）：图标、名字、两行灰字、右边的小胶囊。
public struct ConnectionRow: Identifiable, Hashable, Sendable {
    public var id: ConnectionID
    public var title: String
    public var subtitle: String
    public var systemImage: String
    public var tint: ConnectionIconTint
    public var button: ConnectionButton?
    /// 读屏把整行念成一句（名字、说明、状态）。
    public var accessibilityLabel: String
}

/// 目录里的一组：标题（界面画成 `.headline`）、说明、行。
public struct ConnectionSection: Identifiable, Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        case list(ConnectionList)
        case category(ConnectionCategory)
        case search
    }

    public var id: ID
    public var title: String
    public var explanation: String?
    /// 点标题压栈到完整列表（参考 36 组标题后面的“>”）；nil 时标题不能点。
    public var moreRoute: AppRoute?
    public var rows: [ConnectionRow]
}

/// 详情“账户”组里的一行（参考 38、105、107）：群、key、电脑、保险箱条目。
public struct ConnectionAccount: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// 停用的、离线的：灰字（参考 107 第二行）。
    public var isDimmed: Bool
    /// 点了打开的页面（key 详情、保险箱条目、IM 渠道、登录设备）。
    public var route: AppRoute?
}

/// 一个应用的详情（参考 38、39、52、105–107）。
public struct ConnectionDetail: Identifiable, Hashable, Sendable {
    public var id: ConnectionID
    public var title: String
    public var description: String
    public var systemImage: String
    public var tint: ConnectionIconTint
    public var status: ConnectionStatus
    /// “账户”组（已连接时才有）。
    public var accounts: [ConnectionAccount]
    /// “添加账户”（已连接时才有）。
    public var addAccount: ConnectionAction?
    /// 技能（参考 105）。
    public var skills: [String]
    /// 底部居中的胶囊：没连时“连接”“允许”“添加”（突出的），连上了灰掉的“已连接”；拉不到状态时为 nil。
    public var primary: ConnectionButton?
    /// 右上“…”菜单的“管理”（ThinkTin 自带的接入）。
    public var manageRoute: AppRoute?
    /// 右上“…”菜单（已连接时才有，参考 39：红色“断开连接”）。
    public var showsMenu: Bool
    /// 断开连接的确认弹窗：ThinkTin 自带的接入要到管理页逐个删，这里说清楚去哪删；演示数据是 nil（弹“即将推出”）。
    public var disconnectNote: String?
    /// 说明下面的一句灰字（演示数据写“即将推出”）。
    public var footnote: String?
}

/// 连接目录（规范 4.8，参考 36–52、101–107）：分类、推荐、精选、搜索、已连接列表、详情。
///
/// 应用目录是本地的（`ConnectionsDemoData`）；ThinkTin 自带的接入（电脑、IM 渠道、模型 key、保险箱）的状态和账户
/// 用现有接口拉（`devices()`、`imChannels()`、`credentials()`、`vaultItems()`，规范 4.8.1 说的只用这几个），
/// 一样没拉到不影响别的。不缓存：离线时目录照样显示，自带的那几项不放按钮。
@Observable @MainActor
public final class ConnectionsModel {
    public let catalog: ConnectionCatalog
    /// 选中的分类胶囊；nil 是“全部”。
    public var category: ConnectionCategory?
    /// 搜索框里的字（参考 36 底部的搜索框）。
    public var query = ""

    /// 登录着的电脑；没拉到为 nil。
    public private(set) var computers: [DeviceInfo]?
    public private(set) var imChannels: [ImChannel]?
    public private(set) var credentials: [Credential]?
    public private(set) var vaultItems: [VaultItem]?
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    /// 四样都没拉到时的错（页面顶上的横幅）；拉到了一样就不报，没拉到的那几项不放按钮。
    public private(set) var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let onPhone: Bool

    /// - Parameters:
    ///   - category: 预选的分类（`.connections(category:)`）；Mac 上的“iPhone”换成“全部”。
    ///   - onPhone: 在 iPhone 上（显示“此 iPhone”那一类）。界面层在 iOS 上传 true。
    public init(
        client: any ClientProtocol, catalog: ConnectionCatalog = ConnectionsDemoData.catalog,
        category: ConnectionCategory? = nil, onPhone: Bool = true
    ) {
        self.client = client
        self.catalog = catalog
        self.onPhone = onPhone
        self.category = category.flatMap { onPhone || !$0.isPhoneOnly ? $0 : nil }
    }

    // MARK: 拉数据

    /// 拉自带接入的状态（四个接口一起拉）。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = self.client
        async let devices = Self.attempt { try await client.devices() }
        async let channels = Self.attempt { try await client.imChannels() }
        async let keys = Self.attempt { try await client.credentials() }
        async let items = Self.attempt { try await client.vaultItems() }
        let (d, c, k, v) = await (devices, channels, keys, items)
        computers = d.value?.filter(\.isComputer) ?? computers
        imChannels = c.value ?? imChannels
        credentials = k.value ?? credentials
        vaultItems = v.value ?? vaultItems
        let errors = [d.error, c.error, k.error, v.error].compactMap { $0 }
        error = errors.count == 4 ? errors.first : nil
        hasLoaded = true
    }

    private struct Attempt<Value: Sendable>: Sendable {
        var value: Value?
        var error: ClientError?
    }

    private nonisolated static func attempt<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async -> Attempt<Value> {
        do {
            return Attempt(value: try await body())
        } catch {
            return Attempt(error: (error as? ClientError) ?? .internal(message: String(describing: error)))
        }
    }

    // MARK: 状态

    /// 显示的分类胶囊（“全部”之外）。
    public var categories: [ConnectionCategory] {
        ConnectionCategory.visible(onPhone: onPhone)
    }

    /// 这台设备上显示的应用（Mac 上没有“此 iPhone”的能力）。
    public var visibleApps: [ConnectionApp] {
        catalog.apps.filter { onPhone || !$0.isPhoneOnly }
    }

    /// 自带接入的账户数；没拉到为 nil。
    public func accountCount(of builtIn: ConnectionBuiltIn) -> Int? {
        switch builtIn {
        case .computer: return computers?.count
        case .feishu, .wecom, .dingtalk:
            return imChannels.map { channels in channels.filter { builtIn.imVendors.contains($0.vendor) }.count }
        case .modelKeys: return credentials?.count
        case .vault: return vaultItems?.count
        }
    }

    public func status(of app: ConnectionApp) -> ConnectionStatus {
        guard let builtIn = app.builtIn else {
            return app.kind == .deviceCapability ? .needsPermission : .available
        }
        guard let count = accountCount(of: builtIn) else { return .unknown }
        return count > 0 ? .connected(count: count) : .needsSetup
    }

    /// 已连接的个数（目录右上“已连接 N 个”）。
    public var connectedCount: Int {
        catalog.builtIns.filter { status(of: $0).isConnected }.count
    }

    // MARK: 行和分组

    /// 一行。`showsReason`：推荐组里写推荐理由（连了相关的那一项时）。
    public func row(
        for app: ConnectionApp, showsReason: Bool = false, showsCount: Bool = false,
        language: DisplayLanguage = .current
    ) -> ConnectionRow {
        let status = status(of: app)
        var subtitle = app.summary(language)
        if showsReason, let reason = recommendationReason(for: app, language: language) {
            subtitle = reason
        } else if showsCount, case .connected(let count) = status, let builtIn = app.builtIn {
            subtitle = ConnectionsText.accountCount(count, of: builtIn, language: language)
        }
        let button = button(for: app, status: status, language: language)
        var parts = [app.name(language), subtitle]
        if let button { parts.append(button.title) }
        return ConnectionRow(
            id: app.id, title: app.name(language), subtitle: subtitle, systemImage: app.systemImage, tint: app.tint,
            button: button, accessibilityLabel: parts.joined(separator: language == .chinese ? "，" : ", "))
    }

    /// 推荐理由：连了相关的那一项时“因为你连了飞书”；没连时为 nil（行上写说明）。
    public func recommendationReason(for app: ConnectionApp, language: DisplayLanguage = .current) -> String? {
        guard let because = app.recommendedBecause, let source = catalog.app(because),
            status(of: source).isConnected
        else { return nil }
        return ConnectionsText.because(source.name(language), language: language)
    }

    func button(for app: ConnectionApp, status: ConnectionStatus, language: DisplayLanguage) -> ConnectionButton? {
        let name = app.name(language)
        switch status {
        case .available:
            let title = ConnectionsText.connect(language)
            return ConnectionButton(
                title: title, style: .regular, action: .comingSoon(app.id),
                accessibilityLabel: ConnectionsText.actionLabel(title, name))
        case .needsPermission:
            let title = ConnectionsText.allow(language)
            return ConnectionButton(
                title: title, style: .prominent, action: .comingSoon(app.id),
                accessibilityLabel: ConnectionsText.actionLabel(title, name))
        case .needsSetup:
            guard let builtIn = app.builtIn else { return nil }
            let title = ConnectionsText.setup(builtIn, language: language)
            return ConnectionButton(
                title: title, style: .prominent, action: .open(builtIn.setupRoute),
                accessibilityLabel: ConnectionsText.actionLabel(title, name))
        case .connected:
            return ConnectionButton(
                title: ConnectionsText.connected(language), style: .regular, action: nil,
                accessibilityLabel: ConnectionsText.connected(language))
        case .unknown:
            return nil
        }
    }

    /// 目录的分组：有搜索字时是一组搜索结果；“全部”是“推荐”“精选”（各露出几个，标题点开完整列表）；
    /// 选了分类是那一类（标题、说明、全部的行）。
    public func sections(_ language: DisplayLanguage = .current) -> [ConnectionSection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return [
                ConnectionSection(
                    id: .search, title: ConnectionsText.results(language), explanation: nil, moreRoute: nil,
                    rows: searchResults(text, language: language))
            ]
        }
        guard let category else {
            return ConnectionList.allCases.map { list in
                let rows = listRows(list, language: language)
                return ConnectionSection(
                    id: .list(list), title: list.title(language), explanation: nil,
                    moreRoute: .connectionList(list), rows: Array(rows.prefix(list.previewLimit)))
            }
        }
        return [
            ConnectionSection(
                id: .category(category), title: category.heading(language),
                explanation: category.explanation(language), moreRoute: nil,
                rows: catalog.apps(in: category).map { row(for: $0, language: language) })
        ]
    }

    /// 完整列表（参考 101–104）。
    public func listRows(_ list: ConnectionList, language: DisplayLanguage = .current) -> [ConnectionRow] {
        catalog.apps(in: list).filter { onPhone || !$0.isPhoneOnly }.map {
            row(for: $0, showsReason: list == .recommended, language: language)
        }
    }

    /// 搜索：名字、说明、技能里有这几个字的（两种语言都搜，不分大小写），按目录顺序。
    public func searchResults(_ text: String, language: DisplayLanguage = .current) -> [ConnectionRow] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return visibleApps.filter { app in
            let haystack =
                [app.name.chinese, app.name.english, app.summary.chinese, app.summary.english]
                + app.skills.flatMap { [$0.chinese, $0.english] }
            return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        .map { row(for: $0, language: language) }
    }

    /// 已连接列表（参考 37）：ThinkTin 自带的几项，连上的写账户数，没设置的写说明、按钮去设置。
    /// `query` 不为空时按名字和说明过滤。
    public func installedRows(_ language: DisplayLanguage = .current) -> [ConnectionRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.builtIns.filter { app in
            needle.isEmpty
                || [app.name.chinese, app.name.english, app.summary.chinese, app.summary.english].contains {
                    $0.localizedCaseInsensitiveContains(needle)
                }
        }
        .map { row(for: $0, showsCount: true, language: language) }
    }

    // MARK: 详情

    /// 一个应用的详情；目录里没有这个 id 时为 nil。
    public func detail(_ id: ConnectionID, language: DisplayLanguage = .current) -> ConnectionDetail? {
        guard let app = catalog.app(id), onPhone || !app.isPhoneOnly else { return nil }
        let status = status(of: app)
        let connected = status.isConnected
        var primary = button(for: app, status: status, language: language)
        if let builtIn = app.builtIn, case .needsSetup = status {
            primary?.title = ConnectionsText.setupLong(builtIn, language: language)
        }
        return ConnectionDetail(
            id: app.id, title: app.name(language), description: (app.details ?? app.summary)(language),
            systemImage: app.systemImage, tint: app.tint, status: status,
            accounts: connected ? accounts(of: app, language: language) : [],
            addAccount: connected ? addAccountAction(for: app) : nil,
            skills: app.skills.map { $0(language) }, primary: primary,
            manageRoute: app.builtIn?.manageRoute, showsMenu: connected,
            disconnectNote: app.builtIn.map { ConnectionsText.disconnectNote($0, language: language) },
            footnote: app.builtIn == nil ? ConnectionsText.comingSoonFootnote(language) : nil)
    }

    /// “添加账户”：自带的接入去设置页；演示数据弹“即将推出”。
    func addAccountAction(for app: ConnectionApp) -> ConnectionAction {
        if let builtIn = app.builtIn { return .open(builtIn.setupRoute) }
        return .comingSoon(app.id)
    }

    /// “账户”组（参考 38、107）：自带接入的群、key、电脑、保险箱条目；演示数据没有。
    public func accounts(of app: ConnectionApp, language: DisplayLanguage = .current) -> [ConnectionAccount] {
        let zh = language == .chinese
        switch app.builtIn {
        case .computer:
            return (computers ?? []).map { computer in
                ConnectionAccount(
                    id: computer.id.rawValue, title: computer.name,
                    subtitle: computer.isOnline ? (zh ? "在线" : "Online") : (zh ? "离线" : "Offline"),
                    isDimmed: !computer.isOnline, route: .devices)
            }
        case .feishu, .wecom, .dingtalk:
            let vendors = app.builtIn?.imVendors ?? []
            return (imChannels ?? []).filter { vendors.contains($0.vendor) }.map { channel in
                let state: String? =
                    !channel.isEnabled
                    ? (zh ? "已停用" : "Off")
                    : (channel.lastError != nil ? (zh ? "上次发送失败" : "Last delivery failed") : nil)
                return ConnectionAccount(
                    id: channel.id.rawValue, title: ImChannelText.title(channel, language: language),
                    subtitle: [ImChannelText.vendor(channel.vendor, language: language), state].compactMap { $0 }
                        .joined(separator: " · "),
                    isDimmed: !channel.isEnabled, route: .imChannels)
            }
        case .modelKeys:
            return (credentials ?? []).map { key in
                let label = key.label.trimmingCharacters(in: .whitespaces)
                return ConnectionAccount(
                    id: key.id.rawValue, title: label.isEmpty ? key.vendor : label,
                    subtitle: key.maskedKey + (key.isDisabled ? (zh ? " · 已停用" : " · Off") : ""),
                    isDimmed: key.isDisabled, route: .credential(key.id))
            }
        case .vault:
            return (vaultItems ?? []).map { item in
                ConnectionAccount(
                    id: item.id.rawValue, title: item.name, subtitle: item.purpose.isEmpty ? nil : item.purpose,
                    isDimmed: false, route: .vaultItem(item.id))
            }
        case nil:
            return []
        }
    }

    /// “即将推出”弹窗的说明。
    public func comingSoonMessage(_ id: ConnectionID, language: DisplayLanguage = .current) -> String {
        ConnectionsText.comingSoonMessage(catalog.app(id)?.name(language), language: language)
    }
}
