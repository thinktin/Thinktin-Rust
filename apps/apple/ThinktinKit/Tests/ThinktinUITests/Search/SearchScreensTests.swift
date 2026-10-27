import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 搜索（WBS 12.21）的界面：搜索页、结果的一行，在浅色中文、深色英文、大字号下都能布局。逻辑在 ThinktinKitTests 的 Search 里测。
@MainActor
@Suite("搜索的界面")
struct SearchScreensTests {
    @Test("搜索页能布局")
    func screen() {
        hostAndLayout(SearchDestination(route: .search).previewShell())
        hostAndLayout(SearchDestination(route: .search).previewShell(.english, scheme: .dark))
        hostAndLayout(SearchDestination(route: .search).previewShell().dynamicTypeSize(.accessibility3))
    }

    @Test("结果的一行：带片段、AI 标识、时间")
    func row() {
        let results = [
            SearchResult(
                kind: .run, key: "r", title: "整理周报", snippet: "…分了三组…", isAIGenerated: true, date: Date(),
                route: .run("r")),
            SearchResult(kind: .instance, key: "i", title: "写作助手", route: .conversation("i")),
        ]
        for result in results {
            hostAndLayout(SearchResultRow(result: result) {}.previewShell())
            hostAndLayout(
                SearchResultRow(result: result) {}.previewShell(.english, scheme: .dark).dynamicTypeSize(
                    .accessibility3))
        }
    }
}
