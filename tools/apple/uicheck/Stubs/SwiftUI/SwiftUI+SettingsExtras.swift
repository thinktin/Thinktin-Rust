// 设置的补充页（改版第 2 轮 r2/settings：权限与规则、订阅、导入记忆、发送反馈、保险箱的卡片和联系信息）用到的 SwiftUI 接口。
// 签名照 iOS 17 / macOS 14 SDK。

extension Font {
    /// iOS 13、macOS 11。
    public static let callout = Font(tag: 17)
}

extension OpenURLAction {
    /// iOS 14、macOS 11：`accepted` 是系统有没有打开它（比如没有处理 `mailto:` 的 App 时为 false）。
    public func callAsFunction(_ url: URL, completion: @escaping (_ accepted: Bool) -> Void) {}
}
