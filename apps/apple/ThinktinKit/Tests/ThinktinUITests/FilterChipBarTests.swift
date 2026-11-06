import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 筛选胶囊（docs/ios-ui-redesign.md 2.8）：单选的规则、重复的胶囊、读屏文字、能布局。
@MainActor
@Suite("筛选胶囊")
struct FilterChipBarTests {
    @Test("点没选中的换过去；点已经选中的不变（不改值，也不触发触感）")
    func selection() {
        #expect(FilterChipSelection.next(tapping: 2, current: 1) == 2)
        #expect(FilterChipSelection.next(tapping: 1, current: 1) == nil)
        // “全部”是 nil 的那个胶囊：从某个实例点回“全部”要换成 nil，不是“没变”。
        let all: String? = nil
        #expect(FilterChipSelection.next(tapping: all, current: "a") == .some(nil))
        #expect(FilterChipSelection.next(tapping: "a", current: all) == .some("a"))
        #expect(FilterChipSelection.next(tapping: all, current: all) == nil)
    }

    @Test("value 重复的胶囊只留第一个，顺序不变")
    func uniqueOptions() {
        let options: [FilterChipBar<Int>.Option] = [
            .init(value: 0, title: "全部"), .init(value: 1, title: "媒体"), .init(value: 0, title: "又一个全部"),
            .init(value: 2, title: "文件"),
        ]
        let unique = FilterChipSelection.uniqueOptions(options)
        #expect(unique.map(\.value) == [0, 1, 2])
        #expect(unique.first?.title == "全部")
    }

    @Test("读屏：标题加数")
    func accessibilityLabel() {
        let withCount = FilterChipBar<Int>.Option(value: 1, title: "周报助手", count: 3)
        #expect(withCount.accessibilityLabel(.chinese) == "周报助手，3")
        #expect(withCount.accessibilityLabel(.english) == "周报助手, 3")
        #expect(FilterChipBar<Int>.Option(value: 0, title: "All").accessibilityLabel(.english) == "All")
        #expect(withCount.id == 1)
    }

    @Test("能布局：带数、不带数、选中项不在里面")
    func layout() {
        let options: [FilterChipBar<String?>.Option] = [
            .init(value: nil, title: "全部", count: 12), .init(value: "a", title: "周报助手", count: 5),
            .init(value: "b", title: "一个很长很长很长很长的实例名字"),
        ]
        for language in [DisplayLanguage.chinese, .english] {
            hostAndLayout(
                FilterChipBar(options, selection: .constant("a")).environment(\.displayLanguage, language))
        }
        hostAndLayout(FilterChipBar(options, selection: .constant("不在里面"), horizontalInset: 0))
        hostAndLayout(
            List {
                FilterChipBar(options, selection: .constant(nil))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            })
    }
}
