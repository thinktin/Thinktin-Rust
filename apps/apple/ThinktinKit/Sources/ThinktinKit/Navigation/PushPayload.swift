import Foundation

/// 推送通知里给 App 的数据（服务端 crates/notify/src/apns.rs 的 `payload`）：自定义数据都在 `tt` 下，只有种类和 id，
/// 不带内容：
///
/// ```json
/// {"aps": {"alert": {…}, "category": "APPROVAL"},
///  "tt": {"kind": "approval", "instance": "…", "run": "…", "approval": "…", "plan": "…", "inbox": "…"}}
/// ```
///
/// 点开通知时按 `route` 跳转（规则见 docs/ios.md 第 6.1 节），`inboxItemID` 给收件箱（12.8）标已读。
/// 字段名和安卓的 `tt_*` 一致（crates/notify/src/fcm.rs）。保险箱请求 id 等 10.7 加进 `tt` 后再接。
public struct PushPayload: Hashable, Sendable {
    /// 推送的种类（`notify::PushKind`，和收件箱条目的种类同名）。
    public enum Kind: OpenStringEnum {
        /// 运行完成。
        case runFinished
        /// 运行失败或需要用户处理（key 失效、额度用完）。
        case runFailed
        /// 云端审批（agent 请求权限）。
        case approval
        /// 电脑上的高危操作请手机批准（12.9）。
        case computerApproval
        /// 其他提醒（计划待确认、账号恢复……）。
        case info
        case unknown(String)

        public static let knownCases: [Kind] = [.runFinished, .runFailed, .approval, .computerApproval, .info]

        public var rawValue: String {
            switch self {
            case .runFinished: "run_finished"
            case .runFailed: "run_failed"
            case .approval: "approval"
            case .computerApproval: "computer_approval"
            case .info: "info"
            case .unknown(let raw): raw
            }
        }
    }

    public var kind: Kind
    public var instanceID: InstanceID?
    public var runID: RunID?
    public var approvalID: ApprovalID?
    public var planID: PlanID?
    public var inboxItemID: InboxItemID?

    public init(
        kind: Kind, instanceID: InstanceID? = nil, runID: RunID? = nil, approvalID: ApprovalID? = nil,
        planID: PlanID? = nil, inboxItemID: InboxItemID? = nil
    ) {
        self.kind = kind
        self.instanceID = instanceID
        self.runID = runID
        self.approvalID = approvalID
        self.planID = planID
        self.inboxItemID = inboxItemID
    }

    /// 从通知的 `userInfo`（`UNNotificationContent.userInfo`）解析。没有 `tt`、`tt` 不是字典时返回 nil
    /// （不是我们的推送）；不像 id 的 id 当作没有。
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
        self.init(
            kind: Kind(rawValue: (tt["kind"] as? String) ?? ""),
            instanceID: id("instance").map { InstanceID($0) },
            runID: id("run").map { RunID($0) },
            approvalID: id("approval").map { ApprovalID($0) },
            planID: id("plan").map { PlanID($0) },
            inboxItemID: id("inbox").map { InboxItemID($0) })
    }

    /// 点开通知要去的页面：
    ///
    /// - 审批：审批详情；没有审批 id 时去运行详情，再没有就是审批中心。电脑审批同理（没有 id 时去审批中心）。
    /// - 运行完成、失败：运行详情；没有运行 id 时去实例的对话，再没有就是收件箱里的这一条 / 收件箱。
    /// - 其他提醒（和认不出的种类）：计划详情 → 运行详情 → 实例的对话 → 收件箱里的这一条 → 收件箱，取第一个有 id 的。
    ///
    /// 推送里有实例 id 时 `Router.handle(push:)` 顺带切到这个实例，返回时回到它的对话。
    public var route: AppRoute {
        let inbox: AppRoute = inboxItemID.map(AppRoute.inboxItem) ?? .inbox
        switch kind {
        case .approval, .computerApproval:
            if let approvalID { return .approval(approvalID) }
            if kind == .approval, let runID { return .run(runID) }
            return .approvals
        case .runFinished, .runFailed:
            if let runID { return .run(runID) }
            if let instanceID { return .conversation(instanceID) }
            return inbox
        case .info, .unknown:
            if let planID { return .plan(planID) }
            if let runID { return .run(runID) }
            if let instanceID { return .conversation(instanceID) }
            return inbox
        }
    }
}
