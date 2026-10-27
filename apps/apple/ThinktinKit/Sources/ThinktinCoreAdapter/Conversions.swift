import Foundation
import ThinktinKit

// ThinktinCore 记录 ↔ ThinktinKit 领域模型（字段含义见 crates/client-core/src/ffi.rs）：
// - 时间：Unix 毫秒（Int64）↔ `Date`；
// - id：字符串 ↔ 强类型 `EntityID`；
// - 服务端的字符串枚举 ↔ `OpenStringEnum`（不认识的取值保留在 `unknown(String)` 里，不丢）；
// - 无符号整数 ↔ `Int`（`clamping`，超出范围截断，不崩溃；反过来负数当 0，交给 client-core / 服务端校验范围）；
// - 结构不固定的部分（工具调用、事件载荷、设备消息的内容）原样保留 JSON 文本，由 ThinktinKit 解析。
//   计划策略用结构化的 `PlanPolicy` 记录（11.7），不再经 `policy_json`。
//
// 只做用得到的方向：接口返回的记录（`DeviceInfo`、`Team`、`ContentReport`……）只有 ThinktinCore → ThinktinKit；
// 只往接口发的（`NewPlan`、`PlanChange`）只有反向；两边都走的（`PlanPolicy`、`TeamMember`、`TemplateMember`）两个方向都有。
//
// 两个模块里大部分类型同名。本文件只 import ThinktinKit，但同名类型一律写全 `ThinktinKit.X`，
// ThinktinCore 的类型一律经 `Core.X`（Core.swift），以后哪个文件同时 import 了两个模块也不会有歧义。
//
// 注意：`EntityID` 有 `init(_:)`、`init(rawValue:)`、`init(stringLiteral:)` 三个同型的构造器，
// `.map(RunID.init)` 这种写法有歧义（编译不过），要写成闭包 `{ RunID($0) }`。

extension Date {
    /// 从 ThinktinCore 的毫秒时间构造。
    init(ms: Int64) { self.init(unixMilliseconds: ms) }
}

extension Optional where Wrapped == Int64 {
    /// 可选的毫秒时间 → 可选的 `Date`。
    var date: Date? { map { Date(ms: $0) } }
}

// MARK: - 账号

extension ThinktinKit.User {
    init(core u: Core.User) {
        self.init(
            id: UserID(u.id), phone: u.phone, displayName: u.displayName, status: UserStatus(rawValue: u.status),
            locale: UserLocale(rawValue: u.locale), createdAt: Date(ms: u.createdAtMs))
    }
}

extension ThinktinKit.LoginResult {
    init(core r: Core.LoginResult) {
        self.init(user: ThinktinKit.User(core: r.user), isNewUser: r.newUser)
    }
}

extension ThinktinKit.StopAllResult {
    init(core r: Core.StopAllResult) {
        self.init(
            runsCancelled: Int(clamping: r.runsCancelled), grantsRevoked: Int(clamping: r.grantsRevoked),
            plansPaused: Int(clamping: r.plansPaused))
    }
}

extension ThinktinKit.SignOutOthersResult {
    init(core r: Core.SignOutOthersResult) {
        self.init(
            devicesSignedOut: Int(clamping: r.devicesSignedOut),
            stopped: r.stopped.map { ThinktinKit.StopAllResult(core: $0) })
    }
}

extension ThinktinKit.Session {
    init(core s: Core.Session) {
        self.init(
            userID: UserID(s.userId), deviceID: DeviceID(s.deviceId), accessToken: s.accessToken,
            refreshToken: s.refreshToken)
    }

    var core: Core.Session {
        Core.Session(
            userId: userID.rawValue, deviceId: deviceID.rawValue, accessToken: accessToken, refreshToken: refreshToken)
    }
}

// MARK: - 登录设备与设备消息（14.1）

extension ThinktinKit.DeviceInfo {
    init(core d: Core.DeviceInfo) {
        self.init(
            id: DeviceID(d.id), platform: DevicePlatform(rawValue: d.platform), name: d.name,
            pushChannel: d.pushChannel.map { PushChannel(rawValue: $0) }, isCurrent: d.current, isOnline: d.online,
            createdAt: Date(ms: d.createdAtMs), lastSeenAt: Date(ms: d.lastSeenAtMs))
    }
}

