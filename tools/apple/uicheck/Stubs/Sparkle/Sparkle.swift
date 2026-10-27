// macOS App 自动更新（14.9）的桩：签名照 Sparkle 2.6 的头文件，只放用到的。
@_exported import Foundation

public protocol SPUUpdaterDelegate: AnyObject {}
public protocol SPUStandardUserDriverDelegate: AnyObject {}

open class SPUStandardUpdaterController {
    public init(
        startingUpdater: Bool, updaterDelegate: (any SPUUpdaterDelegate)?,
        userDriverDelegate: (any SPUStandardUserDriverDelegate)?
    ) {}
    open func checkForUpdates(_ sender: Any?) {}
}
