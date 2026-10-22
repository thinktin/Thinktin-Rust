import Foundation
import Observation

/// 实例的模型路由（WBS 12.4，`.modelRoutes(id)`，入口：实例详情、领养完成、引导 12.17、对话页“等待 key”的“去处理”）。
///
/// 规则（ios-packages.md 12.4 “模型别名的规则”）：
/// - `main` 必须有、放第一个（执行器有 main 就用 main）；`fast` 可选，给轻量任务用（Claude 的 Haiku 槽位）；
///   别的别名按格式自己加，一个实例最多 16 个。
/// - 每个别名一把主 key 加最多 3 个备用（降级链），上游模型可以选厂商推荐的，也可以手填（1 到 128 个字符）。
/// - 可选的 key 按 `agent.canUse(_:)` 过滤（key 的协议要包含 agent 的 `activeProtocol`；模型网关不在协议之间转换，
///   配错了运行会卡在等 key），停用的也不列；已经配上的停用、删掉、不兼容的 key 标成问题，改好才能保存。
/// - 保存是整体替换（`setModelRoutes`）。保存前路由里有没同意过的厂商时，界面先确认数据共享（`vendorsNeedingConsent`，
///   App Store 5.1.2(i)）。保存后服务端唤醒卡在等 key 的运行：重新拉这个实例的运行（刷新缓存，对话页跟着变），
///   界面说唤醒了几个（`saveResult`），再调 `AppModel.refreshBadges()`。
/// - 还没有 main 时先放一个 main 的草稿：选最新加的能用的 key 和它的第一个推荐模型（引导里“选刚加的 key 和推荐模型”）。
@Observable @MainActor
public final class ModelRoutesModel {
    public let instanceID: InstanceID
    public private(set) var instance: Instance?
    /// 实例的 agent（目录里的那一条）；没拉到时为 nil，这时不按协议过滤。
    public private(set) var agent: AgentInfo?
    public private(set) var credentials: [Credential] = []
    public private(set) var vendors: [VendorInfo] = []
    /// 服务端现在的路由（main 在前）。
    public private(set) var savedRoutes: [ModelRoute] = []
    /// 正在编辑的路由（main 在前）。
    public private(set) var drafts: [RouteDraft] = []

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 路由和 key 都拉到了（才能编辑、保存）。
    public private(set) var isEditable = false
    /// 路由或 key 拉不到。
    public private(set) var error: ClientError?
    /// 目录、厂商表拉不到（不按协议过滤、厂商名退回成 id）。
    public private(set) var detailsError: ClientError?
    /// 实例不存在了。
    public private(set) var isMissing = false
    /// 这个实例上在等 key 的运行；拉不到为 nil。
    public private(set) var waitingRuns: Int?
    /// 用户动过草稿（返回时要确认放弃）。自动补上的 main 草稿不算。
    public private(set) var hasUserEdits = false

    public private(set) var isSaving = false
    public private(set) var saveError: ClientError?
    /// 保存成功了（界面显示“已保存”和唤醒的结果）；再改动时清掉。
    public private(set) var saveResult: RouteSaveResult?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let consent: ThirdPartyAIConsentStore

    /// 看等 key 的运行时拉几个最近的运行（和应用框架的一样）。
    public static let runsToCheck = 20

    public init(
        client: any ClientProtocol, instanceID: InstanceID, instance: Instance? = nil,
        consent: ThirdPartyAIConsentStore = .init()
    ) {
        self.client = client
        self.instanceID = instanceID
        self.instance = instance?.id == instanceID ? instance : nil
        self.consent = consent
    }

    // MARK: 加载

