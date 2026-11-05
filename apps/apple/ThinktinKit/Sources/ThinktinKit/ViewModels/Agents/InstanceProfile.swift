import Foundation

// Botin 资料、编辑、工作区（规范 4.4.1、4.4.2、4.4.3、4.6.1，参考 09、10、12、65、28）：行上显示什么、“…”菜单里有哪些项、
// 工作区的版本操作和说明放在这里，界面（ThinktinUI 的 `InstanceDetailScreen`、`InstanceEditScreen`、
// `InstanceWorkspaceScreen`）照着画，在 Linux 上测。

// MARK: - 资料页的行

extension InstanceDetailModel {
    /// 正在生效的计划数（“计划”那一行的值“N 个生效”）：没暂停、不在等确认的。计划还没拉到时为 nil（行上不写值）。
    public var activePlanCount: Int? {
        plans.map { list in list.filter { !$0.isPaused && !$0.awaitingConfirmation }.count }
    }

    /// 在等你确认的计划数（“计划”那一行的值后面提醒）。
    public var plansAwaitingConfirmation: Int {
        plans?.filter(\.awaitingConfirmation).count ?? 0
    }
}

extension InstanceRouteStatus {
    /// 资料页“默认模型”那一行的值：main 指向的上游模型；没配（没有别名或没有 main）写“未配置”（警告色，
    /// `needsAttention`）；还没拉到为 nil（不写值）。
    public func defaultModelValue(_ language: DisplayLanguage = .current) -> String? {
        switch self {
        case .unknown: return nil
        case .notConfigured, .missingMain: return language == .chinese ? "未配置" : "Not set"
        case .configured(let main, _): return main.upstreamModel
        }
    }
}

/// 资料页上的字（行的标题和值）。
public enum InstanceProfileText {
    /// “计划”行的值：“3 个生效”；有在等确认的加一句“· 1 个待确认”。
    public static func plansValue(active: Int, awaiting: Int = 0, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        var text = zh ? "\(active) 个生效" : "\(active) active"
        if awaiting > 0 {
            text += zh ? " · \(awaiting) 个待确认" : " · \(awaiting) to confirm"
        }
        return text
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

    public static func defaultModel(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "默认模型" : "Default model"
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

    public static func delete(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "删除这个 Botin" : "Delete this Botin"
    }

    /// “信息”分组：引擎（名字 · 版本）、接入方式、创建于、最近活动。
    public static func infoSection(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "信息" : "Details"
    }

    public static func teamsSection(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "所在团队" : "Teams"
    }
}

// MARK: - 资料页右上“…”菜单（4.4.2）

/// 资料页右上“…”菜单的一项（参考 10：替换主 Bot、复制 ID；主 Botin 只记在这台设备上，`PrimaryBotinStore`，6.10）。
public enum InstanceProfileMenuItem: Hashable, Sendable {
    /// 复制 Botin 的 id（复制后有成功的触感）。
    case copyID
    /// 打开一个页面（模型路由、新建计划）。
    case open(AppRoute)
    /// 删除（先列出影响的确认页 `InstanceDeleteSheet`）。
    case delete

    public func title(_ language: DisplayLanguage) -> String {
        switch self {
        case .copyID: InstanceProfileText.copyID(language)
        case .open(.primaryBotin): ConversationText.replacePrimaryBotin(hasPrimary: true, language: language)
        case .open(let route): route.title(language)
        case .delete: InstanceProfileText.delete(language)
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .copyID: "doc.on.doc"
        case .open(let route):
            switch route {
            case .modelRoutes: "cpu"
            case .newPlan: "calendar.badge.plus"
            case .primaryBotin: "arrow.left.arrow.right"
            default: "chevron.right"
            }
        case .delete: "trash"
        }
    }

    /// 破坏性的（系统标红、放最后一组）。
    public var isDestructive: Bool { self == .delete }

    /// 要联网才能做的（离线时灰掉）：新建计划、删除。复制 id、看模型路由（有缓存）、换主 Botin（本机）离线也行。
    public var needsConnection: Bool {
        switch self {
        case .copyID: false
        case .open(let route):
            switch route {
            case .modelRoutes, .primaryBotin: false
            default: true
            }
        case .delete: true
        }
    }
}

/// 资料页“…”菜单的分组：替换主 Botin、复制 ID（参考 10）；模型路由、新建计划；最后一组删除。
public enum InstanceProfileMenu {
    public static func sections(instanceID: InstanceID) -> [[InstanceProfileMenuItem]] {
        [
            [.open(.primaryBotin), .copyID],
            [.open(.modelRoutes(instanceID)), .open(.newPlan(instanceID: instanceID))],
            [.delete],
        ]
    }
}

// MARK: - 工作区（4.6.1）

extension InstanceDetailModel {
    /// 工作区页最上面的“升级到 vX”：目录里最新的版本比现在的新（或者现在的版本下架了）时有。
    public var upgradeOption: InstanceVersionOption? {
        versionOptions.first { $0.isLatest && ($0.change == .upgrade || $0.change == .switchTo) }
    }

    /// 工作区页“换到别的版本”菜单里列的：目录里的全部版本（新的在前，现在用的打勾）；只有一个版本时为空（不出菜单）。
    public var switchableVersions: [InstanceVersionOption] {
        let options = versionOptions
        return options.count > 1 ? options : []
    }

    /// “换到别的版本”菜单里要不要补一项“现在用的（已下架）”：现在的版本不在目录里时，菜单的选中值（现在的版本）
    /// 在列出的版本里找不到，系统的 `Picker` 会报“选中值没有对应的项”、右边显示空白。
    public var needsDelistedVersionPlaceholder: Bool {
        !switchableVersions.isEmpty && !switchableVersions.contains(where: \.isCurrent)
    }
}

/// 工作区页的字。
public enum InstanceWorkspaceText {
    public static func status(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "状态" : "Status"
    }

    public static func currentVersion(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "引擎版本" : "Engine version"
    }

    /// “换到别的版本”菜单（`Picker(.menu)`）的标题。
    public static func otherVersions(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "换到别的版本" : "Switch version"
    }

    /// 版本菜单里现在用的、已经不在目录里的那个版本：“v1.9.0（已下架）”。
    public static func delistedVersion(_ version: String, language: DisplayLanguage = .current) -> String {
        let label = AgentsText.versionLabel(version)
        return language == .chinese ? "\(label)（已下架）" : "\(label) (no longer listed)"
    }

    /// 升级那一行下面的灰字。
    public static func upgradeDetail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "下次唤醒时按新版本重建，工作区里的文件都保留。"
            : "Rebuilt on the new version the next time it wakes up. Files in the workspace are kept."
    }

    /// 升级那一组的脚注（参考 65 的“你的 Bot 共用的那台电脑”那一句的位置）。
    public static func workspaceFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "这个 Botin 自己的云端沙箱，别的 Botin 用不到它的文件。"
            : "This Botin's own cloud sandbox. Other Botins can't see its files."
    }

