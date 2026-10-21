@_exported import CoreGraphics
@_exported import Foundation

public final class NSAppearance: @unchecked Sendable {
    public struct Name: Hashable, Sendable {
        let raw: String
        public static let aqua = Name(raw: "aqua")
        public static let darkAqua = Name(raw: "darkAqua")
    }
    public let name: Name
    public init(name: Name) { self.name = name }
    public func bestMatch(from appearances: [Name]) -> Name? { appearances.contains(name) ? name : nil }
}

open class NSColor: @unchecked Sendable {
    public typealias Name = String
    public init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {}
    public init(name: Name?, dynamicProvider: @escaping @Sendable (NSAppearance) -> NSColor) {}
}

public struct NSPasteboardType: Hashable, Sendable {
    public static let string = NSPasteboardType()
}

@MainActor
open class NSPasteboard {
    public static let general = NSPasteboard()
    @discardableResult open func clearContents() -> Int { 0 }
    @discardableResult open func setString(_ string: String, forType: NSPasteboardType) -> Bool { true }
}

@MainActor
open class NSView {
    public init() {}
    open var frame: CGRect = .zero
    open func layoutSubtreeIfNeeded() {}
}

@MainActor
open class NSViewController {
    public init() {}
    open var view: NSView = NSView()
}