    /// 拉实例、目录、key、厂商表、路由和最近的运行。用户改过草稿时只刷新 key 和厂商这些，不动草稿。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if instance == nil, let cached = try? client.cachedInstances().first(where: { $0.id == instanceID }) {
            instance = cached
        }
        let client = self.client
        let id = instanceID
        async let fresh = AgentsErrors.attempt { try await client.instance(id) }
        async let agents = AgentsErrors.attempt { try await client.agents() }
        async let credentials = AgentsErrors.attempt { try await client.credentials() }
        async let vendors = AgentsErrors.attempt { try await client.vendors() }
        async let routes = AgentsErrors.attempt { try await client.modelRoutes(instanceID: id) }
        async let waiting = Self.waitingRuns(client: client, instanceID: id)

        var critical: [ClientError] = []
        var minor: [ClientError] = []
        switch await fresh {
        case .success(let value):
            instance = value
            isMissing = value.state == .deleted
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) {
                if failure.isNotFound { isMissing = true } else { minor.append(failure) }
            }
        }
        switch await agents {
        case .success(let list):
            let agentID = instance?.agentID
            agent = list.first { $0.id == agentID }
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { minor.append(failure) }
        }
        switch await vendors {
        case .success(let list): self.vendors = list
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { minor.append(failure) }
        }
        var gotCredentials = false
        switch await credentials {
        case .success(let list):
            self.credentials = list
            gotCredentials = true
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { critical.append(failure) }
        }
        var gotRoutes = false
        switch await routes {
        case .success(let list):
            gotRoutes = true
            savedRoutes = Self.mainFirst(list)
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) {
                if failure.isNotFound { isMissing = true } else { critical.append(failure) }
            }
        }
        waitingRuns = await waiting

        error = critical.first
        detailsError = minor.first
        if gotRoutes && gotCredentials {
            isEditable = !isMissing
            if !hasUserEdits {
                resetDrafts()
            } else {
                fillEmptyMain()
            }
        }
        hasLoaded = true
    }

    /// 只刷新 key 和厂商表（添加 key 的 sheet 关掉之后）：草稿不动，main 还没选 key 时选上新加的。
    public func refreshCredentials() async {
        let client = self.client
        async let credentials = AgentsErrors.attempt { try await client.credentials() }
        async let vendors = AgentsErrors.attempt { try await client.vendors() }
        if case .success(let list) = await vendors { self.vendors = list }
        switch await credentials {
        case .success(let list):
            self.credentials = list
            if isEditable { fillEmptyMain() }
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { error = failure }
        }
    }

    nonisolated private static func waitingRuns(client: any ClientProtocol, instanceID: InstanceID) async -> Int? {
        guard let runs = try? await client.runs(instanceID: instanceID, limit: runsToCheck) else { return nil }
        return runs.filter { $0.state == .waitingQuota }.count
    }

    /// main 放第一个，别的保持原来的顺序。
    static func mainFirst(_ routes: [ModelRoute]) -> [ModelRoute] {
        routes.filter(\.isMain) + routes.filter { !$0.isMain }
    }

    /// 草稿换回服务端现在的路由；没有 main 时补一个预选好的 main 草稿。
    private func resetDrafts() {
        drafts = savedRoutes.map(RouteDraft.init(route:))
        hasUserEdits = false
        if !drafts.contains(where: \.isMain) {
            drafts.insert(RouteDraft(alias: ModelRoute.mainAlias, credentialID: nil, upstreamModel: ""), at: 0)
        }
        fillEmptyMain()
    }

    /// main 还没选 key：选最新加的能用的 key，模型空着时填它的推荐模型。
    private func fillEmptyMain() {
        guard let index = drafts.firstIndex(where: \.isMain), drafts[index].credentialID == nil,
            let newest = selectableCredentials.max(by: { $0.createdAt < $1.createdAt })
        else { return }
        drafts[index].credentialID = newest.id
        if drafts[index].upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[index].upstreamModel = preferredModel(for: ModelRoute.mainAlias, credentialID: newest.id) ?? ""
        }
    }

    // MARK: 显示

    /// 实例的名字（还没拉到时为空）。
    public var instanceName: String { instance?.name ?? "" }

    /// agent 的名字（按商标要求处理过）。
    public var agentName: String {
        if let agent { return AgentsText.displayName(of: agent) }
        return instance.map { AgentsText.displayName(agentID: $0.agentID) } ?? ""
    }

    /// agent 要的协议（老的服务端为 nil，不过滤）。
    public var requiredProtocol: ModelProtocol? { agent?.activeProtocol }

    /// 可以选的 key：没停用，而且 agent 能用（`canUse`）。先加的在前。
    public var selectableCredentials: [Credential] {
        credentials.filter { !$0.isDisabled && canUse($0) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 没停用、但协议对不上所以没列出来的 key 有几把。
    public var incompatibleCredentialCount: Int {
        credentials.filter { !$0.isDisabled && !canUse($0) }.count
    }

    /// 一把能用的 key 都没有（界面提示先加 key）。
    public var hasNoUsableCredentials: Bool { selectableCredentials.isEmpty }

    private func canUse(_ credential: Credential) -> Bool {
        agent?.canUse(credential) ?? true
    }

    public func credential(_ id: CredentialID?) -> Credential? {
        guard let id else { return nil }
        return credentials.first { $0.id == id }
    }

    /// 选 key 的菜单、读屏用的名字：“Claude 主力 · ••••Q7mA”；删掉了的 key 写“已删除的 key”。
    public func credentialTitle(_ id: CredentialID?, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        guard let id else { return zh ? "选一把 key" : "Choose a key" }
        guard let credential = credential(id) else { return zh ? "已删除的 key" : "Deleted key" }
        return ModelsText.credentialMenuTitle(credential, vendors: vendors, language: language)
    }

    /// 选的 key 所属厂商的推荐模型（自定义地址没有）。
    public func suggestedModels(for credentialID: CredentialID?) -> [String] {
        guard let vendorID = credential(credentialID)?.vendor else { return [] }
        return vendors.first { $0.id == vendorID }?.models ?? []
    }

    /// 给这个别名推荐的模型：fast 优先选名字里带 haiku、flash、mini 这类的，别的选第一个推荐的。
    public func preferredModel(for alias: String, credentialID: CredentialID?) -> String? {
        let models = suggestedModels(for: credentialID)
        if alias == RouteRules.fastAlias {
            let light = ["haiku", "flash", "mini", "lite", "fast", "turbo", "air"]
            if let model = models.first(where: { m in light.contains { m.lowercased().contains($0) } }) { return model }
        }
        return models.first
    }

    public func draft(_ id: RouteDraft.ID) -> RouteDraft? {
        drafts.first { $0.id == id }
    }

    public var hasFast: Bool { drafts.contains { $0.alias == RouteRules.fastAlias } }

    /// 还能加别名。
    public var canAddAlias: Bool { isEditable && drafts.count < RouteRules.maxAliases }

    // MARK: 编辑

    /// 给别名换主 key。模型空着、或者是原来那家的推荐模型而新的厂商没有时，换成新厂商的推荐模型。
    public func setCredential(_ credentialID: CredentialID, forRoute id: RouteDraft.ID) {
        mutate(id) { draft in
            let old = draft.credentialID
            draft.credentialID = credentialID
            draft.upstreamModel = adjustedModel(
                draft.upstreamModel, from: old, to: credentialID, alias: draft.alias)
        }
    }

    public func setModel(_ model: String, forRoute id: RouteDraft.ID) {
        mutate(id) { $0.upstreamModel = model }
    }

    /// 加一个备用（降级链最多 3 个）：预选一把还没用在这个别名上的 key。返回新备用的 id；满了返回 nil。
    @discardableResult
    public func addFallback(toRoute id: RouteDraft.ID) -> FallbackDraft.ID? {
        guard let route = draft(id), route.fallbacks.count < ModelRoute.maxFallbacks else { return nil }
        let used = Set([route.credentialID].compactMap { $0 } + route.fallbacks.compactMap(\.credentialID))
        let pick = selectableCredentials.first { !used.contains($0.id) }
        let fallback = FallbackDraft(
            credentialID: pick?.id,
            upstreamModel: pick.flatMap { preferredModel(for: route.alias, credentialID: $0.id) } ?? "")
        mutate(id) { $0.fallbacks.append(fallback) }
        return fallback.id
    }

    public func removeFallback(_ fallbackID: FallbackDraft.ID, fromRoute id: RouteDraft.ID) {
        mutate(id) { $0.fallbacks.removeAll { $0.id == fallbackID } }
    }

    /// 在降级链里上移（`offset` 为 -1）或下移（1）。
    public func moveFallback(_ fallbackID: FallbackDraft.ID, inRoute id: RouteDraft.ID, by offset: Int) {
        mutate(id) { draft in
            guard let from = draft.fallbacks.firstIndex(where: { $0.id == fallbackID }) else { return }
            let to = from + offset
            guard draft.fallbacks.indices.contains(to) else { return }
            draft.fallbacks.swapAt(from, to)
        }
    }

    public func setFallbackCredential(
        _ credentialID: CredentialID, fallback fallbackID: FallbackDraft.ID, route id: RouteDraft.ID
    ) {
        mutate(id) { draft in
            guard let i = draft.fallbacks.firstIndex(where: { $0.id == fallbackID }) else { return }
            let old = draft.fallbacks[i].credentialID
            draft.fallbacks[i].credentialID = credentialID
            draft.fallbacks[i].upstreamModel = adjustedModel(
                draft.fallbacks[i].upstreamModel, from: old, to: credentialID, alias: draft.alias)
        }
    }

    public func setFallbackModel(_ model: String, fallback fallbackID: FallbackDraft.ID, route id: RouteDraft.ID) {
        mutate(id) { draft in
            guard let i = draft.fallbacks.firstIndex(where: { $0.id == fallbackID }) else { return }
            draft.fallbacks[i].upstreamModel = model
        }
    }

    /// 加 fast 别名（已经有了、满了返回 nil）。
    @discardableResult
    public func addFast() -> RouteDraft.ID? {
        guard !hasFast else { return nil }
        if case .added(let id) = addAlias(RouteRules.fastAlias) { return id }
        return nil
    }

    /// 加一个别名：先规整（去空白、转小写），不合法、重名、满了时返回问题。新别名预选 main 的 key 和推荐模型。
    @discardableResult
    public func addAlias(_ name: String) -> AliasAddResult {
        let alias = RouteRules.normalizedAlias(name)
        if let problem = aliasProblem(alias) { return .rejected(problem) }
        let mainKey = drafts.first(where: \.isMain)?.credentialID
        let key =
            credential(mainKey).flatMap { canUse($0) && !$0.isDisabled ? $0.id : nil }
            ?? selectableCredentials.last?.id
        let draft = RouteDraft(
            alias: alias, credentialID: key, upstreamModel: preferredModel(for: alias, credentialID: key) ?? "")
        drafts.append(draft)
        noteEdit()
        return .added(draft.id)
    }

    /// 新别名有什么问题（输入框边输边查）；没问题为 nil。
    public func aliasProblem(_ name: String) -> AliasProblem? {
        let alias = RouteRules.normalizedAlias(name)
        if alias.isEmpty { return .empty }
        if !RouteRules.isValidAlias(alias) { return .invalid }
        if drafts.contains(where: { $0.alias == alias }) { return .duplicate }
        if drafts.count >= RouteRules.maxAliases { return .tooMany(max: RouteRules.maxAliases) }
        return nil
    }

    /// 删掉一个别名（main 删不了）。
    public func removeRoute(_ id: RouteDraft.ID) {
        guard let route = draft(id), !route.isMain else { return }
        drafts.removeAll { $0.id == id }
        noteEdit()
    }

    /// 放弃没保存的改动。
    public func discardChanges() {
        resetDrafts()
        saveError = nil
    }

    private func mutate(_ id: RouteDraft.ID, _ body: (inout RouteDraft) -> Void) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        body(&drafts[i])
        noteEdit()
    }

    private func noteEdit() {
        hasUserEdits = true
        saveResult = nil
        saveError = nil
    }

    /// 换 key 时模型怎么跟着变：空着、或者是旧厂商的推荐模型而新厂商没有它时，换成新厂商推荐的。
    private func adjustedModel(_ model: String, from old: CredentialID?, to new: CredentialID, alias: String) -> String
    {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let newModels = suggestedModels(for: new)
        if trimmed.isEmpty || (suggestedModels(for: old).contains(trimmed) && !newModels.contains(trimmed)) {
            return preferredModel(for: alias, credentialID: new) ?? (trimmed.isEmpty ? "" : model)
        }
        return model
    }

    // MARK: 校验

    /// 一把 key 能不能用在这里；能用为 nil。
    public func keyProblem(_ credentialID: CredentialID?) -> RouteProblem? {
        guard let credentialID else { return .keyMissing }
        guard let credential = credential(credentialID) else { return .keyDeleted }
        if credential.isDisabled { return .keyDisabled }
        if !canUse(credential), let required = requiredProtocol {
            return .keyIncompatible(agentName: agentName, required: required)
        }
        return nil
    }

    /// 上游模型名有什么问题；没问题为 nil。
    public func modelProblem(_ model: String) -> RouteProblem? {
        let count = model.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        if count < RouteRules.modelLength.lowerBound { return .modelMissing }
        if count > RouteRules.modelLength.upperBound { return .modelTooLong(max: RouteRules.modelLength.upperBound) }
        return nil
    }

    /// 别名自己（名字、主 key、模型、备用个数）的问题。
    public func problems(forRoute id: RouteDraft.ID) -> [RouteProblem] {
        guard let route = draft(id) else { return [] }
        var out: [RouteProblem] = []
        if !RouteRules.isValidAlias(route.alias) { out.append(.aliasInvalid) }
        if drafts.filter({ $0.alias == route.alias }).count > 1 { out.append(.aliasDuplicate) }
        if let problem = keyProblem(route.credentialID) { out.append(problem) }
        if let problem = modelProblem(route.upstreamModel) { out.append(problem) }
        if route.fallbacks.count > ModelRoute.maxFallbacks {
            out.append(.tooManyFallbacks(max: ModelRoute.maxFallbacks))
        }
        return out
    }

    /// 一个备用的问题。
    public func problems(forFallback fallback: FallbackDraft) -> [RouteProblem] {
        [keyProblem(fallback.credentialID), modelProblem(fallback.upstreamModel)].compactMap { $0 }
    }

    /// 整页的问题。
    public var pageProblems: [RoutesPageProblem] {
        var out: [RoutesPageProblem] = []
        if !drafts.contains(where: \.isMain) { out.append(.missingMain) }
        if drafts.count > RouteRules.maxAliases { out.append(.tooManyAliases(max: RouteRules.maxAliases)) }
        return out
    }

    /// 每个别名、每个备用都没问题。
    public var isValid: Bool {
        pageProblems.isEmpty
            && drafts.allSatisfy { route in
                problems(forRoute: route.id).isEmpty && route.fallbacks.allSatisfy { problems(forFallback: $0).isEmpty }
            }
    }

    /// 草稿和服务端现在的不一样（按别名比，顺序不算：服务端按别名排序存，main 总在第一个）。
    public var hasChanges: Bool {
        Self.normalized(drafts.map(\.content)) != Self.normalized(savedRoutes.map { RouteDraft(route: $0).content })
    }

    private static func normalized(_ contents: [RouteContent]) -> [RouteContent] {
        contents.sorted { $0.alias < $1.alias }
    }

    /// 能保存。
    public var canSave: Bool { isEditable && hasChanges && isValid && !isSaving }

    /// 要保存的路由：main 在第一个，模型名去掉首尾空白。草稿有问题时为 nil。
    public var routesToSave: [ModelRoute]? {
        guard isValid else { return nil }
        let routes = drafts.compactMap { draft -> ModelRoute? in
            guard let key = draft.credentialID else { return nil }
            let fallbacks = draft.fallbacks.compactMap { f -> RouteFallback? in
                guard let key = f.credentialID else { return nil }
                return RouteFallback(credentialID: key, upstreamModel: f.upstreamModel.trimmed)
            }
            return ModelRoute(
                alias: draft.alias, credentialID: key, upstreamModel: draft.upstreamModel.trimmed, fallbacks: fallbacks)
        }
        return Self.mainFirst(routes)
    }

    // MARK: 第三方 AI 数据共享

    /// 路由里用到、还没同意过数据共享的厂商（同意记录的键和显示名），按出现的顺序去重。
    public func vendorsNeedingConsent(_ language: DisplayLanguage = .current) -> [ConsentVendor] {
        usedVendors(language).filter { !consent.hasConsented(to: $0.key) }
    }

    /// 路由里用到的厂商（模型路由页上的数据去向提示）。
    public func usedVendors(_ language: DisplayLanguage = .current) -> [ConsentVendor] {
        var seen = Set<String>()
        var out: [ConsentVendor] = []
        let ids = drafts.flatMap { [$0.credentialID] + $0.fallbacks.map(\.credentialID) }.compactMap { $0 }
        for id in ids {
            guard let credential = credential(id) else { continue }
            let key = ThirdPartyAIConsentStore.vendorKey(for: credential)
            guard seen.insert(key).inserted else { continue }
            out.append(ConsentVendor(key: key, name: consentName(credential, language: language)))
        }
        return out
    }

    /// 同意时显示的厂商名：预置厂商是厂商名，自定义地址是“自定义地址（备注）”。
    private func consentName(_ credential: Credential, language: DisplayLanguage) -> String {
        guard credential.vendor == NewCredential.customVendor else {
            return ModelsText.vendorName(credential.vendor, vendors: vendors, language: language)
        }
        let custom = ModelsText.customVendorName(language)
        let label = credential.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return custom }
        return language == .chinese ? "\(custom)（\(label)）" : "\(custom) (\(label))"
    }

    // MARK: 保存

    /// 保存。路由里有没同意过的厂商时要先在界面上确认（`consented` 传 true 并记下同意），否则不保存、返回 false。
    @discardableResult
    public func save(consented: Bool = false) async -> Bool {
        guard canSave, let routes = routesToSave else { return false }
        let pending = vendorsNeedingConsent()
        if !pending.isEmpty && !consented { return false }
        isSaving = true
        saveError = nil
        saveResult = nil
        defer { isSaving = false }
        let before = await Self.waitingRuns(client: client, instanceID: instanceID) ?? waitingRuns
        do {
            try await client.setModelRoutes(instanceID: instanceID, routes: routes)
        } catch {
            guard let failure = AgentsErrors.from(error) else { return false }
            saveError = failure
            // 多半是 key 刚被停用、删掉了：重新拉 key，本地校验会把出问题的标出来。
            if failure.isInvalidInput { await refreshCredentials() }
            return false
        }
        consent.record(pending.map(\.key))
        if let fresh = try? await client.modelRoutes(instanceID: instanceID) {
            savedRoutes = Self.mainFirst(fresh)
        } else {
            savedRoutes = routes
        }
        resetDrafts()
        let after = await Self.waitingRuns(client: client, instanceID: instanceID)
        waitingRuns = after
        saveResult = RouteSaveResult(wake: KeyWakeResult(before: before, after: after))
        return true
    }
}

