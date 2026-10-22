import Foundation
import Observation

/// 实例详情（WBS 12.3，深链 `thinktin://instance/{id}`）：状态和状态说明、改名、版本升级 / 回滚、模型路由入口、
/// 本实例的计划和产出物入口、所在团队、删除。
///
/// - 先显示缓存（`cachedInstances`，离线也能看，docs/ios.md 6.2），再拉 `instance(_:)`；同时拉目录（版本列表、许可证）、
///   模型路由（有没有 main）、本实例的计划、团队。这几样拉不到不影响页面，只在 `detailsError` 里记一下。
/// - 版本：`AgentInfo.versions` 的第一个是最新版本，实例不是它时提示升级；也可以换回旧版本（回滚）。
///   `setInstanceVersion` 只记下目标版本，下次唤醒沙箱时按新版本重建，工作区保留（`versionChange` 给界面提示）。
/// - 删除：先 `prepareDeletion()` 查影响（`InstanceDeletionImpact`：会停掉的运行、一起删掉的计划和产出物、
///   会被移除的流水线步骤、团队成员身份），界面列出来、二次确认后再 `delete()`。
@Observable @MainActor
public final class InstanceDetailModel {
    public let instanceID: InstanceID
    public private(set) var instance: Instance?
    /// 实例的 agent（目录里的那一条）；目录里没有了（下架）或没拉到时为 nil。
    public private(set) var agent: AgentInfo?
    /// 模型路由；nil 是还没拉到（或拉不到）。
    public private(set) var routes: [ModelRoute]?
    /// 这个实例自己的计划；nil 是还没拉到。
    public private(set) var plans: [Plan]?
    /// 这个实例所在的团队；nil 是还没拉到。
    public private(set) var teams: [Team]?

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 实例本身拉不到（网络不通时照样显示缓存里的）。
    public private(set) var error: ClientError?
    /// 目录、路由、计划、团队里有拉不到的（第一个错误）。
    public private(set) var detailsError: ClientError?
    /// 实例不存在了（被删了，或者不是这个账号的）。
    public private(set) var isMissing = false

    public private(set) var isRenaming = false
    public private(set) var renameError: ClientError?

    public private(set) var isChangingVersion = false
    public private(set) var versionError: ClientError?
    /// 打开页面之后换过的版本：界面提示“下次唤醒时生效”。
    public private(set) var versionChange: InstanceVersionChange?

    /// 删除的影响（`prepareDeletion()` 之后有）。
    public private(set) var deletionImpact: InstanceDeletionImpact?
    public private(set) var isCheckingImpact = false
    /// 查影响时第一个拉不到的（影响没查全）。
    public private(set) var impactError: ClientError?
    public private(set) var isDeleting = false
    public private(set) var deleteError: ClientError?
    /// 删掉了：界面关掉确认页、离开这个实例的页面、刷新实例列表。
    public private(set) var isDeleted = false

    @ObservationIgnored private let client: any ClientProtocol

    /// - Parameter instance: 已经有的实例（应用框架的实例列表里的），先显示它。
    public init(client: any ClientProtocol, instanceID: InstanceID, instance: Instance? = nil) {
        self.client = client
        self.instanceID = instanceID
        self.instance = instance?.id == instanceID ? instance : nil
    }

    // MARK: 加载