    /// 版本那一组的脚注。
    public static func versionFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "换版本后下次唤醒沙箱时生效，工作区里的文件都保留，正在跑的任务不受影响。"
            : "A new version takes effect the next time the sandbox wakes up. Files in the workspace are kept, and "
                + "running tasks aren't affected."
    }

    /// 现在的版本不在目录里（下架了）时的提醒。
    public static func unlistedVersion(current: String, latest: String, language: DisplayLanguage = .current) -> String
    {
        let current = AgentsText.versionLabel(current)
        let latest = AgentsText.versionLabel(latest)
        return language == .chinese
            ? "现在用的 \(current) 已经不在目录里了，建议升级到 \(latest)。"
            : "\(current) is no longer listed. Upgrading to \(latest) is recommended."
    }

    /// 右上“?”和说明 sheet 的标题。
    public static func helpTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "关于工作区" : "About the workspace"
    }
}

/// 工作区说明 sheet 的一行（参考 28 的版式：图标 + 标题 + 多行灰字）。
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

/// 工作区说明 sheet 的一组。
public struct WorkspaceHelpSection: Hashable, Sendable, Identifiable {
    public var title: String
    public var items: [WorkspaceHelpItem]

    public var id: String { title }

    public init(title: String, items: [WorkspaceHelpItem]) {
        self.title = title
        self.items = items
    }
}

/// 工作区说明（右上“?”）：沙箱的几种状态（复用 `AgentsText.stateExplanation`），和换版本、工作区文件的规矩。
public enum WorkspaceHelp {
    /// 说明里讲的状态（删除了的、认不出的不讲）。
    static let states: [(InstanceState, String)] = [
        (.provisioning, "hammer"), (.running, "play.circle"), (.paused, "pause.circle"), (.archived, "archivebox"),
    ]

    /// - Parameter stateName: 状态的名字（界面传 ThinktinUI 的 `localizedName`，和状态点旁边的字一致）。
    public static func sections(
        _ language: DisplayLanguage = .current, stateName: (InstanceState) -> String
    ) -> [WorkspaceHelpSection] {
        let zh = language == .chinese
        let stateItems = states.map { state, image in
            WorkspaceHelpItem(
                systemImage: image, title: stateName(state),
                detail: AgentsText.stateExplanation(state, language: language))
        }
        let versionItems = [
            WorkspaceHelpItem(
                systemImage: "arrow.up.circle", title: zh ? "升级" : "Upgrade",
                detail: zh
                    ? "目录里有新版本时，工作区页最上面会出现“升级到”。升级后下次唤醒时生效。"
                    : "When a newer version is listed, “Upgrade to” appears at the top of the workspace page. "
                        + "It takes effect the next time the sandbox wakes up."),
            WorkspaceHelpItem(
                systemImage: "arrow.uturn.backward.circle", title: zh ? "换回旧版本" : "Roll back",
                detail: zh
                    ? "在“换到别的版本”里选一个旧版本，同样下次唤醒时生效。"
                    : "Pick an older version under “Switch version”. It also takes effect on the next wake-up."),
            WorkspaceHelpItem(
                systemImage: "folder", title: zh ? "工作区里的文件" : "Files in the workspace",
                detail: zh
                    ? "休眠、唤醒、换版本都不会动工作区里的文件；删除 Botin 时才一起删掉。"
                    : "Sleeping, waking and switching versions leave the files alone. They're only removed when you "
                        + "delete the Botin."),
        ]
        return [
            WorkspaceHelpSection(title: zh ? "状态" : "Status", items: stateItems),
            WorkspaceHelpSection(title: zh ? "版本" : "Versions", items: versionItems),
        ]
    }
}
