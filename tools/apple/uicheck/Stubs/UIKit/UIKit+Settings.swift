// WBS 12.12（设置中心的“通知”跳到系统设置）用到的 UIKit 类型的桩：签名照 Apple 文档（iOS 17 SDK）。
// SDK 里 UIApplication 是 UIResponder 的子类、整个类在主线程上（@MainActor）；这里只放用到的两个常量，
// 也标成 @MainActor（只能在主线程上取），和真实 SDK 一样严格。

@MainActor
open class UIApplication {
    /// 系统设置里这个 App 的那一页（iOS 8）。
    public static let openSettingsURLString: String = "app-settings:"
    /// 系统设置里这个 App 的通知设置（iOS 16）。
    public static let openNotificationSettingsURLString: String = "app-settings:notifications"
}
