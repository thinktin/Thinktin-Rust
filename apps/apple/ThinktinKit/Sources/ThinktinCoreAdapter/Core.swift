import Foundation
import ThinktinCore

/// ThinktinCore（UniFFI 生成）的类型统一从这里引用。
///
/// 两个模块里大多数类型同名（`Instance`、`Run`、`Plan`、`Schedule`、`Session`、`ClientError`……）。约定：
/// - 这个文件只 import ThinktinCore，把要用的类型和自由函数收在 `Core` 下；
/// - 适配层的其他文件只 import ThinktinKit，同名类型写全 `ThinktinKit.X`，ThinktinCore 的一律写 `Core.X`。
///
/// 其他文件经 `Core.X` 用到 ThinktinCore 类型的成员，靠的是 Swift 默认的成员可见性（模块里有一个文件 import 了，
/// 成员就处处可见）。所以这个目标不要打开 `MemberImportVisibility`（SE-0444），否则要在用到的文件里也 import ThinktinCore。
enum Core {
    typealias Client = ThinktinCore.ThinktinClient
    typealias ClientConfig = ThinktinCore.ClientConfig
    typealias ClientError = ThinktinCore.ClientError
    typealias PairingError = ThinktinCore.PairingError
    typealias SessionStore = ThinktinCore.SessionStore
    typealias Session = ThinktinCore.Session
    typealias EventListener = ThinktinCore.EventListener
    typealias EventSubscription = ThinktinCore.EventSubscription
    typealias StreamStatus = ThinktinCore.StreamStatus

    typealias User = ThinktinCore.User
    typealias LoginResult = ThinktinCore.LoginResult
    typealias StopAllResult = ThinktinCore.StopAllResult
    typealias SignOutOthersResult = ThinktinCore.SignOutOthersResult
    typealias DeviceInfo = ThinktinCore.DeviceInfo
    typealias DeviceMessage = ThinktinCore.DeviceMessage
    typealias AgentInfo = ThinktinCore.AgentInfo
    typealias Instance = ThinktinCore.Instance
    typealias ModelRoute = ThinktinCore.ModelRoute
    typealias RouteFallback = ThinktinCore.RouteFallback
    typealias Run = ThinktinCore.Run
    typealias Artifact = ThinktinCore.Artifact
    typealias Approval = ThinktinCore.Approval
    typealias ApprovalOption = ThinktinCore.ApprovalOption
    typealias Schedule = ThinktinCore.Schedule
    typealias Trigger = ThinktinCore.Trigger
    typealias PlanStep = ThinktinCore.PlanStep
    typealias PlanPolicy = ThinktinCore.PlanPolicy
    typealias Plan = ThinktinCore.Plan
    typealias NewPlan = ThinktinCore.NewPlan
    typealias PlanChange = ThinktinCore.PlanChange
    typealias Team = ThinktinCore.Team
    typealias TeamMember = ThinktinCore.TeamMember
    typealias TeamTemplate = ThinktinCore.TeamTemplate
    typealias TemplateMember = ThinktinCore.TemplateMember
    typealias ContentReport = ThinktinCore.ContentReport
    typealias InboxItem = ThinktinCore.InboxItem
    typealias InboxPage = ThinktinCore.InboxPage
    typealias InstanceEvent = ThinktinCore.InstanceEvent
    typealias Credential = ThinktinCore.Credential
    typealias NewCredential = ThinktinCore.NewCredential
    typealias VendorInfo = ThinktinCore.VendorInfo
    typealias UsageBucket = ThinktinCore.UsageBucket
    typealias UsageSummary = ThinktinCore.UsageSummary
    typealias VaultItem = ThinktinCore.VaultItem
    typealias VaultItemDetail = ThinktinCore.VaultItemDetail
    typealias NewVaultItem = ThinktinCore.NewVaultItem
    typealias VaultItemUpdate = ThinktinCore.VaultItemUpdate
    typealias VaultRequest = ThinktinCore.VaultRequest
    typealias DetectedSecret = ThinktinCore.DetectedSecret
    typealias SecretReference = ThinktinCore.SecretReference
    typealias SavedSecret = ThinktinCore.SavedSecret
    typealias ImChannel = ThinktinCore.ImChannel
    typealias NewImChannel = ThinktinCore.NewImChannel
    typealias RunFilter = ThinktinCore.RunFilter
    typealias LogSink = ThinktinCore.LogSink
    typealias LogRecord = ThinktinCore.LogRecord
    typealias LogLevel = ThinktinCore.LogLevel

    // 自由函数（不联网）。

    /// 语言列表拼成 `Accept-Language`（11.8）；一个能用的都没有时是空串。
    static func acceptLanguageHeader(_ tags: [String]) -> String {
        ThinktinCore.acceptLanguageHeader(tags: tags)
    }

    /// 把 client-core 的日志交给 `sink`（11.8）；再调一次是换掉 sink、改级别。进程里已经有别的 tracing 订阅者时返回 false。
    static func initLogging(sink: any LogSink, maxLevel: LogLevel) -> Bool {
        ThinktinCore.initLogging(sink: sink, maxLevel: maxLevel)
    }

    static func detectSecrets(_ text: String) -> [DetectedSecret] {
        ThinktinCore.detectSecrets(text: text)
    }

    static func redactMessage(_ text: String, references: [SecretReference]) -> String {
        ThinktinCore.redactMessage(text: text, references: references)
    }

    static func uniqueVaultName(base: String, taken: [String]) -> String {
        ThinktinCore.uniqueVaultName(base: base, taken: taken)
    }

    static func makeClient(config: ClientConfig, sessions: any SessionStore) throws -> Client {
        try ThinktinCore.ThinktinClient(config: config, sessions: sessions)
    }
}
