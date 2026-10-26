import Foundation
import Observation

/// 保险箱（WBS 12.13，`.vault`）：条目（按名字排，显示用途、能用的实例；没有密码）、等你填写的请求、填过 / 拒绝 / 过期的请求。
/// 最多 200 条，满了不能新建。离线策略是“没有缓存”：离线时显示已经拉到的，写操作禁用。
@Observable @MainActor
public final class VaultModel {
    public private(set) var items: [VaultItem] = []
    /// 全部请求（`vaultRequests(all: true)`），新的在前。
    public private(set) var requests: [VaultRequest] = []
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var actionError: ClientError?
    public private(set) var deleting: Set<VaultItemID> = []

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(client: any ClientProtocol, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    public var isFull: Bool { items.count >= VaultRules.maxItems }

    /// 等你填写的（还没过期的）。
    public var pendingRequests: [VaultRequest] {
        let now = now()
        return requests.filter { $0.status == .pending && $0.expiresAt > now }
    }

    /// 填过、拒绝了、过期了的（还在等但已经过了期限的也算过期）。
    public var pastRequests: [VaultRequest] {
        let now = now()
        return requests.filter { $0.status != .pending || $0.expiresAt <= now }
    }

    /// 请求现在的状态：过了期限还显示“等你填写”的按过期算（服务端定时清理前）。
    public func status(of request: VaultRequest) -> VaultRequestStatus {
        request.status == .pending && request.expiresAt <= now() ? .expired : request.status
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if instanceNames.isEmpty, let cached = try? client.cachedInstances() { instanceNames = VaultNames.of(cached) }
        let client = self.client
        do {
            async let items = client.vaultItems()
            async let requests = client.vaultRequests(all: true)
            self.items = try await items.sorted { $0.name < $1.name }
            self.requests = try await requests.sorted { $0.createdAt > $1.createdAt }
            error = nil
            hasLoaded = true
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
        if let fresh = try? await client.instances() { instanceNames = VaultNames.of(fresh) }
    }

    public func delete(_ item: VaultItem) async {
        guard !deleting.contains(item.id) else { return }
        deleting.insert(item.id)
        actionError = nil
        defer { deleting.remove(item.id) }
        do {
            try await client.deleteVaultItem(item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { items.removeAll { $0.id == item.id } } else { actionError = failure }
        }
    }

    /// 新建、修改后放进列表（不用再拉一次）。
    public func upsert(_ item: VaultItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
        items.sort { $0.name < $1.name }
    }

    public func clearActionError() {
        actionError = nil
    }
}

/// 一个条目（`.vaultItem(id)`）：名字、引用、用途、账号（服务端解密后返回；密码永远不返回）、能用的实例、时间；修改、删除。
@Observable @MainActor
public final class VaultItemModel {
    public let itemID: VaultItemID
    public private(set) var detail: VaultItemDetail?
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false
    public private(set) var isDeleting = false
    public private(set) var isDeleted = false
    public private(set) var actionError: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, itemID: VaultItemID) {
        self.client = client
        self.itemID = itemID
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await client.vaultItem(itemID)
            error = nil
            isMissing = false
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isMissing = true } else { self.error = failure }
        }
        if let fresh = try? await client.instances() { instanceNames = VaultNames.of(fresh) }
    }

    /// 修改后：换上新的条目（账号可能也改了，再拉一次详情）。
    public func didSave() async {
        await load()
    }

    public func delete() async {
        guard !isDeleting else { return }
        isDeleting = true
        actionError = nil
        defer { isDeleting = false }
        do {
            try await client.deleteVaultItem(itemID)
            isDeleted = true
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isDeleted = true } else { actionError = failure }
        }
    }

    public func clearActionError() {
        actionError = nil
    }
}

