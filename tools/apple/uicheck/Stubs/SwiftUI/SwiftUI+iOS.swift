// 只有 iOS 有的 SwiftUI 接口（UIKit 版的桩里才有，和真实 SDK 一样 macOS 上没有）。prep.py 把 ThinktinUI 里的
// `#if os(iOS)` 换成了 `#if canImport(UIKit)`，这些分支在 UIKit 版里会被类型检查。

#if canImport(UIKit)
    public struct NavigationBarItem: Sendable {
        public enum TitleDisplayMode: Hashable, Sendable {
            case automatic, inline, large
        }
    }
#endif
