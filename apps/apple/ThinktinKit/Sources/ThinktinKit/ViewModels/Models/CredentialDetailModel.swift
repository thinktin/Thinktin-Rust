import Foundation
import Observation

/// key 详情（WBS 12.4，`.credential(id)`）：改备注、启用 / 停用、换 key（`replaceCredentialSecret`）、每日上限、删除，
/// 以及哪些实例的哪些别名在用它、最近 30 天的用量。
///
/// - 启用、换 key 后服务端会唤醒等 key 的运行（7.11）：操作前后数一下用这把 key 的实例上等 key 的运行，
///   界面说“已唤醒 N 个任务”（`wakeResult`）。界面再调一次 `AppModel.refreshBadges()`，抽屉跟着变。
/// - 删除：服务端不让删还在路由里的 key（409）。先列出用它的别名（`references`），有的话不让删、给“去改路由”的入口。
/// - 停用还在用的 key 前提醒：用它的别名会改用备用 key，没有备用的任务会停在“等待 key”。
/// - 每日上限只在添加时能设（`PATCH /v1/credentials/{id}` 不收它），这里只显示。
@Observable @MainActor
public final class CredentialDetailModel {
    public let credentialID: CredentialID
    public private(set) var credential: Credential?
    public private(set) var vendors: [VendorInfo] = []
    /// 用这把 key 的别名（主 key 或备用）；nil 是还没查到（或查不全）。
    public private(set) var references: [CredentialReference]?
    /// 最近 30 天这把 key 的用量；nil 是还没拉到，拉到了没用过是全 0。
    public private(set) var recentUsage: UsageBucket?

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 用量、路由引用这些附带的信息里第一个拉不到的。
    public private(set) var detailsError: ClientError?
    /// key 不存在了（删掉了）。
    public private(set) var isMissing = false

    public private(set) var isRenaming = false
    public private(set) var renameError: ClientError?
    public private(set) var isTogglingDisabled = false
    public private(set) var toggleError: ClientError?
    public private(set) var isReplacing = false
    public private(set) var replaceRejection: CredentialRejection?
    public private(set) var replaceError: ClientError?
    /// 换过 key 了（界面提示一句，显示新的后 4 位）。
    public private(set) var didReplace = false
    /// 启用、换 key 之后唤醒了几个等 key 的运行。
    public private(set) var wakeResult: KeyWakeResult?
    /// 启用、换 key 成功了，但没数到等 key 的运行（拉不到）：界面只说通用的一句。
    public private(set) var didWake = false

    public private(set) var isDeleting = false
    public private(set) var deleteError: ClientError?
    public private(set) var isDeleted = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let now: @Sendable () -> Date

    /// 用量看最近几天。
    public static let usageDays = 30

    public init(
        client: any ClientProtocol, credentialID: CredentialID, credential: Credential? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.credentialID = credentialID
        self.credential = credential?.id == credentialID ? credential : nil
        self.now = now
    }

    // MARK: 加载

