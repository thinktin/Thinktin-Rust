package cn.thinktin.data.model

/**
 * 服务端的状态都是字符串（docs/android-design.md 第 8.1 节）。App 里用枚举，
 * 不认识的取值（服务端新加的）一律映射成 Unknown，界面按“未知”显示，不崩。
 */
interface WireEnum {
    /** 服务端的字符串取值；Unknown 为空串。 */
    val wire: String
}

internal inline fun <reified E> parseWire(value: String, unknown: E): E
    where E : Enum<E>, E : WireEnum =
    enumValues<E>().firstOrNull { it.wire.isNotEmpty() && it.wire == value } ?: unknown

enum class InstanceState(override val wire: String) : WireEnum {
    Provisioning("provisioning"),
    Running("running"),
    Paused("paused"),
    Archived("archived"),
    Deleted("deleted"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): InstanceState = parseWire(value, Unknown)
    }
}

enum class RunState(override val wire: String) : WireEnum {
    Queued("queued"),
    Starting("starting"),
    Running("running"),
    WaitingApproval("waiting_approval"),
    WaitingDevice("waiting_device"),
    WaitingQuota("waiting_quota"),
    WaitingChildren("waiting_children"),
    Backoff("backoff"),
    Succeeded("succeeded"),
    Failed("failed"),
    Cancelled("cancelled"),
    Unknown(""),
    ;

    /** 已经结束，不会再变。 */
    val isTerminal: Boolean get() = this == Succeeded || this == Failed || this == Cancelled

    /** 等用户处理（审批、电脑、key）：界面显示警告色横幅。 */
    val needsAttention: Boolean
        get() = this == WaitingApproval || this == WaitingDevice || this == WaitingQuota

    /** 还在进行（含排队、等待），可以停止。 */
    val isActive: Boolean get() = !isTerminal && this != Unknown

    companion object {
        fun fromWire(value: String): RunState = parseWire(value, Unknown)
    }
}

enum class RunSource(override val wire: String) : WireEnum {
    User("user"),
    Plan("plan"),
    Pipeline("pipeline"),
    Delegate("delegate"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): RunSource = parseWire(value, Unknown)
    }
}

enum class RunKind(override val wire: String) : WireEnum {
    Agent("agent"),
    Pipeline("pipeline"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): RunKind = parseWire(value, Unknown)
    }
}

/** 收件箱条目的种类。服务端以后可能加新的：不认识的按 [Info] 显示（client-core 的约定），所以没有 Unknown。 */
enum class InboxKind(override val wire: String) : WireEnum {
    RunFinished("run_finished"),
    RunFailed("run_failed"),
    Approval("approval"),
    ComputerApproval("computer_approval"),
    VaultRequest("vault_request"),
    PlanConfirm("plan_confirm"),
    Info("info"),
    ;

    companion object {
        fun fromWire(value: String): InboxKind = parseWire(value, Info)
    }
}

enum class ApprovalState(override val wire: String) : WireEnum {
    Pending("pending"),
    Approved("approved"),
    Rejected("rejected"),
    Expired("expired"),
    Cancelled("cancelled"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): ApprovalState = parseWire(value, Unknown)
    }
}

enum class OptionKind(override val wire: String) : WireEnum {
    AllowOnce("allow_once"),
    AllowAlways("allow_always"),
    RejectOnce("reject_once"),
    RejectAlways("reject_always"),
    Unknown(""),
    ;

    val isAllow: Boolean get() = this == AllowOnce || this == AllowAlways

    companion object {
        fun fromWire(value: String): OptionKind = parseWire(value, Unknown)
    }
}

enum class VaultRequestStatus(override val wire: String) : WireEnum {
    Pending("pending"),
    Fulfilled("fulfilled"),
    Declined("declined"),
    Expired("expired"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): VaultRequestStatus = parseWire(value, Unknown)
    }
}

enum class DevicePlatform(override val wire: String) : WireEnum {
    Ios("ios"),
    Android("android"),
    Macos("macos"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): DevicePlatform = parseWire(value, Unknown)
    }
}

