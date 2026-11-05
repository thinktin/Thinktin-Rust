import Foundation

/// 页面里本地打开、没有 `AppRoute` 的子页和状态（编辑 Botin、头像、工作区、引擎详情 sheet、保险箱的新建表单、设备详情、
/// 外观……）。按 `AppRoute` 的规矩它们只在一个功能里用，不加路由（docs/ios.md 第 9 节）；要直接打开它们时（截图脚本的
/// `THINKTIN_OPEN_SCREEN`，见 App 的 `OpenScreen.swift`）先 `Router.show` 父页面，再 `Router.requestSubpages(_:)`
/// 记下要依次打开的子页。父页面出现、要用的数据拿到之后，ThinktinUI 的 `onSubpageRequest` 取走排在最前面、是自己的那一项
/// （`Router.takeSubpage`）并打开它；子页出现后再取下一项（资料 → 编辑 → 头像）。
public enum Subpage: Hashable, Sendable {
    /// 对话页的查找栏（规范 4.3.3，参考 04）：和参考一样不聚焦、不弹键盘。
    case conversationFind
    /// Botin 资料 → 编辑 Botin（规范 4.4.3，参考 12；语音、速度、语言三行在这一页上）。
    case botinEdit
    /// 编辑 Botin → 头像（规范 4.4.4，参考 18）。
    case botinAvatar
    /// Botin 资料 → 工作区（规范 4.6.1，参考 65）。
    case workspace
    /// 引擎目录 → 第一个引擎的详情 sheet（规范 4.7.1 的“了解引擎”，和参考 38 的插件详情一样是 medium / large 两档）。
    case engineDetail
    /// 产出物库选中“媒体”（规范 4.5.2，参考 23、83）。
    case artifactsMedia
    /// 保险箱右上“+” → 新建登录信息、卡片、联系信息（规范 4.9.6、4.9.7，参考 59、60、61）。
    case newVaultItem(VaultItemKind)
    /// 权限与规则 → 新建一条“始终询问”的规则（规范 4.9.8，参考 63）。
    case newPermissionRule
    /// 登录设备 → 这台设备的详情（规范 4.9.9，参考 67）。
    case currentDevice
    /// 登录设备 → 第一台电脑的详情（规范 4.9.9，参考 69）。
    case computerDevice
    /// 设置 → 外观（规范 4.9.11，参考 72）。
    case appearanceSettings
    /// 设置 → 语言（规范 4.9.12，参考 73）。
    case languageSettings
    /// 设置 → 触感反馈（规范 4.9.13，参考 74）。
    case hapticsSettings
    /// 连接的列表 → 一个应用的详情 sheet（规范 4.8.3，参考 38、52）。
    case connectionDetail(ConnectionID)

    /// 页面出现、压栈或弹出的动画走完之后再打开子页：转场里改导航状态，系统可能不理。
    public static let settleDelay: Duration = .milliseconds(600)

    /// 新建保险箱条目时是哪一种；别的子页为 nil。
    public var newVaultItemKind: VaultItemKind? {
        if case .newVaultItem(let kind) = self { return kind }
        return nil
    }

    /// 应用详情时是哪个应用；别的子页为 nil。
    public var connectionID: ConnectionID? {
        if case .connectionDetail(let id) = self { return id }
        return nil
    }
}