/// 新建 / 修改条目（sheet）：名字（新建时；1–64 个小写字母、数字、`-`、`_`）、用途、账号、密码（修改时不填就不改）、能用的实例
/// （所有实例，或者选几个，最多 50 个）。重名时换一个不重复的名字（`github` → `github_2`）让用户确认后再存；满 200 条不能新建。
@Observable @MainActor
public final class VaultItemEditorModel {
    public let itemID: VaultItemID?
    public var name = ""
    public var purpose = ""
    public var username = ""
    public var password = ""
    public var allInstances = true
    public private(set) var selected: Set<InstanceID> = []
    /// 能选的实例（不含已删除的），最近活跃的在前。
    public private(set) var instances: [Instance] = []
    public private(set) var original: VaultItemDetail?
    public private(set) var hasLoaded = false
    public private(set) var error: ClientError?
    public private(set) var isSaving = false
    public private(set) var saveError: ClientError?
    public private(set) var showsProblems = false
    /// 名字被占用、换成了这个（页面提示一句，用户可以再改）。
    public private(set) var renamedTo: String?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private var takenNames: [String] = []
    @ObservationIgnored private var itemCount = 0

    public init(client: any ClientProtocol, itemID: VaultItemID? = nil, presetInstance: InstanceID? = nil) {
        self.client = client
        self.itemID = itemID
        if let presetInstance {
            allInstances = false
            selected = [presetInstance]
        }
    }

    public var isEditing: Bool { itemID != nil }

    public var problems: [VaultFormProblem] {
        var result: [VaultFormProblem] = []
        if !isEditing {
            if itemCount >= VaultRules.maxItems { result.append(.full) }
            if let problem = VaultNameProblem.check(name) { result.append(.name(problem)) }
        }
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if purpose.unicodeScalars.count > VaultRules.maxPurpose { result.append(.purposeTooLong) }
        if username.unicodeScalars.count > VaultRules.maxUsername { result.append(.usernameTooLong) }
        if VaultRules.hasControlCharacters(purpose) || VaultRules.hasControlCharacters(username) {
            result.append(.controlCharacters)
        }
        if !isEditing || !password.isEmpty, let problem = VaultRules.passwordProblem(password) {
            result.append(.password(problem))
        }
        if !allInstances {
            if selected.isEmpty { result.append(.noInstances) }
            if selected.count > VaultRules.maxInstances { result.append(.tooManyInstances) }
        }
        return result
    }

    /// 页面上显示的问题（点过保存才显示）。
    public var visibleProblems: [VaultFormProblem] { showsProblems ? problems : [] }

    public var hasChanges: Bool {
        guard let original else {
            return !name.isEmpty || !purpose.isEmpty || !username.isEmpty || !password.isEmpty
        }
        return purpose != original.item.purpose || username != original.username || !password.isEmpty
            || instanceIDs != original.item.instanceIDs.sorted()
    }

    /// 要提交的实例（空表示所有实例）。
    private var instanceIDs: [InstanceID] { allInstances ? [] : selected.sorted() }

