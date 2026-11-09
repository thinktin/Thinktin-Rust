import Foundation
import Testing

@testable import ThinktinKit

private let writer = ConversationFixture.writer

@Suite("对话内查找：匹配、Markdown 显示的字、分段")
struct ConversationFindMatchingTests {
    @Test("匹配不分大小写、变音符号、全角半角；互不重叠；位置按字符数")
    func occurrences() {
        #expect(ConversationFind.occurrences(of: "thinktin", in: "ThinkTin 和 THINKTIN") == [0..<8, 11..<19])
        #expect(ConversationFind.occurrences(of: "cafe", in: "Café") == [0..<4])
        #expect(ConversationFind.occurrences(of: "ＡＢＣ", in: "xabc") == [1..<4])
        #expect(ConversationFind.occurrences(of: "aa", in: "aaaaa") == [0..<2, 2..<4])
        // 表情和汉字都算一个字符。
        #expect(ConversationFind.occurrences(of: "周报", in: "👍 周报和周报") == [2..<4, 5..<7])
        #expect(ConversationFind.occurrences(of: "", in: "abc").isEmpty)
        #expect(ConversationFind.occurrences(of: "x", in: "").isEmpty)
        #expect(ConversationFind.occurrences(of: "没有", in: "这里什么都").isEmpty)
    }

    @Test("行内 Markdown 去掉标记：强调、行内代码、链接、图片、自动链接、转义；词中间的下划线和算式不动")
    func inlinePlainText() {
        #expect(MarkdownInline.plainText("**加粗** 和 *斜体* 和 `代码`") == "加粗 和 斜体 和 代码")
        #expect(MarkdownInline.plainText("看 [文档](https://example.com/a_(b)) 和 ![图](x.png)") == "看 文档 和 图")
        #expect(MarkdownInline.plainText("~~删掉~~ __也加粗__") == "删掉 也加粗")
        #expect(MarkdownInline.plainText("snake_case_name 和 2 * 3 = 6") == "snake_case_name 和 2 * 3 = 6")
        #expect(MarkdownInline.plainText("\\*不是强调\\* 和 <https://a.b/c>") == "*不是强调* 和 https://a.b/c")
        #expect(MarkdownInline.plainText("*没有配对 和 `没有结尾") == "*没有配对 和 `没有结尾")
        #expect(MarkdownInline.plainText("`` 带 ` 的代码 ``") == "带 ` 的代码")
        #expect(MarkdownInline.plainText("没有任何标记") == "没有任何标记")
    }

    @Test("分段：用户消息先引用后正文；回复按块，列表一项一段，表格补齐到列数，代码原样，分隔线没有")
    func segments() {
        let quoted = ConversationFindTarget.userMessage(MessageQuote.compose(quote: "原文", body: "好的"))
        #expect(quoted == [.verbatim("原文"), .verbatim("好的")])
        #expect(ConversationFindTarget.userMessage("普通") == [.verbatim("普通")])
        let blocks = MarkdownParser.parse(
            """
            # 标题

            - 第一项
            - **第二项**

            ```swift
            let a = 1
            ```

            | 甲 | 乙 |
            |---|---|
            | 1 |

            ---
            """)
        #expect(
            ConversationFindTarget.markdown(blocks) == [
                .markdown("标题"), .markdown("第一项"), .markdown("**第二项**"), .verbatim("let a = 1"),
                .markdown("甲"), .markdown("乙"), .markdown("1"), .markdown(""),
            ])
        #expect(MarkdownBlock.rule.findSegments.isEmpty)
        let highlight = ConversationFindHighlight(query: "项", currentSegment: 2, currentOccurrence: 0)
        #expect(highlight.segment(2) == FindSegmentHighlight(query: "项", current: 0))
        #expect(highlight.segment(1) == FindSegmentHighlight(query: "项", current: nil))
        #expect(ConversationFindTarget.summaryID(turnID: "run-1") == "summary-run-1")
    }
}

