// 对话页（12.5，改版第 1 轮 B 线）用到的 UIKit：长按消息“选择文本”的只读 `UITextView`（SwiftUI 的 `Text` 在 iOS 上只能整段
// 复制，不能划选一部分）。签名照 iOS 17 SDK，实现全是空的，只用来在 Linux 上做类型检查。单独放一个文件，免得和别的功能
// 同时往 UIKit.swift 里加东西时冲突；合并时别的功能也加了同名的，留一份就行。

extension UIColor {
    public static let clear = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct UIEdgeInsets: Hashable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}

open class UIFont: @unchecked Sendable {
    public struct TextStyle: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let body = TextStyle(rawValue: "UICTFontTextStyleBody")
        public static let callout = TextStyle(rawValue: "UICTFontTextStyleCallout")
        public static let footnote = TextStyle(rawValue: "UICTFontTextStyleFootnote")
    }

    init() {}

    open class func preferredFont(forTextStyle style: UIFont.TextStyle) -> UIFont { UIFont() }
}

@MainActor
open class UIScrollView: UIView {
    open var isScrollEnabled = true
    open var alwaysBounceVertical = false
}

@MainActor
open class UITextView: UIScrollView {
    open var text: String! = ""
    open var font: UIFont?
    open var textColor: UIColor?
    open var backgroundColor: UIColor?
    open var isEditable = true
    open var isSelectable = true
    open var adjustsFontForContentSizeCategory = false
    open var textContainerInset = UIEdgeInsets.zero
}
