import Foundation
import Testing

@testable import ThinktinKit

private let writer = ConversationFixture.writer
private let reviewer = ConversationFixture.reviewer

/// 东八区的公历（测试里的“今天”“星期几”不跟着跑测试的机器变）。
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
}()

/// 2026-11-05（星期四）22:09，东八区。
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 22, minute: 9))!

private func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11, year: Int = 2026) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func turn(_ id: String, at date: Date?) -> ConversationTurn {
    let run = date.map { Run(id: RunID(id), instanceID: writer, prompt: "任务", createdAt: $0) }
    return ConversationTurn(id: id, runID: run?.id, run: run, items: [], state: nil, isStreaming: false)
}

@Suite("对话页的版式：时间分隔、引用回复、菜单、第一次进来")
struct ConversationLayoutTests {
    @Test("时间分隔：今天、昨天、一周内写星期几，更早写日期（往年带年份）；中英文")
    func separatorLabels() {
        let label = { (date: Date, language: DisplayLanguage) in
            ConversationTimeSeparator.label(date, now: now, language: language, calendar: calendar)
        }
        #expect(label(at(5, 22, 9), .chinese) == "今天 22:09")
        #expect(label(at(5, 0, 5), .english) == "Today 00:05")
        #expect(label(at(4, 23, 59), .chinese) == "昨天 23:59")
        #expect(label(at(4, 8, 0), .english) == "Yesterday 08:00")
        #expect(label(at(3, 2, 22), .chinese) == "星期二 02:22")
        #expect(label(at(30, 16, 14, month: 10), .chinese) == "星期五 16:14")
        #expect(label(at(30, 16, 14, month: 10), .english) == "Friday 16:14")
        #expect(label(at(29, 9, 0, month: 10), .chinese) == "10月29日 09:00")
        #expect(label(at(29, 9, 0, month: 10), .english) == "Oct 29, 09:00")
        #expect(label(at(21, 9, 5, month: 10, year: 2025), .chinese) == "2025年10月21日 09:05")
    }

    @Test("时间分隔加在哪：第一组总有，隔 15 分钟以上或跨天才加；没有时间的组跳过")
    func separatorPlacement() {
        let turns = [
            turn("a", at: at(3, 2, 22)),
            turn("b", at: at(3, 2, 30)),  // 隔 8 分钟：不加
            turn("c", at: at(3, 2, 45)),  // 和上一组隔 15 分钟：加
            turn("none-1", at: nil),  // 没有时间：跳过，也不算上一组
            turn("d", at: at(3, 23, 59)),
            turn("e", at: at(4, 0, 1)),  // 只隔 2 分钟，但跨天了：加
            turn("f", at: at(5, 22, 0)),
        ]
        let labels = ConversationTimeSeparator.labels(for: turns, now: now, language: .chinese, calendar: calendar)
        #expect(labels["a"] == "星期二 02:22")
        #expect(labels["b"] == nil)
        #expect(labels["c"] == "星期二 02:45")
        #expect(labels["none-1"] == nil)
        #expect(labels["d"] == "星期二 23:59")
        #expect(labels["e"] == "昨天 00:01")
        #expect(labels["f"] == "今天 22:00")
        #expect(ConversationTimeSeparator.labels(for: [], now: now, calendar: calendar).isEmpty)
        // 运行还没拿到的组用第一项的时间。
        let item = ConversationItem(
            id: "seq-1", runID: nil, createdAt: at(5, 21, 0),
            content: .systemNotice(SystemNotice(kind: .logTruncated)))
        let notice = ConversationTurn(id: "none-2", runID: nil, items: [item], state: nil, isStreaming: false)
        #expect(ConversationTimeSeparator.date(of: notice) == at(5, 21, 0))
    }

    @Test("引用：拼成 Markdown 引用块放在正文前；正文空时不带引用；空行、首尾空白、太长截断")
    func quoteCompose() {
        #expect(MessageQuote.compose(quote: "原文", body: "  好的 \n") == "> 原文\n\n好的")
        #expect(MessageQuote.compose(quote: "第一行\n\n第三行", body: "嗯") == "> 第一行\n>\n> 第三行\n\n嗯")
        #expect(MessageQuote.compose(quote: "原文", body: "  \n") == "  \n")
        #expect(MessageQuote.compose(quote: nil, body: " 原样 ") == " 原样 ")
        #expect(MessageQuote.compose(quote: "   ", body: "正文") == "正文")
        #expect(MessageQuote.normalized("  \r\n 一段\r\n两行 \n") == "一段\n两行")
        #expect(MessageQuote.normalized(" \n ") == nil)
        let long = MessageQuote.normalized(String(repeating: "字", count: 1500))
        #expect(long?.count == MessageQuote.maxLength + 1)
        #expect(long?.hasSuffix("…") == true)
        #expect(MessageQuote.preview("第一行\n\n  第二行\t末尾") == "第一行 第二行 末尾")
    }

