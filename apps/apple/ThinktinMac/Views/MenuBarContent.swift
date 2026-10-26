import AppKit
import SwiftUI
import ThinktinKit
import ThinktinUI

/// 菜单栏图标（WBS 14.6 的“正在被控制”提示）：配好了手机、连着中继时换成“电脑和手机”，手机随时能让 agent 用这台电脑；
/// agent 正在执行工具时换成“移动的指针”。它一直在，所以由它接打开主窗口的请求（`MacEnvironment.mainWindowRequests`）。
struct MenuBarIcon: View {
    let environment: MacEnvironment

    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let model = environment.host.model
        let controllable = model?.isControllable == true
        let inUse = model?.activeTool != nil
        Image(systemName: inUse ? "cursorarrow.motionlines" : controllable ? "macbook.and.iphone" : "macbook")
            .accessibilityLabel(
                Text(MacText.menuBarLabel(controllable: controllable, inUse: inUse, language: language))
            )
            .onChange(of: environment.mainWindowRequests, initial: true) {
                guard environment.mainWindowRequests > 0 else { return }
                openWindow(id: MacEnvironment.mainWindowID)
                NSApp.activate()
            }
    }
}

/// 菜单栏点开的面板：手机控制（ThinktinUI 的 `ComputerHostPanel`）、系统权限和开机自动打开、打开主窗口、检查更新、退出。
struct MenuBarContent: View {
    let environment: MacEnvironment

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: 0) {
            if let model = environment.host.model {
                ComputerHostPanel(model: model)
            } else {
                Text(MacText.hostUnavailable(phase: environment.appModel.phase, language: language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Metrics.Spacing.m)
            }
            if let error = environment.host.error {
                Text(ComputerHostText.error(error, language: language))
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom], Metrics.Spacing.m)
            }
            Divider()
            MacPermissionsSection(permissions: environment.permissions)
                .padding(Metrics.Spacing.m)
            Divider()
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                Button(zh ? "打开 ThinkTin" : "Open ThinkTin") { environment.requestMainWindow() }
                if environment.updater.isAvailable {
                    Button(zh ? "检查更新…" : "Check for Updates…") { environment.updater.checkForUpdates() }
                }
                Button(zh ? "退出 ThinkTin" : "Quit ThinkTin") { NSApp.terminate(nil) }
            }
            .typography(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .padding(Metrics.Spacing.m)
        }
        .frame(width: 340, alignment: .leading)
        .background(Theme.paper)
        .environment(\.pairingCodeImage, PairingQRCode.environmentValue)
        .task {
            // 面板开着时每两秒查一次：系统不发权限变化的通知，手机发来、吊销授权时服务也不发事件。
            while !Task.isCancelled {
                environment.permissions.refresh()
                environment.host.model?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// 系统权限引导（WBS 14.7）和开机自动打开（14.6）。
struct MacPermissionsSection: View {
    let permissions: MacPermissions

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            Text(zh ? "系统权限" : "Permissions")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            permissionRow(
                title: zh ? "屏幕录制" : "Screen Recording",
                detail: zh
                    ? "agent 截图看屏幕要用。打开后重新打开 ThinkTin。"
                    : "Lets agents take screenshots. Reopen ThinkTin after turning it on.",
                granted: permissions.screenRecording
            ) {
                permissions.requestScreenRecording()
            }
            permissionRow(
                title: zh ? "辅助功能" : "Accessibility",
                detail: zh ? "agent 点击、打字、按键要用。" : "Lets agents click, type and press keys.",
                granted: permissions.accessibility
            ) {
                permissions.requestAccessibility()
            }
            if !permissions.screenRecording || !permissions.accessibility {
                Text(MacText.restartHint(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(
                zh ? "开机时自动打开" : "Open at login",
                isOn: Binding(get: { permissions.opensAtLogin }, set: { permissions.setOpensAtLogin($0) })
            )
            .typography(.subheadline)
            if permissions.loginItem == .requiresApproval {
                Button(zh ? "要在系统设置里允许：去打开" : "Allow it in System Settings") {
                    permissions.openLoginItemSettings()
                }
                .typography(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(StatusTone.waiting.color)
            }
            if let error = permissions.loginItemError {
                Text(error)
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(
        title: String, detail: String, granted: Bool, request: @escaping @MainActor () -> Void
    ) -> some View {
        let zh = language == .chinese
        return HStack(alignment: .top, spacing: Metrics.Spacing.s) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? StatusTone.success.color : StatusTone.waiting.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(title)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if granted {
                Text(zh ? "已打开" : "On")
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
            } else {
                PillButton(zh ? "去打开" : "Turn on", kind: .secondary, size: .compact, action: request)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 菜单栏的文案。
enum MacText {
    static func menuBarLabel(controllable: Bool, inUse: Bool, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        if inUse { return zh ? "ThinkTin：agent 正在使用这台电脑" : "ThinkTin: an agent is using this Mac" }
        if controllable { return zh ? "ThinkTin：手机可以控制这台电脑" : "ThinkTin: your phone can control this Mac" }
        return "ThinkTin"
    }

    static func hostUnavailable(phase: AppModel.Phase, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch phase {
        case .signedIn:
            return zh ? "正在准备手机控制……" : "Getting phone control ready…"
        case .signedOut:
            return zh
                ? "登录后，手机就能让 agent 使用这台电脑。点“打开 ThinkTin”登录。"
                : "Sign in to let your phone give agents access to this Mac. Click Open ThinkTin to sign in."
        case .frozen:
            return zh ? "账号已冻结，手机控制停了。" : "Your account is frozen, so phone control is off."
        case .upgradeRequired:
            return zh ? "这个版本太旧了，更新 ThinkTin 后才能用。" : "This version is too old. Update ThinkTin to continue."
        }
    }

    static func restartHint(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "打开权限后，在上面停止再开始一次手机控制，agent 才用得上。"
            : "After turning a permission on, stop and start phone control above so agents can use it."
    }
}
