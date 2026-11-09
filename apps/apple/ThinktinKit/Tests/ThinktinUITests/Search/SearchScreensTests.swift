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

    @Test("改版的搜索：没输入时列出 Botin、选了一类时的提示、全部分组、只看消息、没结果")
    func results() {
        let client = MockClient(state: DemoData.state(), stepDelay: 0, autoReply: false)
        let search = SearchModel(client: client)
        search.loadCache()
        let states: [(SearchKind?, String)] = [
            (nil, ""), (.run, ""), (.instance, ""), (nil, "周报"), (.run, "周报"), (.plan, "没有这个词 zzz"),
        ]
        for (filter, query) in states {
            search.filter = filter
            search.query = query
            hostAndLayout(SearchResultsView(search: search).previewShell(client: client))
            hostAndLayout(SearchResultsView(search: search).previewShell(.english, scheme: .dark, client: client))
        }
    }

    @Test("结果的一行：带片段、AI 标识、时间；Botin 的结果画它挑的头像")
    func row() {
        let results = [
            SearchResult(
                kind: .run, key: "r", title: "写作助手", snippet: "…分了三组…", isAIGenerated: true, date: Date(),
                route: .run("r"), instanceID: "i", direction: .received),
            SearchResult(
                kind: .run, key: "s", title: "写作助手", snippet: "整理周报", date: Date().addingTimeInterval(-3 * 86400),
                route: .run("s"), instanceID: "i", direction: .sent),
            SearchResult(kind: .instance, key: "i", title: "写作助手", route: .conversation("i"), instanceID: "i"),
            SearchResult(kind: .plan, key: "p", title: "每周周报", snippet: "写作助手", route: .plan("p")),
        ]
        for result in results {
            hostAndLayout(SearchResultRow(result: result) {}.previewShell())
            hostAndLayout(
                SearchResultRow(result: result) {}.previewShell(.english, scheme: .dark).dynamicTypeSize(
                    .accessibility3))
        }
        let appearances = InstanceAppearanceStore(defaults: nil)
        appearances.set(InstanceAppearance(shape: .cloud, color: .blue), for: "i")
        hostAndLayout(SearchResultRow(result: results[2], appearances: appearances) {}.previewShell())
    }
}
