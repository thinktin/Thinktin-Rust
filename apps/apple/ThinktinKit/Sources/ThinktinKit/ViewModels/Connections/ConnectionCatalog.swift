import Foundation

// 连接目录（改版规范 4.8、6.12；参考 36–52、101–107）的数据结构。
//
// ThinkTin 现在只有四样接入（电脑、IM 渠道、模型 key、保险箱，`ConnectionBuiltIn`），用真数据；参考里其余的第三方应用、
// “此 iPhone”的能力、外部密码管理器 ThinkTin 还没有后端，目录里先放本地的演示数据（`ConnectionsDemoData`），点了弹“即将推出”。
// 用户会按真实功能再删改（docs/progress/r2-connections.md）。

extension IDTag {
    /// 连接目录里的一个应用（客户端自己的 id，不是服务端的）。
    public enum Connection {}
}

/// 连接目录里的一个应用：`computer`、`feishu`、`docs`。目录是本地的，id 也是本地定的。
public typealias ConnectionID = EntityID<IDTag.Connection>

/// 一段中英文都有的文字（目录是本地数据，两种语言写在一起）。
public struct ConnectionText: Hashable, Sendable {
    public var chinese: String
    public var english: String

    public init(_ chinese: String, _ english: String) {
        self.chinese = chinese
        self.english = english
    }

    public func callAsFunction(_ language: DisplayLanguage) -> String {
        language == .chinese ? chinese : english
    }
}

/// 目录顶上的分类胶囊（参考 36、40–51），按这个顺序排；“全部”是 nil。
///
/// 参考的分类之外，ThinkTin 多了“电脑”“模型”两类，放在“iPhone”后面：ThinkTin 自带的接入大多在这两类和“通信”（IM 渠道）、
/// “密码管理器”（保险箱）里。
public enum ConnectionCategory: String, CaseIterable, Hashable, Sendable, Codable {
    /// 这台手机上的能力（参考 40“此 iPhone”：日历、家庭、提醒、通讯录、位置、闹钟）。只在 iPhone 上显示。
    case thisDevice
    case computer
    case models
    case passwords
    case productivity
    case communication
    case design
    case code
    case data
    case sales
    case marketing
    case finance
    case research
    case support

    /// 胶囊上的字。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .thisDevice: return "iPhone"
        case .computer: return zh ? "电脑" : "Computer"
        case .models: return zh ? "模型" : "Models"
        case .passwords: return zh ? "密码管理器" : "Passwords"
        case .productivity: return zh ? "效率" : "Productivity"
        case .communication: return zh ? "通信" : "Communication"
        case .design: return zh ? "设计" : "Design"
        case .code: return zh ? "代码" : "Code"
        case .data: return zh ? "数据" : "Data"
        case .sales: return zh ? "销售" : "Sales"
        case .marketing: return zh ? "营销" : "Marketing"
        case .finance: return zh ? "财务" : "Finance"
        case .research: return zh ? "研究" : "Research"
        case .support: return zh ? "支持" : "Support"
        }
    }

    /// 选中这一类时列表顶上的标题（参考 40“此 iPhone”、41“密码管理器”）。
    public func heading(_ language: DisplayLanguage = .current) -> String {
        switch self {
        case .thisDevice: return language == .chinese ? "此 iPhone" : "This iPhone"
        default: return title(language)
        }
    }

    /// 标题下面的一段说明（参考 40 只有“此 iPhone”有）。
    public func explanation(_ language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch self {
        case .thisDevice:
            return zh
                ? "允许以后，Botin 能用这台 iPhone 上的这些能力；没允许的，Botin 第一次要用时会先问你。"
                : "Once allowed, Botins can use these on this iPhone. Anything you haven't allowed, a Botin asks about first."
        case .computer:
            return zh
                ? "在电脑上装好 ThinkTin、用手机扫它显示的二维码配对。"
                : "Install ThinkTin on your computer, then scan the code it shows with this phone to pair."
        default:
            return nil
        }
    }

    /// 只有手机上才有的分类（Mac 上不显示）。
    public var isPhoneOnly: Bool { self == .thisDevice }

    /// 显示的胶囊（“全部”之外）：Mac 上去掉“iPhone”。
    public static func visible(onPhone: Bool) -> [ConnectionCategory] {
        allCases.filter { onPhone || !$0.isPhoneOnly }
    }
}

/// 目录“全部”里能点开完整列表的两组（参考 36 的“为你推荐 >”“精选插件 >”，完整列表 101–104）。
public enum ConnectionList: String, CaseIterable, Hashable, Sendable, Codable {
    case recommended
    case featured

    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .recommended: return zh ? "为你推荐" : "Recommended"
        case .featured: return zh ? "精选" : "Featured"
        }
    }

    /// 目录“全部”里先显示几个（参考 36：推荐露出 4 个、精选 6 个），其余在完整列表里。
    public var previewLimit: Int {
        switch self {
        case .recommended: return 4
        case .featured: return 6
        }
    }
}

