import SwiftUI

/// 字体（docs/ios.md 第 4 节）：标题用衬线（系统的 New York，`.serif` 设计），正文用系统默认的无衬线（SF）。
/// 全部是 Dynamic Type 的语义字号，跟着用户的字号设置缩放；不写死磅值，不打包字体文件。
///
/// 用法：`Text("下午好").typography(.largeTitle)`，或 `.font(Typography.body.font)`。
public enum Typography: CaseIterable, Sendable {
    // 标题：衬线。
    case largeTitle
    case title
    case title2
    case title3
    // 正文：系统字体。
    case headline
    case subheadline
    case body
    case callout
    case footnote
    case caption
    case caption2

    /// 对应的 Dynamic Type 语义字号。
    public var textStyle: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }

    /// 标题类（用衬线）。
    public var isHeading: Bool {
        switch self {
        case .largeTitle, .title, .title2, .title3: true
        default: false
        }
    }

    /// 字体设计：标题衬线，其余系统默认。
    public var design: Font.Design { isHeading ? .serif : .default }

    /// 字重用语义字号的默认值（`headline` 是半粗，其余常规）。
    public var font: Font { .system(textStyle, design: design) }

    /// 同字号的等宽字体（代码块、工具调用参数）。
    public var monospacedFont: Font { .system(textStyle, design: .monospaced) }
}

extension View {
    /// 按设计令牌设字体。
    public func typography(_ style: Typography) -> some View {
        font(style.font)
    }
}
