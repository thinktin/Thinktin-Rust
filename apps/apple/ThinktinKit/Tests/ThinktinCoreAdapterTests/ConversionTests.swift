import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// ThinktinCore 记录 → ThinktinKit 领域模型（Conversions.swift）。记录用 ThinktinCore 的公开构造器拼，
/// 检查时间（毫秒 → Date）、id、枚举（含不认识的取值原样保留）、可选字段和 JSON 文本。
@Suite("ThinktinCore → ThinktinKit 转换")
struct ConversionTests {
    typealias F = AdapterFixture

    // MARK: 运行

    @Test("Run：时间、id、枚举、可选字段")
    func run() {
        let core = ThinktinCore.Run(
            id: F.runID, kind: "pipeline", instanceId: F.instanceID, planId: F.planID, parentRunId: nil,
            rootRunId: F.rootRunID, stepKey: "build", source: "plan", prompt: "每天早上汇总新闻", state: "waiting_approval",
            stateReason: "approval", attempt: 2, tokensUsed: 12_345, summary: nil, error: "boom",
            createdAtMs: F.createdMs, startedAtMs: F.startedMs, finishedAtMs: nil)
        let run = ThinktinKit.Run(core: core)

        #expect(run.id == RunID(F.runID))
        #expect(run.kind == .pipeline)
        #expect(run.instanceID == InstanceID(F.instanceID))
        #expect(run.planID == PlanID(F.planID))
        #expect(run.parentRunID == nil)
        #expect(run.isRoot)
        #expect(run.rootRunID == RunID(F.rootRunID))
        #expect(run.stepKey == "build")
        #expect(run.source == .plan)
        #expect(run.prompt == "每天早上汇总新闻")
        #expect(run.state == .waitingApproval)
        #expect(run.state.isWaiting)
        #expect(run.stateReason == "approval")
        #expect(run.attempt == 2)
        #expect(run.tokensUsed == 12_345)
        #expect(run.summary == nil)
        #expect(run.error == "boom")
        #expect(run.createdAt == F.date(F.createdMs))
        #expect(run.createdAt.unixMilliseconds == F.createdMs)
        #expect(run.startedAt?.unixMilliseconds == F.startedMs)
        #expect(run.finishedAt == nil)
        #expect(run.duration(now: F.date(F.startedMs + 90_000)) == 90)
    }

    @Test("Run：不认识的取值原样保留，超出范围的数截断")
    func runUnknownValues() {
        let core = ThinktinCore.Run(
            id: F.runID, kind: "swarm", instanceId: F.instanceID, planId: nil, parentRunId: F.rootRunID,
            rootRunId: F.rootRunID, stepKey: nil, source: "webhook", prompt: "", state: "hibernating", stateReason: nil,
            attempt: 1, tokensUsed: UInt64.max, summary: "完成", error: nil, createdAtMs: F.createdMs,
            startedAtMs: F.startedMs, finishedAtMs: F.finishedMs)
        let run = ThinktinKit.Run(core: core)

        #expect(run.kind == .unknown("swarm"))
        #expect(run.kind.rawValue == "swarm")
        #expect(run.source == .unknown("webhook"))
        #expect(run.state == .unknown("hibernating"))
        #expect(run.state.rawValue == "hibernating")
        #expect(!run.state.isKnown)
        #expect(run.state.isActive)
        #expect(run.parentRunID == RunID(F.rootRunID))
        #expect(!run.isRoot)
        #expect(run.tokensUsed == Int.max)
        #expect(run.summary == "完成")
        #expect(run.finishedAt?.unixMilliseconds == F.finishedMs)
    }

    // MARK: 实例

    @Test("Instance：状态枚举和时间")
    func instance() {
        let paused = ThinktinKit.Instance(
            core: ThinktinCore.Instance(
                id: F.instanceID, agentId: "claude", agentVersion: "2.0.1", harness: "acp", name: "写周报的",
                state: "paused", createdAtMs: F.createdMs, lastActiveAtMs: F.finishedMs))
        #expect(paused.id == InstanceID(F.instanceID))
        #expect(paused.agentID == AgentID("claude"))
        #expect(paused.agentVersion == "2.0.1")
        #expect(paused.harness == "acp")
        #expect(paused.name == "写周报的")
        #expect(paused.state == .paused)
        #expect(paused.createdAt.unixMilliseconds == F.createdMs)
        #expect(paused.lastActiveAt.unixMilliseconds == F.finishedMs)

        let migrating = ThinktinKit.Instance(
            core: ThinktinCore.Instance(
                id: F.instanceID, agentId: "codex", agentVersion: "1", harness: "cli", name: "x", state: "migrating",
                createdAtMs: 0, lastActiveAtMs: 0))
        #expect(migrating.state == .unknown("migrating"))
        #expect(migrating.createdAt == Date(timeIntervalSince1970: 0))
    }

