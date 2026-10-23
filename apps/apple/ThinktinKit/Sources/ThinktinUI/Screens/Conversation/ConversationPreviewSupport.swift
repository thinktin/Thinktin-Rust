import SwiftUI
import ThinktinKit

// 预览和界面测试用的数据（12.5）。

/// 静态的演示内容。
enum ConversationPreviewData {
    /// 各种块都有的一段回复。
    static let markdownSample = """
        ## 这周的进展

        后端的**事件流续传**做完了，`client-core` 也接上了。详情见 [设计文档](https://example.com/design)。

        1. 断线重连不丢事件
        2. 重置后整页重载
           - 运行记录保留
        - [x] 合并到主干
        - [ ] 发版说明

        > 下周开始做实时活动。

        ```swift
        let model = ConversationModel(client: client, instanceID: id)
        await model.start()
        ```

        | 模块 | 状态 |
        |---|---|
        | 后端 | 完成 |
        | iOS | 进行中 |

        ---

        有问题随时找我。
        """

    /// 几种工具调用卡片：执行命令（完成）、读文件（进行中）、改文件（失败）、平台工具（建计划）。
    static let toolCards: [ToolCallCard] = [
        ToolCallCard(
            toolCallID: "t1", title: "运行测试", kind: "execute", status: .completed,
            raw: [
                "rawInput": ["command": ["swift", "test"]],
                "content": [
                    ["type": "content", "content": ["type": "text", "text": "Test run with 587 tests passed"]]
                ],
            ]),
        ToolCallCard(
            toolCallID: "t2", title: "读取 notes/weekly.md", kind: "read", status: .inProgress,
            raw: ["rawInput": ["path": "notes/weekly.md"]]),
        ToolCallCard(
            toolCallID: "t3", title: "修改 Package.swift", kind: "edit", status: .failed,
            raw: ["rawInput": ["path": "Package.swift"], "rawOutput": "permission denied"]),
        ToolCallCard(
            toolCallID: "p1", title: "schedule_create", raw: ["title": "每周依赖检查", "cron": "30 10 * * 1"],
            platformCategory: .plan),
    ]

    static let agentPlan = AgentPlanCard(entries: [
        AgentPlanEntry(content: "读周报草稿", status: .completed),
        AgentPlanEntry(content: "按项目分组", status: .inProgress),
        AgentPlanEntry(content: "发到研发群", status: .pending),
    ])

    /// 带 GitHub 令牌和私钥的消息（密码拦截的预览）。
    static let secretMessage =
        "用这个令牌推送：ghp_" + String(repeating: "a1B2", count: 6)
        + "\n部署用：\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
}

/// 几种演示客户端。
enum ConversationPreviewClients {
    /// 委派的子运行（`delegated()` 里的）。
    static let childRunID: RunID = "0192f3a0-0000-7000-8000-00000000c201"

    /// 写作助手正在输出：回放一段带思考、工具调用、待办清单、Markdown 的回答（不停地循环不好看，播一次）。
    static func streaming() -> MockClient {
        var state = DemoData.state()
        let runID: RunID = "0192f3a0-0000-7000-8000-00000000c101"
        state.runs.append(
            Run(
                id: runID, instanceID: DemoData.writerID, prompt: "整理一下这周的进展，写成周报。", state: .running,
                createdAt: Date(), startedAt: Date()))
        let mock = MockClient(state: state, stepDelay: 0.6, autoReply: false)
        mock.setScript(
            MockEventScript(
                runID: runID,
                steps: [
                    .event(.runState, payload: ["state": "running", "attempt": 1]),
                    .event(.turnStarted, payload: [:]),
                    .event(.agentThought, payload: ["text": "先看看工作区里的笔记，"]),
                    .event(
                        .agentPlan,
                        payload: [
                            "entries": [
                                ["content": "读笔记", "status": "in_progress"], ["content": "写周报", "status": "pending"],
                            ]
                        ]),
                    .event(
                        .toolCall,
                        payload: [
                            "tool_call_id": "tc-s-1", "title": "读取 notes/", "kind": "read", "status": "in_progress",
                            "raw": ["rawInput": ["path": "notes/"]],
                        ]),
                    .event(.toolCallUpdate, payload: ["tool_call_id": "tc-s-1", "status": "completed"]),
                    .event(.agentMessage, payload: ["text": "## 这周的进展\n\n"]),
                    .event(.agentMessage, payload: ["text": "后端的**事件流续传**做完了。\n\n- 断线重连不丢事件\n"]),
                    .event(.agentMessage, payload: ["text": "- 重置后整页重载\n\n```swift\nawait model.start()\n"]),
                ]), for: DemoData.writerID)
        return mock
    }

