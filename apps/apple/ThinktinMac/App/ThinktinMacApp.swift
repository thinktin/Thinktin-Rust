import AppKit
import SwiftUI
import ThinktinKit
import ThinktinUI

/// macOS App 入口（WBS 14.5）：菜单栏常驻（Info.plist 的 `LSUIElement`，没有程序坞图标），点开是“手机控制”面板
/// （`MenuBarContent`）；对话、计划这些和 iPhone 一样的界面在主窗口里（`RootView`，ThinktinUI 复用）。
///
/// 菜单栏放在第一个场景：主窗口不是第一个场景，启动时不自己打开（开机由登录项拉起时不弹窗口），要打开时
/// 由菜单栏图标调 `openWindow`（`MacEnvironment.requestMainWindow()`）。深链（`thinktin://…`）在 App 代理里交给
/// `Router`，再打开主窗口。
@main
struct ThinktinMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    var body: some Scene {
        let environment = delegate.environment
        MenuBarExtra {
            MenuBarContent(environment: environment)
                .settingsPreferences()
        } label: {
            MenuBarIcon(environment: environment)
        }
        .menuBarExtraStyle(.window)
        Window("ThinkTin", id: MacEnvironment.mainWindowID) {
            RootView(model: environment.appModel)
                .settingsPreferences()
                .frame(minWidth: 420, minHeight: 560)
        }
        .defaultSize(width: 960, height: 720)
    }
}
