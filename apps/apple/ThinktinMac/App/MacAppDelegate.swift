import AppKit
import Foundation

/// App 代理（WBS 14.5、14.6）：启动完开始跟着登录状态建工具服务；关掉主窗口不退出（菜单栏常驻）；
/// 在访达里再打开一次 App、点了深链（`thinktin://…`，交给 `Router`）时打开主窗口。
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var environment: MacEnvironment { .shared }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.start()
    }

    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { environment.requestMainWindow() }
        return true
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = environment.appModel.router.handle(url: url) }
        environment.requestMainWindow()
    }
}
