import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 11.7（App 接口补齐）、5.5（内容举报）带来的记录和 ThinktinKit 模型之间的转换（Conversions.swift）。
/// 记录用 ThinktinCore 的公开构造器拼，检查字段、时间（毫秒 → Date）、不认识的枚举值原样保留、可选字段；
/// App 发给接口的（`PlanChange`、`NewPlan`、`TeamMember`、`TemplateMember`、`PlanPolicy`）检查反向转换。
@Suite("ThinktinCore ↔ ThinktinKit 转换（11.7、5.5 的新记录）")
struct AppAPIConversionTests {
    typealias F = AdapterFixture

    // MARK: 登录设备与设备消息

    @Test("DeviceInfo：平台、推送通道、当前、在线、时间")
    func deviceInfo() {
        let phone = ThinktinKit.DeviceInfo(
            core: ThinktinCore.DeviceInfo(
                id: F.deviceID, platform: "ios", name: "小明的 iPhone", pushChannel: "apns", current: true,
                online: false, createdAtMs: F.createdMs, lastSeenAtMs: F.finishedMs))
        #expect(phone.id == DeviceID(F.deviceID))
        #expect(phone.platform == .ios)
        #expect(phone.name == "小明的 iPhone")
        #expect(phone.pushChannel == .apns)
        #expect(phone.isCurrent)
        #expect(!phone.isOnline)
        #expect(phone.createdAt.unixMilliseconds == F.createdMs)
        #expect(phone.lastSeenAt.unixMilliseconds == F.finishedMs)
        #expect(phone.supportsLiveActivities)
        #expect(!phone.isComputer)

        let mac = ThinktinKit.DeviceInfo(
            core: ThinktinCore.DeviceInfo(
                id: F.otherDeviceID, platform: "macos", name: "MacBook", pushChannel: nil, current: false,
                online: true, createdAtMs: F.createdMs, lastSeenAtMs: F.createdMs))
        #expect(mac.platform == .macos)
        #expect(mac.pushChannel == nil)
        #expect(!mac.isCurrent)
        #expect(mac.isOnline)
        #expect(mac.isComputer)
        #expect(!mac.supportsLiveActivities)

        let future = ThinktinKit.DeviceInfo(
            core: ThinktinCore.DeviceInfo(
                id: F.otherDeviceID, platform: "harmonyos", name: "平板", pushChannel: "petal", current: false,
                online: false, createdAtMs: 0, lastSeenAtMs: 0))
        #expect(future.platform == .unknown("harmonyos"))
        #expect(future.platform.rawValue == "harmonyos")
        #expect(future.pushChannel == .unknown("petal"))
        #expect(future.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test("DeviceMessage：方向、种类（含不认识的）、内容 JSON 原样保留、过期时间")
    func deviceMessage() throws {
        let body = #"{"approval_id":"a1","decision":"approve","sig":"MEUCIQ=="}"#
        let message = ThinktinKit.DeviceMessage(
            core: ThinktinCore.DeviceMessage(
                id: F.messageID, fromDeviceId: F.otherDeviceID, toDeviceId: F.deviceID, kind: "approval_request",
                bodyJson: body, createdAtMs: F.createdMs, expiresAtMs: F.finishedMs))
        #expect(message.id == DeviceMessageID(F.messageID))
        #expect(message.fromDeviceID == DeviceID(F.otherDeviceID))
        #expect(message.toDeviceID == DeviceID(F.deviceID))
        #expect(message.kind == .approvalRequest)
        #expect(message.bodyJSON == body)
        #expect(try #require(message.body)["decision"]?.stringValue == "approve")
        #expect(message.createdAt.unixMilliseconds == F.createdMs)
        #expect(message.expiresAt.unixMilliseconds == F.finishedMs)
        #expect(!message.isExpired(now: F.date(F.finishedMs - 1)))
        #expect(message.isExpired(now: F.date(F.finishedMs)))

        let future = ThinktinKit.DeviceMessage(
            core: ThinktinCore.DeviceMessage(
                id: F.messageID, fromDeviceId: F.otherDeviceID, toDeviceId: F.deviceID, kind: "screen_share",
                bodyJson: "not json", createdAtMs: 0, expiresAtMs: 0))
        #expect(future.kind == .unknown("screen_share"))
        #expect(future.kind.rawValue == "screen_share")
        #expect(future.bodyJSON == "not json")
        #expect(future.body == nil)
    }

    // MARK: 计划策略

    @Test("PlanPolicy：ThinktinCore 的平字段 ↔ ThinktinKit 的 budget，来回不变")
    func planPolicyRoundTrip() {
        let core = ThinktinCore.PlanPolicy(
            preauthorizedTools: ["read", "edit"], approvalTimeoutSecs: 900, onApprovalTimeout: "fail",
            maxTokens: 50_000, maxDurationSecs: 1800, maxSteps: 40, dailyTokenLimit: 2_000_000, waitTimeoutSecs: 3600)
        let kit = ThinktinKit.PlanPolicy(core: core)
        #expect(kit.preauthorizedTools == ["read", "edit"])
        #expect(kit.approvalTimeoutSecs == 900)
        #expect(kit.onApprovalTimeout == .fail)
        #expect(kit.budget.maxTokens == 50_000)
        #expect(kit.budget.maxDurationSecs == 1800)
        #expect(kit.budget.maxSteps == 40)
        #expect(kit.dailyTokenLimit == 2_000_000)
        #expect(kit.waitTimeoutSecs == 3600)
        #expect(kit.core == core)

        // 不限的上限（nil）两边都是 nil。
        let unlimited = ThinktinCore.PlanPolicy(maxTokens: nil, maxSteps: nil, dailyTokenLimit: nil)
        let kitUnlimited = ThinktinKit.PlanPolicy(core: unlimited)
        #expect(kitUnlimited.budget.maxTokens == nil)
        #expect(kitUnlimited.budget.maxSteps == nil)
        #expect(kitUnlimited.dailyTokenLimit == nil)
        #expect(kitUnlimited.core == unlimited)
    }

    @Test("PlanPolicy：两边的默认策略一样（都是服务端的默认值）")
    func planPolicyDefaults() {
        #expect(ThinktinKit.PlanPolicy(core: ThinktinCore.PlanPolicy()) == ThinktinKit.PlanPolicy())
        #expect(ThinktinKit.PlanPolicy().core == ThinktinCore.PlanPolicy())
    }

    @Test("PlanPolicy → ThinktinCore：负数当 0，不认识的超时动作原样发出（client-core 再拒绝）")
    func planPolicyKitToCoreEdges() {
        let kit = ThinktinKit.PlanPolicy(
            approvalTimeoutSecs: -1, onApprovalTimeout: .unknown("escalate"),
            budget: ThinktinKit.RunBudget(maxTokens: -5, maxDurationSecs: -10, maxSteps: Int.max),
            dailyTokenLimit: -1, waitTimeoutSecs: Int.min)
        let core = kit.core
        #expect(core.approvalTimeoutSecs == 0)
        #expect(core.onApprovalTimeout == "escalate")
        #expect(core.maxTokens == 0)
        #expect(core.maxDurationSecs == 0)
        #expect(core.maxSteps == UInt32.max)
        #expect(core.dailyTokenLimit == 0)
        #expect(core.waitTimeoutSecs == 0)
    }

    @Test("NewPlan → ThinktinCore：带上策略和补跑方式；不给时是 nil（用服务端默认的）")
    func newPlanWithPolicy() {
        let policy = ThinktinKit.PlanPolicy(
            preauthorizedTools: ["search"], approvalTimeoutSecs: 600, onApprovalTimeout: .skip,
            budget: ThinktinKit.RunBudget(maxTokens: 10_000), waitTimeoutSecs: 7200)
        let plan = ThinktinKit.NewPlan(
            instanceID: InstanceID(F.instanceID), title: "早报", goal: "汇总新闻",
            triggers: [.once(F.date(F.finishedMs))], policy: policy, catchUp: .all)
        let core = plan.core
        #expect(core.instanceId == F.instanceID)
        #expect(core.triggers == [.once(atMs: F.finishedMs)])
        #expect(core.steps.isEmpty)
        #expect(core.policy == policy.core)
        #expect(core.policy?.maxTokens == 10_000)
        #expect(core.policy?.maxDurationSecs == 6 * 3600)
        #expect(core.catchUp == "all")

        let plain = ThinktinKit.NewPlan(instanceID: InstanceID(F.instanceID), title: "t", goal: "g", triggers: [])
        #expect(plain.core.policy == nil)
        #expect(plain.core.catchUp == nil)
    }

    @Test("PlanChange → ThinktinCore：只带给了的字段，其余为 nil")
    func planChangePartial() {
        #expect(
            ThinktinKit.PlanChange(title: "新标题").core
                == ThinktinCore.PlanChange(title: "新标题", goal: nil, policy: nil, catchUp: nil, steps: nil))
        #expect(ThinktinKit.PlanChange(catchUp: .skip).core == ThinktinCore.PlanChange(catchUp: "skip"))
        #expect(ThinktinKit.PlanChange().core == ThinktinCore.PlanChange())

        // 给空数组是“变回单个 agent 的计划”，和不给（nil）不一样。
        let clearSteps = ThinktinKit.PlanChange(steps: []).core
        #expect(clearSteps.steps == [])
        #expect(clearSteps.title == nil && clearSteps.goal == nil && clearSteps.policy == nil)
        #expect(clearSteps.catchUp == nil)

        // 不认识的补跑方式原样发出（client-core 拒绝，抛 invalidArgument）。
        #expect(ThinktinKit.PlanChange(catchUp: .unknown("weekly")).core.catchUp == "weekly")
    }