// MARK: - 草稿

/// 编辑中的一个别名。`id` 只在编辑时用来认（别名本身可能还不合法）。
public struct RouteDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var alias: String
    public var credentialID: CredentialID?
    public var upstreamModel: String
    public var fallbacks: [FallbackDraft]

    public init(
        id: UUID = UUID(), alias: String, credentialID: CredentialID?, upstreamModel: String,
        fallbacks: [FallbackDraft] = []
    ) {
        self.id = id
        self.alias = alias
        self.credentialID = credentialID
        self.upstreamModel = upstreamModel
        self.fallbacks = fallbacks
    }

    public init(route: ModelRoute) {
        self.init(
            alias: route.alias, credentialID: route.credentialID, upstreamModel: route.upstreamModel,
            fallbacks: route.fallbacks.map {
                FallbackDraft(credentialID: $0.credentialID, upstreamModel: $0.upstreamModel)
            })
    }

    public var isMain: Bool { alias == ModelRoute.mainAlias }
    public var isFast: Bool { alias == RouteRules.fastAlias }

    var content: RouteContent {
        RouteContent(
            alias: alias, credentialID: credentialID, upstreamModel: upstreamModel.trimmed,
            fallbacks: fallbacks.map { [$0.credentialID?.rawValue ?? "", $0.upstreamModel.trimmed] })
    }
}

