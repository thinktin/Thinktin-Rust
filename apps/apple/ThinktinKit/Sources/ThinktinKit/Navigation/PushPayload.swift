import Foundation

/// 推送通知里给 App 的数据（服务端 crates/notify/src/apns.rs 的 `payload`，约定见 docs/push.md 第 3、4 节）：
/// 自定义数据都在 `tt` 下，只有种类、子类型和 id，不带内容：
///
/// ```json
/// {"aps": {"alert": {…}, "category": "VAULT_REQUEST", "badge": 3},
///  "tt": {"kind": "vault_request", "instance": "…", "run": "…", "approval": "…", "plan": "…", "inbox": "…",
///         "vault_request": "…", "subtype": "…"}}
/// ```
///
/// 点开通知时按 `route` 跳转（规则见 docs/ios.md 第 6.1 节），`AppModel.receive(push:)` 按 `subtype` 处理账号冻结、
/// 解冻，`inboxItemID` 给收件箱（12.8）标已读。字段名和安卓的 `tt_*` 一致（crates/notify/src/fcm.rs）。
public struct PushPayload: Hashable, Sendable {
    /// 推送的种类（`notify::PushKind`，和收件箱条目的种类同名，docs/push.md 第 2 节）。不认识的按 `info` 处理。
    public enum Kind: OpenStringEnum {
        /// 运行完成。
        case runFinished
        /// 运行失败或需要用户处理（key 失效、额度用完，`subtype` 是等待原因码）。
        case runFailed
        /// 云端审批（agent 请求权限）。
        case approval
        /// 电脑上的高危操作请手机批准（12.9）。
        case computerApproval
        /// agent 请用户往保险箱里填账号密码，运行等着（10.7，带 `vaultRequestID`）。
        case vaultRequest
        /// agent 建了或改了计划，等用户确认（10.7，带 `planID`）。
        case planConfirm
        /// 其他提醒（账号冻结 / 恢复、触发规则失效……，看 `subtype`）。
        case info
        case unknown(String)

        public static let knownCases: [Kind] = [
            .runFinished, .runFailed, .approval, .computerApproval, .vaultRequest, .planConfirm, .info,
        ]

        public var rawValue: String {
            switch self {
            case .runFinished: "run_finished"
            case .runFailed: "run_failed"
            case .approval: "approval"
            case .computerApproval: "computer_approval"
            case .vaultRequest: "vault_request"
            case .planConfirm: "plan_confirm"
            case .info: "info"
            case .unknown(let raw): raw
            }
        }
    }

    public var kind: Kind
    /// 是哪一种提醒（10.7，`tt.subtype`）；没有时为 nil。
    public var subtype: NotificationSubtype?
    public var instanceID: InstanceID?
    public var runID: RunID?
    public var approvalID: ApprovalID?
    public var planID: PlanID?
    public var inboxItemID: InboxItemID?
    /// 保险箱请求（10.7，`tt.vault_request`）。
    public var vaultRequestID: VaultRequestID?

    public init(
        kind: Kind, subtype: NotificationSubtype? = nil, instanceID: InstanceID? = nil, runID: RunID? = nil,
        approvalID: ApprovalID? = nil, planID: PlanID? = nil, inboxItemID: InboxItemID? = nil,
        vaultRequestID: VaultRequestID? = nil
    ) {
        self.kind = kind
        self.subtype = subtype
        self.instanceID = instanceID
        self.runID = runID
        self.approvalID = approvalID
        self.planID = planID
        self.inboxItemID = inboxItemID
        self.vaultRequestID = vaultRequestID
    }

    /// 从通知的 `userInfo`（`UNNotificationContent.userInfo`）解析。没有 `tt`、`tt` 不是字典时返回 nil
    /// （不是我们的推送）；不像 id 的 id 当作没有，空的子类型当作没有。
    public init?(userInfo: [AnyHashable: Any]) {
        let tt: [String: Any]
        if let dict = userInfo["tt"] as? [String: Any] {
            tt = dict
        } else if let dict = userInfo["tt"] as? [AnyHashable: Any] {
            tt = Dictionary(
                dict.compactMap { key, value in (key.base as? String).map { ($0, value) } },
                uniquingKeysWith: { first, _ in first })
        } else {
            return nil
        }
        func id(_ key: String) -> String? {
            guard let value = tt[key] as? String, DeepLink.isValidID(value) else { return nil }
            return value
        }
        let subtype = (tt["subtype"] as? String).flatMap { raw -> NotificationSubtype? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : NotificationSubtype(rawValue: trimmed)
        }
        self.init(
            kind: Kind(rawValue: (tt["kind"] as? String) ?? ""),
            subtype: subtype,
            instanceID: id("instance").map { InstanceID($0) },
            runID: id("run").map { RunID($0) },
            approvalID: id("approval").map { ApprovalID($0) },
            planID: id("plan").map { PlanID($0) },
            inboxItemID: id("inbox").map { InboxItemID($0) },
            vaultRequestID: id("vault_request").map { VaultRequestID($0) })
    }

    /// 点开通知要去的页面：
    ///
    /// - 审批：审批详情；没有审批 id 时去运行详情，再没有就是审批中心。电脑审批同理（没有 id 时去审批中心）。
    /// - 运行完成、失败：运行详情（等 key、等电脑的也在那里处理）；没有运行 id 时去实例的对话，再没有就是收件箱里的这一条 /
    ///   收件箱。
    /// - 保险箱请求：填写请求页；没有请求 id 时去运行详情 → 实例的对话 → 收件箱里的这一条 → 收件箱。
    /// - 计划待确认：计划确认页；没有计划 id 时去计划列表（那里有“待确认”分区）。
    /// - 其他提醒（和认不出的种类）：先看子类型——审批超时跳过的去运行详情，IM 渠道停用的去 IM 渠道设置；
    ///   其余按计划详情 → 运行详情 → 实例的对话 → 收件箱里的这一条 → 收件箱，取第一个有 id 的。
    ///
    /// 推送里有实例 id 时 `Router.handle(push:)` 顺带切到这个实例，返回时回到它的对话。
    public var route: AppRoute {
        let inbox: AppRoute = inboxItemID.map(AppRoute.inboxItem) ?? .inbox
        func fallback() -> AppRoute {
            if let runID { return .run(runID) }
            if let instanceID { return .conversation(instanceID) }
            return inbox
        }
        switch kind {
        case .approval, .computerApproval:
            if let approvalID { return .approval(approvalID) }
            if kind == .approval, let runID { return .run(runID) }
            return .approvals
        case .runFinished, .runFailed:
            return fallback()
        case .vaultRequest:
            if let vaultRequestID { return .vaultRequest(vaultRequestID) }
            return fallback()
        case .planConfirm:
            if let planID { return .confirmPlan(planID) }
            return .plans
        case .info, .unknown:
            switch subtype {
            case .approvalSkipped?:
                if let runID { return .run(runID) }
                if let approvalID { return .approval(approvalID) }
            case .imChannelDisabled?:
                return .imChannels
            default:
                break
            }
            if let planID { return .plan(planID) }
            return fallback()
        }
    }
}