extension ThinktinKit.DeviceMessage {
    init(core m: Core.DeviceMessage) {
        self.init(
            id: DeviceMessageID(m.id), fromDeviceID: DeviceID(m.fromDeviceId), toDeviceID: DeviceID(m.toDeviceId),
            kind: DeviceMessageKind(rawValue: m.kind), bodyJSON: m.bodyJson, createdAt: Date(ms: m.createdAtMs),
            expiresAt: Date(ms: m.expiresAtMs))
    }
}

// MARK: - agent 与实例

extension ThinktinKit.AgentInfo {
    init(core a: Core.AgentInfo) {
        self.init(
            id: AgentID(a.id), name: a.name, version: a.version, license: a.license, sites: a.sites,
            harnesses: a.harnesses, defaultHarness: a.defaultHarness, versions: a.versions, description: a.description,
            upstream: a.upstream, licenseNote: a.licenseNote,
            protocols: a.protocols.map { ModelProtocol(rawValue: $0) },
            activeProtocol: a.activeProtocol.map { ModelProtocol(rawValue: $0) })
    }
}

extension ThinktinKit.Instance {
    init(core i: Core.Instance) {
        self.init(
            id: InstanceID(i.id), agentID: AgentID(i.agentId), agentVersion: i.agentVersion, harness: i.harness,
            name: i.name, state: InstanceState(rawValue: i.state), createdAt: Date(ms: i.createdAtMs),
            lastActiveAt: Date(ms: i.lastActiveAtMs))
    }
}

extension ThinktinKit.RouteFallback {
    init(core f: Core.RouteFallback) {
        self.init(credentialID: CredentialID(f.credentialId), upstreamModel: f.upstreamModel)
    }

    var core: Core.RouteFallback {
        Core.RouteFallback(credentialId: credentialID.rawValue, upstreamModel: upstreamModel)
    }
}

extension ThinktinKit.ModelRoute {
    init(core r: Core.ModelRoute) {
        self.init(
            alias: r.alias, credentialID: CredentialID(r.credentialId), upstreamModel: r.upstreamModel,
            fallbacks: r.fallbacks.map { ThinktinKit.RouteFallback(core: $0) })
    }

    var core: Core.ModelRoute {
        Core.ModelRoute(
            alias: alias, credentialId: credentialID.rawValue, upstreamModel: upstreamModel,
            fallbacks: fallbacks.map(\.core))
    }
}

// MARK: - 运行

extension ThinktinKit.Run {
    init(core r: Core.Run) {
        self.init(
            id: RunID(r.id), kind: RunKind(rawValue: r.kind), instanceID: InstanceID(r.instanceId),
            planID: r.planId.map { PlanID($0) }, parentRunID: r.parentRunId.map { RunID($0) },
            rootRunID: RunID(r.rootRunId), stepKey: r.stepKey, source: RunSource(rawValue: r.source),
            prompt: r.prompt, state: RunState(rawValue: r.state), stateReason: r.stateReason,
            attempt: Int(clamping: r.attempt), tokensUsed: Int(clamping: r.tokensUsed), summary: r.summary,
            error: r.error, createdAt: Date(ms: r.createdAtMs), startedAt: r.startedAtMs.date,
            finishedAt: r.finishedAtMs.date, waitCode: r.waitCode.map { RunWaitCode(rawValue: $0) })
    }
}

extension ThinktinKit.RunFilter {
    var core: Core.RunFilter {
        Core.RunFilter(planId: planID?.rawValue, activeOnly: activeOnly, rootsOnly: rootsOnly)
    }
}

extension ThinktinKit.Artifact {
    init(core a: Core.Artifact) {
        self.init(
            id: ArtifactID(a.id), instanceID: InstanceID(a.instanceId), runID: RunID(a.runId), name: a.name,
            version: Int(clamping: a.version), contentType: a.contentType, size: Int(clamping: a.size),
            sha256: a.sha256, createdAt: Date(ms: a.createdAtMs))
    }
}

// MARK: - 审批

extension ThinktinKit.ApprovalOption {
    init(core o: Core.ApprovalOption) {
        self.init(id: o.optionId, name: o.name, kind: ApprovalOptionKind(rawValue: o.kind))
    }
}

