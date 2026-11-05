import Foundation

// 第 2 轮·对话页的附加功能（对话内查找的高亮和读屏播报，规范 4.3.3）用到的 API，签名照 iOS 17 / macOS 14 SDK。
// 加之前 grep 过整个 Stubs/，没有重复声明。

// MARK: - AttributedString 的 SwiftUI 属性（iOS 15）

// Linux 的 Foundation 有 AttributedString，但没有 SwiftUI 的属性域：照 SDK 补 `backgroundColor`、`foregroundColor` 两个
// （`attributed[range].backgroundColor = …` 靠 `AttributeDynamicLookup` 的这个下标）。
extension AttributeScopes {
    public var swiftUI: SwiftUIAttributes.Type { SwiftUIAttributes.self }

    public struct SwiftUIAttributes: AttributeScope {
        public let foregroundColor: ForegroundColorAttribute
        public let backgroundColor: BackgroundColorAttribute
        public let foundation: FoundationAttributes

        public enum ForegroundColorAttribute: AttributedStringKey {
            public typealias Value = Color
            public static let name = "SwiftUI.ForegroundColor"
        }

        public enum BackgroundColorAttribute: AttributedStringKey {
            public typealias Value = Color
            public static let name = "SwiftUI.BackgroundColor"
        }
    }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwiftUIAttributes, T>) -> T {
        self[T.self]
    }
}

// MARK: - 读屏播报（Accessibility 框架，iOS 17 / macOS 14）

// SDK 里在 Accessibility 模块（界面代码 `#if canImport(Accessibility)` 再 import）；桩里没有那个模块，放在 SwiftUI 里。
public enum AccessibilityNotification {
    public struct Announcement {
        public init(_ announcement: String) {}
        public init(_ attributedAnnouncement: AttributedString) {}
        public func post() {}
    }
}

// MARK: - 输入框“+”菜单（规范 4.3.6）

extension View {
    /// iOS 15 / macOS 12：菜单按钮旁边的小箭头（Mac 默认有）。
    public func menuIndicator(_ visibility: Visibility) -> some View { _m() }
}

// MARK: - 长按消息弹面板（规范 4.3.4）

extension View {
    /// iOS 16 / macOS 13 的写法（带 `onPressingChanged`）；iOS 13 起的 `perform:` 也是它。
    public func onLongPressGesture(
        minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10, perform action: @escaping () -> Void,
        onPressingChanged: ((Bool) -> Void)? = nil
    ) -> some View { _m() }
}