@MainActor
@Suite("对话内查找：视图模型")
struct ConversationFindModelTests {
    @Test("打开查找、输入后跳到最新一处；上下跳、到头绕回；高亮当前这一处；完成后清掉")
    func findFlow() async throws {
        let model = ConversationModel(client: ConversationFixture.mock(), instanceID: writer)
        await model.start()
        #expect(!model.find.isActive)
        model.setFindQuery("周报")
        #expect(model.find.query.isEmpty, "没打开查找栏时不收查找词")
        model.beginFind()
        #expect(model.find.isActive && model.find.matches.isEmpty && !model.find.canMove)
        model.setFindQuery("周报")
        // 任务、回复里的“周报”：周报那次（任务、回复各一处）、发到团队群那次（任务、回复各一处）；思考、产出物卡片不找。
        let matches = model.find.matches
        #expect(matches.count == 4)
        #expect(model.find.currentIndex == 3, "跳到最新一处")
        let weekly = try #require(model.turn(for: DemoData.weeklyRunID))
        #expect(matches.first?.turnID == weekly.id)
        #expect(Set(matches.map(\.targetID)).count == 4)
        #expect(
            ConversationText.findCount(current: model.find.currentIndex, total: 4, language: .chinese) == "第 4 个，共 4 个")
        model.findPrevious()
        #expect(model.find.currentIndex == 2)
        model.findNext()
        model.findNext()
        #expect(model.find.currentIndex == 0, "到底了绕回第一处")
        model.findPrevious()
        #expect(model.find.currentIndex == 3, "到头了绕到最后一处")
        let current = try #require(model.find.currentMatch)
        let highlight = try #require(model.find.highlight(for: current.targetID))
        #expect(highlight.currentSegment == current.segment && highlight.currentOccurrence == 0)
        let other = try #require(matches.first)
        #expect(model.find.highlight(for: other.targetID)?.currentSegment == nil)
        #expect(model.find.highlight(for: "没有这一项") == nil)
        model.endFind()
        #expect(!model.find.isActive && model.find.query.isEmpty && model.find.matches.isEmpty)
        #expect(model.find.currentIndex == nil && model.find.highlight(for: current.targetID) == nil)
    }

    @Test("Markdown 回复按显示出来的字找、分段；没找到时计数是 0；首尾空白不算")
    func markdownAndNoMatch() async throws {
        let model = ConversationModel(client: ConversationFixture.mock(), instanceID: writer)
        await model.start()
        model.beginFind()
        // 通知汇总：一段 + 三项列表，每项里一个“thinktin/”。“**”是标记，显示出来没有，找不到。
        model.setFindQuery("  thinktin/  ")
        #expect(model.find.matches.count == 3)
        #expect(model.find.matches.map(\.segment) == [1, 2, 3])
        model.setFindQuery("**")
        #expect(model.find.matches.isEmpty && model.find.currentIndex == nil)
        #expect(ConversationText.findCount(current: nil, total: 0, language: .chinese) == "第 0 个，共 0 个")
        #expect(ConversationText.findCount(current: nil, total: 0, language: .english) == "0 of 0")
        #expect(ConversationText.findAnnouncement(current: nil, total: 0, language: .chinese) == "没有找到")
        model.setFindQuery("   ")
        #expect(!model.find.isSearching && model.find.matches.isEmpty)
        // 界面换上真的 Markdown 解析（这里用一个换字的假转换看它有没有用上）：只用在回复（Markdown）上，用户消息原样。
        model.find.plainText = { $0.replacingOccurrences(of: "周报", with: "週報") }
        model.setFindQuery("週報")
        #expect(model.find.matches.count == 2)
    }

    @Test("时间线变了重新找，当前这一处不跳；往上翻出更早的匹配时下标跟着挪")
    func refreshKeepsCurrent() async throws {
        let now = Date()
        let mock = ConversationFixture.manyRuns(count: 60, eventsPerRun: 5, now: now)
        let model = ConversationModel(client: mock, instanceID: writer, now: { now })
        await model.start()
        #expect(model.canLoadOlder)
        model.beginFind()
        model.setFindQuery("任务 5")
        let before = model.find.matches.count
        #expect(before > 0)
        let current = try #require(model.find.currentMatch)
        while model.canLoadOlder { await model.loadOlder() }
        #expect(model.find.matches.count > before, "翻出了更早的“任务 5…”")
        #expect(model.find.currentMatch == current, "当前这一处没跳")
    }

    @Test("只看本次过程、找不到 Botin 时不能查找；菜单里也没有")
    func findUnavailable() async {
        let mock = ConversationFixture.mock()
        let focus = ConversationModel(client: mock, instanceID: writer, focusRunID: DemoData.weeklyRunID)
        await focus.start()
        focus.beginFind()
        #expect(!focus.find.isActive)
        let gone = ConversationModel(client: mock, instanceID: "gone")
        await gone.start()
        gone.beginFind()
        #expect(!gone.find.isActive)
        #expect(!gone.menuSections.joined().contains(.find))
        #expect(!gone.menuSections.joined().contains(.deleteBotin), "Botin 不在了没有删除")
        #expect(!focus.menuSections.joined().contains(.deleteBotin), "只看一次运行时没有删除")
        let live = ConversationModel(client: mock, instanceID: writer)
        await live.start()
        #expect(live.menuSections.first == [.open(.instance(writer)), .find])
    }
}
