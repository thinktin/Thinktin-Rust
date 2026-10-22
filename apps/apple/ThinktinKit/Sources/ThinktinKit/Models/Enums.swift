import Foundation

// 服务端字符串枚举的 Swift 版本（取值见 crates/proto/src/domain.rs、shim.rs、api.rs）。
// 每个都有 `unknown(String)`：服务端加了新取值时界面按“未知”显示，不崩溃。

/// 账号状态。冻结会暂停所有运行授权（4.6）。
public enum UserStatus: OpenStringEnum {
    case active, frozen, deleted
    case unknown(String)

    public static let knownCases: [UserStatus] = [.active, .frozen, .deleted]

    public var rawValue: String {
        switch self {
        case .active: "active"
        case .frozen: "frozen"
        case .deleted: "deleted"
        case .unknown(let raw): raw
        }
    }
}

/// 设备平台。
public enum DevicePlatform: OpenStringEnum {
    case ios, android, macos
    case unknown(String)

    public static let knownCases: [DevicePlatform] = [.ios, .android, .macos]

    public var rawValue: String {
        switch self {
        case .ios: "ios"
        case .android: "android"
        case .macos: "macos"
        case .unknown(let raw): raw
        }
    }
}

extension DevicePlatform {
    /// 当前编译的平台（Linux 上编译测试时按 macOS 算）。
    public static var current: DevicePlatform {
        #if os(iOS)
            .ios
        #else
            .macos
        #endif
    }
}

/// 推送通道（8.3、10.7，docs/push.md 第 1 节）。iOS 用 `apns`（TestFlight、App Store 的包）或 `apnsSandbox`
/// （开发证书签名的包，`aps-environment` 是 development，令牌是 APNs 沙盒环境的；报错了会被 APNs 判成
/// `BadDeviceToken` 清掉）。
public enum PushChannel: OpenStringEnum {
    case apns
    /// APNs 沙盒环境（Xcode 直装的 Debug 构建）。
    case apnsSandbox
    case fcm, hms, honor, mi, oppo, vivo, unipush
    case unknown(String)

    public static let knownCases: [PushChannel] = [
        .apns, .apnsSandbox, .fcm, .hms, .honor, .mi, .oppo, .vivo, .unipush,
    ]

    public var rawValue: String {
        switch self {
        case .apns: "apns"
        case .apnsSandbox: "apns_sandbox"
        case .fcm: "fcm"
        case .hms: "hms"
        case .honor: "honor"
        case .mi: "mi"
        case .oppo: "oppo"
        case .vivo: "vivo"
        case .unipush: "unipush"
        case .unknown(let raw): raw
        }
    }
}

/// 用户的语言（1.6）：服务端生成的推送、收件箱文案按它输出。App 界面的语言由 App 自己管。
///
/// 不叫 `Locale`，免得和 `Foundation.Locale` 冲突。
public enum UserLocale: OpenStringEnum {
    case zhCN, en
    case unknown(String)

    public static let knownCases: [UserLocale] = [.zhCN, .en]

    public var rawValue: String {
        switch self {
        case .zhCN: "zh-CN"
        case .en: "en"
        case .unknown(let raw): raw
        }
    }