    /// 拉实例和它的目录信息、路由、计划、团队（打开页面、下拉刷新、联网后）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if instance == nil, let cached = try? client.cachedInstances().first(where: { $0.id == instanceID }) {
            instance = cached
        }
        do {
            let fresh = try await client.instance(instanceID)
            instance = fresh
            error = nil
            isMissing = fresh.state == .deleted
        } catch {
            guard let failure = AgentsErrors.from(error) else { return }
            if failure.isNotFound {
                isMissing = true
                self.error = nil
            } else {
                self.error = failure
            }
        }
        guard let instance, !isMissing else {
            hasLoaded = true
            return
        }
        await loadDetails(agentID: instance.agentID)
        hasLoaded = true
    }

    private func loadDetails(agentID: AgentID) async {
        let client = self.client
        let id = instanceID
        async let agents = AgentsErrors.attempt { try await client.agents() }
        async let routes = AgentsErrors.attempt { try await client.modelRoutes(instanceID: id) }
        async let plans = AgentsErrors.attempt { try await client.plans(instanceID: id) }
        async let teams = AgentsErrors.attempt { try await client.teams() }
        var errors: [ClientError] = []
        func note(_ error: any Error) {
            if let failure = AgentsErrors.from(error) { errors.append(failure) }
        }
        switch await agents {
        case .success(let list): agent = list.first { $0.id == agentID }
        case .failure(let error): note(error)
        }
        switch await routes {
        case .success(let list): self.routes = list
        case .failure(let error): note(error)
        }
        switch await plans {
        case .success(let list): self.plans = list.filter { $0.instanceID == id }
        case .failure(let error): note(error)
        }
        switch await teams {
        case .success(let list): self.teams = list.filter { $0.contains(id) }
        case .failure(let error): note(error)
        }
        detailsError = errors.first
    }

    // MARK: 显示

    /// agent 的名字（按商标要求处理过）。
    public var agentDisplayName: String {
        if let agent { return AgentsText.displayName(of: agent) }
        return instance.map { AgentsText.displayName(agentID: $0.agentID) } ?? ""
    }

    /// 模型路由的情况（实例详情里“模型路由”那一行）。
    public var routeStatus: InstanceRouteStatus {
        guard let routes else { return .unknown }
        if let main = routes.first(where: \.isMain) { return .configured(main: main, aliases: routes.count) }
        return routes.isEmpty ? .notConfigured : .missingMain(aliases: routes.count)
    }

    /// 实例在哪个团队里是什么角色。
    public func role(in team: Team) -> TeamRole? {
        team.members.first { $0.instanceID == instanceID }?.role
    }

    // MARK: 改名

    /// 改名（去掉首尾空白后 1 到 64 个字符）。名字没变直接算成功。
    @discardableResult
    public func rename(to newName: String) async -> Bool {
        let name = InstanceNameRule.normalized(newName)
        guard let instance, !isRenaming, InstanceNameRule.problem(name) == nil else { return false }
        if name == instance.name { return true }
        isRenaming = true
        renameError = nil
        defer { isRenaming = false }
        do {
            self.instance = try await client.renameInstance(instanceID, name: name)
            return true
        } catch {
            renameError = AgentsErrors.from(error)
            return false
        }
    }

    /// 关掉改名表单时清掉上次的错误。
    public func clearRenameError() {
        renameError = nil
    }

    // MARK: 版本

    /// 最新的版本（目录里 `versions` 的第一个）；没拉到目录时为 nil。
    public var latestVersion: String? { agent?.catalogLatestVersion }

    /// 实例不是最新版本：提示升级。
    public var upgradeAvailable: Bool {
        guard let instance, let agent else { return false }
        return agent.hasUpgrade(from: instance.agentVersion)
    }

    /// 实例现在的版本在不在目录的版本列表里（不在说明下架了，建议升级）。目录没拉到时算在。
    public var isCurrentVersionListed: Bool {
        guard let instance, let agent else { return true }
        return agent.catalogVersions.contains(instance.agentVersion)
    }

    /// 版本列表（新的在前）：每个版本标出是不是最新、是不是现在用的、换过去是升级还是回滚。
    public var versionOptions: [InstanceVersionOption] {
        guard let instance, let agent else { return [] }
        let versions = agent.catalogVersions
        let currentIndex = versions.firstIndex(of: instance.agentVersion)
        return versions.enumerated().map { index, version in
            let change: InstanceVersionOption.Change
            if version == instance.agentVersion {
                change = .current
            } else if let currentIndex {
                change = index < currentIndex ? .upgrade : .rollback
            } else {
                // 现在的版本不在列表里（下架了）：最新的算升级，别的只是切换。
                change = index == 0 ? .upgrade : .switchTo
            }
            return InstanceVersionOption(version: version, isLatest: index == 0, change: change)
        }
    }

    /// 换到这个版本（升级到最新时不带版本号，由服务端取当前上架的版本）。下次唤醒时生效，工作区保留。
    @discardableResult
    public func setVersion(_ version: String) async -> Bool {
        guard let instance, !isChangingVersion, version != instance.agentVersion else { return false }
        isChangingVersion = true
        versionError = nil
        defer { isChangingVersion = false }
        do {
            let updated = try await client.setInstanceVersion(
                instanceID, version: version == latestVersion ? nil : version)
            versionChange = InstanceVersionChange(from: instance.agentVersion, to: updated.agentVersion)
            self.instance = updated
            return true
        } catch {
            versionError = AgentsErrors.from(error)
            return false
        }
    }

    // MARK: 删除

    /// 查删除的影响（打开删除确认页时）。
    public func prepareDeletion() async {
        guard !isCheckingImpact else { return }
        isCheckingImpact = true
        impactError = nil
        defer { isCheckingImpact = false }
        guard let result = await InstanceDeletionImpact.check(instanceID: instanceID, client: client) else { return }
        deletionImpact = result.impact
        impactError = result.error
    }

    /// 删除（二次确认之后）。已经不存在了（别处删了）也算删掉了。
    @discardableResult
    public func delete() async -> Bool {
        guard !isDeleting, !isDeleted else { return false }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await client.deleteInstance(instanceID)
            isDeleted = true
        } catch {
            guard let failure = AgentsErrors.from(error) else { return false }
            if failure.isNotFound {
                isDeleted = true
            } else {
                deleteError = failure
            }
        }
        return isDeleted
    }
}

