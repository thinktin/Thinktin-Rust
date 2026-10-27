import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import ServiceManagement

/// 系统权限和登录项（WBS 14.6、14.7）：截图要“屏幕录制”，点击、打字、按键要“辅助功能”；开机自动打开是登录项
/// （`SMAppService.mainApp`）。系统不发权限变化的通知，菜单栏面板开着时定时查（`refresh()`）。
///
/// 工具服务连上中继时把现在能用的工具报给平台（`MacNativeTools.available()`），所以打开权限后要停止再开始一次
/// 手机控制，新工具才报上去；屏幕录制还要重新打开 App 才生效（系统的规定）。
@Observable @MainActor
final class MacPermissions {
    private(set) var screenRecording = MacPermissions.hasScreenRecording
    private(set) var accessibility = MacPermissions.hasAccessibility
    private(set) var loginItem: SMAppService.Status = SMAppService.mainApp.status
    /// 改登录项失败的原因（没签名的开发版、被管理员禁了）。
    var loginItemError: String?

    /// 这两个查询线程安全，工具服务在自己的线程上也会调。
    nonisolated static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    nonisolated static var hasAccessibility: Bool { AXIsProcessTrusted() }

    func refresh() {
        screenRecording = Self.hasScreenRecording
        accessibility = Self.hasAccessibility
        loginItem = SMAppService.mainApp.status
    }

    /// 请求屏幕录制权限：第一次会弹系统的提示，之后只能去系统设置里开。
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings(Self.screenRecordingSettings) }
        refresh()
    }

    /// 请求辅助功能权限：弹系统的提示，带“打开系统设置”。
    func requestAccessibility() {
        // 键是 `kAXTrustedCheckOptionPrompt` 的值；直接写字符串，不碰那个全局变量（Swift 6 的并发检查不让）。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings(Self.accessibilitySettings) }
        refresh()
    }

    var opensAtLogin: Bool { loginItem == .enabled }

    /// 开机自动打开（只有菜单栏图标，不弹窗口）。要用户在系统设置里批准时状态是 `requiresApproval`。
    func setOpensAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        refresh()
        if loginItem == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 系统设置里“隐私与安全性”的两页。
    static let screenRecordingSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private func openSettings(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }
}