extension ThinktinKit.Approval {
    init(core a: Core.Approval) {
        self.init(
            id: ApprovalID(a.id), runID: RunID(a.runId), instanceID: InstanceID(a.instanceId), title: a.title,
            options: a.options.map { ThinktinKit.ApprovalOption(core: $0) }, toolCallJSON: a.toolCallJson,
            state: ApprovalState(rawValue: a.state), expiresAt: Date(ms: a.expiresAtMs),
            createdAt: Date(ms: a.createdAtMs), requestID: a.requestId, attempt: Int(clamping: a.attempt),
            decidedOption: a.decidedOption, decidedAt: a.decidedAtMs.date)
    }
}

// MARK: - 计划

extension ThinktinKit.Schedule {
    init(core s: Core.Schedule) {
        switch s {
        case .cron(let expr, let tz): self = .cron(expression: expr, timeZone: tz)
        case .rrule(let rule): self = .rrule(rule)
        case .once(let atMs): self = .once(Date(ms: atMs))
        }
    }

    var core: Core.Schedule {
        switch self {
        case .cron(let expression, let timeZone): .cron(expr: expression, tz: timeZone)
        case .rrule(let rule): .rrule(rule: rule)
        case .once(let date): .once(atMs: date.unixMilliseconds)
        }
    }
}

extension ThinktinKit.Trigger {
    init(core t: Core.Trigger) {
        self.init(
            id: TriggerID(t.id), schedule: ThinktinKit.Schedule(core: t.schedule), isEnabled: t.enabled,
            nextFireAt: t.nextFireAtMs.date, lastFireAt: t.lastFireAtMs.date,
            disabledReason: t.disabledReason.map { TriggerDisabledReason(rawValue: $0) })
    }
}

extension ThinktinKit.PlanStep {
    init(core s: Core.PlanStep) {
        self.init(key: s.key, instanceID: InstanceID(s.instanceId), prompt: s.prompt, dependsOn: s.dependsOn)
    }

    var core: Core.PlanStep {
        Core.PlanStep(key: key, instanceId: instanceID.rawValue, prompt: prompt, dependsOn: dependsOn)
    }
}

extension ThinktinKit.PlanPolicy {
    /// ThinktinCore 的 `PlanPolicy` 是平的（`maxTokens`、`maxDurationSecs`、`maxSteps` 和别的字段并列），
    /// ThinktinKit 照服务端的 JSON 把每次运行的上限收在 `budget` 里。
    init(core p: Core.PlanPolicy) {
        self.init(
            preauthorizedTools: p.preauthorizedTools, approvalTimeoutSecs: Int(clamping: p.approvalTimeoutSecs),
            onApprovalTimeout: ApprovalTimeoutAction(rawValue: p.onApprovalTimeout),
            budget: ThinktinKit.RunBudget(
                maxTokens: p.maxTokens.map { Int(clamping: $0) }, maxDurationSecs: Int(clamping: p.maxDurationSecs),
                maxSteps: p.maxSteps.map { Int(clamping: $0) }),
            dailyTokenLimit: p.dailyTokenLimit.map { Int(clamping: $0) },
            waitTimeoutSecs: Int(clamping: p.waitTimeoutSecs))
    }

    /// 负数当 0（服务端按范围拒绝，抛 invalid）；不认识的超时动作原样发出，client-core 拒绝（`invalidArgument`）。
    var core: Core.PlanPolicy {
        Core.PlanPolicy(
            preauthorizedTools: preauthorizedTools, approvalTimeoutSecs: UInt64(clamping: approvalTimeoutSecs),
            onApprovalTimeout: onApprovalTimeout.rawValue, maxTokens: budget.maxTokens.map { UInt64(clamping: $0) },
            maxDurationSecs: UInt64(clamping: budget.maxDurationSecs),
            maxSteps: budget.maxSteps.map { UInt32(clamping: $0) },
            dailyTokenLimit: dailyTokenLimit.map { UInt64(clamping: $0) },
            waitTimeoutSecs: UInt64(clamping: waitTimeoutSecs))
    }
}

