import Foundation
import ThinktinCore

/// ThinktinCore（UniFFI 生成）的类型统一从这里引用。
///
/// 两个模块里大多数类型同名（`Instance`、`Run`、`ClientError`……）。这个文件只 import ThinktinCore，
/// 适配层的其他文件只 import ThinktinKit：不加前缀的名字一律是 ThinktinKit 的领域模型，`Core.` 开头的是 ThinktinCore 的。
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
    typealias Plan = ThinktinCore.Plan
    typealias NewPlan = ThinktinCore.NewPlan
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

    // 自由函数（不联网）。

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
