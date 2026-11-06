import Foundation

// Botin 资料、编辑、工作区（规范 4.4.1、4.4.2、4.4.3、4.6.1，参考 09、10、12、65）：行上显示什么、“…”菜单里有哪些项、
// 工作区页的字放在这里，界面（ThinktinUI 的 `InstanceDetailScreen`、`InstanceEditScreen`、`InstanceWorkspaceScreen`）
// 照着画，在 Linux 上测。

// MARK: - 资料页的行

extension InstanceDetailModel {
    /// 正在生效的计划数（“计划”那一行的值“N 个生效”）：没暂停、不在等确认的。计划还没拉到时为 nil（行上不写值）。
    public var activePlanCount: Int? {
        plans.map { list in list.filter { !$0.isPaused && !$0.awaitingConfirmation }.count }
    }
}

/// 资料页上的字（行的标题和值）。
public enum InstanceProfileText {
    /// “计划”行的值：“3 个生效”（参考 09 的“0 已开启”，只有数）。以前后面加的“· N 个待确认”2026-11-06 照参考去掉了。
    public static func plansValue(active: Int, language: DisplayLanguage = .current) -> String {
        language == .chinese ? "\(active) 个生效" : "\(active) active"
    }

    public static func plans(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "计划" : "Plans"
    }

    public static func artifacts(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "产出物" : "Artifacts"
    }

    /// “工作区”行和工作区页的标题（Botin 的云端沙箱）。
    public static func workspace(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "工作区" : "Workspace"
    }

    /// 头部名字下面的小胶囊、编辑页的标题。
    public static func edit(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "编辑" : "Edit"
    }

    public static func editTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "编辑 Botin" : "Edit Botin"
    }

    /// 编辑页“名称”分组、“外观”分组和里面的“头像”行。
    public static func nameSection(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "名称" : "Name"
    }

    public static func appearanceSection(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "外观" : "Appearance"
    }

    public static func avatar(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "头像" : "Avatar"
    }

    /// 头像页卡片最下面的按钮。
    public static func resetAvatar(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "重置为默认" : "Reset to default"
    }

    /// 头像页的脚注：只存在这台设备上（服务端还没有头像字段，规范 6.9）。
    public static func avatarFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "头像只保存在这台设备上，默认是圆形、按名字取色。"
            : "The avatar is saved on this device only. By default it's a circle coloured by the name."
    }

    public static func copyID(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "复制 Botin ID" : "Copy Botin ID"
    }

    /// 第二组“通知”开关（参考 09 的位置）。按 Botin 开关推送要后端（规范 6.14 A），现在开关跟着系统的通知权限、不能拨。
    public static func notifications(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "通知" : "Notifications"
    }

    /// “通知”那一组的脚注：发什么通知，现在跟着系统设置，按 Botin 开关即将推出。
    public static func notificationsFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "做完任务、需要你处理时发通知。现在跟着系统的通知设置，按 Botin 单独开关即将推出。"
            : "Get notified when it finishes a task or needs you. This follows your system notification settings "
                + "for now; a switch for each Botin is coming soon."
    }
}

// MARK: - 资料页右上“…”菜单（4.4.2）

/// 资料页右上“…”菜单的一项（参考 10：替换主 Bot、复制 ID；主 Botin 只记在这台设备上，`PrimaryBotinStore`，6.10）。
/// 都是本机的操作，离线也能用。
public enum InstanceProfileMenuItem: Hashable, Sendable {
    /// 复制 Botin 的 id（复制后有成功的触感）。
    case copyID
    /// 打开一个页面（替换主 Botin…：选择主 Botin 的 sheet）。
    case open(AppRoute)

    public func title(_ language: DisplayLanguage) -> String {
        switch self {
        case .copyID: InstanceProfileText.copyID(language)
        case .open(.primaryBotin): ConversationText.replacePrimaryBotin(hasPrimary: true, language: language)
        case .open(let route): route.title(language)
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .copyID: "doc.on.doc"
        case .open(.primaryBotin): "arrow.left.arrow.right"
        case .open: "chevron.right"
        }
    }
}

/// 资料页“…”菜单：一组两项，替换主 Botin…、复制 ID（参考 10）。以前 ThinkTin 自己加的模型路由、新建计划和最后一组的
/// “删除这个 Botin”2026-11-06 照参考去掉了（用户要求删掉、参考里没有；删除 Botin 现在没有入口，规范 1.5）。
public enum InstanceProfileMenu {
    public static func sections(instanceID: InstanceID) -> [[InstanceProfileMenuItem]] {
        [[.open(.primaryBotin), .copyID]]
    }
}

// MARK: - 工作区（4.6.1）

/// 工作区页的字（参考 65 的两组：重置、磁盘空间）。
public enum InstanceWorkspaceText {
    /// 重置那一组的脚注（参考 65 的“你的 Bot 共用的那台电脑”那一句的位置）。
    public static func workspaceFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "这个 Botin 自己的云端沙箱，别的 Botin 用不到它的文件。"
            : "This Botin's own cloud sandbox. Other Botins can't see its files."
    }

    /// “重置工作区”那一行（参考 65“重置电脑”的位置：红字 + 一行灰字，没有箭头）。要后端（规范 6.17），点了说即将推出。
    public static func reset(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "重置工作区" : "Reset workspace"
    }

    /// 重置那一行下面的灰字。
    public static func resetDetail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "回到最近一次快照，之后改过的文件会丢。"
            : "Roll back to the last snapshot. Files changed since then are lost."
    }

    /// “磁盘空间”那一行（参考 65）。还没有接口（6.17），值写“即将推出”，不编一个“正常”。
    public static func diskSpace(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "磁盘空间" : "Disk space"
    }

    /// 重置、磁盘空间还没有接口时的值和提示框的标题。
    public static func comingSoon(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出" : "Coming soon"
    }

    /// 点“重置工作区”弹的提示框里的话。
    public static func resetComingSoonMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "从快照重置工作区还在做，现在的文件不受影响。"
            : "Resetting the workspace from a snapshot isn't ready yet. Your files are unchanged."
    }

    /// 提示框的按钮。
    public static func ok(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "好" : "OK"
    }
}

/// 说明 sheet 的一行（参考 28 的版式：图标 + 标题 + 多行灰字；观看与接管的使用说明 `InstanceScreenHelp` 用）。
public struct WorkspaceHelpItem: Hashable, Sendable, Identifiable {
    public var systemImage: String
    public var title: String
    public var detail: String

    public var id: String { title }

    public init(systemImage: String, title: String, detail: String) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
    }
}

/// 说明 sheet 的一组。
public struct WorkspaceHelpSection: Hashable, Sendable, Identifiable {
    public var title: String
    public var items: [WorkspaceHelpItem]

    public var id: String { title }

    public init(title: String, items: [WorkspaceHelpItem]) {
        self.title = title
        self.items = items
    }
}
