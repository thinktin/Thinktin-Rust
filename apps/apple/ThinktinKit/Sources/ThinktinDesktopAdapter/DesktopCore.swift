#if os(macOS) || os(Linux)
    import ThinktinCore

    /// ThinktinCore 里电脑端工具服务（`desktop`）的类型统一从这里引用（和 ThinktinCoreAdapter 的 `Core` 一样的约定：
    /// 只有这个文件 import ThinktinCore，其他文件写 `DesktopCore.X`；`CapabilityGrant` 两个模块都有）。
    /// iOS 的 ThinktinCore 里没有这些类型（`ThinktinDesktop.swift` 只在 macOS 上编），所以整个目标只在 macOS（和
    /// Linux 上 `build-linux-swift.sh --desktop` 打的包）里有内容。
    enum DesktopCore {
        typealias Service = ThinktinCore.DesktopService
        typealias Settings = ThinktinCore.DesktopSettings
        typealias Tokens = ThinktinCore.DesktopTokens
        typealias NativeTools = ThinktinCore.NativeTools
        typealias NativeToolResult = ThinktinCore.NativeToolResult
        typealias Signer = ThinktinCore.PairingSigner
        typealias Observer = ThinktinCore.DesktopObserver
        typealias FfiError = ThinktinCore.DesktopFfiError
        typealias ConnectionStatus = ThinktinCore.ConnectionStatus
        typealias PairingState = ThinktinCore.PairingState
        typealias StopReason = ThinktinCore.StopReason
        typealias PhoneInfo = ThinktinCore.PhoneInfo
        typealias Grant = ThinktinCore.CapabilityGrant
    }
#endif