    // MARK: 计划

    @Test("Plan：三种触发规则、步骤、策略 JSON")
    func plan() throws {
        let onceMs: Int64 = 1_767_225_600_000  // 2026-01-01 00:00 UTC
        let core = ThinktinCore.Plan(
            id: F.planID, instanceId: F.instanceID, title: "早报", goal: "每天早上汇总新闻", paused: false,
            createdBy: "agent", awaitingConfirmation: true, revision: 3,
            policyJson:
                #"{"preauthorized_tools":["read","search"],"approval_timeout_secs":600,"on_approval_timeout":"skip"}"#,
            createdAtMs: F.createdMs,
            triggers: [
                ThinktinCore.Trigger(
                    id: "t-cron", schedule: .cron(expr: "0 8 * * *", tz: "Asia/Shanghai"), enabled: true,
                    nextFireAtMs: F.finishedMs, lastFireAtMs: F.startedMs),
                ThinktinCore.Trigger(
                    id: "t-rrule",
                    schedule: .rrule(rule: "DTSTART;TZID=Asia/Shanghai:20260101T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO"),
                    enabled: false, nextFireAtMs: nil, lastFireAtMs: nil),
                ThinktinCore.Trigger(
                    id: "t-once", schedule: .once(atMs: onceMs), enabled: true, nextFireAtMs: onceMs, lastFireAtMs: nil),
            ],
            steps: [
                ThinktinCore.PlanStep(key: "fetch", instanceId: F.instanceID, prompt: "抓新闻", dependsOn: []),
                ThinktinCore.PlanStep(key: "write", instanceId: F.rootRunID, prompt: "写摘要", dependsOn: ["fetch"]),
            ])
        let plan = ThinktinKit.Plan(core: core)

        #expect(plan.id == PlanID(F.planID))
        #expect(plan.instanceID == InstanceID(F.instanceID))
        #expect(plan.title == "早报")
        #expect(plan.goal == "每天早上汇总新闻")
        #expect(!plan.isPaused)
        #expect(plan.createdBy == .agent)
        #expect(plan.awaitingConfirmation)
        #expect(plan.revision == 3)
        #expect(plan.createdAt.unixMilliseconds == F.createdMs)

        try #require(plan.triggers.count == 3)
        #expect(plan.triggers[0].id == TriggerID("t-cron"))
        #expect(plan.triggers[0].schedule == .cron(expression: "0 8 * * *", timeZone: "Asia/Shanghai"))
        #expect(plan.triggers[0].isEnabled)
        #expect(plan.triggers[0].nextFireAt?.unixMilliseconds == F.finishedMs)
        #expect(plan.triggers[0].lastFireAt?.unixMilliseconds == F.startedMs)
        #expect(
            plan.triggers[1].schedule
                == .rrule("DTSTART;TZID=Asia/Shanghai:20260101T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO"))
        #expect(!plan.triggers[1].isEnabled)
        #expect(plan.triggers[1].nextFireAt == nil)
        #expect(plan.triggers[2].schedule == .once(F.date(onceMs)))
        // 只算启用的触发器：cron 的下次时间比一次性的早。
        #expect(plan.nextFireAt?.unixMilliseconds == min(F.finishedMs, onceMs))

        #expect(plan.isPipeline)
        #expect(plan.steps.map(\.key) == ["fetch", "write"])
        #expect(plan.steps[1].instanceID == InstanceID(F.rootRunID))
        #expect(plan.steps[1].dependsOn == ["fetch"])

