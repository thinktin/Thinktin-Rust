package cn.thinktin.app.ui.plans

import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.Trigger
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.UUID

/** 计划表单的上限（和服务端 crates/gateway/src/routes/plans.rs 一致）。 */
object PlanLimits {
    const val MAX_TITLE = 100
    const val MAX_GOAL = 8000
    const val MAX_TRIGGERS = 10

    /** 审批、等待的超时：60 秒到 7 天。 */
    const val MIN_TIMEOUT_SECS = 60L
    const val MAX_TIMEOUT_SECS = 7 * 24 * 3600L

    /** 单次运行最长：1 秒到 24 小时。 */
    const val MAX_DURATION_SECS = 24 * 3600L
}

/** 标题、目标的问题（和服务端一样：去掉首尾空白后 1 到 N 个字符，按 Unicode 码点数）。 */
enum class TextProblem { Empty, TooLong }

object PlanText {
    fun length(text: String): Int = text.trim().let { it.codePointCount(0, it.length) }

    fun check(text: String, max: Int): TextProblem? {
        val n = length(text)
        return when {
            n == 0 -> TextProblem.Empty
            n > max -> TextProblem.TooLong
            else -> null
        }
    }
}

/** 策略表单的问题。 */
enum class PolicyProblem {
    ApprovalTimeout,
    WaitTimeout,
    MaxDuration,
    MaxTokens,
    MaxSteps,
    DailyTokenLimit,
}

/** ACP 的工具种类（预授权的可选项；`other` 不让预授权）。 */
val PREAUTHORIZABLE_TOOLS = listOf("read", "search", "fetch", "edit", "move", "delete", "execute", "think")

/**
 * 编辑中的计划策略（4.4、4.7）：时长按小时填（可以带小数），上限留空是不限。没动过的字段保留原来的秒数
 * （原来不是整小时的不会被四舍五入改掉）。
 */
data class PlanPolicyDraft(
    val original: PlanPolicy = PlanPolicy(),
    val approvalTimeoutHours: String = hours(original.approvalTimeoutSecs),
    val onApprovalTimeout: ApprovalTimeoutAction = original.onApprovalTimeout,
    val waitTimeoutHours: String = hours(original.waitTimeoutSecs),
    val maxDurationHours: String = hours(original.maxDurationSecs),
    val maxTokens: String = original.maxTokens?.toString().orEmpty(),
    val maxSteps: String = original.maxSteps?.toString().orEmpty(),
    val dailyTokenLimit: String = original.dailyTokenLimit?.toString().orEmpty(),
    val preauthorizedTools: Set<String> = original.preauthorizedTools.toSet(),
) {
    private fun secs(text: String, originalSecs: Long): Long? {
        if (text.trim() == hours(originalSecs)) return originalSecs
        val value = text.trim().toBigDecimalOrNull() ?: return null
        if (value.signum() <= 0) return null
        return value.multiply(BigDecimal(3600)).setScale(0, RoundingMode.HALF_UP).toLong()
    }

    /** 空的是不限（null）；填了要是正整数。返回 [Result.failure] 表示填得不对。 */
    private fun limit(text: String): Result<Long?> {
        val t = text.trim()
        if (t.isEmpty()) return Result.success(null)
        val n = t.toLongOrNull()?.takeIf { it > 0 } ?: return Result.failure(IllegalArgumentException(t))
        return Result.success(n)
    }

    val problems: List<PolicyProblem>
        get() = buildList {
            val approval = secs(approvalTimeoutHours, original.approvalTimeoutSecs)
            if (approval == null || approval !in PlanLimits.MIN_TIMEOUT_SECS..PlanLimits.MAX_TIMEOUT_SECS) {
                add(PolicyProblem.ApprovalTimeout)
            }
            val wait = secs(waitTimeoutHours, original.waitTimeoutSecs)
            if (wait == null || wait !in PlanLimits.MIN_TIMEOUT_SECS..PlanLimits.MAX_TIMEOUT_SECS) add(PolicyProblem.WaitTimeout)
            val duration = secs(maxDurationHours, original.maxDurationSecs)
            if (duration == null || duration !in 1..PlanLimits.MAX_DURATION_SECS) add(PolicyProblem.MaxDuration)
            if (limit(maxTokens).isFailure) add(PolicyProblem.MaxTokens)
            if (limit(maxSteps).let { it.isFailure || (it.getOrNull() ?: 0L) > Int.MAX_VALUE.toLong() }) add(PolicyProblem.MaxSteps)
            if (limit(dailyTokenLimit).isFailure) add(PolicyProblem.DailyTokenLimit)
        }

    /** 填好的策略；有问题时为 null。 */
    val policy: PlanPolicy?
        get() {
            if (problems.isNotEmpty()) return null
            return original.copy(
                preauthorizedTools = original.preauthorizedTools.filter { it in preauthorizedTools } +
                    preauthorizedTools.filter { it !in original.preauthorizedTools }.sorted(),
                approvalTimeoutSecs = secs(approvalTimeoutHours, original.approvalTimeoutSecs)!!,
                onApprovalTimeout = onApprovalTimeout,
                waitTimeoutSecs = secs(waitTimeoutHours, original.waitTimeoutSecs)!!,
                maxDurationSecs = secs(maxDurationHours, original.maxDurationSecs)!!,
                maxTokens = limit(maxTokens).getOrNull(),
                maxSteps = limit(maxSteps).getOrNull()?.toInt(),
                dailyTokenLimit = limit(dailyTokenLimit).getOrNull(),
            )
        }

    companion object {
        /** 秒数显示成小时（整小时不带小数，其余最多两位小数）。 */
        fun hours(secs: Long): String =
            BigDecimal(secs).divide(BigDecimal(3600), 2, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
    }
}

/** 编辑器里的一条触发规则：已有的（带服务端的 id、下一次 / 上一次触发）或新加的。 */
data class TriggerItem(
    val id: String,
    /** 已有的触发器；新加的为 null。 */
    val trigger: Trigger?,
    val schedule: Schedule,
) {
    val isNew: Boolean get() = trigger == null

    companion object {
        fun existing(trigger: Trigger) = TriggerItem(trigger.id, trigger, trigger.schedule)
        fun new(schedule: Schedule) = TriggerItem("new-" + UUID.randomUUID(), null, schedule)
    }
}
