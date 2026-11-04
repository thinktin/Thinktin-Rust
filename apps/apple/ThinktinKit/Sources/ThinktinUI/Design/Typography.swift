import SwiftUI

/// 字体（docs/ios.md 第 4 节；改版定了 6.2 C，见 docs/ios-ui-redesign.md 2.3）：全部用系统字体（SF），标题也不再用衬线；
/// 导航标题由系统画。全部是 Dynamic Type 的语义字号，跟着用户的字号设置缩放；不写死磅值，不打包字体文件。
///
/// 常用的：列表里的名字 `.headline`；预览、副标题 `.subheadline` + `inkSecondary`；时间 `.caption` + `inkTertiary`；
/// 正文 `.body`；资料页的名字 `.title2` 加粗。分组标题、脚注用 `Section` 自带的。
///
/// 用法：`Text("下午好").typography(.largeTitle)`，或 `.font(Typography.body.font)`。
public enum Typography: CaseIterable, Sendable {
    // 标题。
    case largeTitle
    case title
    case title2
    case title3
    // 正文。
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

    /// 标题类（读屏、版式上当标题；字体和正文一样是系统字体）。
    public var isHeading: Bool {
        switch self {
        case .largeTitle, .title, .title2, .title3: true
        default: false
        }
    }

    /// 字体设计：一律系统默认（SF）。改版前标题用衬线（New York），6.2 C 定了不再用。
    public var design: Font.Design { .default }

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