    /// `Accept-Language`（`en-US,en;q=0.9,zh-CN;q=0.8`）里最想要的、支持的语言：按 q 值从高到低（相同的按出现顺序），
    /// q=0 的不要，q 写错了的那一项跳过；一个都认不出返回 nil。和服务端的 `Locale::from_accept_language` 一致
    /// （新用户注册时服务端按它定推送和收件箱的语言，认不出时用中文）。
    public init?(acceptLanguage header: String) {
        // 每一项是“标签;q=…”，没写 q 的算 1；最多看 20 项。
        var entries: [(q: Float, tag: String)] = []
        for part in header.split(separator: ",", omittingEmptySubsequences: false).prefix(20) {
            let fields = part.split(separator: ";", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var q: Float = 1
            if let field = fields.dropFirst().first(where: { $0.hasPrefix("q=") }) {
                guard let parsed = Float(field.dropFirst(2).trimmingCharacters(in: .whitespaces)) else { continue }
                q = parsed.isNaN ? 0 : parsed
            }
            entries.append((q, fields.first ?? ""))
        }
        // q 从高到低；相同的保持出现的顺序（稳定排序）。
        let ordered = entries.enumerated().sorted { a, b in
            a.element.q != b.element.q ? a.element.q > b.element.q : a.offset < b.offset
        }
        let supported = ordered.lazy.filter { $0.element.q > 0 }.compactMap { UserLocale(languageTag: $0.element.tag) }
        guard let found = supported.first else { return nil }
        self = found
    }

    /// 从系统的语言标签（`zh-Hans-CN`、`en_US`、`zh`）认出支持的语言；认不出返回 nil。和服务端的 `Locale::from_tag` 一致。
    public init?(languageTag tag: String) {
        let first =
            tag.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch first {
        case "zh": self = .zhCN
        case "en": self = .en
        default: return nil
        }
    }
}

/// 实例（沙箱）的状态（4.10）。
public enum InstanceState: OpenStringEnum {
    case provisioning, running
    /// 内存快照，唤醒快。
    case paused
    /// 只留工作区卷，唤醒要从模板重建。
    case archived
    case deleted
    case unknown(String)

    public static let knownCases: [InstanceState] = [.provisioning, .running, .paused, .archived, .deleted]

    public var rawValue: String {
        switch self {
        case .provisioning: "provisioning"
        case .running: "running"
        case .paused: "paused"
        case .archived: "archived"
        case .deleted: "deleted"
        case .unknown(let raw): raw
        }
    }
}

/// 运行由什么发起。
public enum RunSource: OpenStringEnum {
    case user, plan, pipeline, delegate
    case unknown(String)

    public static let knownCases: [RunSource] = [.user, .plan, .pipeline, .delegate]

    public var rawValue: String {
        switch self {
        case .user: "user"
        case .plan: "plan"
        case .pipeline: "pipeline"
        case .delegate: "delegate"
        case .unknown(let raw): raw
        }
    }
}

/// 运行的种类：agent 在实例的沙箱里执行一轮；pipeline 是流水线的根，只协调子运行（8.3）。
public enum RunKind: OpenStringEnum {
    case agent, pipeline
    case unknown(String)

    public static let knownCases: [RunKind] = [.agent, .pipeline]

    public var rawValue: String {
        switch self {
        case .agent: "agent"
        case .pipeline: "pipeline"
        case .unknown(let raw): raw
        }
    }
}

/// 运行的状态机（4.3）。
public enum RunState: OpenStringEnum {
    case queued
    /// 拿到执行租约，正在唤醒沙箱、等 agent 就绪。
    case starting
    case running
    case waitingApproval
    case waitingDevice
    case waitingQuota
    /// 父运行等子运行（4.11）。
    case waitingChildren
    /// 崩溃或超时后的重试等待。
    case backoff
    case succeeded
    case failed
    case cancelled
    case unknown(String)

    public static let knownCases: [RunState] = [
        .queued, .starting, .running, .waitingApproval, .waitingDevice, .waitingQuota, .waitingChildren,
        .backoff, .succeeded, .failed, .cancelled,
    ]

    public var rawValue: String {
        switch self {
        case .queued: "queued"
        case .starting: "starting"
        case .running: "running"
        case .waitingApproval: "waiting_approval"
        case .waitingDevice: "waiting_device"
        case .waitingQuota: "waiting_quota"
        case .waitingChildren: "waiting_children"
        case .backoff: "backoff"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }

    /// 已经结束（成功、失败、取消）。
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    /// 在等什么（审批、电脑、key、子任务）：界面显示原因和下一步。
    public var isWaiting: Bool {
        switch self {
        case .waitingApproval, .waitingDevice, .waitingQuota, .waitingChildren: true
        default: false
        }
    }

    /// 还没结束（包括排队、退避和不认识的状态）。可以取消。
    public var isActive: Bool { !isTerminal }
}

/// 审批的状态。
public enum ApprovalState: OpenStringEnum {
    case pending, approved, rejected, expired, cancelled
    case unknown(String)