    /// 拉 key（从列表里找）、厂商表，再查哪些路由在用它、最近的用量。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = self.client
        async let vendorList = AgentsErrors.attempt { try await client.vendors() }
        do {
            let list = try await client.credentials()
            credential = list.first { $0.id == credentialID }
            isMissing = credential == nil
            error = nil
        } catch {
            if let failure = AgentsErrors.from(error) { self.error = failure }
        }
        if case .success(let list) = await vendorList { vendors = list }
        guard credential != nil, !isMissing else {
            hasLoaded = true
            return
        }
        await loadDetails()
        hasLoaded = true
    }

    private func loadDetails() async {
        let client = self.client
        let id = credentialID
        let from = now().addingTimeInterval(-Double(Self.usageDays) * 86_400)
        async let usage = AgentsErrors.attempt {
            try await client.usage(group: .credential, from: from, to: nil, timeZone: nil)
        }
        async let refs = Self.findReferences(to: id, client: client)
        var errors: [ClientError] = []
        switch await usage {
        case .success(let summary):
            recentUsage = summary.buckets.first { $0.key == id.rawValue } ?? UsageBucket(key: id.rawValue)
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { errors.append(failure) }
        }
        switch await refs {
        case .success(let list): references = list
        case .failure(let failure):
            references = nil
            if let failure = AgentsErrors.from(failure) { errors.append(failure) }
        }
        detailsError = errors.first
    }

    /// 查每个实例的路由，找出用这把 key 的别名（主 key 在前，再按实例名、别名）。有一个实例查不到就算查不全（失败）。
    nonisolated static func findReferences(to id: CredentialID, client: any ClientProtocol) async
        -> Result<[CredentialReference], any Error>
    {
        do {
            let instances = try await client.instances().filter { $0.state != .deleted }
            let routes = try await withThrowingTaskGroup(of: (Instance, [ModelRoute]).self) { group in
                for instance in instances {
                    group.addTask { (instance, try await client.modelRoutes(instanceID: instance.id)) }
                }
                var out: [(Instance, [ModelRoute])] = []
                for try await item in group { out.append(item) }
                return out
            }
            var refs: [CredentialReference] = []
            for (instance, list) in routes {
                for route in list {
                    if route.credentialID == id {
                        refs.append(CredentialReference(instance: instance, alias: route.alias, position: 0))
                    }
                    for (i, fallback) in route.fallbacks.enumerated() where fallback.credentialID == id {
                        refs.append(CredentialReference(instance: instance, alias: route.alias, position: i + 1))
                    }
                }
            }
            return .success(refs.sorted())
        } catch {
            return .failure(error)
        }
    }

    // MARK: 显示

    public func summary(_ language: DisplayLanguage = .current) -> CredentialSummary? {
        credential.map { CredentialSummary(credential: $0, vendors: vendors, language: language) }
    }

    /// 用它的实例（去重，按 `references` 的顺序：主 key 在前）。
    public var referencingInstances: [InstanceID] {
        var seen = Set<InstanceID>()
        return (references ?? []).compactMap { seen.insert($0.instanceID).inserted ? $0.instanceID : nil }
    }

    /// 能删：查过了，没有路由在用它。
    public var canDelete: Bool { references?.isEmpty == true && !isDeleting }

    /// 删不了的原因（界面放在删除按钮下面）；能删、还没查到为 nil。
    public func deleteBlockedReason(_ language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        guard let references else {
            return zh ? "正在查哪些模型路由在用它…" : "Checking which model routes use it…"
        }
        guard !references.isEmpty else { return nil }
        let count = Set(references.map(\.instanceID)).count
        return zh
            ? "还有 \(count) 个实例的模型路由在用它，先在路由里换成别的 key 才能删。"
            : "It's still used by model routes in \(count) instance(s). Switch them to another key before deleting."
    }

    /// 停用前的提醒（有路由在用它时）；没在用为 nil。
    public func disableWarning(_ language: DisplayLanguage = .current) -> String? {
        guard let references, !references.isEmpty else { return nil }
        let zh = language == .chinese
        return zh
            ? "有 \(references.count) 个别名在用它。停用后这些别名会改用备用 key；没有备用的，任务会停在“等待 key”。"
            : "\(references.count) alias(es) use it. Once disabled they switch to their fallbacks; aliases without a "
                + "fallback leave tasks waiting for a key."
    }

    // MARK: 改备注

    /// 改备注（去掉首尾空白，0 到 64 个字符；空的就显示厂商名）。没变直接算成功。
    @discardableResult
    public func rename(to newLabel: String) async -> Bool {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let credential, !isRenaming, CredentialRules.labelProblem(label) == nil else { return false }
        if label == credential.label { return true }
        isRenaming = true
        renameError = nil
        defer { isRenaming = false }
        do {
            self.credential = try await client.updateCredential(credentialID, label: label, disabled: nil)
            return true
        } catch {
            renameError = AgentsErrors.from(error)
            return false
        }
    }

    public func clearRenameError() {
        renameError = nil
    }

    // MARK: 启用 / 停用

    /// 启用或停用。启用后数一下唤醒了几个等 key 的运行。
    @discardableResult
    public func setDisabled(_ disabled: Bool) async -> Bool {
        guard let credential, !isTogglingDisabled, credential.isDisabled != disabled else { return false }
        isTogglingDisabled = true
        toggleError = nil
        wakeResult = nil
        didWake = false
        defer { isTogglingDisabled = false }
        var before: Int?
        if !disabled { before = await waitingRuns() }
        do {
            self.credential = try await client.updateCredential(credentialID, label: nil, disabled: disabled)
        } catch {
            toggleError = AgentsErrors.from(error)
            return false
        }
        if !disabled { await noteWake(before: before) }
        return true
    }

    // MARK: 换 key

    /// 换 key（同一个厂商、同一条记录，路由不用改）。
    @discardableResult
    public func replaceSecret(_ newKey: String) async -> Bool {
        let key = CredentialRules.normalizedKey(newKey)
        guard credential != nil, !isReplacing, CredentialRules.keyProblem(key) == nil else { return false }
        isReplacing = true
        replaceRejection = nil
        replaceError = nil
        wakeResult = nil
        didWake = false
        defer { isReplacing = false }
        let before = await waitingRuns()
        do {
            credential = try await client.replaceCredentialSecret(credentialID, apiKey: key)
            didReplace = true
        } catch {
            guard let failure = AgentsErrors.from(error) else { return false }
            if let rejection = CredentialRejection(failure) {
                replaceRejection = rejection
            } else {
                replaceError = failure
            }
            return false
        }
        await noteWake(before: before)
        return true
    }

    /// 关掉换 key 的表单时清掉上次的错误。
    public func clearReplaceErrors() {
        replaceRejection = nil
        replaceError = nil
    }

    // MARK: 删除

    /// 删除（二次确认之后）。还在路由里的不发请求。已经不存在了也算删掉了。
    @discardableResult
    public func delete() async -> Bool {
        guard canDelete, !isDeleted else { return false }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await client.deleteCredential(credentialID)
            isDeleted = true
        } catch {
            guard let failure = AgentsErrors.from(error) else { return false }
            if failure.isNotFound {
                isDeleted = true
            } else {
                deleteError = failure
                // 别处刚把它配进了路由（409）：重新查一次引用，界面换成“先改路由”。
                if failure.isConflict,
                    case .success(let refs) = await Self.findReferences(to: credentialID, client: client)
                {
                    references = refs
                }
            }
        }
        return isDeleted
    }

    /// 删除失败的说明：服务端说还在用（409）时换成“还有路由在用”，别的照常。
    public func deleteErrorMessage(_ language: DisplayLanguage = .current) -> String? {
        guard let deleteError else { return nil }
        if deleteError.isConflict { return deleteBlockedReason(language) ?? deleteError.localizedMessage(language) }
        return deleteError.localizedMessage(language)
    }

    // MARK: 等 key 的运行

    private func waitingRuns() async -> Int? {
        let instances = references.map { Set($0.map(\.instanceID)) }
        return await KeyWaitProbe.waitingRuns(client: client, instanceIDs: instances)
    }

    private func noteWake(before: Int?) async {
        let after = await waitingRuns()
        wakeResult = KeyWakeResult(before: before, after: after)
        didWake = true
    }
}

