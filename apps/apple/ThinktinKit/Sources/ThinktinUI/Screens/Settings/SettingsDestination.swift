import SwiftUI
import ThinktinKit

/// 设置、多语言与开源许可（WBS 12.12）的接入点：`AppShell` 把 `route.feature == .settings` 的页面都交给它。
///
/// - `.settings`：设置中心（`SettingsScreen`），sheet（入口是首页左上的头像，过渡期是抽屉底部的头像），里面的子页压进
///   sheet 自己的导航栈（`Router.sheetPath`），左上的 × 由应用框架加。账号、登录设备用 12.2 的页面；用量、保险箱、连接
///   跳各自功能的 `AppRoute`；外观、语言、触感反馈是本目录里的子页面（不加 `AppRoute`）。
/// - `.about`：关于（`AboutScreen`）：版本号、构建号、备案号、条款、AI 生成内容说明。
/// - `.licenses`：开源许可（`LicensesScreen`）：agent 的许可证、Swift 依赖、客户端核心的第三方组件（按许可证分组、可搜、
///   点进去看原文）。
///
/// - `.permissions`：权限与规则（`PermissionsScreen`，参考 62–64、100）；`.subscription`：订阅（`SubscriptionScreen`，参考 56）；
///   `.importMemory`：导入记忆（`ImportMemoryScreen`，参考 71）；`.feedback`：发送反馈（`FeedbackScreen`，参考 76、77）。
///   这四页还没有后端：数据是本机的演示数据，要服务端的操作弹“即将推出”，反馈用邮件发。
///
/// 这几页都不用联网（`OfflinePolicy.local`）。视图模型在 `ThinktinKit/ViewModels/Settings/`。外观、语言要在 App 的根视图上
/// `.settingsPreferences()` 才生效（应用框架接上，见 `SettingsEnvironment.swift`）。页面上没有 agent 写的文字，按 AI 生成
/// 标识的规则表（ios-packages.md 12.5）都不用标；关于页的 AI 生成内容说明里放了标识的样子。
struct SettingsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .settings: SettingsScreen()
        case .about: AboutScreen()
        case .licenses: LicensesScreen()
        case .permissions: PermissionsScreen()
        case .subscription: SubscriptionScreen()
        case .importMemory: ImportMemoryScreen()
        case .feedback: FeedbackScreen()
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("设置 · 浅色中文") {
    SettingsDestination(route: .settings)
        .settingsPreviewEnvironment()
        .previewShell()
}

#Preview("设置 · 深色英文") {
    SettingsDestination(route: .settings)
        .settingsPreviewEnvironment(notifications: .notDetermined)
        .previewShell(.english, scheme: .dark)
}

#Preview("关于 · 深色英文") {
    SettingsDestination(route: .about).previewShell(.english, scheme: .dark)
}

#Preview("开源许可 · 浅色中文") {
    SettingsDestination(route: .licenses).previewShell()
}