    public static let knownCases: [ApprovalState] = [.pending, .approved, .rejected, .expired, .cancelled]

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .approved: "approved"
        case .rejected: "rejected"
        case .expired: "expired"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }
}

/// 审批选项的种类（同 ACP 的 `PermissionOptionKind`）。
public enum ApprovalOptionKind: OpenStringEnum {
    case allowOnce, allowAlways, rejectOnce, rejectAlways
    case unknown(String)

    public static let knownCases: [ApprovalOptionKind] = [.allowOnce, .allowAlways, .rejectOnce, .rejectAlways]

    public var rawValue: String {
        switch self {
        case .allowOnce: "allow_once"
        case .allowAlways: "allow_always"
        case .rejectOnce: "reject_once"
        case .rejectAlways: "reject_always"
        case .unknown(let raw): raw
        }
    }

    /// 批准类的选项（批准前要做生物识别确认）。不认识的按前缀判断。
    public var isAllow: Bool {
        switch self {
        case .allowOnce, .allowAlways: true
        case .rejectOnce, .rejectAlways: false
        case .unknown(let raw): raw.hasPrefix("allow")
        }
    }

    public var isReject: Bool {
        switch self {
        case .rejectOnce, .rejectAlways: true
        case .allowOnce, .allowAlways: false
        case .unknown(let raw): raw.hasPrefix("reject")
        }
    }
}

/// 审批由谁决定（`agent.permission_resolved` 的 `by`）。
public enum DecisionSource: OpenStringEnum {
    /// 按计划的预授权范围自动决定（4.7）。
    case policy
    /// 用户在 App 里决定。
    case user
    /// 等待用户决定超时（4.7）。
    case timeout
    /// 这一轮被取消，未决的请求一并作废。
    case cancelled
    case unknown(String)

    public static let knownCases: [DecisionSource] = [.policy, .user, .timeout, .cancelled]

    public var rawValue: String {
        switch self {
        case .policy: "policy"
        case .user: "user"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }
}

/// 审批超时后怎么办（4.7）。
public enum ApprovalTimeoutAction: OpenStringEnum {
    /// 拒绝这一步，让 agent 继续。
    case skip
    /// 暂停整个计划。
    case pausePlan
    /// 这次运行失败。
    case fail
    case unknown(String)

    public static let knownCases: [ApprovalTimeoutAction] = [.skip, .pausePlan, .fail]

    public var rawValue: String {
        switch self {
        case .skip: "skip"
        case .pausePlan: "pause_plan"
        case .fail: "fail"
        case .unknown(let raw): raw
        }
    }
}

/// 计划由谁建的：agent 通过平台工具建的计划要用户确认后才生效（7.8）。
public enum PlanAuthor: OpenStringEnum {
    case user, agent
    case unknown(String)

    public static let knownCases: [PlanAuthor] = [.user, .agent]

    public var rawValue: String {
        switch self {
        case .user: "user"
        case .agent: "agent"
        case .unknown(let raw): raw
        }
    }
}

/// agent 对计划做了什么（`plan.needs_confirmation` 的 `change`）。
///
/// 不叫 `PlanChange`：那个名字给了 `updatePlan` 的部分修改（和 ThinktinCore 的记录同名）。
public enum PlanChangeKind: OpenStringEnum {
    case created, updated
    case unknown(String)

    public static let knownCases: [PlanChangeKind] = [.created, .updated]

    public var rawValue: String {
        switch self {
        case .created: "created"
        case .updated: "updated"
        case .unknown(let raw): raw
        }
    }
}

/// 计划错过的触发（暂停、停机期间该触发没触发的）怎么补（4.4）。
public enum CatchUp: OpenStringEnum {
    /// 错过几次都只补一次（默认）。
    case once
    /// 错过几次补几次。
    case all
    /// 不补，等下一次。
    case skip
    case unknown(String)

    public static let knownCases: [CatchUp] = [.once, .all, .skip]

    /// 新建计划不指定时服务端用的。
    public static let `default`: CatchUp = .once

    public var rawValue: String {
        switch self {
        case .once: "once"
        case .all: "all"
        case .skip: "skip"
        case .unknown(let raw): raw
        }
    }
}

/// 团队成员的角色（8.1）。
public enum TeamRole: OpenStringEnum {
    /// 负责人：委派时由它分工（8.7）。一个团队最多一个。
    case lead
    case member
    case unknown(String)