/// 降级链里编辑中的一项。
public struct FallbackDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var credentialID: CredentialID?
    public var upstreamModel: String

    public init(id: UUID = UUID(), credentialID: CredentialID?, upstreamModel: String) {
        self.id = id
        self.credentialID = credentialID
        self.upstreamModel = upstreamModel
    }
}

/// 草稿的内容（比较有没有改动用，不含编辑用的 id）。
struct RouteContent: Hashable {
    var alias: String
    var credentialID: CredentialID?
    var upstreamModel: String
    var fallbacks: [[String]]
}

/// 加别名的结果。
public enum AliasAddResult: Hashable, Sendable {
    case added(RouteDraft.ID)
    case rejected(AliasProblem)
}

/// 新别名的问题。
public enum AliasProblem: Hashable, Sendable {
    case empty
    /// 格式不对。
    case invalid
    case duplicate
    case tooMany(max: Int)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .empty: return zh ? "起个名字。" : "Enter a name."
        case .invalid:
            return zh
                ? "只能用小写字母、数字和 . _ -，字母或数字开头，最长 \(RouteRules.maxAliasLength) 个字符。"
                : "Use lowercase letters, digits and . _ -, starting with a letter or digit (up to "
                    + "\(RouteRules.maxAliasLength) characters)."
        case .duplicate: return zh ? "已经有这个别名了。" : "This alias already exists."
        case .tooMany(let max): return zh ? "一个实例最多 \(max) 个别名。" : "An instance can have up to \(max) aliases."
        }
    }
}

