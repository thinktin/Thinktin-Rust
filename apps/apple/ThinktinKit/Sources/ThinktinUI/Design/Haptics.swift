import SwiftUI

// 触感反馈（改版规范 4.9.13、6.22）：界面里要震的地方一律用 `appFeedback(_:trigger:)`，不直接写 `.sensoryFeedback`，
// 这样设置里的“触感反馈”关掉后整个 App 都不震。开关存在 `SettingsPreferences.hapticsEnabled`，由根视图的
// `.settingsPreferences()` 放进环境。

private struct HapticsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 设置里的触感反馈开关（默认开）。
    public var hapticsEnabled: Bool {
        get { self[HapticsEnabledKey.self] }
        set { self[HapticsEnabledKey.self] = newValue }
    }
}

extension View {
    /// `trigger` 变了时给一下系统触感（`.sensoryFeedback`），设置里关了触感反馈就不给。
    func appFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(AppFeedback(feedback: feedback, trigger: trigger))
    }
}

private struct AppFeedback<T: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: T
    @Environment(\.hapticsEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let feedback: SensoryFeedback? = isEnabled ? self.feedback : nil
        content.sensoryFeedback(trigger: trigger) { _, _ in feedback }
    }
}