extension ThinktinKit.Plan {
    /// 策略取结构化的 `policy`；`policy_json` 是同一份策略的 JSON（留给老版本 App），这里不再读
    /// （ThinktinKit 的 `Plan.policyJSON` 由 `policy` 重新编出来）。
    ///
    /// `nextFireAt`、`invalidTriggers` 以服务端的为准（11.8）；老的服务端没给 `next_fire_at` 时按同样的规则从触发器算
    /// （`Plan.init` 已经算好）。
    init(core p: Core.Plan) {
        self.init(
            id: PlanID(p.id), instanceID: InstanceID(p.instanceId), title: p.title, goal: p.goal, isPaused: p.paused,
            createdBy: PlanAuthor(rawValue: p.createdBy), awaitingConfirmation: p.awaitingConfirmation,
            revision: Int(clamping: p.revision), policy: ThinktinKit.PlanPolicy(core: p.policy),
            catchUp: CatchUp(rawValue: p.catchUp), createdAt: Date(ms: p.createdAtMs),
            triggers: p.triggers.map { ThinktinKit.Trigger(core: $0) },
            steps: p.steps.map { ThinktinKit.PlanStep(core: $0) })
        if let next = p.nextFireAtMs.date { nextFireAt = next }
        invalidTriggers = Int(clamping: p.invalidTriggers)
    }
}

extension ThinktinKit.NewPlan {
    /// `policy`、`catchUp` 为 nil 时不发，用服务端默认的。
    var core: Core.NewPlan {
        Core.NewPlan(
            instanceId: instanceID.rawValue, title: title, goal: goal, triggers: triggers.map(\.core),
            steps: steps.map(\.core), policy: policy?.core, catchUp: catchUp?.rawValue)
    }
}

extension ThinktinKit.PlanChange {
    /// 只带给了的字段，其余为 nil（client-core 不发，服务端不改）。`steps` 给空数组就是变回单个 agent 的计划。
    var core: Core.PlanChange {
        Core.PlanChange(
            title: title, goal: goal, policy: policy?.core, catchUp: catchUp?.rawValue, steps: steps?.map(\.core))
    }
}

// MARK: - 团队与团队模板（8.1）

extension ThinktinKit.TeamMember {
    init(core m: Core.TeamMember) {
        self.init(
            instanceID: InstanceID(m.instanceId), role: TeamRole(rawValue: m.role), position: Int(clamping: m.position))
    }

    var core: Core.TeamMember {
        Core.TeamMember(instanceId: instanceID.rawValue, role: role.rawValue, position: UInt32(clamping: position))
    }
}

extension ThinktinKit.Team {
    init(core t: Core.Team) {
        self.init(
            id: TeamID(t.id), name: t.name, members: t.members.map { ThinktinKit.TeamMember(core: $0) },
            createdAt: Date(ms: t.createdAtMs))
    }
}

extension ThinktinKit.TemplateMember {
    init(core m: Core.TemplateMember) {
        self.init(agentID: AgentID(m.agentId), harness: m.harness, name: m.name, role: TeamRole(rawValue: m.role))
    }

    var core: Core.TemplateMember {
        Core.TemplateMember(agentId: agentID.rawValue, harness: harness, name: name, role: role.rawValue)
    }
}

extension ThinktinKit.TeamTemplate {
    init(core t: Core.TeamTemplate) {
        self.init(
            id: TeamTemplateID(t.id), name: t.name, members: t.members.map { ThinktinKit.TemplateMember(core: $0) },
            createdAt: Date(ms: t.createdAtMs))
    }
}

// MARK: - 内容举报（5.5）

extension ThinktinKit.ContentReport {
    init(core r: Core.ContentReport) {
        self.init(
            id: ContentReportID(r.id), runID: RunID(r.runId), instanceID: InstanceID(r.instanceId),
            eventSeq: r.eventSeq, artifactID: r.artifactId.map { ArtifactID($0) },
            reason: ReportReason(rawValue: r.reason), note: r.note, state: ReportState(rawValue: r.state),
            resolution: r.resolution, createdAt: Date(ms: r.createdAtMs), handledAt: r.handledAtMs.date)
    }
}

// MARK: - 收件箱

extension ThinktinKit.InboxItem {
    init(core i: Core.InboxItem) {
        self.init(
            id: InboxItemID(i.id), instanceID: i.instanceId.map { InstanceID($0) }, runID: i.runId.map { RunID($0) },
            planID: i.planId.map { PlanID($0) }, approvalID: i.approvalId.map { ApprovalID($0) },
            vaultRequestID: i.vaultRequestId.map { VaultRequestID($0) }, kind: InboxKind(rawValue: i.kind),
            subtype: i.subtype.map { NotificationSubtype(rawValue: $0) }, title: i.title, body: i.body,
            isAIGenerated: i.aiGenerated, isRead: i.read, createdAt: Date(ms: i.createdAtMs))
    }
}

