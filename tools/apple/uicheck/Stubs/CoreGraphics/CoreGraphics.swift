@_exported import Foundation

// CoreFoundation 的几个类型（SDK 里 CoreGraphics、Security 都连带导出 CoreFoundation）。
public typealias OSStatus = Int32
public typealias CFTypeRef = AnyObject
public typealias CFString = String
public protocol _CFDictionaryLike {}
extension Dictionary: _CFDictionaryLike {}
public typealias CFDictionary = any _CFDictionaryLike

public final class CGImage: @unchecked Sendable {
    public init() {}
    public var width: Int { 0 }
    public var height: Int { 0 }
}

// macOS App（14.3、14.4、14.8）：二维码放大、截图的显示器、键鼠事件、窗口列表、屏幕录制权限。签名照 macOS 14 SDK。

public struct CGAffineTransform: Equatable, Sendable {
    public init(scaleX sx: CGFloat, y sy: CGFloat) {}
}

public typealias CGDirectDisplayID = UInt32
public typealias CGWindowID = UInt32
public typealias CGKeyCode = UInt16
public typealias UniChar = UInt16

public func CGMainDisplayID() -> CGDirectDisplayID { 0 }

public final class CGDisplayMode {
    public var width: Int { 0 }
    public var height: Int { 0 }
    public var pixelWidth: Int { 0 }
    public var pixelHeight: Int { 0 }
}

public func CGDisplayCopyDisplayMode(_ display: CGDirectDisplayID) -> CGDisplayMode? { nil }

public func CGPreflightScreenCaptureAccess() -> Bool { false }
public func CGRequestScreenCaptureAccess() -> Bool { false }

public struct CGWindowListOption: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let optionOnScreenOnly = CGWindowListOption(rawValue: 1 << 0)
    public static let excludeDesktopElements = CGWindowListOption(rawValue: 1 << 4)
}

public let kCGNullWindowID: CGWindowID = 0
public let kCGWindowLayer: String = "kCGWindowLayer"
public let kCGWindowBounds: String = "kCGWindowBounds"
public let kCGWindowOwnerPID: String = "kCGWindowOwnerPID"

/// SDK 里返回 `CFArray?`；这里给 `[Any]?`，`as? [[String: Any]]` 照样能转。
public func CGWindowListCopyWindowInfo(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID) -> [Any]? { nil }

public enum CGEventType: UInt32, Sendable {
    case leftMouseDown = 1
    case leftMouseUp, rightMouseDown, rightMouseUp, mouseMoved
    case keyDown = 10
    case keyUp
}

public enum CGMouseButton: UInt32, Sendable {
    case left, right, center
}

public enum CGEventTapLocation: UInt32, Sendable {
    case cghidEventTap, cgSessionEventTap, cgAnnotatedSessionEventTap
}

public enum CGEventField: UInt32, Sendable {
    case mouseEventClickState = 1
}

public struct CGEventFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let maskShift = CGEventFlags(rawValue: 0x0002_0000)
    public static let maskControl = CGEventFlags(rawValue: 0x0004_0000)
    public static let maskAlternate = CGEventFlags(rawValue: 0x0008_0000)
    public static let maskCommand = CGEventFlags(rawValue: 0x0010_0000)
}

public final class CGEventSource {}

public final class CGEvent {
    public init?(
        mouseEventSource source: CGEventSource?, mouseType: CGEventType, mouseCursorPosition: CGPoint,
        mouseButton: CGMouseButton
    ) {}
    public init?(keyboardEventSource source: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) {}
    public var flags: CGEventFlags = []
    public func setIntegerValueField(_ field: CGEventField, value: Int64) {}
    public func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UniChar>?) {}
    public func post(tap: CGEventTapLocation) {}
}
