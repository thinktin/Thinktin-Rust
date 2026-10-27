// 截图（14.3）的桩：签名照 macOS 14 SDK，只放用到的。
@_exported import CoreGraphics

open class SCDisplay {
    open var displayID: CGDirectDisplayID { 0 }
    open var width: Int { 0 }
    open var height: Int { 0 }
    open var frame: CGRect { .zero }
}

open class SCRunningApplication {
    open var bundleIdentifier: String { "" }
    open var processID: pid_t { 0 }
}

open class SCWindow {}

open class SCShareableContent {
    open var displays: [SCDisplay] { [] }
    open var applications: [SCRunningApplication] { [] }
    open var windows: [SCWindow] { [] }
    open class func excludingDesktopWindows(_ excludeDesktopWindows: Bool, onScreenWindowsOnly: Bool) async throws
        -> SCShareableContent
    { SCShareableContent() }
}

open class SCContentFilter {
    public init(
        display: SCDisplay, excludingApplications applications: [SCRunningApplication], exceptingWindows: [SCWindow]
    ) {}
}

open class SCStreamConfiguration {
    public init() {}
    open var width: Int = 0
    open var height: Int = 0
    open var showsCursor: Bool = true
}

open class SCScreenshotManager {
    open class func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws
        -> CGImage
    { CGImage() }
}