    public static let knownCases: [TeamRole] = [.lead, .member]

    public var rawValue: String {
        switch self {
        case .lead: "lead"
        case .member: "member"
        case .unknown(let raw): raw
        }
    }
}

/// 手机和电脑之间经平台转发的消息的种类（14.1，内容和签名见 docs/pairing.md）。
/// 平台只转发：内容由两端用安全芯片里的私钥签名。
public enum DeviceMessageKind: OpenStringEnum {
    /// 手机 → 电脑：扫码后的配对应答。
    case pairResponse
    /// 电脑 → 手机：确认配对。
    case pairConfirm
    /// 电脑 → 手机：高危操作，请手机签名批准。
    case approvalRequest
    /// 手机 → 电脑：签了名的批准或拒绝。
    case approvalDecision
    /// 手机 → 电脑：普通操作的能力令牌。
    case capability
    /// 手机 → 电脑：吊销能力令牌。
    case revocation
    case unknown(String)

    public static let knownCases: [DeviceMessageKind] = [
        .pairResponse, .pairConfirm, .approvalRequest, .approvalDecision, .capability, .revocation,
    ]

    public var rawValue: String {
        switch self {
        case .pairResponse: "pair_response"
        case .pairConfirm: "pair_confirm"
        case .approvalRequest: "approval_request"
        case .approvalDecision: "approval_decision"
        case .capability: "capability"
        case .revocation: "revocation"
        case .unknown(let raw): raw
        }
    }

    /// 由电脑发给手机（否则由手机发给电脑）。和服务端的 `from_computer` 一致；不认识的种类按 false 算。
    public var isFromComputer: Bool {
        switch self {
        case .pairConfirm, .approvalRequest: true
        default: false
        }
    }
}

/// 给自己的手机号发验证码的用途（`sendSelfCode`）。是客户端发出去的参数，所以不需要 `unknown`。
public enum SelfCodePurpose: String, Sendable, Hashable, Codable, CaseIterable {
    /// 注销账号（16.4）：验证码交给 `deleteAccount`。
    case deleteAccount = "delete_account"
    /// 换手机号。
    case changePhone = "change_phone"
}

/// 举报 agent 输出的原因（5.5，`reportContent`）。服务端加了新原因时旧版本 App 显示成“其他”。
public enum ReportReason: OpenStringEnum {
    /// 危害人身安全、教唆违法犯罪。
    case harmful
    /// 违法违规的内容。
    case illegal
    /// 色情低俗。
    case sexual
    /// 歧视、仇恨、侮辱。
    case hateful
    /// 泄露个人信息、侵犯隐私。
    case privacy
    /// 虚假信息。
    case misinformation
    /// 侵犯知识产权。
    case infringement
    case other
    case unknown(String)

    public static let knownCases: [ReportReason] = [
        .harmful, .illegal, .sexual, .hateful, .privacy, .misinformation, .infringement, .other,
    ]

    public var rawValue: String {
        switch self {
        case .harmful: "harmful"
        case .illegal: "illegal"
        case .sexual: "sexual"
        case .hateful: "hateful"
        case .privacy: "privacy"
        case .misinformation: "misinformation"
        case .infringement: "infringement"
        case .other: "other"
        case .unknown(let raw): raw
        }
    }
}

/// 举报的处理状态（5.5）。
public enum ReportState: OpenStringEnum {
    /// 待处理。
    case open
    /// 已处理（结果在 `ContentReport.resolution`，也发到收件箱和推送）。
    case closed
    case unknown(String)

    public static let knownCases: [ReportState] = [.open, .closed]

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .closed: "closed"
        case .unknown(let raw): raw
        }
    }
}

/// 收件箱条目的种类（和推送的 `tt.kind` 一样，docs/push.md 第 2 节）。以后可能加新的，不认识的按 `info` 显示。
public enum InboxKind: OpenStringEnum {
    case runFinished, runFailed, approval
    /// 电脑上的高危操作请手机批准（12.9）。
    case computerApproval
    /// agent 请用户往保险箱里填账号密码，运行等着（10.7，带 `vaultRequestID`）。
    case vaultRequest
    /// agent 建了或改了计划，等用户确认（10.7，带 `planID`）。
    case planConfirm
    case info
    case unknown(String)