enum class TeamRole(override val wire: String) : WireEnum {
    Lead("lead"),
    Member("member"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): TeamRole = parseWire(value, Unknown)
    }
}

/** 计划错过的触发怎么补（4.4）。 */
enum class CatchUp(override val wire: String) : WireEnum {
    /** 错过的只补一次（默认）。 */
    Once("once"),
    All("all"),
    Skip("skip"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): CatchUp = parseWire(value, Unknown)
    }
}

/** 审批（和等电脑、等 key）超时以后怎么办（4.7）。 */
enum class ApprovalTimeoutAction(override val wire: String) : WireEnum {
    /** 拒绝这一步，让 agent 继续。 */
    Skip("skip"),

    /** 暂停整个计划（默认）。 */
    PausePlan("pause_plan"),

    /** 这次运行失败。 */
    Fail("fail"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): ApprovalTimeoutAction = parseWire(value, Unknown)
    }
}

/** 举报原因（5.5）。 */
enum class ReportReason(override val wire: String) : WireEnum {
    Harmful("harmful"),
    Illegal("illegal"),
    Sexual("sexual"),
    Hateful("hateful"),
    Privacy("privacy"),
    Misinformation("misinformation"),
    Infringement("infringement"),
    Other("other"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): ReportReason = parseWire(value, Unknown)
    }
}

/** 举报的处理状态。 */
enum class ReportState(override val wire: String) : WireEnum {
    Open("open"),
    Closed("closed"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): ReportState = parseWire(value, Unknown)
    }
}

/** 给自己手机号发验证码的用途（sendSelfCode）。 */
enum class SelfCodePurpose(override val wire: String) : WireEnum {
    /** 注销账号（16.4）。 */
    DeleteAccount("delete_account"),
    ChangePhone("change_phone"),
}

/** 手机和电脑之间的消息种类（14.1）。 */
enum class DeviceMessageKind(override val wire: String) : WireEnum {
    /** 手机 → 电脑：扫码后的配对应答。 */
    PairResponse("pair_response"),

    /** 电脑 → 手机：确认配对。 */
    PairConfirm("pair_confirm"),

    /** 电脑 → 手机：高危操作，请手机签名批准。 */
    ApprovalRequest("approval_request"),

    /** 手机 → 电脑：签了名的批准或拒绝。 */
    ApprovalDecision("approval_decision"),

    /** 手机 → 电脑：普通操作的能力令牌。 */
    Capability("capability"),

    /** 手机 → 电脑：吊销能力令牌。 */
    Revocation("revocation"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): DeviceMessageKind = parseWire(value, Unknown)
    }
}

/**
 * 运行在等什么（[Run.waitCode]，11.8）：只在 waiting_quota / waiting_device 时有。界面按码映射文案；
 * 不认识的（服务端以后加的）是 Unknown，按 [RunState] 显示。
 */
enum class WaitCode(override val wire: String) : WireEnum {
    /** key 无效：去换 key。 */
    Invalid("invalid"),

    /** 欠费：充值或换 key（每小时也自己再试）。 */
    NoBalance("no_balance"),

    /** 没有能用的 key（停用了或当天额度用完；每小时也自己再试）。 */
    Unavailable("unavailable"),

    /** 限流：几分钟后自己继续，不用处理。 */
    RateLimited("rate_limited"),

    /** 上游过载：几分钟后自己继续，不用处理。 */
    Overloaded("overloaded"),

    /** 等电脑上线。 */
    DeviceOffline("device_offline"),
    Unknown(""),
    ;

    /** 要用户处理（换 key、充值、开电脑）；限流和过载会自己继续。 */
    val needsUserAction: Boolean get() = this != RateLimited && this != Overloaded && this != Unknown

    companion object {
        fun fromWire(value: String): WaitCode = parseWire(value, Unknown)
    }
}

/** 触发器被后台停用的原因（[Trigger.disabledReason]，11.8）。 */
enum class TriggerDisabledReason(override val wire: String) : WireEnum {
    /** 规则失效了（比如时区没了）：删掉重新加。 */
    InvalidRule("invalid_rule"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): TriggerDisabledReason = parseWire(value, Unknown)
    }
}
