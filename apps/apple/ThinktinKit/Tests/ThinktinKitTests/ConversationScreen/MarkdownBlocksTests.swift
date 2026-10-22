import Foundation
import Testing

@testable import ThinktinKit

@Suite("块级 Markdown")
struct MarkdownBlocksTests {
    private func blocks(_ text: String) -> [MarkdownBlock] {
        MarkdownParser.parse(text).map(\.block)
    }

    @Test("标题、段落、分隔线")
    func headingsAndParagraphs() {
        let out = blocks("# 周报\n\n这周做了三件事，\n都上线了。\n\n---\n\n## 下周 ##\n#不是标题")
        #expect(
            out == [
                .heading(level: 1, text: "周报"), .paragraph("这周做了三件事，\n都上线了。"), .rule,
                .heading(level: 2, text: "下周"), .paragraph("#不是标题"),
            ])
    }

    @Test("无序、有序、嵌套、任务列表")
    func lists() throws {
        let out = blocks("- 一\n- 二\n  - 二点一\n    - 更深\n- [x] 做完了\n- [ ] 还没做\n\n1. 第一\n2) 第二")
        #expect(out.count == 2)
        guard case .list(let bullets) = out[0], case .list(let numbers) = out[1] else {
            Issue.record("不是两个列表：\(out)")
            return
        }
        #expect(bullets.items.map(\.text) == ["一", "二", "二点一", "更深", "做完了", "还没做"])
        #expect(bullets.items.map(\.level) == [0, 0, 1, 2, 0, 0])
        #expect(bullets.items.map(\.checked) == [nil, nil, nil, nil, true, false])
        #expect(bullets.items.allSatisfy { $0.number == nil })
        #expect(numbers.items.map(\.number) == [1, 2])
        #expect(numbers.items.map(\.text) == ["第一", "第二"])
    }

    @Test("列表项的续行拼进上一项；空行隔开的同类项还是一个列表")
    func listContinuation() {
        let out = blocks("- 第一项\n  接着说\n\n- 第二项\n\n下一段")
        #expect(
            out == [
                .list(MarkdownList(items: [.init(text: "第一项\n接着说"), .init(text: "第二项")])),
                .paragraph("下一段"),
            ])
    }

    @Test("围栏代码块：语言、原样保留缩进和空行；没结束的标成未结束")
    func codeBlocks() {
        let out = blocks("看这里：\n\n```swift\nlet a = 1\n\n  if a > 0 {}\n```\n\n~~~\nraw\n~~~\n\n```bash\nnpm i")
        #expect(
            out == [
                .paragraph("看这里："),
                .code(language: "swift", code: "let a = 1\n\n  if a > 0 {}", isClosed: true),
                .code(language: nil, code: "raw", isClosed: true),
                .code(language: "bash", code: "npm i", isClosed: false),
            ])
    }

    @Test("列表项里缩进的代码块单独显示，去掉围栏的缩进")
    func codeInsideList() {
        let out = blocks("1. 先装依赖：\n   ```bash\n   npm install\n   ```\n2. 再跑测试")
        #expect(
            out == [
                .list(MarkdownList(items: [.init(text: "先装依赖：", number: 1)])),
                .code(language: "bash", code: "npm install", isClosed: true),
                .list(MarkdownList(items: [.init(text: "再跑测试", number: 2)])),
            ])
    }

    @Test("引用（懒续行）")
    func quotes() {
        #expect(blocks("> 第一行\n> 第二行\n接着\n\n正文") == [.quote("第一行\n第二行\n接着"), .paragraph("正文")])
    }

    @Test("表格：表头、对齐行、格子里的竖线；降级成文字")
    func tables() throws {
        let out = blocks("| 项目 | 状态 |\n|:---|---:|\n| 后端 | 完成 |\n| a \\| b | 进行中 |\n\n后面")
        #expect(out.count == 2)
        guard case .table(let table) = out[0] else {
            Issue.record("不是表格：\(out)")
            return
        }
        #expect(table.header == ["项目", "状态"])
        #expect(table.rows == [["后端", "完成"], ["a | b", "进行中"]])
        #expect(table.columnCount == 2)
        #expect(table.plainText == "项目 | 状态\n后端 | 完成\na | b | 进行中")
        // 没有对齐行的不是表格。
        #expect(blocks("a | b\nc | d") == [.paragraph("a | b\nc | d")])
    }

    @Test("Windows 换行、结尾的换行、只有空白")
    func whitespace() {
        #expect(blocks("一\r\n二\r\n") == [.paragraph("一\n二")])
        #expect(blocks("   \n\n") == [])
        #expect(blocks("") == [])
    }

    @Test("块的 offset 是 UTF-8 位置")
    func offsets() {
        let items = MarkdownParser.parse("标题\n\n- 项")
        #expect(items.map(\.offset) == [0, "标题\n\n".utf8.count])
        #expect(items.map(\.id) == [0, 1])
    }

    @Test("流式追加：前面的块和 id 不变，只重新解析最后一块；结果和整段解析一样")
    func streaming() {
        let chunks = [
            "# 结果\n\n", "第一段", "说完了。\n\n- 一\n", "- 二\n\n```py\nprint(1)", "\n```\n\n| a | b |\n",
            "|---|---|\n| 1 | 2 |",
        ]
        var stream = MarkdownStream()
        var text = ""
        var previous: [MarkdownBlockItem] = []
        for chunk in chunks {
            text += chunk
            let now = stream.update(text)
            #expect(now == MarkdownParser.parse(text), "增量结果和整段解析一致：\(text)")
            // 除了上一次的最后一块，前面的都原样保留。
            for old in previous.dropLast() {
                #expect(now.first { $0.id == old.id } == old)
            }
            previous = now
        }
        #expect(stream.fullParses == 1, "只在第一次整段解析")
        // 整个换掉（不是追加）时从头解析。
        stream.update("别的")
        #expect(stream.fullParses == 2)
        #expect(stream.blocks.map(\.block) == [.paragraph("别的")])
    }
}