    @Test("PlanChange → ThinktinCore：全部字段")
    func planChangeFull() {
        let policy = ThinktinKit.PlanPolicy(preauthorizedTools: ["read"], dailyTokenLimit: 100_000)
        let steps = [
            ThinktinKit.PlanStep(key: "fetch", instanceID: InstanceID(F.instanceID), prompt: "抓"),
            ThinktinKit.PlanStep(
                key: "write", instanceID: InstanceID(F.otherInstanceID), prompt: "写", dependsOn: ["fetch"]),
        ]
        let change = ThinktinKit.PlanChange(
            title: "周报", goal: "每周五写", policy: policy, catchUp: .once, steps: steps)
        #expect(
            change.core
                == ThinktinCore.PlanChange(
                    title: "周报", goal: "每周五写", policy: policy.core, catchUp: "once",
                    steps: [
                        ThinktinCore.PlanStep(key: "fetch", instanceId: F.instanceID, prompt: "抓", dependsOn: []),
                        ThinktinCore.PlanStep(
                            key: "write", instanceId: F.otherInstanceID, prompt: "写", dependsOn: ["fetch"]),
                    ]))
        #expect(change.core.policy?.dailyTokenLimit == 100_000)
    }

    // MARK: 团队与团队模板

    @Test("Team、TeamMember：角色（含不认识的）、顺序、时间")
    func team() throws {
        let team = ThinktinKit.Team(
            core: ThinktinCore.Team(
                id: F.teamID, name: "发版小组",
                members: [
                    ThinktinCore.TeamMember(instanceId: F.instanceID, role: "lead", position: 0),
                    ThinktinCore.TeamMember(instanceId: F.otherInstanceID, role: "member", position: 1),
                    ThinktinCore.TeamMember(instanceId: F.rootRunID, role: "reviewer", position: UInt32.max),
                ], createdAtMs: F.createdMs))
        #expect(team.id == TeamID(F.teamID))
        #expect(team.name == "发版小组")
        #expect(team.createdAt.unixMilliseconds == F.createdMs)
        try #require(team.members.count == 3)
        #expect(
            team.members.map(\.instanceID) == [F.instanceID, F.otherInstanceID, F.rootRunID].map { InstanceID($0) })
        #expect(team.members.map(\.role) == [.lead, .member, .unknown("reviewer")])
        #expect(team.members.map(\.position) == [0, 1, Int(UInt32.max)])
        #expect(team.lead?.instanceID == InstanceID(F.instanceID))
        #expect(team.contains(InstanceID(F.otherInstanceID)))
    }

    @Test("TeamMember → ThinktinCore：来回不变；负的顺序当 0")
    func teamMemberRoundTrip() {
        let members = ThinktinKit.Team.members([InstanceID(F.instanceID), InstanceID(F.otherInstanceID)])
        #expect(
            members.map(\.core) == [
                ThinktinCore.TeamMember(instanceId: F.instanceID, role: "lead", position: 0),
                ThinktinCore.TeamMember(instanceId: F.otherInstanceID, role: "member", position: 1),
            ])
        #expect(members.map { ThinktinKit.TeamMember(core: $0.core) } == members)
        #expect(ThinktinKit.TeamMember(instanceID: InstanceID(F.instanceID), position: -3).core.position == 0)
        #expect(
            ThinktinKit.TeamMember(instanceID: InstanceID(F.instanceID), role: .unknown("observer")).core.role
                == "observer")
    }

    @Test("TeamTemplate、TemplateMember：接入方式可选、角色（含不认识的）、时间；成员来回不变")
    func teamTemplate() throws {
        let template = ThinktinKit.TeamTemplate(
            core: ThinktinCore.TeamTemplate(
                id: F.templateID, name: "内容团队",
                members: [
                    ThinktinCore.TemplateMember(agentId: "claude", harness: "acp", name: "主编", role: "lead"),
                    ThinktinCore.TemplateMember(agentId: "codex", harness: nil, name: "写手", role: "member"),
                    ThinktinCore.TemplateMember(agentId: "gemini", harness: nil, name: "校对", role: "critic"),
                ], createdAtMs: F.startedMs))
        #expect(template.id == TeamTemplateID(F.templateID))
        #expect(template.name == "内容团队")
        #expect(template.createdAt.unixMilliseconds == F.startedMs)
        try #require(template.members.count == 3)
        #expect(template.members.map(\.agentID) == ["claude", "codex", "gemini"].map { AgentID($0) })
        #expect(template.members.map(\.harness) == ["acp", nil, nil])
        #expect(template.members.map(\.name) == ["主编", "写手", "校对"])
        #expect(template.members.map(\.role) == [.lead, .member, .unknown("critic")])
        #expect(template.lead?.name == "主编")

        for member in template.members {
            #expect(ThinktinKit.TemplateMember(core: member.core) == member)
        }
        #expect(
            ThinktinKit.TemplateMember(agentID: "claude", name: "助理").core
                == ThinktinCore.TemplateMember(agentId: "claude", harness: nil, name: "助理", role: "member"))
    }

    // MARK: 内容举报

    @Test("ContentReport：举报整个运行（没有事件、产出物），待处理")
    func reportOnRun() {
        let report = ThinktinKit.ContentReport(
            core: ThinktinCore.ContentReport(
                id: F.reportID, runId: F.runID, instanceId: F.instanceID, eventSeq: nil, artifactId: nil,
                reason: "harmful", note: nil, state: "open", resolution: nil, createdAtMs: F.createdMs,
                handledAtMs: nil))
        #expect(report.id == ContentReportID(F.reportID))
        #expect(report.runID == RunID(F.runID))
        #expect(report.instanceID == InstanceID(F.instanceID))
        #expect(report.eventSeq == nil)
        #expect(report.artifactID == nil)
        #expect(report.target == .run)
        #expect(report.reason == .harmful)
        #expect(report.note == nil)
        #expect(report.state == .open)
        #expect(report.isOpen)
        #expect(report.resolution == nil)
        #expect(report.createdAt.unixMilliseconds == F.createdMs)
        #expect(report.handledAt == nil)
    }

    @Test("ContentReport：一条事件、一个产出物；处理完的带结果和时间")
    func reportOnEventAndArtifact() {
        let event = ThinktinKit.ContentReport(
            core: ThinktinCore.ContentReport(
                id: F.reportID, runId: F.runID, instanceId: F.instanceID, eventSeq: UInt64.max, artifactId: nil,
                reason: "misinformation", note: "数据是编的", state: "closed", resolution: "已核实，内容已处理",
                createdAtMs: F.createdMs, handledAtMs: F.finishedMs))
        #expect(event.eventSeq == UInt64.max)
        #expect(event.target == .event(seq: UInt64.max))
        #expect(event.reason == .misinformation)
        #expect(event.note == "数据是编的")
        #expect(event.state == .closed)
        #expect(!event.isOpen)
        #expect(event.resolution == "已核实，内容已处理")
        #expect(event.handledAt?.unixMilliseconds == F.finishedMs)

        let artifact = ThinktinKit.ContentReport(
            core: ThinktinCore.ContentReport(
                id: F.reportID, runId: F.runID, instanceId: F.instanceID, eventSeq: 7, artifactId: F.artifactID,
                reason: "infringement", note: "", state: "open", resolution: nil, createdAtMs: F.createdMs,
                handledAtMs: nil))
        #expect(artifact.artifactID == ArtifactID(F.artifactID))
        // 同时有产出物和事件时，举报的对象是产出物。
        #expect(artifact.target == .artifact(ArtifactID(F.artifactID)))
        #expect(artifact.reason == .infringement)
        #expect(artifact.note == "")
    }

    @Test("ContentReport：不认识的原因、状态原样保留")
    func reportUnknownValues() {
        let report = ThinktinKit.ContentReport(
            core: ThinktinCore.ContentReport(
                id: F.reportID, runId: F.runID, instanceId: F.instanceID, eventSeq: nil, artifactId: nil,
                reason: "spam", note: nil, state: "escalated", resolution: nil, createdAtMs: 0, handledAtMs: 0))
        #expect(report.reason == .unknown("spam"))
        #expect(report.reason.rawValue == "spam")
        #expect(!report.reason.isKnown)
        #expect(report.state == .unknown("escalated"))
        #expect(!report.isOpen)
        #expect(report.handledAt == Date(timeIntervalSince1970: 0))
    }
}
