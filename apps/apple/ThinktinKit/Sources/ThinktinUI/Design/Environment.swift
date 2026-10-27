import SwiftUI
import ThinktinKit

// 界面层的环境值。

private struct DisplayLanguageKey: EnvironmentKey {
    static var defaultValue: DisplayLanguage { .current }
}

extension EnvironmentValues {
    /// 界面文案的语言。默认跟系统（`DisplayLanguage.current`）；预览、测试里用
    /// `.environment(\.displayLanguage, .english)` 固定成某一种。
    ///
    /// 组件的文案（状态名、错误提示、“AI 生成”）和 ThinktinKit 的 `ClientError.localizedMessage(_:)`、
    /// `DisplayLanguage.aiGeneratedLabel` 一样按它取中文或英文。
    public var displayLanguage: DisplayLanguage {
        get { self[DisplayLanguageKey.self] }
        set { self[DisplayLanguageKey.self] = newValue }
    }
}