    @Test("引用：发出去的消息能拆回引用和正文；不是这个样子的整段当正文")
    func quoteSplit() {
        let sent = MessageQuote.compose(quote: "第一行\n\n第三行", body: "好")
        let split = MessageQuote.split(sent)
        #expect(split.quote == "第一行\n\n第三行")
        #expect(split.body == "好")
        #expect(MessageQuote.split(">没空格\n\n正文").quote == "没空格")
        // 引用后面没有空行、没有正文、开头不是引用：都当正文。
        #expect(MessageQuote.split("> 引用\n紧接着").quote == nil)
        #expect(MessageQuote.split("> 只有引用\n\n").quote == nil)
        #expect(MessageQuote.split("正文\n> 中间的引用\n\n后面").quote == nil)
        #expect(MessageQuote.split("普通消息").body == "普通消息")
    }

    @Test("引用回复在别处只显示正文：运行树的标题、读屏先念正文再念引用")
    func quoteBodyElsewhere() {
        let sent = MessageQuote.compose(quote: "我现在有一个只有你能看到的保险箱\n第二行", body: "帮我存一下\n细节")
        #expect(MessageQuote.body(sent) == "帮我存一下\n细节")
        #expect(MessageQuote.body("普通消息") == "普通消息")
        #expect(
            MessageQuote.spoken(sent, language: .chinese) == "帮我存一下\n细节。引用：我现在有一个只有你能看到的保险箱 第二行")
        #expect(MessageQuote.spoken("普通消息", language: .english) == "普通消息")
        let node = RunTreeNode(
            run: Fixture.run("r1", prompt: sent, state: .running, createdAt: Date()), depth: 0, childCount: 0,
            isFocus: false)
        #expect(node.title == "帮我存一下")
    }

    @Test("“…”菜单：Botin 资料、在对话中查找一组，计划、新建计划、产出物、模型路由一组，有任务在跑时最后是停止")
    func conversationMenu() {
        let idle = ConversationMenu.sections(instanceID: writer, canStop: false)
        #expect(
            idle == [
                [.open(.instance(writer)), .find],
                [
                    .open(.plans(instanceID: writer)), .open(.newPlan(instanceID: writer)),
                    .open(.artifacts(instanceID: writer)), .open(.modelRoutes(writer)),
                ],
            ])
        let busy = ConversationMenu.sections(instanceID: writer, canStop: true)
        #expect(busy.last == [.stop])
        #expect(busy.flatMap { $0 }.filter(\.isDestructive) == [.stop])
        #expect(ConversationMenuItem.open(.instance(writer)).title(.chinese) == "Botin 资料")
        #expect(ConversationMenuItem.open(.instance(writer)).systemImage == "person.crop.circle")
        #expect(ConversationMenuItem.stop.title(.chinese) == "停止当前任务")
        #expect(ConversationMenuItem.open(.artifacts(instanceID: writer)).systemImage == "folder")
        #expect(ConversationMenuItem.find.title(.chinese) == "在对话中查找")
        #expect(ConversationMenuItem.find.systemImage == "magnifyingglass")
        #expect(
            ConversationMenu.sections(instanceID: writer, canFind: false, canStop: false).first == [
                .open(.instance(writer))
            ])
        // 每一项的图标都是认得的（不是兜底的 chevron）。
        #expect(busy.flatMap { $0 }.allSatisfy { $0.systemImage != "chevron.right" })
    }

    @Test("长按菜单：引用回复（agent 的还有标为未读）一组；复制、选择文本、复制运行 ID 一组；agent 的再分享、举报，用户的再发一次")
    func messageMenu() {
        #expect(
            MessageMenuLayout.agentOutput(canQuote: true, hasRunID: true, canReport: true)
                == [[.quote, .markUnread], [.copy, .selectText, .copyRunID], [.share], [.report]])
        #expect(
            MessageMenuLayout.agentOutput(canQuote: false, hasRunID: false, canReport: false)
                == [[.copy, .selectText], [.share]])
        #expect(
            MessageMenuLayout.userMessage(canQuote: true, hasRunID: true, canSendAgain: true)
                == [[.quote], [.copy, .selectText, .copyRunID], [.sendAgain]])
        #expect(
            MessageMenuLayout.userMessage(canQuote: false, hasRunID: false, canSendAgain: false) == [
                [.copy, .selectText]
            ])
        #expect(MessageMenuAction.allCases.filter(\.isDestructive) == [.report])
        #expect(MessageMenuAction.allCases.filter(\.isComingSoon) == [.markUnread])
        #expect(MessageMenuAction.markUnread.title(.chinese) == "标为未读")
        #expect(MessageMenuAction.quote.title(.chinese) == "引用回复")
        #expect(MessageMenuAction.copyRunID.title(.english) == "Copy Run ID")
        #expect(Set(MessageMenuAction.allCases.map(\.systemImage)).count == MessageMenuAction.allCases.count)
    }
}