    public static let knownCases: [InboxKind] = [
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

/// agent 请用户填账号密码的请求（9.11）。过了期限还没处理的读出来是 `expired`。
public enum VaultRequestStatus: OpenStringEnum {
    case pending, fulfilled, declined, expired
    case unknown(String)

    public static let knownCases: [VaultRequestStatus] = [.pending, .fulfilled, .declined, .expired]

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .fulfilled: "fulfilled"
        case .declined: "declined"
        case .expired: "expired"
        case .unknown(let raw): raw
        }
    }

    public var isResolved: Bool { self != .pending }
}

/// 保险箱表单要填的字段。
public enum VaultField: OpenStringEnum {
    case username, password
    case unknown(String)

    public static let knownCases: [VaultField] = [.username, .password]

    public var rawValue: String {
        switch self {
        case .username: "username"
        case .password: "password"
        case .unknown(let raw): raw
        }
    }
}

/// 消息里认出来的密码、key 的种类（11.6）。
public enum SecretKind: OpenStringEnum {
    case privateKey, urlPassword, apiKey, token, labeled, highEntropy
    case unknown(String)

    public static let knownCases: [SecretKind] = [.privateKey, .urlPassword, .apiKey, .token, .labeled, .highEntropy]

    public var rawValue: String {
        switch self {
        case .privateKey: "private_key"
        case .urlPassword: "url_password"
        case .apiKey: "api_key"
        case .token: "token"
        case .labeled: "labeled"
        case .highEntropy: "high_entropy"
        case .unknown(let raw): raw
        }
    }
}

/// IM 渠道（10.5）：群机器人所在的平台。
public enum ImVendor: OpenStringEnum {
    case feishu, lark, wecom, dingtalk
    case unknown(String)

    public static let knownCases: [ImVendor] = [.feishu, .lark, .wecom, .dingtalk]

    public var rawValue: String {
        switch self {
        case .feishu: "feishu"
        case .lark: "lark"
        case .wecom: "wecom"
        case .dingtalk: "dingtalk"
        case .unknown(let raw): raw
        }
    }
}

/// 发到 IM 群里的事件（10.5）。
public enum ImEvent: OpenStringEnum {
    case runFinished, runFailed, approval
    case unknown(String)

    public static let knownCases: [ImEvent] = [.runFinished, .runFailed, .approval]

    public var rawValue: String {
        switch self {
        case .runFinished: "run_finished"
        case .runFailed: "run_failed"
        case .approval: "approval"
        case .unknown(let raw): raw
        }
    }
}

/// 工具调用的状态（同 ACP 的 `ToolCallStatus`）。
public enum ToolCallStatus: OpenStringEnum {
    case pending, inProgress, completed, failed
    case unknown(String)

    public static let knownCases: [ToolCallStatus] = [.pending, .inProgress, .completed, .failed]

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown(let raw): raw
        }
    }

    public var isFinished: Bool { self == .completed || self == .failed }
}

/// 一轮任务结束的原因（同 ACP 的 `StopReason`）。
public enum StopReason: OpenStringEnum {
    case endTurn, maxTokens, maxTurnRequests, refusal, cancelled
    case unknown(String)

    public static let knownCases: [StopReason] = [.endTurn, .maxTokens, .maxTurnRequests, .refusal, .cancelled]

    public var rawValue: String {
        switch self {
        case .endTurn: "end_turn"
        case .maxTokens: "max_tokens"
        case .maxTurnRequests: "max_turn_requests"
        case .refusal: "refusal"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }
}

/// 服务端的错误码（`ClientError.api` 的 `code`，见 crates/proto/src/api.rs 的 `ErrorCode`）。
public enum APIErrorCode: OpenStringEnum {
    /// 没登录或访问令牌过期（client-core 会自己刷新，一般到不了界面）。
    case unauthenticated
    /// 刷新令牌失效：回到登录页。
    case sessionRevoked
    case accountFrozen
    case forbidden
    case notFound
    /// 和现有状态冲突（重复创建、并发修改、运行已结束）。
    case conflict
    /// 请求不合法：参数、取值、状态迁移。
    case invalid
    /// 限流或额度用完：按 `retry_after_secs` 退避。
    case rateLimited
    case upgradeRequired
    /// 暂时不可用：退避重试。
    case unavailable
    case `internal`
    case unknown(String)

