import Foundation
import ThinktinKit

// ThinktinCore 记录 ↔ ThinktinKit 领域模型。毫秒 → Date，字符串 → 强类型 id / 枚举，无符号整数 → Int（截断到范围内）。

extension Date {
    init(ms: Int64) { self.init(unixMilliseconds: ms) }
}

extension Optional where Wrapped == Int64 {
    var date: Date? { map(Date.init(ms:)) }
}

// MARK: Core → Kit

extension User {
    init(core u: Core.User) {
        self.init(
            id: UserID(u.id), phone: u.phone, displayName: u.displayName, status: UserStatus(rawValue: u.status),
            locale: UserLocale(rawValue: u.locale), createdAt: Date(ms: u.createdAtMs))
    }
}

extension LoginResult {
    init(core r: Core.LoginResult) {
        self.init(user: User(core: r.user), isNewUser: r.newUser)
    }
}

extension StopAllResult {
    init(core r: Core.StopAllResult) {
        self.init(
            runsCancelled: Int(clamping: r.runsCancelled), grantsRevoked: Int(clamping: r.grantsRevoked),
            plansPaused: Int(clamping: r.plansPaused))
    }
}

extension SignOutOthersResult {
    init(core r: Core.SignOutOthersResult) {
        self.init(devicesSignedOut: Int(clamping: r.devicesSignedOut), stopped: r.stopped.map(StopAllResult.init(core:)))
    }
}

extension AgentInfo {
    init(core a: Core.AgentInfo) {
        self.init(
            id: AgentID(a.id), name: a.name, version: a.version, license: a.license, sites: a.sites,
            harnesses: a.harnesses, defaultHarness: a.defaultHarness, versions: a.versions)
    }
}

extension Instance {
    init(core i: Core.Instance) {
        self.init(
            id: InstanceID(i.id), agentID: AgentID(i.agentId), agentVersion: i.agentVersion, harness: i.harness,
            name: i.name, state: InstanceState(rawValue: i.state), createdAt: Date(ms: i.createdAtMs),
            lastActiveAt: Date(ms: i.lastActiveAtMs))
    }
}

extension ModelRoute {
    init(core r: Core.ModelRoute) {
        self.init(
            alias: r.alias, credentialID: CredentialID(r.credentialId), upstreamModel: r.upstreamModel,
            fallbacks: r.fallbacks.map {
                RouteFallback(credentialID: CredentialID($0.credentialId), upstreamModel: $0.upstreamModel)
            })
    }

    var core: Core.ModelRoute {
        Core.ModelRoute(
            alias: alias, credentialId: credentialID.rawValue, upstreamModel: upstreamModel,
            fallbacks: fallbacks.map {
                Core.RouteFallback(credentialId: $0.credentialID.rawValue, upstreamModel: $0.upstreamModel)
            })
    }
}

extension Run {
    init(core r: Core.Run) {
        self.init(
            id: RunID(r.id), kind: RunKind(rawValue: r.kind), instanceID: InstanceID(r.instanceId),
            planID: r.planId.map(PlanID.init), parentRunID: r.parentRunId.map(RunID.init),
            rootRunID: RunID(r.rootRunId), stepKey: r.stepKey, source: RunSource(rawValue: r.source),
            prompt: r.prompt, state: RunState(rawValue: r.state), stateReason: r.stateReason,
            attempt: Int(r.attempt), tokensUsed: Int(clamping: r.tokensUsed), summary: r.summary, error: r.error,
            createdAt: Date(ms: r.createdAtMs), startedAt: r.startedAtMs.date, finishedAt: r.finishedAtMs.date)
    }
}

extension Artifact {
    init(core a: Core.Artifact) {
        self.init(
            id: ArtifactID(a.id), instanceID: InstanceID(a.instanceId), runID: RunID(a.runId), name: a.name,
            version: Int(a.version), contentType: a.contentType, size: Int(clamping: a.size), sha256: a.sha256,
            createdAt: Date(ms: a.createdAtMs))
    }
}

extension Approval {
    init(core a: Core.Approval) {
        self.init(
            id: ApprovalID(a.id), runID: RunID(a.runId), instanceID: InstanceID(a.instanceId), title: a.title,
            options: a.options.map {
                ApprovalOption(id: $0.optionId, name: $0.name, kind: ApprovalOptionKind(rawValue: $0.kind))
            }, toolCallJSON: a.toolCallJson, state: ApprovalState(rawValue: a.state), expiresAt: Date(ms: a.expiresAtMs),
            createdAt: Date(ms: a.createdAtMs))
    }
}

