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

enum class InboxKind(override val wire: String) : WireEnum {
    RunFinished("run_finished"),
    RunFailed("run_failed"),
    Approval("approval"),
    ComputerApproval("computer_approval"),
    Info("info"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String): InboxKind = parseWire(value, Unknown)
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
