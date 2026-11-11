import Foundation

/// 连接目录（规范 4.8）的文案。参考里的文字只学版式（“连接”“已连接 N 个”“账户”“添加账户”“断开连接”这类通用的界面用词），
/// 组名、搜索框、说明都是 ThinkTin 自己的话（2026-11-05 截图审查：参考的搜索框原句、“为你推荐”“已安装”换掉了）。
/// 这几页的字都不是 agent 写的，不带 AI 生成标识。
public enum ConnectionsText {
    /// 这几页有没有要带 AI 生成标识的字段：目录是本地数据，账户名是用户填的，都不是 agent 写的。
    public static let showsAIGeneratedLabel = false

    public static func connect(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "连接" : "Connect"
    }

    public static func allow(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "允许" : "Allow"
    }

    public static func connected(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "已连接" : "Connected"
    }

    /// 自带的接入还没设置时，行上的按钮（短）。
    public static func setup(_ builtIn: ConnectionBuiltIn, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch builtIn {
        case .computer: return zh ? "配对" : "Pair"
        default: return zh ? "添加" : "Add"
        }
    }

    /// 自带的接入还没设置时，详情底部的按钮（长一点，说清楚加什么）。
    public static func setupLong(_ builtIn: ConnectionBuiltIn, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch builtIn {
        case .computer: return zh ? "配对电脑" : "Pair a computer"
        case .feishu, .wecom, .dingtalk: return zh ? "添加群机器人" : "Add a group bot"
        case .modelKeys: return zh ? "添加 key" : "Add a key"
        case .vault: return zh ? "添加条目" : "Add an item"
        }
    }

    /// 按钮的读屏标签：“连接 在线文档”。
    public static func actionLabel(_ action: String, _ name: String) -> String {
        "\(action) \(name)"
    }

    /// 目录右上的胶囊（参考 36“已连接 5 个”）。
    public static func connectedCount(_ count: Int, language: DisplayLanguage = .current) -> String {
        language == .chinese ? "已连接 \(count) 个" : "\(count) connected"
    }

    /// 已连接列表里一行的副标题（参考 37“2 个连接器”）：“1 台电脑”“3 个 key”。
    public static func accountCount(
        _ count: Int, of builtIn: ConnectionBuiltIn, language: DisplayLanguage = .current
    ) -> String {
        if language == .chinese {
            switch builtIn {
            case .computer: return "\(count) 台电脑"
            case .feishu, .wecom, .dingtalk: return "\(count) 个群"
            case .modelKeys: return "\(count) 个 key"
            case .vault: return "\(count) 个条目"
            }
        }
        let noun: (String, String) =
            switch builtIn {
            case .computer: ("computer", "computers")
            case .feishu, .wecom, .dingtalk: ("group", "groups")
            case .modelKeys: ("key", "keys")
            case .vault: ("item", "items")
            }
        return "\(count) \(count == 1 ? noun.0 : noun.1)"
    }

    /// 推荐理由（参考 36“因为你在使用 …”）。
    public static func because(_ name: String, language: DisplayLanguage = .current) -> String {
        language == .chinese ? "因为你连了\(name)" : "Because you use \(name)"
    }

    /// 搜索结果那一组的标题。
    public static func results(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "搜索结果" : "Results"
    }

    /// 目录底部的搜索框（参考 36 的位置）：名字、说明、技能都搜，所以写“名字或用途”。
    public static func searchPrompt(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "按名字或用途搜索" : "Search by name or use"
    }

    /// 已连接列表的搜索框。
    public static func installedSearchPrompt(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "搜索已连接的应用" : "Search connected apps"
    }

    /// 已连接列表的分组标题（参考 37 的位置）：列的是 ThinkTin 自带的接入，不是装上去的插件。
    public static func installedHeader(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "ThinkTin 自带" : "Built into ThinkTin"
    }

    /// 详情里说明下面的一句（演示数据）。
    public static func comingSoonFootnote(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出：ThinkTin 还不能连这个应用。" : "Coming soon: ThinkTin can't connect this app yet."
    }

    public static func comingSoonTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出" : "Coming soon"
    }

    /// “即将推出”弹窗的说明。
    public static func comingSoonMessage(_ name: String?, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        guard let name, !name.isEmpty else {
            return zh ? "这个功能还在做，做好了会在这里打开。" : "This isn't ready yet. It will open here when it is."
        }
        return zh
            ? "ThinkTin 还不能连\(name)，做好了会在这里打开。"
            : "ThinkTin can't connect \(name) yet. It will open here when it's ready."
    }

    /// 详情里的分组标题（参考 38“账户”）。
    public static func accountsHeader(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "账户" : "Accounts"
    }

    public static func addAccount(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加账户" : "Add account"
    }

    public static func skillsHeader(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "技能" : "Skills"
    }

    public static func manage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "管理" : "Manage"
    }

    /// 参考 39 的菜单项。
    public static func disconnect(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "断开连接" : "Disconnect"
    }

    /// 自带的接入断开连接：要到管理页逐个删（这一页不替用户一次删光）。
    public static func disconnectNote(_ builtIn: ConnectionBuiltIn, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch builtIn {
        case .computer:
            return zh
                ? "在登录设备里让电脑下线、或者解除配对，Botin 就不能再用它了。"
                : "Sign the computer out or unpair it in Devices, and Botins can no longer use it."
        case .feishu, .wecom, .dingtalk:
            return zh
                ? "在 IM 渠道里删掉这些群机器人，就不会再往群里发消息了。"
                : "Delete these group bots in IM channels and nothing more will be posted."
        case .modelKeys:
            return zh
                ? "在模型 key 里停用或删除 key。删除以前先在模型路由里给 Botin 换一把，不然它们调不了模型。"
                : "Turn off or delete keys in Model keys. Switch your Botins to another key in their model routes "
                    + "first, or they can't call a model."
        case .vault:
            return zh
                ? "在密码保险箱里删掉条目，Botin 就不能再用这些账号登录了。"
                : "Delete items in the Vault and Botins can no longer sign in with them."
        }
    }

    /// 断开连接弹窗上去管理页的按钮。
    public static func goManage(_ builtIn: ConnectionBuiltIn, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let page = builtIn.manageRoute.title(language)
        return zh ? "去\(page)" : "Open \(page)"
    }

    /// 搜不到时的说明。
    public static func noResults(_ query: String, language: DisplayLanguage = .current) -> String {
        language == .chinese ? "没有和“\(query)”有关的应用。" : "No apps match “\(query)”."
    }

    /// 目录的读屏提示：点行看详情。
    public static func rowHint(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "查看详情" : "Shows details"
    }

    /// 分组标题能点开完整列表时的读屏提示。
    public static func seeAllHint(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "查看完整列表" : "Shows the full list"
    }

    /// 设置里那一行的副标题（规范 4.9.1：“电脑、IM 渠道、模型 key”）。
    public static func settingsSubtitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "电脑、IM 渠道、模型 key 和更多应用" : "Computers, IM channels, model keys and more"
    }
}
