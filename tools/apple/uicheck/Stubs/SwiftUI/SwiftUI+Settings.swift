// 设置、多语言与开源许可（WBS 12.12）的界面用到、别的桩文件里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 单独放一个文件，免得和别的功能同时往 SwiftUI.swift 里加东西时合并冲突。合并时如果别的功能也加了同名的
// （textSelection 这种通用的），留一份就行。

// MARK: - 文字可以选中、复制（iOS 15、macOS 12）

public protocol TextSelectability {
    static var allowsSelection: Bool { get }
}

public struct EnabledTextSelectability: TextSelectability {
    public static var allowsSelection: Bool { true }
}

public struct DisabledTextSelectability: TextSelectability {
    public static var allowsSelection: Bool { false }
}

extension TextSelectability where Self == EnabledTextSelectability {
    public static var enabled: EnabledTextSelectability { EnabledTextSelectability() }
}

extension TextSelectability where Self == DisabledTextSelectability {
    public static var disabled: DisabledTextSelectability { DisabledTextSelectability() }
}

extension View {
    public func textSelection<S: TextSelectability>(_ selectability: S) -> some View { _m() }
}