    public func load() async {
        let client = self.client
        do {
            async let instances = client.instances()
            async let items = client.vaultItems()
            self.instances = try await instances.filter { $0.state != .deleted }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
            let all = try await items
            takenNames = all.map(\.name)
            itemCount = all.count
            if let itemID, original == nil {
                let detail = try await client.vaultItem(itemID)
                original = detail
                name = detail.item.name
                purpose = detail.item.purpose
                username = detail.username
                allInstances = detail.item.isAvailableToAllInstances
                selected = Set(detail.item.instanceIDs)
            }
            error = nil
            hasLoaded = true
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
    }

    public func toggle(_ instance: InstanceID) {
        if selected.contains(instance) { selected.remove(instance) } else { selected.insert(instance) }
    }

    /// 名字输入：只收小写字母、数字、`-`、`_`（大写转小写，空格换成 `-`）。
    public func setName(_ raw: String) {
        name = String(
            raw.lowercased().replacingOccurrences(of: " ", with: "-").unicodeScalars.filter { s in
                (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x30 && s.value <= 0x39) || s == "-" || s == "_"
            }
            .prefix(VaultNameProblem.maxLength)
            .map(Character.init))
        renamedTo = nil
    }

    /// 保存；成功返回条目。重名时换好名字、提示一句，等用户再点保存。
    public func save() async -> VaultItem? {
        guard !isSaving, hasLoaded else { return nil }
        if !isEditing, takenNames.contains(name) {
            rename()
            return nil
        }
        guard problems.isEmpty else {
            showsProblems = true
            return nil
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let itemID, let original {
                let change = VaultItemUpdate(
                    purpose: purpose == original.item.purpose ? nil : purpose,
                    username: username == original.username ? nil : username,
                    password: password.isEmpty ? nil : password,
                    instanceIDs: instanceIDs == original.item.instanceIDs.sorted() ? nil : instanceIDs)
                let saved = try await client.updateVaultItem(itemID, change: change)
                password = ""
                return saved
            }
            let saved = try await client.createVaultItem(
                NewVaultItem(
                    name: name, purpose: purpose, username: username, password: password, instanceIDs: instanceIDs))
            password = ""
            return saved
        } catch {
            guard let failure = ConversationErrors.from(error) else { return nil }
            // 别处刚建了同名的：换个名字让用户确认。
            if failure.isConflict, !isEditing, let names = try? await client.vaultItems().map(\.name) {
                takenNames = names
                itemCount = names.count
                rename()
            } else {
                saveError = failure
            }
            return nil
        }
    }

    public func clearSaveError() {
        saveError = nil
    }

    private func rename() {
        let suggestion = client.secretDetector.uniqueVaultName(base: name, taken: takenNames)
        name = suggestion
        renamedTo = suggestion
    }
}

/// 填写请求（`.vaultRequest(id)`，推送、收件箱、深链 `thinktin://vault/request/{id}`、保险箱里的列表进来）：agent 要的账号密码，
/// 填好只进保险箱（agent 只拿到名字）。已经有同名条目的，填好会换掉它的账号密码（服务端就是这样），先提示。也可以拒绝。
/// 已经处理过、过期了的显示结果。
@Observable @MainActor
public final class VaultRequestModel {
    public let requestID: VaultRequestID
    public private(set) var request: VaultRequest?
    /// 同名的已有条目（填好会更新它）。
    public private(set) var existingItem: VaultItem?
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public var username = ""
    public var password = ""
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false
    public private(set) var isWorking = false
    public private(set) var actionError: ClientError?
    public private(set) var showsProblems = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(client: any ClientProtocol, requestID: VaultRequestID, now: @escaping @Sendable () -> Date = Date.init)
    {
        self.client = client
        self.requestID = requestID
        self.now = now
    }

    /// 现在的状态（过了期限的按过期算）。
    public var status: VaultRequestStatus? {
        guard let request else { return nil }
        return request.status == .pending && request.expiresAt <= now() ? .expired : request.status
    }

    public var canFill: Bool { status == .pending }

    public var problems: [VaultFormProblem] {
        var result: [VaultFormProblem] = []
        if username.unicodeScalars.count > VaultRules.maxUsername { result.append(.usernameTooLong) }
        if VaultRules.hasControlCharacters(username) { result.append(.controlCharacters) }
        if let problem = VaultRules.passwordProblem(password) { result.append(.password(problem)) }
        return result
    }

    public var visibleProblems: [VaultFormProblem] { showsProblems ? problems : [] }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = self.client
        let requestID = self.requestID
        do {
            async let requests = client.vaultRequests(all: true)
            async let items = client.vaultItems()
            let found = try await requests.first { $0.id == requestID }
            let all = try await items
            request = found
            isMissing = found == nil
            existingItem = found.flatMap { request in all.first { $0.name == request.name } }
            error = nil
            hasLoaded = true
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
        if let fresh = try? await client.instances() { instanceNames = VaultNames.of(fresh) }
    }

    /// 填好存进保险箱；成功返回 true（页面显示结果）。
    public func fulfill() async -> Bool {
        guard !isWorking, canFill else { return false }
        guard problems.isEmpty else {
            showsProblems = true
            return false
        }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            request = try await client.fulfillVaultRequest(
                requestID, username: username.trimmingCharacters(in: .whitespaces), password: password, purpose: nil)
            password = ""
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    public func decline() async -> Bool {
        guard !isWorking, canFill else { return false }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            request = try await client.declineVaultRequest(requestID)
            password = ""
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    public func clearActionError() {
        actionError = nil
    }

    /// 已经在别处处理过、过期了（冲突）：重新拉一次显示结果，不算出错。
    private func handle(_ error: any Error) async {
        guard let failure = ConversationErrors.from(error) else { return }
        if failure.isConflict || failure.isNotFound {
            await load()
        } else {
            actionError = failure
        }
    }
}

/// 实例 id → 名字（不含已删除的）。
enum VaultNames {
    static func of(_ instances: [Instance]) -> [InstanceID: String] {
        Dictionary(
            instances.filter { $0.state != .deleted }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
