import Foundation

/// 演示数据：3 个 agent、2 个实例、几次运行（含进行中的审批和保险箱请求）、计划、收件箱、模型 key、保险箱条目。
/// 预览、截图、Linux 上的测试都用它。时间都相对 `now`，看起来总是“最近”。
public enum DemoData {
    // MARK: 固定 id（测试里直接引用）

    public static let userID: UserID = "0192f3a0-0000-7000-8000-000000000001"
    public static let deviceID: DeviceID = "0192f3a0-0000-7000-8000-0000000000d1"

    public static let claudeAgentID: AgentID = "claude"
    public static let codexAgentID: AgentID = "codex"
    public static let hermesAgentID: AgentID = "hermes"

    /// “写作助手”（Claude）。
    public static let writerID: InstanceID = "0192f3a0-0000-7000-8000-000000000101"
    /// “代码审查”（Codex）。
    public static let reviewerID: InstanceID = "0192f3a0-0000-7000-8000-000000000102"

    /// 周报整理（已完成）。
    public static let weeklyRunID: RunID = "0192f3a0-0000-7000-8000-000000000201"
    /// 计划触发的通知汇总（已完成）。
    public static let digestRunID: RunID = "0192f3a0-0000-7000-8000-000000000202"
    /// 发到团队群（等审批）。
    public static let postRunID: RunID = "0192f3a0-0000-7000-8000-000000000203"
    /// PR 检查（失败）。
    public static let reviewRunID: RunID = "0192f3a0-0000-7000-8000-000000000204"
    /// npm 发布（运行中，等保险箱）。
    public static let publishRunID: RunID = "0192f3a0-0000-7000-8000-000000000205"

    public static let pendingApprovalID: ApprovalID = "0192f3a0-0000-7000-8000-000000000301"
    public static let digestPlanID: PlanID = "0192f3a0-0000-7000-8000-000000000401"
    public static let agentPlanID: PlanID = "0192f3a0-0000-7000-8000-000000000402"
    public static let claudeCredentialID: CredentialID = "0192f3a0-0000-7000-8000-000000000501"
    public static let deepseekCredentialID: CredentialID = "0192f3a0-0000-7000-8000-000000000502"
    public static let qwenCredentialID: CredentialID = "0192f3a0-0000-7000-8000-000000000503"
    public static let weeklyArtifactID: ArtifactID = "0192f3a0-0000-7000-8000-000000000601"
    public static let githubVaultID: VaultItemID = "0192f3a0-0000-7000-8000-000000000701"
    public static let ossVaultID: VaultItemID = "0192f3a0-0000-7000-8000-000000000702"
    public static let npmVaultRequestID: VaultRequestID = "0192f3a0-0000-7000-8000-000000000801"
    public static let feishuChannelID: ImChannelID = "0192f3a0-0000-7000-8000-000000000901"

    /// 审批卡片上的 request_id。
    public static let pendingPermissionRequestID = "perm-post-1"

    // MARK: 整套状态