@MainActor
@Suite("对话页：引用回复、第一次进来、菜单的状态")
struct ConversationLayoutModelTests {
    @Test("引用回复：引用块算进字数；只有引用不能发；发出去的是引用 + 正文，发完引用和输入框都清掉")
    func sendWithQuote() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: reviewer)
        await model.start()
        model.setQuote("  CI 挂在 lint 上  ")
        #expect(model.quotedText == "CI 挂在 lint 上")
        #expect(!model.canSend && model.promptLength == 0, "只有引用、没有正文不能发")
        model.draft = "怎么修？"
        #expect(model.outgoingText == "> CI 挂在 lint 上\n\n怎么修？")
        #expect(model.promptLength == model.outgoingText.unicodeScalars.count)
        await model.send()
        let runID = try #require(model.lastSentRunID)
        #expect(mock.state.runs.first { $0.id == runID }?.prompt == "> CI 挂在 lint 上\n\n怎么修？")
        #expect(model.draft.isEmpty && model.quotedText == nil)
        // 取消引用。
        model.setQuote("另一段")
        model.clearQuote()
        #expect(model.quotedText == nil)
        model.setQuote("   ")
        #expect(model.quotedText == nil)
    }

    @Test("引用回复：引用块算进 32000 字上限")
    func quoteCountsTowardLimit() async {
        let model = ConversationModel(client: ConversationFixture.mock(), instanceID: writer)
        await model.load()
        model.draft = String(repeating: "a", count: ConversationModel.maxPromptLength - 3)
        #expect(model.canSend)
        model.setQuote("引用")
        #expect(model.isOverLimit && !model.canSend)
    }

    @Test("引用回复：发送失败时引用和输入框都留着；密码拦截存好后引用并进输入框")
    func quoteSurvivesFailureAndInterception() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: reviewer)
        await model.start()
        model.setQuote("原来的回复")
        model.draft = "接着做"
        mock.failNext(with: .network(message: "offline"))
        await model.send()
        #expect(model.sendError != nil)
        #expect(model.draft == "接着做" && model.quotedText == "原来的回复")
        model.clearSendError()
        // 正文里有像密码的：拦下的消息是带引用的整段；存进保险箱后放回输入框的也是整段，引用不再单独带。
        model.draft = "用这个令牌推送：ghp_" + String(repeating: "a1B2", count: 6)
        await model.send()
        let interception = try #require(model.interception)
        #expect(interception.message.hasPrefix("> 原来的回复\n\n"))
        let entry = try #require(interception.entries.first)
        #expect(await model.saveSecret(entry.id))
        #expect(model.quotedText == nil)
        #expect(model.draft.hasPrefix("> 原来的回复\n\n") && !model.draft.contains("ghp_"))
        #expect(model.outgoingText == model.draft)
    }

    @Test("第一次进来：没配默认模型时是“去配置”卡片，配好了是示例任务；有任务、找不到、只看本次过程时没有")
    func starter() async throws {
        let mock = ConversationFixture.mock()
        let instance = try await mock.adopt(agentID: DemoData.hermesAgentID, name: "资料员", harness: nil)
        let fresh = ConversationModel(client: mock, instanceID: instance.id)
        #expect(fresh.starter == nil, "还没加载")
        await fresh.start()
        #expect(fresh.starter == .needsSetup)
        mock.update {
            $0.routes[instance.id] = [
                ModelRoute(alias: ModelRoute.mainAlias, credentialID: DemoData.deepseekCredentialID, upstreamModel: "m")
            ]
        }
        await fresh.start()
        #expect(fresh.starter == .suggestions)
        let suggestion = try #require(ConversationText.starterSuggestions(.chinese).first)
        fresh.draft = "原来的字"
        fresh.useSuggestion(suggestion)
        #expect(fresh.draft == suggestion && fresh.canSend)
        #expect(
            ConversationText.starterSuggestions(.english).count == ConversationText.starterSuggestions(.chinese).count)
        let busy = ConversationModel(client: mock, instanceID: writer)
        await busy.start()
        #expect(busy.starter == nil)
        let gone = ConversationModel(client: mock, instanceID: "gone")
        await gone.start()
        #expect(gone.starter == nil)
        #expect(ConversationText.welcome(instanceName: "资料员", language: .chinese).hasPrefix("给 资料员 布置第一个任务。"))
        #expect(
            ConversationText.starterTitle(instanceName: "Scout", language: .english)
                == "What should Scout help with first?")
    }

    @Test("“…”菜单跟着状态变：有任务在跑才有停止；时间分隔按视图模型的“现在”算")
    func menuFollowsState() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        #expect(model.activeRunID != nil)
        #expect(model.menuSections.last == [.stop])
        let idle = ConversationModel(client: mock, instanceID: reviewer)
        await idle.start()
        if idle.activeRunID == nil {
            #expect(!idle.menuSections.flatMap { $0 }.contains(.stop))
        }
        let labels = model.timeSeparators(language: .chinese)
        #expect(!labels.isEmpty)
        #expect(labels[model.turns.first?.id ?? ""] != nil, "第一组前面总有")
    }
}
