package cn.thinktin.data.schedule

import cn.thinktin.data.model.Schedule
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * 在本地预先算触发规则接下来几次的触发时间（13.6，和 iOS 的 `ScheduleForecast` 一致）。触发器编辑器的“接下来几次”、
 * “太频繁”“不会再触发”的本地检查用它；App 算不了的写法（[canForecast] 为假）只描述、不预测，保存时由服务端检查。
 * 只是预览：实际触发以服务端算的为准，削峰还会再晚几分钟。
 */
object ScheduleForecast {
    /** 服务端默认允许的最小触发间隔（crates/gateway 的 `min_trigger_interval`，5 分钟）。 */
    const val MIN_INTERVAL_MS: Long = 5 * 60 * 1000L

    /** 严格晚于 [afterMs] 的前 [count] 次触发（Unix 毫秒）；算不了这种写法时为 null，再也不会触发时是空列表。 */
    fun nextFires(schedule: Schedule, afterMs: Long, count: Int): List<Long>? {
        if (count <= 0) return emptyList()
        val after = Instant.ofEpochMilli(afterMs)
        return when (schedule) {
            is Schedule.Once -> if (schedule.atMs > afterMs) listOf(schedule.atMs) else emptyList()
            is Schedule.Cron -> {
                val cron = CronSchedule.parse(schedule.expr, schedule.tz) ?: return null
                val out = mutableListOf<Long>()
                var cursor = after
                while (out.size < count) {
                    val next = cron.next(cursor) ?: break
                    out += next.toEpochMilli()
                    cursor = next
                }
                out
            }
            is Schedule.Rrule -> RecurrenceRule.parse(schedule.rule)?.occurrences(after, count)?.map { it.toEpochMilli() }
        }
    }

    /** 能不能在本地预测这条规则。 */
    fun canForecast(schedule: Schedule): Boolean = when (schedule) {
        is Schedule.Once -> true
        is Schedule.Cron -> CronSchedule.parse(schedule.expr, schedule.tz) != null
        is Schedule.Rrule -> RecurrenceRule.parse(schedule.rule) != null
    }

    /**
     * 从 [afterMs] 起前 [samples] 次触发里相邻两次的最小间隔（毫秒；服务端按同样的办法看前 50 次）。
     * 一次性的、算不了的、不到两次的为 null。
     */
    fun minimumGapMs(schedule: Schedule, afterMs: Long, samples: Int = 50): Long? {
        if (schedule is Schedule.Once) return null
        val fires = nextFires(schedule, afterMs, samples) ?: return null
        if (fires.size < 2) return null
        return fires.zipWithNext { a, b -> b - a }.min()
    }

    /** IANA 时区名（服务端的 chrono-tz 只认这些）；认不出为 null。 */
    fun zone(id: String): ZoneId? {
        if (id.isBlank()) return null
        if (id == "UTC" || id == "Etc/UTC") return ZoneOffset.UTC
        return if (id in ZoneId.getAvailableZoneIds()) ZoneId.of(id) else null
    }

    /**
     * 本地时间转成时刻。这一刻不存在（夏令时跳过的那段）时：[fixedTime] 的取跳过之后的第一刻（croner 的做法），
     * 否则跳过（null）。重复的那段（夏令时结束）取较早的那一次。
     */
    fun localInstant(day: LocalDate, hour: Int, minute: Int, second: Int, zone: ZoneId, fixedTime: Boolean): Instant? {
        val local = LocalDateTime.of(day, LocalTime.of(hour, minute, second))
        val rules = zone.rules
        val offsets = rules.getValidOffsets(local)
        return when {
            offsets.isNotEmpty() -> local.toInstant(offsets[0])
            fixedTime -> rules.getTransition(local)?.instant
            else -> null
        }
    }
}