    public static let knownCases: [APIErrorCode] = [
        .unauthenticated, .sessionRevoked, .accountFrozen, .forbidden, .notFound, .conflict, .invalid,
        .rateLimited, .upgradeRequired, .unavailable, .internal,
    ]

    public var rawValue: String {
        switch self {
        case .unauthenticated: "unauthenticated"
        case .sessionRevoked: "session_revoked"
        case .accountFrozen: "account_frozen"
        case .forbidden: "forbidden"
        case .notFound: "not_found"
        case .conflict: "conflict"
        case .invalid: "invalid"
        case .rateLimited: "rate_limited"
        case .upgradeRequired: "upgrade_required"
        case .unavailable: "unavailable"
        case .internal: "internal"
        case .unknown(let raw): raw
        }
    }
}

/// 用量的分组方式（`usage(group:)`）。是客户端发出去的参数，所以不需要 `unknown`。
public enum UsageGroup: String, Sendable, Hashable, Codable, CaseIterable {
    case day, instance, model, credential
}

/// 运行在等什么（11.8，`Run.waitCode`、`run.state` 事件的 `wait_code`）：只在等 key（`waitingQuota`）、
/// 等电脑（`waitingDevice`）时有。界面据此决定显示“去换 key”还是“稍后自动继续”，不用去解析 `stateReason`
/// （那是给人看的一句话）。服务端以后可能加新值，不认识的（`unknown`）按运行状态显示。
public enum RunWaitCode: OpenStringEnum {
    /// key 无效或没有权限：去换 key。
    case invalid
    /// 欠费、额度用完：去充值或换 key（每小时也自己再试一次）。
    case noBalance
    /// 没有能用的 key（都停用了、当天额度用完、解不开）：去处理 key（每小时也自己再试一次）。
    case unavailable
    /// 被限流：几分钟后自己继续，不用处理。
    case rateLimited
    /// 模型服务繁忙或连不上：几分钟后自己继续，不用处理。
    case overloaded
    /// 等用户的电脑上线。
    case deviceOffline
    case unknown(String)

    public static let knownCases: [RunWaitCode] = [
        .invalid, .noBalance, .unavailable, .rateLimited, .overloaded, .deviceOffline,
    ]

    public var rawValue: String {
        switch self {
        case .invalid: "invalid"
        case .noBalance: "no_balance"
        case .unavailable: "unavailable"
        case .rateLimited: "rate_limited"
        case .overloaded: "overloaded"
        case .deviceOffline: "device_offline"
        case .unknown(let raw): raw
        }
    }

    /// 要用户去模型 key 页处理（换 key、充值、启用别的 key）：界面给“去处理”的入口。
    public var needsKeyAction: Bool {
        switch self {
        case .invalid, .noBalance, .unavailable: true
        default: false
        }
    }

    /// 过几分钟自己继续，不用处理：界面只说“稍后自动继续”。
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded: true
        default: false
        }
    }
}

/// 模型接口的协议（11.8）：agent 能说哪几种（`AgentInfo.protocols`）、运行时用哪种（`AgentInfo.activeProtocol`），
/// 厂商和 key 提供哪几种（`VendorInfo.protocols`、`Credential.protocols`）。模型网关不在协议之间转换，所以实例配的
/// 每把 key（包括降级的）都要支持 agent 的 `activeProtocol`。
public enum ModelProtocol: OpenStringEnum {
    /// Anthropic Messages。
    case anthropic
    /// OpenAI Chat Completions（大多数国内厂商走这个）。
    case chat
    /// OpenAI Responses（Codex 只会这个）。
    case responses
    case unknown(String)

    /// 顺序就是界面上显示的顺序（和服务端的 `proto::vendors::PROTOCOLS` 一致）。
    public static let knownCases: [ModelProtocol] = [.anthropic, .chat, .responses]

    public var rawValue: String {
        switch self {
        case .anthropic: "anthropic"
        case .chat: "chat"
        case .responses: "responses"
        case .unknown(let raw): raw
        }
    }
}