/// 一个别名（或一个备用）的问题。
public enum RouteProblem: Hashable, Sendable {
    case aliasInvalid
    case aliasDuplicate
    case keyMissing
    /// 选的 key 停用了（服务端不收停用的 key）。
    case keyDisabled
    /// 选的 key 删掉了。
    case keyDeleted
    /// key 的协议对不上 agent 要的。
    case keyIncompatible(agentName: String, required: ModelProtocol)
    case modelMissing
    case modelTooLong(max: Int)
    case tooManyFallbacks(max: Int)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .aliasInvalid: return AliasProblem.invalid.message(language)
        case .aliasDuplicate: return AliasProblem.duplicate.message(language)
        case .keyMissing: return zh ? "选一把 key。" : "Choose a key."
        case .keyDisabled:
            return zh ? "这把 key 已经停用了：换一把，或者先到 key 详情里启用。" : "This key is disabled. Pick another or enable it first."
        case .keyDeleted: return zh ? "这把 key 已经删掉了，换一把。" : "This key was deleted. Pick another."
        case .keyIncompatible(let name, let required):
            return zh
                ? "\(name) 要支持 \(ModelsText.protocolName(required)) 的 key，这把不支持，运行会卡在“等待 key”。"
                : "\(name) needs a key that supports \(ModelsText.protocolName(required)); this one doesn't, so tasks "
                    + "would wait for a key."
        case .modelMissing: return zh ? "填上游模型的名字。" : "Enter the upstream model name."
        case .modelTooLong(let max): return zh ? "模型名最多 \(max) 个字符。" : "Model names can be up to \(max) characters."
        case .tooManyFallbacks(let max): return zh ? "最多 \(max) 个备用。" : "Up to \(max) fallbacks."
        }
    }
}

