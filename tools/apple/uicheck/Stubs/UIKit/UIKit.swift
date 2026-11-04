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

    // 系统的语义文字色（iOS 13）：带透明度，跟着外观、底色自动调。值照 iOS 17 SDK（浅色 / 深色）。
    public static let label = UIColor(dynamicProvider: { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 1, blue: 1, alpha: 1) : UIColor(red: 0, green: 0, blue: 0, alpha: 1)
    })
    public static let secondaryLabel = UIColor(dynamicProvider: { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.6)
            : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.6)
    })
    public static let tertiaryLabel = UIColor(dynamicProvider: { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.3)
            : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.3)
    })

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
