import SwiftUI

// 表单里的输入框（规范 2.5、4.9.6 的字段写法，参考 59：标签在上、输入在下，没有自己画的框）。放在 `Form` / 分组 `List` 的一行里，
// 行的卡片底由系统画。以前各页自己画的带描边输入框（`PlansTextField`）都换成它。

/// 标签在上的系统输入框：灰色小标签、`TextField`（多行时跟着内容长高），下面一行提示或问题（问题用失败色）和字数。
struct FormTextField: View {
    let title: String
    let text: Binding<String>
    var prompt: String?
    var multiline = false
    /// 字数上限（显示“12/100”）；nil 不显示。
    var limit: Int?
    var count: Int = 0
    var problem: String?
    var hint: String?
    /// 数字键盘（iOS）。
    var numeric = false
    /// 等宽字体、英文键盘（cron、RRULE、路径、配对码）。
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            field
                .font(monospaced ? Typography.body.monospacedFont : Typography.body.font)
                .foregroundStyle(Theme.ink)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(problem ?? hint ?? ""))
            if problem != nil || hint != nil || limit != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let message = problem ?? hint {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(problem == nil ? Theme.inkSecondary : StatusTone.failure.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    if let limit {
                        Text(verbatim: "\(count)/\(limit)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(count > limit ? StatusTone.failure.color : Theme.inkTertiary)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
    }

    @ViewBuilder
    private var field: some View {
        if multiline {
            TextField(title, text: text, prompt: prompt.map { Text($0) }, axis: .vertical)
                .lineLimit(3...12)
                .codeInput(monospaced)
        } else if numeric {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .numberInput()
        } else {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .codeInput(monospaced)
        }
    }
}

extension View {
    /// 数字输入框：iOS 上是数字键盘。
    func numberInput() -> some View {
        #if canImport(UIKit)
            self.keyboardType(.numberPad)
        #else
            self
        #endif
    }

    /// 代码一类的输入（cron、RRULE、路径）：iOS 上用英文键盘（不出中文输入法）、不自动大写和纠错。`enabled` 为 false 时不变。
    @ViewBuilder
    func codeInput(_ enabled: Bool = true) -> some View {
        #if canImport(UIKit)
            if enabled {
                self.keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                self
            }
        #else
            self
        #endif
    }
}