extension ThinktinKit.InboxPage {
    init(core p: Core.InboxPage) {
        self.init(items: p.items.map { ThinktinKit.InboxItem(core: $0) }, unread: Int(clamping: p.unread))
    }
}

// MARK: - 事件流

extension ThinktinKit.InstanceEvent {
    init(core e: Core.InstanceEvent) {
        self.init(
            instanceID: InstanceID(e.instanceId), seq: e.seq, runID: e.runId.map { RunID($0) },
            kind: InstanceEventKind(rawValue: e.kind), payloadJSON: e.payloadJson, isAIGenerated: e.aiGenerated,
            createdAt: Date(ms: e.createdAtMs))
    }
}

extension ThinktinKit.StreamStatus {
    init(core s: Core.StreamStatus) {
        switch s {
        case .connecting: self = .connecting
        case .live: self = .live
        case .reconnecting(let retryInMs): self = .reconnecting(retryIn: TimeInterval(retryInMs) / 1000)
        case .signedOut: self = .signedOut
        case .notFound: self = .notFound
        case .accountFrozen: self = .accountFrozen
        case .upgradeRequired: self = .upgradeRequired
        case .stopped: self = .stopped
        }
    }
}

// MARK: - 模型 key 与用量

extension ThinktinKit.Credential {
    init(core c: Core.Credential) {
        self.init(
            id: CredentialID(c.id), vendor: c.vendor, label: c.label, last4: c.last4,
            dailyTokenLimit: c.dailyTokenLimit.map { Int(clamping: $0) }, isDisabled: c.disabled,
            createdAt: Date(ms: c.createdAtMs), protocols: c.protocols.map { ModelProtocol(rawValue: $0) })
    }
}

extension ThinktinKit.NewCredential {
    var core: Core.NewCredential {
        Core.NewCredential(
            vendor: vendor, label: label, apiKey: apiKey, anthropicBase: anthropicBase, openaiBase: openaiBase,
            responsesBase: responsesBase, dailyTokenLimit: dailyTokenLimit.map { UInt64(clamping: $0) })
    }
}

extension ThinktinKit.VendorInfo {
    init(core v: Core.VendorInfo) {
        self.init(
            id: v.id, name: v.name, protocols: v.protocols, models: v.models, notes: v.notes,
            subscriptionKeyPrefixes: v.subscriptionKeyPrefixes, planOnlyBases: v.planOnlyBases)
    }
}

extension ThinktinKit.UsageBucket {
    init(core b: Core.UsageBucket) {
        self.init(
            key: b.key, requests: Int(clamping: b.requests), inputTokens: Int(clamping: b.inputTokens),
            cacheReadTokens: Int(clamping: b.cacheReadTokens), cacheWriteTokens: Int(clamping: b.cacheWriteTokens),
            outputTokens: Int(clamping: b.outputTokens), chargedTokens: Int(clamping: b.chargedTokens),
            estimatedRequests: Int(clamping: b.estimatedRequests), failedRequests: Int(clamping: b.failedRequests))
    }
}

extension ThinktinKit.UsageSummary {
    init(core s: Core.UsageSummary) {
        self.init(
            buckets: s.buckets.map { ThinktinKit.UsageBucket(core: $0) }, total: ThinktinKit.UsageBucket(core: s.total))
    }
}

// MARK: - 保险箱与密码检查

extension ThinktinKit.VaultItem {
    init(core v: Core.VaultItem) {
        self.init(
            id: VaultItemID(v.id), name: v.name, purpose: v.purpose, hasUsername: v.hasUsername,
            instanceIDs: v.instanceIds.map { InstanceID($0) }, createdAt: Date(ms: v.createdAtMs),
            updatedAt: Date(ms: v.updatedAtMs), lastUsedAt: v.lastUsedAtMs.date)
    }
}

extension ThinktinKit.VaultItemDetail {
    init(core d: Core.VaultItemDetail) {
        self.init(item: ThinktinKit.VaultItem(core: d.item), username: d.username)
    }
}

extension ThinktinKit.NewVaultItem {
    var core: Core.NewVaultItem {
        Core.NewVaultItem(
            name: name, purpose: purpose, username: username, password: password,
            instanceIds: instanceIDs.map(\.rawValue))
    }
}

