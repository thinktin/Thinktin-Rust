import SwiftUI
import ThinktinKit

/// 一排单选的筛选胶囊（docs/ios-ui-redesign.md 2.8）：横向滚动的普通按钮（`.plain`），每个垫一块实心的胶囊底：选中的是
/// 强调色底、白字，没选中的是卡片色（`paperElevated`）底、正文色的字，都没有描边、没有阴影（参考 22、36、78 是平的实心
/// 胶囊）。以前是系统的玻璃按钮：深色下没选中的是空心的，浅色下放在列表行里时几个胶囊的玻璃阴影连成一块灰底、在行的下沿
/// 被切出一道横边（2026-11-11 截图 05、35），所以 2026-11-11 换成实心的。换选中项时有系统的选择触感。
///
/// 字是 medium 的 `.footnote`（参考 22、36、78 量出来约 13pt）；胶囊约 34pt 高（13pt 的字行高 18pt，上下各 8pt）、两个字的
/// 约 50pt 宽（左右各 12pt），首页搜索的六个胶囊一屏放得下。
///
/// 用在计划和产出物的“按实例筛选”、产出物的类型、首页搜索的类型（第 1、2 轮由各线换掉 `PlansFilterChip`）。放在
/// `List` 里时作为第一行，加 `.listRowBackground(Color.clear)` 和 `.listRowInsets(EdgeInsets())`。
///
/// 保险箱用 `style: .tabs`（参考 57 和别的页不一样）：没选中的只是一段灰字和灰色的数，没有底；选中的是一块和卡片同色的
/// 胶囊底、正文色的字；字是 `.callout`、胶囊约 38pt 高（参考 57 量出来约 16pt 的字、38pt 高），四个胶囊一屏放得下。
///
/// ```swift
/// FilterChipBar(
///     [.init(value: nil, title: "全部", count: 12)] + instances.map { .init(value: $0.id, title: $0.name) },
///     selection: $model.instanceFilter)
/// ```
public struct FilterChipBar<Value: Hashable>: View {
    /// 一个胶囊。
    public struct Option: Identifiable, Hashable {
        /// 选中它时 `selection` 的值。
        public var value: Value
        public var title: String
        /// 标题后面的数（这一类有几条）；nil 不显示。
        public var count: Int?

        public var id: Value { value }

        public init(value: Value, title: String, count: Int? = nil) {
            self.value = value
            self.title = title
            self.count = count
        }

        /// 读屏念的：“周报助手，3”。选没选中由系统按 `isSelected` 念。
        public func accessibilityLabel(_ language: DisplayLanguage) -> String {
            guard let count else { return title }
            return title + (language == .chinese ? "，" : ", ") + "\(count)"
        }
    }

    /// 胶囊的画法。
    public enum Style: Hashable, Sendable {
        /// 实心胶囊：选中的强调色底，没选中的卡片色底（计划、产出物、搜索、连接目录、触发器的写法；参考 22、36、78）。
        case capsules
        /// 没有底的灰字，选中的那个垫一块卡片色的胶囊（保险箱；参考 57）。
        case tabs
    }

    private let options: [Option]
    @Binding private var selection: Value
    private let horizontalInset: CGFloat
    private let style: Style

    @Environment(\.displayLanguage) private var language

    /// - Parameters:
    ///   - options: 胶囊，按给的顺序排；`value` 重复的只留第一个。
    ///   - selection: 选中的值。不在 `options` 里时一个都不亮。
    ///   - horizontalInset: 左右留白（滚动时胶囊能滚到屏幕边上）；默认和页边距一样。
    ///   - style: 胶囊的画法；默认实心胶囊。
    public init(
        _ options: [Option], selection: Binding<Value>, horizontalInset: CGFloat = Metrics.Spacing.m,
        style: Style = .capsules
    ) {
        self.options = FilterChipSelection.uniqueOptions(options)
        _selection = selection
        self.horizontalInset = horizontalInset
        self.style = style
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: style == .tabs ? Metrics.Spacing.unit / 2 : Metrics.Spacing.xs) {
                ForEach(options) { option in
                    switch style {
                    case .capsules: chip(option)
                    case .tabs: tab(option)
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, Metrics.Spacing.xxs)
        }
        // 胶囊滚动时能滚到屏幕边上，不在列表行或页边距那里被切掉。
        .scrollClipDisabled()
        .appFeedback(.selection, trigger: selection)
    }

    private func chip(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            if let next = FilterChipSelection.next(tapping: option.value, current: selection) {
                selection = next
            }
        } label: {
            HStack(spacing: Metrics.Spacing.xxs) {
                Text(option.title)
                    .lineLimit(1)
                if let count = option.count {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(Typography.footnote.font.weight(.medium))
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, Metrics.Spacing.s)
            .padding(.vertical, Metrics.Spacing.xs)
            .background(isSelected ? Theme.accent : Theme.paperElevated, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.accessibilityLabel(language)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension FilterChipBar {
    /// `.tabs` 的一个：普通按钮（`.plain`，没有玻璃底），选中的垫一块卡片色（`paperElevated`）的胶囊。
    fileprivate func tab(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            if let next = FilterChipSelection.next(tapping: option.value, current: selection) {
                selection = next
            }
        } label: {
            HStack(spacing: Metrics.Spacing.xxs) {
                Text(option.title)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                if let count = option.count {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .font(isSelected ? Typography.callout.font.weight(.medium) : Typography.callout.font)
            .padding(.horizontal, Metrics.Spacing.s)
            .padding(.vertical, FilterChipLayout.tabVerticalPadding)
            .background {
                if isSelected {
                    Capsule().fill(Theme.paperElevated)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.accessibilityLabel(language)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum FilterChipLayout {
    /// `.tabs` 选中那块胶囊底上下的留白：`.callout` 的字加上下各 10pt 约 39pt 高（参考 57 约 38pt；以前 `.subheadline` 加
    /// 8pt 只有 34pt）。没有现成的 10pt 间距，单写一个。
    static let tabVerticalPadding: CGFloat = 10
}

/// 筛选胶囊的选择规则（纯逻辑，测试直接调）。
enum FilterChipSelection {
    /// 点了 `value` 以后的选中值；点的就是选中的那个时为 nil（不改，也不触发触感）。单选，不能取消成什么都不选：
    /// 要“全部”就给一个“全部”的胶囊。
    static func next<Value: Hashable>(tapping value: Value, current: Value) -> Value? {
        value == current ? nil : value
    }

    /// 去掉 `value` 重复的胶囊（只留第一个），免得 `ForEach` 的 id 重复。
    static func uniqueOptions<Value: Hashable>(
        _ options: [FilterChipBar<Value>.Option]
    ) -> [FilterChipBar<Value>.Option] {
        var seen = Set<Value>()
        return options.filter { seen.insert($0.value).inserted }
    }
}

#Preview("筛选胶囊") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
        FilterChipBar(
            [
                .init(value: nil, title: "全部", count: 12), .init(value: "a", title: "周报助手", count: 5),
                .init(value: "b", title: "Codex", count: 7), .init(value: "c", title: "盯盘"),
            ],
            selection: .constant(String?.none))
        FilterChipBar(
            [.init(value: 0, title: "全部"), .init(value: 1, title: "媒体"), .init(value: 2, title: "文件")],
            selection: .constant(1))
    }
    .padding(.vertical)
    .background(Theme.paper)
}