/// 一个用这把 key 的别名。
public struct CredentialReference: Identifiable, Hashable, Sendable, Comparable {
    public var instanceID: InstanceID
    public var instanceName: String
    public var alias: String
    /// 0 是主 key，1…3 是降级链里的第几个备用。
    public var position: Int

    public var id: String { "\(instanceID.rawValue)/\(alias)/\(position)" }

    public init(instanceID: InstanceID, instanceName: String, alias: String, position: Int) {
        self.instanceID = instanceID
        self.instanceName = instanceName
        self.alias = alias
        self.position = position
    }

    init(instance: Instance, alias: String, position: Int) {
        self.init(instanceID: instance.id, instanceName: instance.name, alias: alias, position: position)
    }

    public var isFallback: Bool { position > 0 }

    /// “写作助手 · main” 下面那行：“主 key” / “备用 1”。
    public func role(_ language: DisplayLanguage = .current) -> String {
        if position == 0 { return language == .chinese ? "主 key" : "Primary key" }
        return ModelsText.fallbackTitle(position, language: language)
    }

    /// 主 key 在前，再按实例名、别名、位置。
    public static func < (a: Self, b: Self) -> Bool {
        if a.isFallback != b.isFallback { return !a.isFallback }
        if a.instanceName != b.instanceName { return a.instanceName < b.instanceName }
        if a.alias != b.alias { return a.alias < b.alias }
        return a.position < b.position
    }
}
