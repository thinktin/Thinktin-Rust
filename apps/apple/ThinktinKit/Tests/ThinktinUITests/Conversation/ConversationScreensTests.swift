import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 对话与运行过程（WBS 12.5）的界面：每个页面在浅色中文、深色英文、大字号下都能布局；每一种时间线项、卡片能出图；
/// 密码拦截、举报这两个弹层能布局。视图模型的逻辑在 ThinktinKitTests 的 ConversationScreen 里测。
@MainActor
@Suite("对话与运行过程的界面")
struct ConversationScreensTests {
    static let routes: [AppRoute] = [
        .home, .conversation(DemoData.writerID), .conversation(DemoData.reviewerID), .conversation("gone"),
        .run(DemoData.weeklyRunID), .run(DemoData.postRunID), .run(DemoData.reviewRunID), .run("gone"),
        .runTree(DemoData.publishRunID), .activeRuns,
    ]

    @Test("每个页面都能布局（中文浅色、英文深色）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(ConversationDestination(route: route).previewShell())
            hostAndLayout(ConversationDestination(route: route).previewShell(.english, scheme: .dark))
        }
    }

    @Test("大字号（AX3）也能布局")
    func accessibilitySizes() {
        for route in Self.routes {
            hostAndLayout(ConversationDestination(route: route).previewShell().dynamicTypeSize(.accessibility3))
        }
    }

    @Test("几种演示数据：流式输出中、等 key、委派的运行树、没有实例的首页")
    func variants() {
        hostAndLayout(
            ConversationScreen(instanceID: DemoData.writerID).previewShell(
                client: ConversationPreviewClients.streaming()))
        hostAndLayout(
            ConversationScreen(instanceID: DemoData.reviewerID)
                .previewShell(.english, scheme: .dark, client: ConversationPreviewClients.waitingForKey()))
        hostAndLayout(
            RunTreeScreen(runID: ConversationPreviewClients.childRunID)
                .previewShell(client: ConversationPreviewClients.delegated()))
        hostAndLayout(ConversationHomeScreen().previewShell(client: ShellPreviewClients.empty()))
        hostAndLayout(
            RunProcessScreen(
                model: ConversationModel(
                    client: MockClient(autoReply: false), instanceID: DemoData.writerID,
                    focusRunID: DemoData.weeklyRunID)
            ).previewShell(.english, scheme: .dark))
    }

    @Test("弹层：密码拦截、举报")
    func sheets() {
        hostAndLayout(SecretInterceptionPreview(message: ConversationPreviewData.secretMessage).previewShell())
        hostAndLayout(
            SecretInterceptionPreview(message: ConversationPreviewData.secretMessage)
                .previewShell(.english, scheme: .dark))
        hostAndLayout(
            ContentReportSheet(client: MockClient(autoReply: false), target: .run(DemoData.weeklyRunID)).previewShell())
        hostAndLayout(
            ContentReportSheet(
                client: MockClient(autoReply: false),
                target: .artifact(runID: DemoData.weeklyRunID, artifactID: DemoData.weeklyArtifactID)
            ).previewShell(.english, scheme: .dark))
    }

    @Test("卡片和状态行在时间线里能布局（审批、保险箱、全部）")
    func cards() {
        hostAndLayout(ConversationCardsPreview(instanceID: DemoData.writerID).previewShell())
        hostAndLayout(ConversationCardsPreview(instanceID: DemoData.reviewerID).previewShell(.english, scheme: .dark))
        hostAndLayout(ConversationCardsPreview(instanceID: DemoData.writerID, showsAll: true).previewShell())
    }

    @Test("不依赖视图模型的项能出图：消息、思考、工具调用、待办、Markdown、系统提示")
    func render() {
        let reply = ConversationItem(
            id: "seq-1", runID: DemoData.weeklyRunID, createdAt: Date(),
            content: .assistantText(AssistantText(text: ConversationPreviewData.markdownSample)))
        renderInBothAppearances(
            UserMessageView(message: UserMessage(text: "帮我把这周的周报整理成要点。"), isAIGenerated: false))
        renderInBothAppearances(
            UserMessageView(
                message: UserMessage(text: String(repeating: "很长的任务。", count: 200), source: .delegate),
                isAIGenerated: true))
        renderInBothAppearances(
            AssistantTextView(
                item: reply, text: AssistantText(text: ConversationPreviewData.markdownSample, isStreaming: true),
                blocks: MarkdownParser.parse(ConversationPreviewData.markdownSample), onReport: { _ in }))
        renderInBothAppearances(
            ThoughtView(item: reply, thought: Thought(text: "先看看工作区。", isStreaming: true), onReport: { _ in }))
        for card in ConversationPreviewData.toolCards {
            renderInBothAppearances(ToolCallCardView(card: card))
        }
        renderInBothAppearances(AgentPlanCardView(card: ConversationPreviewData.agentPlan))
        renderInBothAppearances(MarkdownView(blocks: MarkdownParser.parse(ConversationPreviewData.markdownSample)))
        let kinds: [SystemNotice.Kind] = [
            .agentError, .sessionLost, .agentExited(willRestart: true), .logTruncated, .vaultUsed(["github"]),
            .turnStopped(.maxTokens),
        ]
        for kind in kinds {
            renderInBothAppearances(SystemNoticeView(notice: SystemNotice(kind: kind, message: "detail")))
        }
        renderInBothAppearances(HistoryNoteView(note: .expired))
        renderInBothAppearances(
            HistoryRecordView(
                note: .expired, summary: "## 结果\n\n- 做完了\n- 发到了群里", runID: DemoData.weeklyRunID,
                onReport: { _ in }))
        renderInBothAppearances(
            HistoryRecordView(note: .notCached, summary: nil, runID: DemoData.weeklyRunID, onReport: { _ in }))
        renderInBothAppearances(
            UserMessageView(message: UserMessage(text: "再整理一次周报。"), isAIGenerated: false, onSendAgain: {}))
    }

    @Test("失败、取消的状态行带“重试”；运行详情里等审批的卡片；agent 内容里的链接接管")
    func retryAndLinks() {
        for state in [RunState.failed, .cancelled] {
            hostAndLayout(
                RunStatusLineView(
                    runID: DemoData.reviewRunID, line: RunStatusLine(state: state, error: "boom"), instanceState: nil,
                    onAction: { _ in }, onRetry: {}
                )
                .previewShell())
        }
        hostAndLayout(RunDetailScreen(runID: DemoData.postRunID).previewShell(.english, scheme: .dark))
        hostAndLayout(
            MarkdownView(blocks: MarkdownParser.parse("看 [计划](thinktin://plan/abc) 和 [文档](https://example.com)"))
                .conversationLinkHandling(Router())
                .previewShell())
    }

    @Test("运行状态行：每一种状态（含等待原因码）都能布局")
    func statusLines() {
        var lines = RunState.knownCases.map { RunStatusLine(state: $0, reason: "原因", attempt: 2) }
        lines += RunWaitCode.knownCases.map { RunStatusLine(state: .waitingQuota, reason: "key 失效", waitCode: $0) }
        for line in lines {
            hostAndLayout(
                RunStatusLineView(runID: DemoData.postRunID, line: line, instanceState: .archived) { _ in }
                    .previewShell())
        }
    }

    @Test("本机验证：注入的优先；Mock 客户端直接通过")
    func gateResolution() {
        let mock = MockClient(autoReply: false)
        #expect(ConversationGate.resolve(nil, client: mock) is PassthroughBiometricGate)
        let observed = ObservedClient(mock) { _ in }
        #expect(ConversationGate.resolve(nil, client: observed) is PassthroughBiometricGate)
        let injected = ScriptedBiometricGate(result: .failed)
        #expect(ConversationGate.resolve(injected, client: mock) as? ScriptedBiometricGate === injected)
    }

    @Test("行内 Markdown：解析失败按原文")
    func inlineMarkdown() {
        #expect(!String(InlineText.attributed("**加粗** 和 `代码`").characters).isEmpty)
        #expect(String(InlineText.attributed("纯文字").characters) == "纯文字")
    }
}
