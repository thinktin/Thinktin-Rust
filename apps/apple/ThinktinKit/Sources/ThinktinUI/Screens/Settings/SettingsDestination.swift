import SwiftUI
import ThinktinKit

/// 设置、多语言与开源许可（WBS 12.12）的接入点：`AppShell` 把 `route.feature == .settings` 的页面都交给它。
///
/// - `.settings`：设置中心（`SettingsScreen`），入口是抽屉底部的头像。账号、设备、注销、全部停止、下线其他设备用 12.2 的
///   页面和组件；模型 key 与用量、保险箱、IM 渠道跳各自功能的 `AppRoute`；外观、语言是本目录里的子页面（不加 `AppRoute`）。
/// - `.about`：关于（`AboutScreen`）：版本号、构建号、备案号、条款、AI 生成内容说明。
/// - `.licenses`：开源许可（`LicensesScreen`）：agent 的许可证、Swift 依赖、客户端核心的第三方组件（按许可证分组、可搜、
///   点进去看原文）。
///
/// 这三页都不用联网（`OfflinePolicy.local`）。视图模型在 `ThinktinKit/ViewModels/Settings/`。外观、语言要在 App 的根视图上
/// `.settingsPreferences()` 才生效（应用框架接上，见 `SettingsEnvironment.swift`）。页面上没有 agent 写的文字，按 AI 生成
/// 标识的规则表（ios-packages.md 12.5）都不用标；关于页的 AI 生成内容说明里放了标识的样子。
struct SettingsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .settings: SettingsScreen()
        case .about: AboutScreen()
        case .licenses: LicensesScreen()
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