/// 整页的问题。
public enum RoutesPageProblem: Hashable, Sendable {
    case missingMain
    case tooManyAliases(max: Int)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .missingMain: return zh ? "必须有 main 别名。" : "The main alias is required."
        case .tooManyAliases(let max): return zh ? "最多 \(max) 个别名。" : "Up to \(max) aliases."
        }
    }
}

/// 要确认数据共享的厂商。
public struct ConsentVendor: Identifiable, Hashable, Sendable {
    /// 同意记录的键（`ThirdPartyAIConsentStore.vendorKey(for:)`）。
    public var key: String
    public var name: String

    public var id: String { key }

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// 保存路由的结果。
public struct RouteSaveResult: Hashable, Sendable {
    /// 唤醒了几个等 key 的运行；没数到为 nil。
    public var wake: KeyWakeResult?

    public init(wake: KeyWakeResult?) {
        self.wake = wake
    }

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let saved = zh ? "已保存。" : "Saved."
        guard let wake else {
            return saved + (zh ? "卡在“等待 key”的任务会自动接着跑。" : " Tasks waiting for a key resume on their own.")
        }
        guard let detail = wake.message(language) else { return saved }
        return saved + (zh ? "" : " ") + detail
    }
}

extension String {
    /// 去掉首尾空白。
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
