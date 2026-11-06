import Foundation
import Observation

/// 实例详情（WBS 12.3，深链 `thinktin://instance/{id}`）：Botin 资料页（参考 09）和从它压进去的编辑页、工作区页共用。
/// 管实例本身、改名、本实例的计划（“计划”那一行的数）、删除。
///
/// - 先显示缓存（`cachedInstances`，离线也能看，docs/ios.md 6.2），再拉 `instance(_:)`，然后拉本实例的计划。计划拉不到
///   不影响页面，只在 `detailsError` 里记一下。
/// - 删除：先 `prepareDeletion()` 查影响（`InstanceDeletionImpact`：会停掉的运行、一起删掉的计划和产出物、
///   会停下来等改步骤的别的流水线（11.9）、团队成员身份），界面列出来、二次确认后再 `delete()`。
///
/// 以前资料页上的默认模型、所在团队、信息和工作区页上的引擎版本（升级、回滚）2026-11-06 照参考 09、65 去掉了，
/// 这里拉的目录、模型路由、团队和换版本一起删了。
@Observable @MainActor
public final class InstanceDetailModel {
    public let instanceID: InstanceID
    public private(set) var instance: Instance?
    /// 这个实例自己的计划；nil 是还没拉到。
    public private(set) var plans: [Plan]?

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 实例本身拉不到（网络不通时照样显示缓存里的）。
    public private(set) var error: ClientError?
    /// 本实例的计划拉不到。
    public private(set) var detailsError: ClientError?
    /// 实例不存在了（被删了，或者不是这个账号的）。
    public private(set) var isMissing = false

    public private(set) var isRenaming = false
    public private(set) var renameError: ClientError?

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
    /// 这台设备上按 Botin 记的东西（App 里是 `AppModel.local`）：删掉 Botin 时一起删它的记录（头像外观、置顶和隐藏、
    /// 语音通话设置、表情回应、主 Botin）；nil 不管（测试、预览）。
    @ObservationIgnored public let local: BotinLocalData?

    /// 这台设备上记的语音通话设置（编辑页的“语音通话”组）；没传 `local` 时为 nil（编辑页这时用 `.shared`）。
    public var voices: BotinVoiceStore? { local?.voices }

    /// - Parameters:
    ///   - instance: 已经有的实例（应用框架的实例列表里的），先显示它。
    ///   - local: 这台设备上按 Botin 记的东西（`AppModel.local`），删掉 Botin 时一起删它的记录。
    public init(
        client: any ClientProtocol, instanceID: InstanceID, instance: Instance? = nil, local: BotinLocalData? = nil
    ) {
        self.client = client
        self.instanceID = instanceID
        self.instance = instance?.id == instanceID ? instance : nil
        self.local = local
    }

    // MARK: 加载

    /// 拉实例和它的计划（打开页面、下拉刷新、联网后）。正在拉时再调直接返回。
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
        guard instance != nil, !isMissing else {
            hasLoaded = true
            return
        }
        await loadPlans()
        hasLoaded = true
    }

    /// 拉本实例的计划（“计划”那一行的数）；拉不到记在 `detailsError`，页面照样显示。
    private func loadPlans() async {
        let id = instanceID
        do {
            plans = try await client.plans(instanceID: id).filter { $0.instanceID == id }
            detailsError = nil
        } catch {
            detailsError = AgentsErrors.from(error)
        }
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

    /// 删除（二次确认之后）。已经不存在了（别处删了）也算删掉了。删掉了顺带删这台设备上按它记的东西（`local`：头像外观、
    /// 置顶和隐藏、语音通话设置、表情回应，是主 Botin 的话清掉）。
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
        if isDeleted { local?.forget([instanceID]) }
        return isDeleted
    }
}
