import SwiftUI
import ThinktinKit

/// 一排单选的筛选胶囊（docs/ios-ui-redesign.md 2.8）：横向滚动的系统按钮，选中的是 `.glassProminent`、没选中的是
/// `.glass`（iOS 17 / 18 是 `.borderedProminent` / `.bordered`，见 Design/Glass.swift），外面包一层 `GlassGroup`。
/// 换选中项时有系统的选择触感。
///
/// 用在计划和产出物的“按实例筛选”、产出物的类型、首页搜索的类型（第 1、2 轮由各线换掉 `PlansFilterChip`）。放在
/// `List` 里时作为第一行，加 `.listRowBackground(Color.clear)` 和 `.listRowInsets(EdgeInsets())`。
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

    private let options: [Option]
    @Binding private var selection: Value
    private let horizontalInset: CGFloat

    @Environment(\.displayLanguage) private var language

    /// - Parameters:
    ///   - options: 胶囊，按给的顺序排；`value` 重复的只留第一个。
    ///   - selection: 选中的值。不在 `options` 里时一个都不亮。
    ///   - horizontalInset: 左右留白（滚动时胶囊能滚到屏幕边上）；默认和页边距一样。
    public init(_ options: [Option], selection: Binding<Value>, horizontalInset: CGFloat = Metrics.Spacing.m) {
        self.options = FilterChipSelection.uniqueOptions(options)
        _selection = selection
        self.horizontalInset = horizontalInset
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: Metrics.Spacing.xs) {
                HStack(spacing: Metrics.Spacing.xs) {
                    ForEach(options) { option in
                        chip(option)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, Metrics.Spacing.xxs)
            }
        }
        // 玻璃的阴影和按压时的放大不被滚动视图的边框切掉。
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
        }
        .glassButtonStyle(isSelected ? .prominent : .regular)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text(option.accessibilityLabel(language)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
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
