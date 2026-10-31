import Foundation
import Observation

/// 审批的决定（审批中心和审批详情共用，WBS 12.15）：批准类的先过本机验证（`BiometricGate`，取消了什么都不做，没通过
/// 提示一句），拒绝直接发；已经在别处处理过的（冲突、不存在）查一次最新记录，不算出错。和对话里审批卡片的规则一样
/// （`ConversationModel.decide`）。
enum ApprovalDecision {
    /// 决定的结果。
    enum Result: Sendable {
        /// 决定了，带服务端返回的记录。
        case decided(Approval)
        /// 别处已经处理过（或者过期了）：带最新的记录；查不到（被删、不是自己的）时为 nil。
        case alreadyHandled(Approval?)
        /// 用户取消了本机验证：什么都不做。
        case cancelled
        case failed(ConversationActionError)
    }

    @MainActor
    static func decide(
        _ approval: Approval, option: ApprovalOption, reason: String, client: any ClientProtocol,
        gate: any BiometricGate
    ) async -> Result {
        // 不是明确拒绝的都先验证（认不出的种类也算批准类）。
        if !option.kind.isReject {
            switch await gate.authorize(reason: reason) {
            case .cancelled: return .cancelled
            case .failed: return .failed(.verificationFailed)
            case .approved, .unavailable: break
            }
        }
        do {
            return .decided(try await client.decideApproval(approval.id, optionID: option.id))
        } catch {
            guard let failure = ConversationErrors.from(error) else { return .cancelled }
            if failure.isConflict || failure.isNotFound {
                do {
                    let latest = try await client.getApproval(approval.id)
                    if !latest.isPending { return .alreadyHandled(latest) }
                } catch {
                    guard let lookup = ConversationErrors.from(error) else { return .cancelled }
                    return lookup.isNotFound ? .alreadyHandled(nil) : .failed(.client(lookup))
                }
            }
            return .failed(.client(failure))
        }
    }
}

/// 审批中心（WBS 12.15，`.approvals`，抽屉里的“审批”）：所有实例等你处理的审批（`approvals()`，只返回待处理、没过期的），
/// 快过期的在前。每条显示所属实例、agent 写的标题（AI 生成标识）、要执行的工具调用、剩余时间和选项；点开看详情。
///
/// - 决定后从列表里拿掉；别处已经处理过、过期了的也拿掉，提示一句（`notice`）。
/// - 过期是按时间算的：页面开着时到期的也不再显示（`visible(now:)`），不用等刷新。
/// - 实例名先用缓存，再用 `instances()` 的；拉不到实例时显示“已删除的实例”。
@Observable @MainActor
public final class ApprovalCenterModel {
    public private(set) var approvals: [Approval] = []
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 正在决定的审批。
    public private(set) var deciding: Set<ApprovalID> = []
    /// 某条审批上的错误（本机验证没过、接口出错）。
    public private(set) var errors: [ApprovalID: ConversationActionError] = [:]
    /// 最近一次操作的结果提示（批准了 / 拒绝了 / 已在别处处理）。
    public private(set) var notice: ApprovalNotice?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let gate: any BiometricGate
    @ObservationIgnored private let now: () -> Date

    public init(
        client: any ClientProtocol, biometricGate: any BiometricGate = PassthroughBiometricGate(),
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.gate = biometricGate
        self.now = now
    }

    /// 还能处理的（没过期），快过期的在前。
    public func visible(now date: Date? = nil) -> [Approval] {
        let at = date ?? now()
        return approvals.filter { $0.isPending && !$0.isExpired(now: at) }
    }

    /// 实例名；实例已经没了（删除了）时为 nil。
    public func instanceName(_ id: InstanceID) -> String? { instanceNames[id] }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if instanceNames.isEmpty, let cached = try? client.cachedInstances() {
            instanceNames = Self.names(cached)
        }
        do {
            let list = try await client.approvals()
            approvals = list.filter(\.isPending)
                .sorted { ($0.expiresAt, $0.id.rawValue) < ($1.expiresAt, $1.id.rawValue) }
            error = nil
            // 已经不在列表里的，错误清掉。
            let ids = Set(approvals.map(\.id))
            errors = errors.filter { ids.contains($0.key) }
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
        if let fresh = try? await client.instances() {
            instanceNames.merge(Self.names(fresh)) { _, new in new }
        }
        hasLoaded = true
    }