/// 实例详情里“模型路由”那一行显示什么。
public enum InstanceRouteStatus: Hashable, Sendable {
    /// 还没拉到。
    case unknown
    /// 一个别名都没有：任务会卡在等 key。
    case notConfigured
    /// 有别名但没有 main（App 要求必须有 main）。
    case missingMain(aliases: Int)
    /// 配好了 main。
    case configured(main: ModelRoute, aliases: Int)

    /// 要提醒用户去配（没有 main）。
    public var needsAttention: Bool {
        switch self {
        case .notConfigured, .missingMain: true
        case .unknown, .configured: false
        }
    }

    /// 那一行的说明文字。
    public func summary(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .unknown:
            return zh ? "别名、key 和降级链" : "Aliases, keys and fallbacks"
        case .notConfigured:
            return zh ? "还没配，任务会停在“等待 key”" : "Not set up yet; tasks will wait for a key"
        case .missingMain:
            return zh ? "缺少 main 别名，请补上" : "The main alias is missing"
        case .configured(let main, let aliases):
            let others = aliases - 1
            if others <= 0 { return "main → \(main.upstreamModel)" }
            return zh
                ? "main → \(main.upstreamModel)，另有 \(others) 个别名" : "main → \(main.upstreamModel), +\(others) more"
        }
    }
}

/// 版本列表里的一项。
public struct InstanceVersionOption: Identifiable, Hashable, Sendable {
    /// 换过去是什么操作。
    public enum Change: Hashable, Sendable {
        /// 现在用的就是它。
        case current
        /// 比现在新。
        case upgrade
        /// 比现在旧。
        case rollback
        /// 现在的版本不在列表里，不知道新旧。
        case switchTo
    }

    public var version: String
    /// 目录里最新的版本（`versions` 的第一个）。
    public var isLatest: Bool
    public var change: Change

    public var id: String { version }

    public init(version: String, isLatest: Bool, change: Change) {
        self.version = version
        self.isLatest = isLatest
        self.change = change
    }

    public var isCurrent: Bool { change == .current }

    /// 按钮、确认框上的动作名：“升级到 v2.2.2”“回滚到 v2.1.0”。
    public func actionTitle(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let label = AgentsText.versionLabel(version)
        switch change {
        case .current: return zh ? "正在使用 \(label)" : "Using \(label)"
        case .upgrade: return zh ? "升级到 \(label)" : "Upgrade to \(label)"
        case .rollback: return zh ? "回滚到 \(label)" : "Roll back to \(label)"
        case .switchTo: return zh ? "换到 \(label)" : "Switch to \(label)"
        }
    }
}

/// 换过的版本（界面提示“下次唤醒时生效，工作区保留”）。
public struct InstanceVersionChange: Hashable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public func message(_ language: DisplayLanguage = .current) -> String {
        let to = AgentsText.versionLabel(self.to)
        return language == .chinese
            ? "已换到 \(to)，下次唤醒沙箱时生效，工作区里的文件都保留。"
            : "Switched to \(to). It takes effect the next time the sandbox wakes up; files in the workspace are kept."
    }
}