    /// 演示用的完整状态。`signedIn` 为 false 时从登录页开始（验证码 `123456`）。
    public static func state(now: Date = Date(), signedIn: Bool = true) -> MockState {
        let ago = { (seconds: TimeInterval) in now.addingTimeInterval(-seconds) }
        let min: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400

        let user = User(
            id: userID, phone: "+8613800138000", displayName: "张三", status: .active, locale: .zhCN,
            createdAt: ago(40 * day))

        let instances = [
            Instance(
                id: writerID, agentID: claudeAgentID, agentVersion: "0.90.0", harness: "acp", name: "写作助手",
                state: .running, createdAt: ago(30 * day), lastActiveAt: ago(2 * min)),
            Instance(
                id: reviewerID, agentID: codexAgentID, agentVersion: "2.2.1", harness: "acp", name: "代码审查",
                state: .running, createdAt: ago(12 * day), lastActiveAt: ago(10 * min)),
        ]

        // 运行（时间从早到晚）。
        let weekly = Run(
            id: weeklyRunID, instanceID: writerID, source: .user, prompt: "帮我把这周的周报整理成要点，按项目分组。",
            state: .succeeded, tokensUsed: 18_420, summary: "这周的周报要点整理好了，按项目分了三组。",
            createdAt: ago(26 * hour), startedAt: ago(26 * hour - 5), finishedAt: ago(26 * hour - 95))
        let digest = Run(
            id: digestRunID, instanceID: writerID, planID: digestPlanID, source: .plan,
            prompt: "汇总昨天以来的 GitHub 通知，只列需要我处理的。", state: .succeeded, tokensUsed: 6_310,
            summary: "有 3 条需要你处理。", createdAt: ago(3 * hour), startedAt: ago(3 * hour - 4),
            finishedAt: ago(3 * hour - 50))
        let post = Run(
            id: postRunID, instanceID: writerID, source: .user, prompt: "把整理好的周报发到团队群。",
            state: .waitingApproval, stateReason: "发送消息到「研发群」", tokensUsed: 2_140, createdAt: ago(3 * min),
            startedAt: ago(3 * min - 3))
        let review = Run(
            id: reviewRunID, instanceID: reviewerID, source: .user, prompt: "检查 PR #42 的改动有没有并发问题。",
            state: .failed, stateReason: "upstream rate limited", attempt: 2, tokensUsed: 9_870,
            error: "model gateway: credential rate limited", createdAt: ago(5 * hour), startedAt: ago(5 * hour - 6),
            finishedAt: ago(5 * hour - 300))
        let publish = Run(
            id: publishRunID, instanceID: reviewerID, source: .user, prompt: "发布 0.4.0 到 npm。", state: .running,
            tokensUsed: 1_020, createdAt: ago(12 * min), startedAt: ago(12 * min - 4))

        var writerEvents = EventBuilder(instanceID: writerID)
        // 周报
        writerEvents.add(.runState, weeklyRunID, ["state": "running"], at: weekly.startedAt!)
        writerEvents.add(.turnStarted, weeklyRunID, ["run_id": .string(weeklyRunID.rawValue)], at: weekly.startedAt!)
        writerEvents.add(
            .agentThought, weeklyRunID, ["text": "用户要按项目分组的周报要点。先看看工作区里的周报草稿。"],
            at: weekly.startedAt!.addingTimeInterval(2))
        writerEvents.add(
            .toolCall, weeklyRunID,
            [
                "tool_call_id": "tc-read-1", "title": "读取 notes/weekly.md", "kind": "read", "status": "pending",
                "raw": ["toolCallId": "tc-read-1", "rawInput": ["path": "notes/weekly.md"]],
            ], at: weekly.startedAt!.addingTimeInterval(4))
        writerEvents.add(
            .toolCallUpdate, weeklyRunID,
            [
                "tool_call_id": "tc-read-1", "status": "completed",
                "raw": ["content": [["type": "text", "text": "（412 行）"]]],
            ],
            at: weekly.startedAt!.addingTimeInterval(5))
        writerEvents.add(
            .agentMessage, weeklyRunID, ["text": "这周的周报要点整理好了，按项目分了三组：\n\n"],
            at: weekly.startedAt!.addingTimeInterval(20))
        writerEvents.add(
            .agentMessage, weeklyRunID,
            [
                "text": """
                **Thinktin 后端**
                - 事件流支持断线续传，补发不重复
                - 模型网关加了降级链（最多 3 把备用 key）

                **iOS App**
                - ThinktinKit 的领域模型和 Mock 客户端
                - 对话页的事件归并

                **运维**
                - 预发环境升级到新版本的沙箱模板
                """
            ], at: weekly.startedAt!.addingTimeInterval(60))
        writerEvents.add(
            .artifactPublished, weeklyRunID,
            ["artifact_id": .string(weeklyArtifactID.rawValue), "name": "周报要点.md", "version": 1, "size": 1_536],
            at: weekly.startedAt!.addingTimeInterval(80))
        writerEvents.add(
            .agentUsage, weeklyRunID, ["raw": ["input_tokens": 15_200, "output_tokens": 3_220]],
            at: weekly.startedAt!.addingTimeInterval(85))
        writerEvents.add(.turnEnded, weeklyRunID, ["stop_reason": "end_turn"], at: weekly.finishedAt!)
        writerEvents.add(.runState, weeklyRunID, ["state": "succeeded"], at: weekly.finishedAt!)
        // 计划触发的通知汇总
        writerEvents.add(.runState, digestRunID, ["state": "running"], at: digest.startedAt!)
        writerEvents.add(.turnStarted, digestRunID, [:], at: digest.startedAt!)
        writerEvents.add(
            .toolCall, digestRunID,
            ["tool_call_id": "tc-gh-1", "title": "gh api notifications", "kind": "execute", "status": "completed"],
            at: digest.startedAt!.addingTimeInterval(8))
        writerEvents.add(
            .agentMessage, digestRunID,
            [
                "text":
                    "有 3 条需要你处理：\n\n1. **thinktin/server#311** 请你评审：事件表分区\n2. **thinktin/app#57** 你被提到：推送文案\n3. **thinktin/sdk#12** CI 失败：Node 22 上的测试"
            ], at: digest.startedAt!.addingTimeInterval(40))
        writerEvents.add(.turnEnded, digestRunID, ["stop_reason": "end_turn"], at: digest.finishedAt!)
        writerEvents.add(.runState, digestRunID, ["state": "succeeded"], at: digest.finishedAt!)
        // 发到团队群（等审批）
        writerEvents.add(.runState, postRunID, ["state": "running"], at: post.startedAt!)
        writerEvents.add(.turnStarted, postRunID, [:], at: post.startedAt!)
        writerEvents.add(
            .agentMessage, postRunID, ["text": "好的，我把周报要点发到飞书的「研发群」。"],
            at: post.startedAt!.addingTimeInterval(6))
        let postToolCall: JSONValue = [
            "toolCallId": "tc-post-1", "title": "发送消息到「研发群」", "kind": "execute",
            "rawInput": ["channel": "研发群", "file": "周报要点.md"],
        ]
        writerEvents.add(
            .toolCall, postRunID,
            [
                "tool_call_id": "tc-post-1", "title": "发送消息到「研发群」", "kind": "execute", "status": "pending",
                "raw": postToolCall,
            ],
            at: post.startedAt!.addingTimeInterval(8))
        writerEvents.add(
            .permissionRequested, postRunID,
            [
                "request_id": .string(pendingPermissionRequestID), "title": "发送消息到「研发群」",
                "options": approvalOptionsJSON, "tool_call": postToolCall,
            ], at: post.startedAt!.addingTimeInterval(9))
        writerEvents.add(
            .runState, postRunID, ["state": "waiting_approval", "reason": "发送消息到「研发群」"],
            at: post.startedAt!.addingTimeInterval(9))

        var reviewerEvents = EventBuilder(instanceID: reviewerID)
        // PR 检查（失败）
        reviewerEvents.add(.runState, reviewRunID, ["state": "running"], at: review.startedAt!)
        reviewerEvents.add(
            .toolCall, reviewRunID,
            ["tool_call_id": "tc-diff-1", "title": "git diff main...pr-42", "kind": "execute", "status": "completed"],
            at: review.startedAt!.addingTimeInterval(10))
        reviewerEvents.add(
            .agentMessage, reviewRunID, ["text": "改动集中在 `executor.rs`，我先看锁的顺序。"],
            at: review.startedAt!.addingTimeInterval(30))
        reviewerEvents.add(
            .agentError, reviewRunID, ["message": "model gateway: credential rate limited"],
            at: review.startedAt!.addingTimeInterval(120))
        reviewerEvents.add(
            .runState, reviewRunID, ["state": "backoff", "reason": "upstream rate limited", "attempt": 1],
            at: review.startedAt!.addingTimeInterval(121))
        reviewerEvents.add(
            .runState, reviewRunID, ["state": "failed", "reason": "upstream rate limited", "attempt": 2],
            at: review.finishedAt!)
        // npm 发布（等保险箱）
        reviewerEvents.add(.runState, publishRunID, ["state": "running"], at: publish.startedAt!)
        reviewerEvents.add(.turnStarted, publishRunID, [:], at: publish.startedAt!)
        reviewerEvents.add(
            .agentMessage, publishRunID, ["text": "发布需要 npm 的发布令牌，我先向你要一下（只存进保险箱，我拿不到明文）。"],
            at: publish.startedAt!.addingTimeInterval(5))
        reviewerEvents.add(
            .platformToolCall, publishRunID,
            [
                "call_id": "pc-vault-1", "name": "vault_request",
                "arguments": ["name": "npm", "purpose": "发布 @thinktin/sdk 0.4.0 到 npm", "fields": ["password"]],
            ], at: publish.startedAt!.addingTimeInterval(7))
        reviewerEvents.add(
            .vaultRequested, publishRunID,
            [
                "request_id": .string(npmVaultRequestID.rawValue), "name": "npm",
                "purpose": "发布 @thinktin/sdk 0.4.0 到 npm", "fields": ["password"],
            ], at: publish.startedAt!.addingTimeInterval(8))

        let approvals = [
            Approval(
                id: pendingApprovalID, runID: postRunID, instanceID: writerID, title: "发送消息到「研发群」",
                options: approvalOptions, toolCallJSON: postToolCall.compactString(), state: .pending,
                expiresAt: post.startedAt!.addingTimeInterval(24 * hour),
                createdAt: post.startedAt!.addingTimeInterval(9))
        ]

        let plans = [
            Plan(
                id: digestPlanID, instanceID: writerID, title: "每日 GitHub 通知汇总",
                goal: "每个工作日早上汇总 GitHub 通知，只列需要我处理的。", createdBy: .user, revision: 1,
                policyJSON:
                    #"{"preauthorized_tools":["read","search","fetch"],"approval_timeout_secs":3600,"on_approval_timeout":"skip","budget":{"max_tokens":50000,"max_duration_secs":1800}}"#,
                createdAt: ago(20 * day),
                triggers: [
                    Trigger(
                        id: "0192f3a0-0000-7000-8000-000000000411",
                        schedule: .cron(expression: "0 9 * * 1-5", timeZone: "Asia/Shanghai"),
                        nextFireAt: now.addingTimeInterval(21 * hour), lastFireAt: ago(3 * hour))
                ]),
            Plan(
                id: agentPlanID, instanceID: reviewerID, title: "每周依赖升级检查",
                goal: "每周一上午检查依赖有没有安全更新，有的话开 PR。", createdBy: .agent, awaitingConfirmation: true,
                revision: 2, createdAt: ago(2 * day),
                triggers: [
                    Trigger(
                        id: "0192f3a0-0000-7000-8000-000000000412",
                        schedule: .cron(expression: "30 10 * * 1", timeZone: "Asia/Shanghai"), isEnabled: true)
                ]),
        ]

        let inbox = [
            InboxItem(
                id: "0192f3a0-0000-7000-8000-000000001001", instanceID: writerID, runID: postRunID,
                approvalID: pendingApprovalID, kind: .approval, title: "写作助手 等你审批", body: "发送消息到「研发群」",
                isAIGenerated: true, isRead: false, createdAt: post.startedAt!.addingTimeInterval(9)),
            InboxItem(
                id: "0192f3a0-0000-7000-8000-000000001002", instanceID: reviewerID, runID: publishRunID, kind: .info,
                title: "代码审查 需要账号密码", body: "npm：发布 @thinktin/sdk 0.4.0 到 npm", isAIGenerated: true,
                isRead: false, createdAt: publish.startedAt!.addingTimeInterval(8)),
            InboxItem(
                id: "0192f3a0-0000-7000-8000-000000001003", instanceID: writerID, runID: digestRunID,
                planID: digestPlanID, kind: .runFinished, title: "每日 GitHub 通知汇总 已完成", body: "有 3 条需要你处理。",
                isAIGenerated: true, isRead: true, createdAt: digest.finishedAt!),
            InboxItem(
                id: "0192f3a0-0000-7000-8000-000000001004", instanceID: reviewerID, runID: reviewRunID,
                kind: .runFailed, title: "代码审查 运行失败", body: "上游模型限流，重试 2 次后放弃。", isRead: false,
                createdAt: review.finishedAt!),
            InboxItem(
                id: "0192f3a0-0000-7000-8000-000000001005", instanceID: reviewerID, planID: agentPlanID, kind: .info,
                title: "代码审查 新建了计划，待确认", body: "每周依赖升级检查", isAIGenerated: true, isRead: true,
                createdAt: ago(2 * day)),
        ]

        let credentials = [
            Credential(
                id: claudeCredentialID, vendor: "anthropic", label: "Claude 主力", last4: "Q7mA",
                dailyTokenLimit: 2_000_000, createdAt: ago(30 * day)),
            Credential(
                id: deepseekCredentialID, vendor: "deepseek", label: "DeepSeek", last4: "x9Lk", createdAt: ago(25 * day)
            ),
            Credential(
                id: qwenCredentialID, vendor: "qwen-cn", label: "百炼（停用）", last4: "3hTz", isDisabled: true,
                createdAt: ago(60 * day)),
        ]

        let routes: [InstanceID: [ModelRoute]] = [
            writerID: [
                ModelRoute(
                    alias: "main", credentialID: claudeCredentialID, upstreamModel: "claude-sonnet-5-5",
                    fallbacks: [RouteFallback(credentialID: deepseekCredentialID, upstreamModel: "deepseek-v4-pro")]),
                ModelRoute(alias: "fast", credentialID: claudeCredentialID, upstreamModel: "claude-haiku-5-5"),
            ],
            reviewerID: [
                ModelRoute(alias: "main", credentialID: deepseekCredentialID, upstreamModel: "deepseek-v4-pro")
            ],
        ]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let dailyUsage: [UsageBucket] = (0..<7).reversed().map { i in
            let date = now.addingTimeInterval(-Double(i) * day)
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let key = "\(c.year ?? 0)-\(Formatting.pad2(c.month ?? 1))-\(Formatting.pad2(c.day ?? 1))"
            let scale = [3, 5, 2, 8, 6, 4, 7][i]
            return UsageBucket(
                key: key, requests: 40 * scale, inputTokens: 52_000 * scale, cacheReadTokens: 31_000 * scale,
                cacheWriteTokens: 4_000 * scale, outputTokens: 9_000 * scale, chargedTokens: 70_000 * scale,
                estimatedRequests: i == 3 ? 2 : 0, failedRequests: i == 1 ? 3 : 0)
        }

        let artifactText = """
            # 本周周报要点

            ## Thinktin 后端
            - 事件流支持断线续传，补发不重复
            - 模型网关加了降级链（最多 3 把备用 key）

            ## iOS App
            - ThinktinKit 的领域模型和 Mock 客户端
            - 对话页的事件归并

            ## 运维
            - 预发环境升级到新版本的沙箱模板

            ——本内容由人工智能生成（ThinkTin）
            """
        let artifact = Artifact(
            id: weeklyArtifactID, instanceID: writerID, runID: weeklyRunID, name: "周报要点.md", version: 1,
            contentType: "text/markdown", size: artifactText.utf8.count, sha256: "",
            createdAt: weekly.startedAt!.addingTimeInterval(80))

        let vaultItems = [
            VaultItem(
                id: githubVaultID, name: "github", purpose: "推送代码、开 PR", hasUsername: true, createdAt: ago(15 * day),
                lastUsedAt: ago(5 * hour)),
            VaultItem(
                id: ossVaultID, name: "aliyun-oss", purpose: "上传构建产物到 OSS", hasUsername: true,
                instanceIDs: [reviewerID], createdAt: ago(9 * day)),
        ]

        let vaultRequests = [
            VaultRequest(
                id: npmVaultRequestID, instanceID: reviewerID, runID: publishRunID, name: "npm",
                purpose: "发布 @thinktin/sdk 0.4.0 到 npm", fields: [.password], status: .pending,
                createdAt: publish.startedAt!.addingTimeInterval(8),
                expiresAt: publish.startedAt!.addingTimeInterval(day))
        ]

        let channels = [
            ImChannel(
                id: feishuChannelID, vendor: .feishu, label: "研发群", hint: "x7k2", hasSecret: true,
                events: [.runFinished, .runFailed, .approval], lastSentAt: digest.finishedAt, createdAt: ago(18 * day))
        ]

        return MockState(
            session: signedIn ? demoSession : nil, user: user, agents: agents, instances: instances, routes: routes,
            runs: [weekly, digest, post, review, publish],
            events: [writerID: writerEvents.events, reviewerID: reviewerEvents.events], approvals: approvals,
            plans: plans, inbox: inbox, vendors: vendors, credentials: credentials, dailyUsage: dailyUsage,
            artifacts: [artifact], artifactContents: [weeklyArtifactID: Data(artifactText.utf8)],
            vaultItems: vaultItems, vaultUsernames: [githubVaultID: "zhangsan", ossVaultID: "LTAI5t-demo"],
            vaultRequests: vaultRequests, imChannels: channels)
    }