    /// 选一个选项。
    public func decide(_ approval: Approval, option: ApprovalOption, reason: String) async {
        guard approval.isPending, !deciding.contains(approval.id) else { return }
        errors[approval.id] = nil
        notice = nil
        deciding.insert(approval.id)
        defer { deciding.remove(approval.id) }
        switch await ApprovalDecision.decide(approval, option: option, reason: reason, client: client, gate: gate) {
        case .decided(let record):
            approvals.removeAll { $0.id == approval.id }
            notice = .decided(record, option: option)
        case .alreadyHandled(let latest):
            approvals.removeAll { $0.id == approval.id }
            notice = .alreadyHandled(latest ?? approval)
        case .cancelled:
            break
        case .failed(let failure):
            errors[approval.id] = failure
        }
    }

    public func clearError(_ id: ApprovalID) {
        errors[id] = nil
    }

    public func clearNotice() {
        notice = nil
    }

    static func names(_ instances: [Instance]) -> [InstanceID: String] {
        Dictionary(
            instances.filter { $0.state != .deleted }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 处理完一条审批之后的提示。
public enum ApprovalNotice: Hashable, Sendable {
    /// 你批准了 / 拒绝了（选的那个选项）。
    case decided(Approval, option: ApprovalOption)
    /// 别处已经处理过、或者已经过期。
    case alreadyHandled(Approval)

    public var approvalID: ApprovalID {
        switch self {
        case .decided(let a, _), .alreadyHandled(let a): a.id
        }
    }
}

/// 审批详情（WBS 12.15，`.approval(id)`：推送 `tt.approval`、深链 `thinktin://approval/{id}`、收件箱、对话里的审批卡片
/// 进来）：什么状态都能看（`getApproval`）。待处理的可以直接决定；已处理的显示结论（谁、选了什么、什么时候）。
/// 推送进来时已经处理过、过期了的不报错，显示结论。
@Observable @MainActor
public final class ApprovalDetailModel {
    public let approvalID: ApprovalID
    public private(set) var approval: Approval?
    public private(set) var instanceName: String?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 没有这条审批（不存在、不是自己的）。
    public private(set) var isMissing = false
    public private(set) var isDeciding = false
    public private(set) var decideError: ConversationActionError?
    /// 决定时发现别处已经处理过。
    public private(set) var handledElsewhere = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let gate: any BiometricGate
    @ObservationIgnored private let now: () -> Date

    public init(
        client: any ClientProtocol, approvalID: ApprovalID, approval: Approval? = nil,
        biometricGate: any BiometricGate = PassthroughBiometricGate(), now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.approvalID = approvalID
        self.approval = approval?.id == approvalID ? approval : nil
        self.gate = biometricGate
        self.now = now
    }

    /// 还能决定（待处理、没过期）。
    public var canDecide: Bool {
        guard let approval else { return false }
        return approval.isPending && !approval.isExpired(now: now())
    }

    /// 已处理的结论；待处理的为 nil。页面开着时到期的算过期。
    public var outcome: ApprovalOutcome? {
        guard let approval else { return nil }
        if approval.isPending { return approval.isExpired(now: now()) ? .expired : nil }
        return Self.recordOutcome(of: approval)
    }

    /// 审批记录的结论。服务端的记录只有用户的决定、超时、作废（预授权的不建记录）。
    public nonisolated static func recordOutcome(of approval: Approval) -> ApprovalOutcome? {
        switch approval.state {
        case .pending: nil
        case .approved: .approvedByUser
        case .rejected: .rejectedByUser
        case .expired: .expired
        case .cancelled, .unknown: .cancelled
        }
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let record = try await client.getApproval(approvalID)
            approval = record
            error = nil
            isMissing = false
            if instanceName == nil {
                let cached = (try? client.cachedInstances()) ?? []
                instanceName = cached.first { $0.id == record.instanceID && $0.state != .deleted }?.name
                if instanceName == nil, let fresh = try? await client.instances() {
                    instanceName = fresh.first { $0.id == record.instanceID && $0.state != .deleted }?.name
                }
            }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound {
                isMissing = true
            } else {
                self.error = failure
            }
        }
        hasLoaded = true
    }

    public func decide(option: ApprovalOption, reason: String) async {
        guard let approval, canDecide, !isDeciding else { return }
        decideError = nil
        isDeciding = true
        defer { isDeciding = false }
        switch await ApprovalDecision.decide(approval, option: option, reason: reason, client: client, gate: gate) {
        case .decided(let record):
            self.approval = record
        case .alreadyHandled(let latest):
            handledElsewhere = true
            // 查不到了（被删、不是自己的）就说找不到，别留一条还能点的待处理。
            if let latest { self.approval = latest } else { isMissing = true }
        case .cancelled:
            break
        case .failed(let failure):
            decideError = failure
        }
    }

    public func clearDecideError() {
        decideError = nil
    }
}