extension Schedule {
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

extension Trigger {
    init(core t: Core.Trigger) {
        self.init(
            id: TriggerID(t.id), schedule: Schedule(core: t.schedule), isEnabled: t.enabled,
            nextFireAt: t.nextFireAtMs.date, lastFireAt: t.lastFireAtMs.date)
    }
}

extension PlanStep {
    init(core s: Core.PlanStep) {
        self.init(key: s.key, instanceID: InstanceID(s.instanceId), prompt: s.prompt, dependsOn: s.dependsOn)
    }

    var core: Core.PlanStep {
        Core.PlanStep(key: key, instanceId: instanceID.rawValue, prompt: prompt, dependsOn: dependsOn)
    }
}

extension Plan {
    init(core p: Core.Plan) {
        self.init(
            id: PlanID(p.id), instanceID: InstanceID(p.instanceId), title: p.title, goal: p.goal, isPaused: p.paused,
            createdBy: PlanAuthor(rawValue: p.createdBy), awaitingConfirmation: p.awaitingConfirmation,
            revision: Int(p.revision), policyJSON: p.policyJson, createdAt: Date(ms: p.createdAtMs),
            triggers: p.triggers.map(Trigger.init(core:)), steps: p.steps.map(PlanStep.init(core:)))
    }
}

extension NewPlan {
    var core: Core.NewPlan {
        Core.NewPlan(
            instanceId: instanceID.rawValue, title: title, goal: goal, triggers: triggers.map(\.core),
            steps: steps.map(\.core))
    }
}

extension InboxItem {
    init(core i: Core.InboxItem) {
        self.init(
            id: InboxItemID(i.id), instanceID: i.instanceId.map(InstanceID.init), runID: i.runId.map(RunID.init),
            planID: i.planId.map(PlanID.init), approvalID: i.approvalId.map(ApprovalID.init),
            kind: InboxKind(rawValue: i.kind), title: i.title, body: i.body, isAIGenerated: i.aiGenerated,
            isRead: i.read, createdAt: Date(ms: i.createdAtMs))
    }
}

extension InboxPage {
    init(core p: Core.InboxPage) {
        self.init(items: p.items.map(InboxItem.init(core:)), unread: Int(clamping: p.unread))
    }
}

extension InstanceEvent {
    init(core e: Core.InstanceEvent) {
        self.init(
            instanceID: InstanceID(e.instanceId), seq: e.seq, runID: e.runId.map(RunID.init),
            kind: InstanceEventKind(rawValue: e.kind), payloadJSON: e.payloadJson, isAIGenerated: e.aiGenerated,
            createdAt: Date(ms: e.createdAtMs))
    }
}

extension StreamStatus {
    init(core s: Core.StreamStatus) {
        switch s {
        case .connecting: self = .connecting
        case .live: self = .live
        case .reconnecting(let retryInMs): self = .reconnecting(retryIn: TimeInterval(retryInMs) / 1000)
        case .signedOut: self = .signedOut
        case .notFound: self = .notFound
        case .accountFrozen: self = .accountFrozen
        case .stopped: self = .stopped
        }
    }
}

extension Credential {
    init(core c: Core.Credential) {
        self.init(
            id: CredentialID(c.id), vendor: c.vendor, label: c.label, last4: c.last4,
            dailyTokenLimit: c.dailyTokenLimit.map { Int(clamping: $0) }, isDisabled: c.disabled,
            createdAt: Date(ms: c.createdAtMs))
    }
}

extension NewCredential {
    var core: Core.NewCredential {
        Core.NewCredential(
            vendor: vendor, label: label, apiKey: apiKey, anthropicBase: anthropicBase, openaiBase: openaiBase,
            responsesBase: responsesBase, dailyTokenLimit: dailyTokenLimit.map { UInt64(clamping: $0) })
    }
}

extension VendorInfo {
    init(core v: Core.VendorInfo) {
        self.init(id: v.id, name: v.name, protocols: v.protocols, models: v.models, notes: v.notes)
    }
}

extension UsageBucket {
    init(core b: Core.UsageBucket) {
        self.init(
            key: b.key, requests: Int(clamping: b.requests), inputTokens: Int(clamping: b.inputTokens),
            cacheReadTokens: Int(clamping: b.cacheReadTokens), cacheWriteTokens: Int(clamping: b.cacheWriteTokens),
            outputTokens: Int(clamping: b.outputTokens), chargedTokens: Int(clamping: b.chargedTokens),
            estimatedRequests: Int(clamping: b.estimatedRequests), failedRequests: Int(clamping: b.failedRequests))
    }
}

extension UsageSummary {
    init(core s: Core.UsageSummary) {
        self.init(buckets: s.buckets.map(UsageBucket.init(core:)), total: UsageBucket(core: s.total))
    }
}

extension VaultItem {
    init(core v: Core.VaultItem) {
        self.init(
            id: VaultItemID(v.id), name: v.name, purpose: v.purpose, hasUsername: v.hasUsername,
            instanceIDs: v.instanceIds.map(InstanceID.init), createdAt: Date(ms: v.createdAtMs),
            updatedAt: Date(ms: v.updatedAtMs), lastUsedAt: v.lastUsedAtMs.date)
    }
}

extension VaultItemDetail {
    init(core d: Core.VaultItemDetail) {
        self.init(item: VaultItem(core: d.item), username: d.username)
    }
}

extension NewVaultItem {
    var core: Core.NewVaultItem {
        Core.NewVaultItem(
            name: name, purpose: purpose, username: username, password: password,
            instanceIds: instanceIDs.map(\.rawValue))
    }
}

extension VaultItemUpdate {
    var core: Core.VaultItemUpdate {
        Core.VaultItemUpdate(
            purpose: purpose, username: username, password: password, instanceIds: instanceIDs?.map(\.rawValue))
    }
}

extension VaultRequest {
    init(core r: Core.VaultRequest) {
        self.init(
            id: VaultRequestID(r.id), instanceID: InstanceID(r.instanceId), runID: r.runId.map(RunID.init),
            name: r.name, purpose: r.purpose, fields: r.fields.map(VaultField.init(rawValue:)),
            status: VaultRequestStatus(rawValue: r.status), itemID: r.itemId.map(VaultItemID.init),
            createdAt: Date(ms: r.createdAtMs), expiresAt: Date(ms: r.expiresAtMs), resolvedAt: r.resolvedAtMs.date)
    }
}

extension DetectedSecret {
    init(core d: Core.DetectedSecret) {
        let start = Int(d.start)
        self.init(
            kind: SecretKind(rawValue: d.kind), utf16Range: start..<max(start, Int(d.end)), value: d.value,
            suggestedName: d.suggestedName, service: d.service, isStorable: d.storable)
    }
}

extension SecretReference {
    var core: Core.SecretReference { Core.SecretReference(value: value, name: name) }
}

extension SavedSecret {
    init(core s: Core.SavedSecret) {
        self.init(item: VaultItem(core: s.item), message: s.message)
    }
}

extension ImChannel {
    init(core c: Core.ImChannel) {
        self.init(
            id: ImChannelID(c.id), vendor: ImVendor(rawValue: c.vendor), label: c.label, hint: c.hint,
            hasSecret: c.hasSecret, events: c.events.map(ImEvent.init(rawValue:)), isEnabled: c.enabled,
            lastSentAt: c.lastSentAtMs.date, lastError: c.lastError, createdAt: Date(ms: c.createdAtMs))
    }
}

extension NewImChannel {
    var core: Core.NewImChannel {
        Core.NewImChannel(webhookUrl: webhookURL, secret: secret, label: label, events: events?.map(\.rawValue))
    }
}

extension Session {
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

// MARK: 错误

extension ClientError {
    /// 把任意错误转成 ThinktinKit 的 `ClientError`（ThinktinCore 的 `ClientError`、`PairingError` 一一对应）。
    init(_ error: any Error) {
        if let e = error as? ClientError {
            self = e
        } else if let e = error as? Core.ClientError {
            self.init(core: e)
        } else if let e = error as? Core.PairingError {
            self.init(core: e)
        } else {
            self = .internal(message: String(describing: error))
        }
    }

    init(core e: Core.ClientError) {
        switch e {
        case .Network(let message): self = .network(message: message)
        case .SignedOut: self = .signedOut
        case .UpgradeRequired: self = .upgradeRequired
        case .AccountFrozen: self = .accountFrozen
        case .Api(let status, let code, let message, let retryAfterSecs):
            self = .api(
                status: Int(status), code: APIErrorCode(rawValue: code), message: message,
                retryAfterSecs: retryAfterSecs.map { Int(clamping: $0) })
        case .Decode(let message): self = .decode(message: message)
        case .Cache(let message): self = .cache(message: message)
        case .ContainsSecrets(let count): self = .containsSecrets(count: Int(count))
        case .InvalidArgument(let message): self = .invalidArgument(message: message)
        case .Internal(let message): self = .internal(message: message)
        }
    }

    init(core e: Core.PairingError) {
        switch e {
        case .Malformed(let message): self = .malformed(message: message)
        case .Expired: self = .expired
        case .BadSignature: self = .badSignature
        }
    }
}