        // 策略 JSON 原样保留，由 ThinktinKit 解析（缺的字段用默认值）。
        #expect(plan.policyJSON == core.policyJson)
        let policy = try #require(plan.policy)
        #expect(policy.preauthorizedTools == ["read", "search"])
        #expect(policy.approvalTimeoutSecs == 600)
        #expect(policy.onApprovalTimeout == .skip)
        #expect(policy.waitTimeoutSecs == 24 * 3600)
    }

    @Test("Schedule：ThinktinKit → ThinktinCore → ThinktinKit 来回不变")
    func scheduleRoundTrip() {
        let schedules: [ThinktinKit.Schedule] = [
            .cron(expression: "*/15 9-18 * * 1-5", timeZone: "Asia/Shanghai"),
            .rrule("DTSTART;TZID=Asia/Shanghai:20260101T090000\nRRULE:FREQ=DAILY"),
            .once(F.date(F.createdMs)),
        ]
        for schedule in schedules {
            #expect(ThinktinKit.Schedule(core: schedule.core) == schedule)
        }
        #expect(schedules[0].core == .cron(expr: "*/15 9-18 * * 1-5", tz: "Asia/Shanghai"))
        #expect(schedules[2].core == .once(atMs: F.createdMs))
    }

    @Test("NewPlan、ModelRoute、Session：ThinktinKit → ThinktinCore")
    func kitToCore() {
        let newPlan = ThinktinKit.NewPlan(
            instanceID: InstanceID(F.instanceID), title: "周报", goal: "每周五写周报",
            triggers: [.cron(expression: "0 17 * * 5", timeZone: "Asia/Shanghai")],
            steps: [ThinktinKit.PlanStep(key: "a", instanceID: InstanceID(F.instanceID), prompt: "写")])
        #expect(
            newPlan.core
                == ThinktinCore.NewPlan(
                    instanceId: F.instanceID, title: "周报", goal: "每周五写周报",
                    triggers: [.cron(expr: "0 17 * * 5", tz: "Asia/Shanghai")],
                    steps: [ThinktinCore.PlanStep(key: "a", instanceId: F.instanceID, prompt: "写", dependsOn: [])]))

        let route = ThinktinKit.ModelRoute(
            alias: "main", credentialID: "cred-1", upstreamModel: "claude-sonnet",
            fallbacks: [ThinktinKit.RouteFallback(credentialID: "cred-2", upstreamModel: "deepseek-chat")])
        #expect(route.core.credentialId == "cred-1")
        #expect(
            route.core.fallbacks == [ThinktinCore.RouteFallback(credentialId: "cred-2", upstreamModel: "deepseek-chat")]
        )
        #expect(ThinktinKit.ModelRoute(core: route.core) == route)

        let session = F.session
        #expect(session.core.userId == F.userID)
        #expect(session.core.refreshToken == "refresh-token")
        #expect(ThinktinKit.Session(core: session.core) == session)
    }

    // MARK: 收件箱

    @Test("InboxItem：可选 id、种类、AI 生成标识、已读")
    func inboxItem() {
        let failed = ThinktinKit.InboxItem(
            core: ThinktinCore.InboxItem(
                id: F.itemID, instanceId: F.instanceID, runId: F.runID, planId: F.planID, approvalId: F.approvalID,
                kind: "run_failed", title: "运行失败", body: "agent 说：网络不通", aiGenerated: true, read: false,
                createdAtMs: F.createdMs))
        #expect(failed.id == InboxItemID(F.itemID))
        #expect(failed.instanceID == InstanceID(F.instanceID))
        #expect(failed.runID == RunID(F.runID))
        #expect(failed.planID == PlanID(F.planID))
        #expect(failed.approvalID == ApprovalID(F.approvalID))
        #expect(failed.kind == .runFailed)
        #expect(failed.title == "运行失败")
        #expect(failed.body == "agent 说：网络不通")
        #expect(failed.isAIGenerated)
        #expect(!failed.isRead)
        #expect(failed.createdAt.unixMilliseconds == F.createdMs)

        let digest = ThinktinKit.InboxItem(
            core: ThinktinCore.InboxItem(
                id: F.itemID, instanceId: nil, runId: nil, planId: nil, approvalId: nil, kind: "weekly_digest",
                title: "周报", body: "", aiGenerated: false, read: true, createdAtMs: F.createdMs))
        #expect(digest.kind == .unknown("weekly_digest"))
        #expect(digest.instanceID == nil && digest.runID == nil && digest.planID == nil && digest.approvalID == nil)
        #expect(digest.isRead)

        let page = ThinktinKit.InboxPage(
            core: ThinktinCore.InboxPage(
                items: [
                    ThinktinCore.InboxItem(
                        id: F.itemID, instanceId: nil, runId: nil, planId: nil, approvalId: nil, kind: "info",
                        title: "t", body: "b", aiGenerated: false, read: false, createdAtMs: 1)
                ], unread: 7))
        #expect(page.items.map(\.kind) == [.info])
        #expect(page.unread == 7)
    }

    // MARK: 事件

    @Test("InstanceEvent：seq、种类、载荷 JSON、AI 生成标识")
    func instanceEvent() throws {
        let message = ThinktinKit.InstanceEvent(
            core: ThinktinCore.InstanceEvent(
                instanceId: F.instanceID, seq: 42, runId: F.runID, kind: "agent.message",
                payloadJson: #"{"text":"你好"}"#, aiGenerated: true, createdAtMs: F.createdMs))
        #expect(message.instanceID == InstanceID(F.instanceID))
        #expect(message.seq == 42)
        #expect(message.id == "\(F.instanceID)#42")
        #expect(message.runID == RunID(F.runID))
        #expect(message.kind == .agentMessage)
        #expect(message.payloadJSON == #"{"text":"你好"}"#)
        #expect(message.payloadValue != nil)
        #expect(message.isAIGenerated)
        #expect(message.createdAt.unixMilliseconds == F.createdMs)

        // 服务端说了算：标识按记录里的 ai_generated，不按 kind 猜。
        let state = ThinktinKit.InstanceEvent(
            core: ThinktinCore.InstanceEvent(
                instanceId: F.instanceID, seq: 43, runId: nil, kind: "run.state",
                payloadJson: #"{"state":"running","reason":null,"attempt":1}"#, aiGenerated: false,
                createdAtMs: F.createdMs + 1))
        #expect(state.kind == .runState)
        #expect(state.runID == nil)
        #expect(!state.isAIGenerated)
        #expect(try #require(state.runStatePayload).state == .running)

        let future = ThinktinKit.InstanceEvent(
            core: ThinktinCore.InstanceEvent(
                instanceId: F.instanceID, seq: 44, runId: F.runID, kind: "agent.hologram", payloadJson: "{}",
                aiGenerated: true, createdAtMs: 0))
        #expect(future.kind == .unknown("agent.hologram"))
        #expect(future.kind.rawValue == "agent.hologram")
        #expect(future.isAIGenerated)
    }

    @Test("StreamStatus：每个状态都对应，重连等待毫秒换成秒")
    func streamStatus() {
        let pairs: [(ThinktinCore.StreamStatus, ThinktinKit.StreamStatus)] = [
            (.connecting, .connecting), (.live, .live), (.reconnecting(retryInMs: 1500), .reconnecting(retryIn: 1.5)),
            (.signedOut, .signedOut), (.notFound, .notFound), (.accountFrozen, .accountFrozen), (.stopped, .stopped),
        ]
        for (core, kit) in pairs {
            #expect(ThinktinKit.StreamStatus(core: core) == kit)
        }
    }

    // MARK: 保险箱

    @Test("VaultRequest：字段（含不认识的）、状态、时间")
    func vaultRequest() {
        let expired = ThinktinKit.VaultRequest(
            core: ThinktinCore.VaultRequest(
                id: "req-1", instanceId: F.instanceID, runId: F.runID, name: "github", purpose: "登录 GitHub 提 PR",
                fields: ["username", "password", "otp"], status: "expired", itemId: nil, createdAtMs: F.createdMs,
                expiresAtMs: F.finishedMs, resolvedAtMs: nil))
        #expect(expired.id == VaultRequestID("req-1"))
        #expect(expired.instanceID == InstanceID(F.instanceID))
        #expect(expired.runID == RunID(F.runID))
        #expect(expired.name == "github")
        #expect(expired.purpose == "登录 GitHub 提 PR")
        #expect(expired.fields == [.username, .password, .unknown("otp")])
        #expect(expired.needsUsername)
        #expect(expired.status == .expired)
        #expect(expired.status.isResolved)
        #expect(expired.itemID == nil)
        #expect(expired.createdAt.unixMilliseconds == F.createdMs)
        #expect(expired.expiresAt.unixMilliseconds == F.finishedMs)
        #expect(expired.resolvedAt == nil)

        let fulfilled = ThinktinKit.VaultRequest(
            core: ThinktinCore.VaultRequest(
                id: "req-2", instanceId: F.instanceID, runId: nil, name: "mail", purpose: "", fields: ["password"],
                status: "fulfilled", itemId: F.itemID, createdAtMs: F.createdMs, expiresAtMs: F.finishedMs,
                resolvedAtMs: F.startedMs))
        #expect(fulfilled.runID == nil)
        #expect(fulfilled.fields == [.password])
        #expect(!fulfilled.needsUsername)
        #expect(fulfilled.status == .fulfilled)
        #expect(fulfilled.itemID == VaultItemID(F.itemID))
        #expect(fulfilled.resolvedAt?.unixMilliseconds == F.startedMs)

        let later = ThinktinKit.VaultRequest(
            core: ThinktinCore.VaultRequest(
                id: "req-3", instanceId: F.instanceID, runId: nil, name: "x", purpose: "", fields: [],
                status: "snoozed", itemId: nil, createdAtMs: 0, expiresAtMs: 0, resolvedAtMs: nil))
        #expect(later.status == .unknown("snoozed"))
        #expect(later.status.isResolved)
    }

    @Test("VaultItem 与 SavedSecret；NewVaultItem、VaultItemUpdate 反向转换")
    func vaultItems() {
        let coreItem = ThinktinCore.VaultItem(
            id: F.itemID, name: "github", purpose: "提 PR", hasUsername: true, instanceIds: [F.instanceID],
            createdAtMs: F.createdMs, updatedAtMs: F.startedMs, lastUsedAtMs: nil)
        let saved = ThinktinKit.SavedSecret(
            core: ThinktinCore.SavedSecret(item: coreItem, message: "用 [vault:github] 登录"))
        #expect(saved.item.id == VaultItemID(F.itemID))
        #expect(saved.item.instanceIDs == [InstanceID(F.instanceID)])
        #expect(saved.item.updatedAt.unixMilliseconds == F.startedMs)
        #expect(saved.item.lastUsedAt == nil)
        #expect(saved.item.reference == "[vault:github]")
        #expect(saved.message == "用 [vault:github] 登录")

        let new = ThinktinKit.NewVaultItem(
            name: "mail", purpose: "收邮件", username: "bob", password: "pw", instanceIDs: [InstanceID(F.instanceID)])
        #expect(
            new.core
                == ThinktinCore.NewVaultItem(
                    name: "mail", purpose: "收邮件", username: "bob", password: "pw", instanceIds: [F.instanceID]))
        let change = ThinktinKit.VaultItemUpdate(password: "new")
        #expect(
            change.core == ThinktinCore.VaultItemUpdate(purpose: nil, username: nil, password: "new", instanceIds: nil))
    }

    // MARK: 其他记录

    @Test("User、Approval、Credential、ImChannel、DetectedSecret")
    func otherRecords() {
        let user = ThinktinKit.User(
            core: ThinktinCore.User(
                id: F.userID, phone: "+8613800138000", displayName: nil, status: "frozen", locale: "en",
                createdAtMs: F.createdMs))
        #expect(user.status == .frozen)
        #expect(user.locale == .en)
        #expect(user.nameForDisplay == "138****8000")

        let approval = ThinktinKit.Approval(
            core: ThinktinCore.Approval(
                id: F.approvalID, runId: F.runID, instanceId: F.instanceID, title: "删除文件",
                options: [
                    ThinktinCore.ApprovalOption(optionId: "o1", name: "允许", kind: "allow_once"),
                    ThinktinCore.ApprovalOption(optionId: "o2", name: "拒绝", kind: "reject_always"),
                    ThinktinCore.ApprovalOption(optionId: "o3", name: "稍后", kind: "allow_later"),
                ], toolCallJson: #"{"title":"rm -rf build"}"#, state: "pending", expiresAtMs: F.finishedMs,
                createdAtMs: F.createdMs))
        #expect(approval.options.map(\.id) == ["o1", "o2", "o3"])
        #expect(approval.options.map(\.kind) == [.allowOnce, .rejectAlways, .unknown("allow_later")])
        #expect(approval.options[2].kind.isAllow)
        #expect(approval.state == .pending)
        #expect(approval.toolCallJSON == #"{"title":"rm -rf build"}"#)
        #expect(approval.expiresAt.unixMilliseconds == F.finishedMs)

        let credential = ThinktinKit.Credential(
            core: ThinktinCore.Credential(
                id: "cred-1", vendor: "deepseek", label: "我的 key", last4: "abcd", dailyTokenLimit: 1_000_000,
                disabled: true, createdAtMs: F.createdMs))
        #expect(credential.dailyTokenLimit == 1_000_000)
        #expect(credential.isDisabled)
        #expect(credential.maskedKey == "••••abcd")

        let channel = ThinktinKit.ImChannel(
            core: ThinktinCore.ImChannel(
                id: "im-1", vendor: "slack", label: "团队群", hint: "x9z1", hasSecret: true,
                events: ["run_failed", "approval", "digest"], enabled: false, lastSentAtMs: F.startedMs,
                lastError: "403", createdAtMs: F.createdMs))
        #expect(channel.vendor == .unknown("slack"))
        #expect(channel.events == [.runFailed, .approval, .unknown("digest")])
        #expect(!channel.isEnabled)
        #expect(channel.lastSentAt?.unixMilliseconds == F.startedMs)

        let secret = ThinktinKit.DetectedSecret(
            core: ThinktinCore.DetectedSecret(
                kind: "jwt", start: 5, end: 3, value: "v", suggestedName: "token", service: "", storable: true))
        #expect(secret.kind == .unknown("jwt"))
        // 结束位置比开始还小（不该发生）时不崩溃，当作空范围。
        #expect(secret.utf16Range == 5..<5)
    }
}