/// ThinkTin 已经有的接入（规范 6.12 A）：用真数据（`devices()`、`imChannels()`、`credentials()`、`vaultItems()`），
/// 点了进各自现有的管理页。
public enum ConnectionBuiltIn: String, CaseIterable, Hashable, Sendable {
    /// 配对的电脑（12.9；“登录设备”里的电脑）。
    case computer
    /// 飞书 / Lark 群机器人（12.14）。
    case feishu
    /// 企业微信群机器人。
    case wecom
    /// 钉钉群机器人。
    case dingtalk
    /// 模型 key（12.4）。
    case modelKeys
    /// 密码保险箱（12.13）。
    case vault

    /// IM 渠道算进这一项的平台（飞书和 Lark 是同一个）。
    public var imVendors: [ImVendor] {
        switch self {
        case .feishu: [.feishu, .lark]
        case .wecom: [.wecom]
        case .dingtalk: [.dingtalk]
        default: []
        }
    }

    /// 管理页（详情“…”菜单的“管理”、断开连接的去处）。
    public var manageRoute: AppRoute {
        switch self {
        case .computer: .devices
        case .feishu, .wecom, .dingtalk: .imChannels
        case .modelKeys: .credentials
        case .vault: .vault
        }
    }

    /// 还没设置时按钮去的地方（参考“授权”的位置）：配对电脑看登录设备页的说明、加群在 IM 渠道页、加 key 弹添加 key、
    /// 保险箱进列表点“+”。
    public var setupRoute: AppRoute {
        switch self {
        case .computer: .devices
        case .feishu, .wecom, .dingtalk: .imChannels
        case .modelKeys: .addCredential
        case .vault: .vault
        }
    }
}

/// 图标方块的底色（界面上换成系统色）。参考的图标是各家的 Logo，ThinkTin 不用别家的 Logo，一律 SF Symbol + 底色。
public enum ConnectionIconTint: String, CaseIterable, Hashable, Sendable {
    /// 灰底（参考里没有 Logo 的插件是灰底拼图）。
    case neutral
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink
}

/// 目录里的一个应用。
public struct ConnectionApp: Identifiable, Hashable, Sendable {
    /// 什么样的入口：决定按钮写什么（参考的“连接”“允许”）。
    public enum Kind: Hashable, Sendable {
        /// 第三方应用：“连接”。
        case app
        /// 这台手机上的能力（参考 40）：“允许”。
        case deviceCapability
    }

    public var id: ConnectionID
    public var name: ConnectionText
    /// 列表里的两行灰字。
    public var summary: ConnectionText
    /// 详情里的长说明（参考 105、106）；nil 用 `summary`。
    public var details: ConnectionText?
    public var systemImage: String
    public var tint: ConnectionIconTint
    public var categories: [ConnectionCategory]
    public var kind: Kind
    /// ThinkTin 自带的接入（真数据）；nil 是演示数据（即将推出）。
    public var builtIn: ConnectionBuiltIn?
    /// 带的技能（参考 105“含技能插件”）。
    public var skills: [ConnectionText]
    /// 推荐的理由：连了这一项时写“因为你连了 X”（参考 36“因为你在使用 …”）；没连就显示 `summary`。
    public var recommendedBecause: ConnectionBuiltIn?

    public init(
        id: ConnectionID, name: ConnectionText, summary: ConnectionText, details: ConnectionText? = nil,
        systemImage: String, tint: ConnectionIconTint = .neutral, categories: [ConnectionCategory], kind: Kind = .app,
        builtIn: ConnectionBuiltIn? = nil, skills: [ConnectionText] = [], recommendedBecause: ConnectionBuiltIn? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.details = details
        self.systemImage = systemImage
        self.tint = tint
        self.categories = categories
        self.kind = kind
        self.builtIn = builtIn
        self.skills = skills
        self.recommendedBecause = recommendedBecause
    }

    /// 只在手机上有的（“此 iPhone”的能力）。
    public var isPhoneOnly: Bool { categories.contains(.thisDevice) }
}

/// 整个目录：应用（按显示顺序）和“为你推荐”“精选”两组。
public struct ConnectionCatalog: Hashable, Sendable {
    public var apps: [ConnectionApp]
    public var recommended: [ConnectionID]
    public var featured: [ConnectionID]

    public init(apps: [ConnectionApp], recommended: [ConnectionID], featured: [ConnectionID]) {
        self.apps = apps
        self.recommended = recommended
        self.featured = featured
    }

    public func app(_ id: ConnectionID) -> ConnectionApp? {
        apps.first { $0.id == id }
    }

    /// ThinkTin 自带的那一项。
    public func app(_ builtIn: ConnectionBuiltIn) -> ConnectionApp? {
        apps.first { $0.builtIn == builtIn }
    }

    /// 一个分类里的应用（按目录顺序）。
    public func apps(in category: ConnectionCategory) -> [ConnectionApp] {
        apps.filter { $0.categories.contains(category) }
    }

    /// 一组里的应用（按组里的顺序；目录里没有的 id 跳过）。
    public func apps(in list: ConnectionList) -> [ConnectionApp] {
        let ids =
            switch list {
            case .recommended: recommended
            case .featured: featured
            }
        return ids.compactMap(app)
    }

    /// ThinkTin 自带的几项（按目录顺序）：已连接列表（参考 37）里列它们。
    public var builtIns: [ConnectionApp] {
        apps.filter { $0.builtIn != nil }
    }
}
