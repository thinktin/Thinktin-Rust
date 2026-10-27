@_exported import CoreGraphics
@_exported import Foundation

public enum UIUserInterfaceStyle: Int, Sendable {
    case unspecified, light, dark
}

open class UITraitCollection: @unchecked Sendable {
    public let userInterfaceStyle: UIUserInterfaceStyle
    public init(userInterfaceStyle: UIUserInterfaceStyle) { self.userInterfaceStyle = userInterfaceStyle }
}

open class UIColor: @unchecked Sendable {
    let comps: (CGFloat, CGFloat, CGFloat, CGFloat)
    let provider: (@Sendable (UITraitCollection) -> UIColor)?

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        comps = (red, green, blue, alpha)
        provider = nil
    }

    public init(dynamicProvider: @escaping @Sendable (UITraitCollection) -> UIColor) {
        comps = (0, 0, 0, 0)
        provider = dynamicProvider
    }

    open func resolvedColor(with traitCollection: UITraitCollection) -> UIColor {
        provider?(traitCollection) ?? self
    }

    @discardableResult
    open func getRed(
        _ red: UnsafeMutablePointer<CGFloat>?, green: UnsafeMutablePointer<CGFloat>?,
        blue: UnsafeMutablePointer<CGFloat>?, alpha: UnsafeMutablePointer<CGFloat>?
    ) -> Bool {
        let c = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).comps
        red?.pointee = c.0
        green?.pointee = c.1
        blue?.pointee = c.2
        alpha?.pointee = c.3
        return true
    }
}

@MainActor
open class UIPasteboard {
    public static let general = UIPasteboard()
    open var string: String?
}

@MainActor
open class UIView {
    public init() {}
    open var frame: CGRect = .zero
    open func setNeedsLayout() {}
    open func layoutIfNeeded() {}
}

@MainActor
open class UIViewController {
    public init() {}
    open var view: UIView! = UIView()
}

@MainActor
open class UIDevice {
    public static let current = UIDevice()
    open var name: String { "iPhone" }
}
