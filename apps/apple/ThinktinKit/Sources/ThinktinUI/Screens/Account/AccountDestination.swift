import SwiftUI
import ThinktinKit

/// 注册登录与设备管理（WBS 12.2）的接入点：`AppShell` 把 `route.feature == .account` 的页面都交给它。
///
/// - `.signIn`：没登录时 `AppShell` 整页显示（不经过 `AppDestination`，没有全局横幅）。欢迎页 → 手机号 → 验证码
///   （`SignInFlow`）；登录成功后 `AppModel` 自己切到主界面，新用户再弹出引导（12.17）。
/// - `.account`：账号页（`AccountScreen`）：昵称、手机号、登录设备、全部停止、退出登录、注销账号。设置中心（12.12）进这里。
/// - `.devices`：登录设备（`DevicesScreen`）：单台下线、下线其他设备（可以同时全部停止）。
/// - `.pairComputer(code)`：系统相机扫了电脑上的配对二维码（`thinktin-pair:` 深链），弹出配对（`PairComputerSheet`）。
///
/// 只在本功能里用的子页面（改昵称、注销、选区号、下线其他设备）不加 `AppRoute`，在这个目录里用 `NavigationLink` 或
/// 本地 sheet 打开（docs/ios.md 9.1）。视图模型在 `ThinktinKit/ViewModels/Account/`。这些页面没有 agent 写的文字，
/// 按 AI 生成标识的规则表（ios-packages.md 12.5）都不用标。
struct AccountDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .signIn: SignInFlow()
        case .account: AccountScreen()
        case .devices: DevicesScreen()
        case .pairComputer(let code): PairComputerRoute(code: code)
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("登录 · 浅色中文") {
    AccountDestination(route: .signIn).previewShell(client: AccountPreviewClients.signedOut())
}

#Preview("登录设备 · 深色英文") {
    AccountDestination(route: .devices).previewShell(.english, scheme: .dark)
}