    /// 代码审查在等 key（key 无效）：状态行给“去处理”。
    static func waitingForKey() -> MockClient {
        var state = DemoData.state()
        if let i = state.runs.firstIndex(where: { $0.id == DemoData.publishRunID }) {
            state.runs[i].state = .waitingQuota
            state.runs[i].stateReason = "DeepSeek 的 key 无效，请换一把"
            state.runs[i].waitCode = .invalid
        }
        state.events[DemoData.reviewerID] = (state.events[DemoData.reviewerID] ?? []).filter {
            $0.runID != DemoData.publishRunID || $0.kind == .agentMessage
        }
        state.vaultRequests = []
        return MockClient(state: state, autoReply: false)
    }

    /// npm 发布委派了一个子运行给写作助手（运行树有两层）。
    static func delegated() -> MockClient {
        var state = DemoData.state()
        state.runs.append(
            Run(
                id: childRunID, instanceID: DemoData.writerID, parentRunID: DemoData.publishRunID,
                rootRunID: DemoData.publishRunID, source: .delegate, prompt: "写 0.4.0 的发布说明", state: .running,
                createdAt: Date(), startedAt: Date()))
        return MockClient(state: state, autoReply: false)
    }
}

/// 只显示一个实例对话里的卡片（预览、界面测试用）：用环境里的客户端建视图模型，`showsAll` 时整个时间线都显示。
struct ConversationCardsPreview: View {
    let instanceID: InstanceID
    var showsAll = false

    @Environment(\.client) private var client

    var body: some View {
        Content(client: client, instanceID: instanceID, showsAll: showsAll)
    }

    private struct Content: View {
        @State private var model: ConversationModel
        let showsAll: Bool

        init(client: any ClientProtocol, instanceID: InstanceID, showsAll: Bool) {
            _model = State(initialValue: ConversationModel(client: client, instanceID: instanceID))
            self.showsAll = showsAll
        }

        var body: some View {
            let model = self.model
            ScrollViewReader { proxy in
                ScrollView {
                    if showsAll {
                        ConversationTimeline(model: model, instanceState: nil, proxy: proxy, onReport: { _ in }) {
                            EmptyView()
                        }
                        .padding(Metrics.Spacing.m)
                    } else {
                        VStack(spacing: Metrics.Spacing.s) {
                            ForEach(model.turns) { turn in
                                ForEach(turn.items) { item in
                                    switch item.content {
                                    case .approval(let card): ApprovalCardView(item: item, card: card, model: model)
                                    case .vaultRequest(let card): VaultRequestCardView(card: card, model: model)
                                    default: EmptyView()
                                    }
                                }
                            }
                        }
                        .padding(Metrics.Spacing.m)
                    }
                }
            }
            .background(Theme.paper)
            .task { await model.start() }
        }
    }
}

/// 直接显示密码拦截弹层（用环境里的客户端建视图模型，输入一条带密码的消息再“发送”）。
struct SecretInterceptionPreview: View {
    let message: String

    @Environment(\.client) private var client

    var body: some View {
        Content(client: client, message: message)
    }

    private struct Content: View {
        @State private var model: ConversationModel
        let message: String

        init(client: any ClientProtocol, message: String) {
            _model = State(initialValue: ConversationModel(client: client, instanceID: DemoData.reviewerID))
            self.message = message
        }

        var body: some View {
            let model = self.model
            SecretInterceptionSheet(model: model, onOpenRoute: { _ in })
                .task {
                    await model.load()
                    model.draft = message
                    await model.send()
                }
        }
    }
}