extension ThinktinKit.VaultItemUpdate {
    var core: Core.VaultItemUpdate {
        Core.VaultItemUpdate(
            purpose: purpose, username: username, password: password, instanceIds: instanceIDs?.map(\.rawValue))
    }
}

extension ThinktinKit.VaultRequest {
    init(core r: Core.VaultRequest) {
        self.init(
            id: VaultRequestID(r.id), instanceID: InstanceID(r.instanceId), runID: r.runId.map { RunID($0) },
            name: r.name, purpose: r.purpose, fields: r.fields.map { VaultField(rawValue: $0) },
            status: VaultRequestStatus(rawValue: r.status), itemID: r.itemId.map { VaultItemID($0) },
            createdAt: Date(ms: r.createdAtMs), expiresAt: Date(ms: r.expiresAtMs), resolvedAt: r.resolvedAtMs.date)
    }
}

extension ThinktinKit.DetectedSecret {
    /// `start` / `end` 是 UTF-16 下标（client-core 已经从字节下标换算好），左闭右开。
    init(core d: Core.DetectedSecret) {
        let start = Int(clamping: d.start)
        self.init(
            kind: SecretKind(rawValue: d.kind), utf16Range: start..<max(start, Int(clamping: d.end)), value: d.value,
            suggestedName: d.suggestedName, service: d.service, isStorable: d.storable)
    }
}

extension ThinktinKit.SecretReference {
    var core: Core.SecretReference { Core.SecretReference(value: value, name: name) }
}

extension ThinktinKit.SavedSecret {
    init(core s: Core.SavedSecret) {
        self.init(item: ThinktinKit.VaultItem(core: s.item), message: s.message)
    }
}

// MARK: - IM 渠道

extension ThinktinKit.ImChannel {
    init(core c: Core.ImChannel) {
        self.init(
            id: ImChannelID(c.id), vendor: ImVendor(rawValue: c.vendor), label: c.label, hint: c.hint,
            hasSecret: c.hasSecret, events: c.events.map { ImEvent(rawValue: $0) }, isEnabled: c.enabled,
            lastSentAt: c.lastSentAtMs.date, lastError: c.lastError, createdAt: Date(ms: c.createdAtMs))
    }
}

extension ThinktinKit.NewImChannel {
    var core: Core.NewImChannel {
        Core.NewImChannel(webhookUrl: webhookURL, secret: secret, label: label, events: events?.map(\.rawValue))
    }
}

// MARK: - 错误

extension ThinktinKit.ClientError {
    /// 把任意错误转成 ThinktinKit 的 `ClientError`：ThinktinCore 的 `ClientError`、`PairingError` 逐个 case 对应；
    /// 已经是 ThinktinKit 的原样返回；其他（UniFFI 的内部错误，比如 Rust 里 panic）算 `internal`。
    init(_ error: any Error) {
        if let e = error as? ThinktinKit.ClientError {
            self = e
        } else if let e = error as? Core.ClientError {
            self.init(core: e)
        } else if let e = error as? Core.PairingError {
            self.init(core: e)
        } else {
            self = .internal(message: String(describing: error))
        }
    }

    /// ThinktinCore 的 `detail`（339e191 起，原来叫 `message`）放进 ThinktinKit 的 `message`：都是英文、给开发者看的
    /// 说明，界面不显示（按错误码本地化，`localizedMessage`）。
    init(core e: Core.ClientError) {
        switch e {
        case .Network(let detail): self = .network(message: detail)
        case .SignedOut: self = .signedOut
        case .UpgradeRequired: self = .upgradeRequired
        case .AccountFrozen: self = .accountFrozen
        case .Api(let status, let code, let detail, let retryAfterSecs):
            self = .api(
                status: Int(status), code: APIErrorCode(rawValue: code), message: detail,
                retryAfterSecs: retryAfterSecs.map { Int(clamping: $0) })
        case .Decode(let detail): self = .decode(message: detail)
        case .Cache(let detail): self = .cache(message: detail)
        case .ContainsSecrets(let count): self = .containsSecrets(count: Int(clamping: count))
        case .InvalidArgument(let detail): self = .invalidArgument(message: detail)
        case .Internal(let detail): self = .internal(message: detail)
        }
    }

    init(core e: Core.PairingError) {
        switch e {
        case .Malformed(let detail): self = .malformed(message: detail)
        case .Expired: self = .expired
        case .BadSignature: self = .badSignature
        }
    }
}
