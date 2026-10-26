// macOS App（14.5–14.7）用到的 AppKit 类型的桩：签名照 macOS 14 SDK，只放用到的。
// SDK 里 NSApplicationDelegate 继承 NSObjectProtocol、整个协议在主线程上，方法都是可选的。NSWorkspace、NSRunningApplication
// 不在主线程上（这里也不加 @MainActor、不标 Sendable，比 SDK 严）。

@MainActor
open class NSApplication {
    public init() {}
    open class var shared: NSApplication { NSApplication() }
    open func activate() {}
    open func terminate(_ sender: Any?) {}
}

@MainActor public var NSApp: NSApplication! { NSApplication.shared }

@MainActor
public protocol NSApplicationDelegate: AnyObject {
    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
    func application(_ application: NSApplication, open urls: [URL])
}

extension NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {}
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    public func application(_ application: NSApplication, open urls: [URL]) {}
}

open class NSRunningApplication: NSObject {
    open var bundleIdentifier: String? { nil }
    open var processIdentifier: pid_t { 0 }
}

open class NSWorkspace: NSObject {
    open class var shared: NSWorkspace { NSWorkspace() }
    open var frontmostApplication: NSRunningApplication? { nil }
    open var notificationCenter: NotificationCenter { NotificationCenter() }
    open func open(_ url: URL) -> Bool { true }
    open func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? { nil }
    open func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration) async throws
        -> NSRunningApplication
    { NSRunningApplication() }

    open class OpenConfiguration: NSObject {
        open var activates: Bool = true
    }

    public static let didActivateApplicationNotification = NSNotification.Name(
        "NSWorkspaceDidActivateApplicationNotification")
    public static let applicationUserInfoKey = "NSWorkspaceApplicationKey"
}

open class NSImageRep: NSObject {}

open class NSBitmapImageRep: NSImageRep {
    public enum FileType: UInt, Sendable {
        case tiff, bmp, gif, jpeg, png, jpeg2000
    }

    public struct PropertyKey: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let compressionFactor = PropertyKey(rawValue: "NSImageCompressionFactor")
    }

    public init(cgImage: CGImage) {}
    open func representation(using storageType: FileType, properties: [PropertyKey: Any]) -> Data? { nil }
}
