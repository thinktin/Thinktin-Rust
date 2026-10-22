import Foundation

/// 功能（一个工作包的界面），对应 ThinktinUI 里 `Screens/<directory>/` 一个目录（docs/ios.md 第 9 节）。
///
/// 每个功能有一个接入点 `Screens/<directory>/<directory>Destination.swift`：`struct XxxDestination: View { let route: AppRoute }`，
/// `AppShell` 按 `AppRoute.feature` 把页面分派给它。做这个功能的人只改自己目录里的文件，不碰 `Shell/`。
public enum AppFeature: String, CaseIterable, Hashable, Sendable {
    /// 登录、设备、账号（12.2）。
    case account
    /// agent 目录、领养、实例详情（12.3）。
    case agents
    /// 模型 key、模型路由、用量（12.4）。
    case models
    /// 实例对话、运行详情、运行树、进行中（12.5）。
    case conversation
    /// 计划（12.6）。
    case plans
    /// 团队、团队模板、流水线编辑器（12.7）。
    case teams
    /// 收件箱（12.8）。
    case inbox
    /// 设置中心、开源许可、关于（12.12）。
    case settings
    /// 密码保险箱（12.13）。
    case vault
    /// IM 渠道（12.14）。
    case imChannels
    /// 审批中心与审批卡（12.15）。
    case approvals
    /// 首次启动与引导（12.17）。
    case onboarding
    /// 产出物（12.18）。
    case artifacts
    /// 搜索（12.21）。
    case search
    /// 应用框架自己的页面：新任务、冻结页、升级页（12.16，在 `Shell/` 里，不在 `Screens/`）。
    case shell

    /// 负责的工作包（WBS 编号）。
    public var workPackage: String {
        switch self {
        case .account: "12.2"
        case .agents: "12.3"
        case .models: "12.4"
        case .conversation: "12.5"
        case .plans: "12.6"
        case .teams: "12.7"
        case .inbox: "12.8"
        case .settings: "12.12"
        case .vault: "12.13"
        case .imChannels: "12.14"
        case .approvals: "12.15"
        case .onboarding: "12.17"
        case .artifacts: "12.18"
        case .search: "12.21"
        case .shell: "12.16"
        }
    }

    /// ThinktinUI 里的目录名：`Screens/<directory>/`（`shell` 是 `Shell/`）；视图模型在 `ViewModels/<directory>/`，
    /// 测试在 `Tests/ThinktinKitTests/<directory>/`、`Tests/ThinktinUITests/<directory>/`。
    public var directory: String {
        switch self {
        case .imChannels: "ImChannels"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// 接入点的类型名（`AccountDestination`）；`shell` 是 `ShellDestination`。
    public var destinationTypeName: String { directory + "Destination" }
}
