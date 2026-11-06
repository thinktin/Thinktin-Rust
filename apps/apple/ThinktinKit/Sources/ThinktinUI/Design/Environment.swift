import SwiftUI
import ThinktinKit

// 界面层的环境值。

private struct DisplayLanguageKey: EnvironmentKey {
    static var defaultValue: DisplayLanguage { .current }
}

private struct BotinFaceMotionKey: EnvironmentKey {
    static var defaultValue: Bool { true }
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

    /// Botin 头像的脸动不动（`BotinFace`：在跑时眨眼、往四处看、做小动作，点了、挑了时的反应，换形状时变形）。默认动；
    /// 截图时 App 设成 false，每次截出来的都一样。系统打开“减弱动态效果”时不管这个值都不动。
    public var botinFaceMotion: Bool {
        get { self[BotinFaceMotionKey.self] }
        set { self[BotinFaceMotionKey.self] = newValue }
    }
}