    /// 演示会话（令牌是假的）。
    public static let demoSession = Session(
        userID: userID, deviceID: deviceID, accessToken: "demo-access-token", refreshToken: "demo-refresh-token")

    public static let agents: [AgentInfo] = [
        AgentInfo(
            id: claudeAgentID, name: "Claude Agent", version: "0.90.0", license: "LicenseRef-Anthropic-Commercial",
            sites: ["cn", "global"], harnesses: ["acp", "cli"], defaultHarness: "acp", versions: ["0.90.0", "0.89.2"]),
        AgentInfo(
            id: codexAgentID, name: "Codex", version: "2.2.2", license: "Apache-2.0", sites: ["cn", "global"],
            harnesses: ["acp"], defaultHarness: "acp", versions: ["2.2.2", "2.2.1", "2.1.0"]),
        AgentInfo(
            id: hermesAgentID, name: "Hermes Agent", version: "0.19.0", license: "MIT", sites: ["cn", "global"],
            harnesses: ["acp"], defaultHarness: "acp", versions: ["0.19.0"]),
    ]

    public static let vendors: [VendorInfo] = [
        VendorInfo(
            id: "anthropic", name: "Anthropic (Claude)", protocols: ["anthropic", "chat"],
            models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]),
        VendorInfo(
            id: "openai", name: "OpenAI", protocols: ["chat", "responses"], models: ["gpt-6-astra", "gpt-6.1-sol"]),
        VendorInfo(
            id: "deepseek", name: "DeepSeek", protocols: ["anthropic", "chat", "responses"],
            models: ["deepseek-v4-pro", "deepseek-flash"]),
        VendorInfo(
            id: "qwen-cn", name: "阿里云百炼（北京）", protocols: ["anthropic", "chat", "responses"],
            models: ["qwen3.8-max", "qwen3.8-flash"], notes: "Token Plan 的 key（sk-tp-）不能用于 API 调用。"),
    ]

    public static let approvalOptions: [ApprovalOption] = [
        ApprovalOption(id: "allow", name: "允许一次", kind: .allowOnce),
        ApprovalOption(id: "allow_always", name: "总是允许", kind: .allowAlways),
        ApprovalOption(id: "reject", name: "拒绝", kind: .rejectOnce),
    ]

    static var approvalOptionsJSON: JSONValue {
        .array(
            approvalOptions.map {
                ["option_id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind.rawValue)]
            })
    }

    // MARK: 回放脚本

    /// 发消息后 agent 的回答（MockClient 自动播放）。消息里有“发”“删除”“部署”“审批”时先请求审批。
    public static func replyScript(for run: Run) -> MockEventScript {
        let prompt = run.prompt
        if needsApproval(prompt) {
            return approvalRequestScript(for: run)
        }
        let quoted = prompt.count > 24 ? String(prompt.prefix(24)) + "…" : prompt
        return MockEventScript(
            runID: run.id,
            steps: [
                .event(.runState, payload: ["state": "starting"]),
                .event(.runState, payload: ["state": "running"]),
                .event(.turnStarted, payload: [:]),
                .event(.agentThought, payload: ["text": "先弄清楚要做什么，"]),
                .event(.agentThought, payload: ["text": "再看看工作区里有什么能用的。"]),
                .event(
                    .toolCall,
                    payload: [
                        "tool_call_id": "tc-\(run.id.rawValue.suffix(4))-1", "title": "搜索工作区", "kind": "search",
                        "status": "pending", "raw": ["rawInput": ["query": .string(quoted)]],
                    ]),
                .event(
                    .toolCallUpdate,
                    payload: ["tool_call_id": "tc-\(run.id.rawValue.suffix(4))-1", "status": "in_progress"]),
                .wait(0.3),
                .event(
                    .toolCallUpdate,
                    payload: [
                        "tool_call_id": "tc-\(run.id.rawValue.suffix(4))-1", "status": "completed",
                        "raw": ["content": [["type": "text", "text": "找到 3 个相关文件"]]],
                    ]),
                .event(.agentMessage, payload: ["text": "收到：「\(quoted)」。"]),
                .event(.agentMessage, payload: ["text": "\n\n我看了工作区里的 3 个相关文件，"]),
                .event(.agentMessage, payload: ["text": "整理如下：\n\n- 要点一\n- 要点二\n- 要点三"]),
                .event(.agentUsage, payload: ["raw": ["input_tokens": 2_400, "output_tokens": 380]]),
                .event(.turnEnded, payload: ["stop_reason": "end_turn"]),
                .event(.runState, payload: ["state": "succeeded"]),
            ])
    }

    /// 先请求审批，停在等审批（`MockClient.decideApproval` 之后接着播 `approvalResolvedScript`）。
    public static func approvalRequestScript(for run: Run) -> MockEventScript {
        let requestID = "perm-\(run.id.rawValue.suffix(6))"
        let toolCall: JSONValue = [
            "toolCallId": .string("tc-\(requestID)"), "title": "执行操作", "kind": "execute",
            "rawInput": ["command": .string(run.prompt)],
        ]
        return MockEventScript(
            runID: run.id,
            steps: [
                .event(.runState, payload: ["state": "running"]),
                .event(.turnStarted, payload: [:]),
                .event(.agentMessage, payload: ["text": "这一步需要你确认后才能执行。"]),
                .event(
                    .toolCall,
                    payload: [
                        "tool_call_id": .string("tc-\(requestID)"), "title": "执行操作", "kind": "execute",
                        "status": "pending",
                        "raw": toolCall,
                    ]),
                .event(
                    .permissionRequested,
                    payload: [
                        "request_id": .string(requestID), "title": .string("执行：\(run.prompt)"),
                        "options": approvalOptionsJSON,
                        "tool_call": toolCall,
                    ]),
                .event(.runState, payload: ["state": "waiting_approval", "reason": .string("执行：\(run.prompt)")]),
            ])
    }

    /// 审批决定之后：批准就执行完，拒绝就收尾。
    public static func approvalResolvedScript(
        runID: RunID, requestID: String, toolCallID: String?, optionID: String, approved: Bool
    ) -> MockEventScript {
        var steps: [MockEventScript.Step] = [
            .event(
                .permissionResolved,
                payload: ["request_id": .string(requestID), "option_id": .string(optionID), "by": "user"]),
            .event(.runState, payload: ["state": "running"]),
        ]
        if let toolCallID {
            steps.append(
                .event(
                    .toolCallUpdate,
                    payload: ["tool_call_id": .string(toolCallID), "status": approved ? "completed" : "failed"]))
        }
        steps += [
            .event(.agentMessage, payload: ["text": approved ? "已经执行完了。" : "好的，这一步先不做了。"]),
            .event(.turnEnded, payload: ["stop_reason": "end_turn"]),
            .event(.runState, payload: ["state": "succeeded"]),
        ]
        return MockEventScript(runID: runID, steps: steps)
    }

    /// 保险箱请求处理之后。
    public static func vaultResolvedScript(runID: RunID, fulfilled: Bool) -> MockEventScript {
        MockEventScript(
            runID: runID,
            steps: [
                .event(
                    .agentMessage,
                    payload: ["text": fulfilled ? "收到，正在发布……\n\n已发布 `@thinktin/sdk@0.4.0`。" : "好的，那我先不发布了。"]),
                .event(.turnEnded, payload: ["stop_reason": "end_turn"]),
                .event(.runState, payload: ["state": "succeeded"]),
            ])
    }

    static func needsApproval(_ prompt: String) -> Bool {
        ["发到", "发送", "删除", "部署", "审批", "deploy", "delete", "approve"].contains {
            prompt.localizedCaseInsensitiveContains($0)
        }
    }
}

/// 拼演示事件用：seq 从 1 开始递增。
struct EventBuilder {
    let instanceID: InstanceID
    private(set) var events: [InstanceEvent] = []

    init(instanceID: InstanceID) {
        self.instanceID = instanceID
    }

    mutating func add(_ kind: InstanceEventKind, _ runID: RunID?, _ payload: JSONValue, at date: Date) {
        events.append(
            InstanceEvent(
                instanceID: instanceID, seq: UInt64(events.count + 1), runID: runID, kind: kind,
                payloadJSON: payload.compactString(), createdAt: date))
    }
}
