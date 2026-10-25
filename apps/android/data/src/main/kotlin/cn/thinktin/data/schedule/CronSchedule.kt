package cn.thinktin.data.schedule

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * cron 的一段（分、时、日、月、周）。`*`、`?` 是 [Any]；`*／n` 是 [Step]；其余（数字、名字、范围、带步长的范围、逗号列表）
 * 展开成 [Values]（升序去重）。和 iOS 的 `CronField` 一致。
 */
sealed interface CronField {
    data object Any : CronField

    /** `*／n`（n ≥ 2）。 */
    data class Step(val n: Int) : CronField

    data class Values(val values: List<Int>) : CronField

    /** 展开成具体的取值（升序）。 */
    fun expanded(range: IntRange): List<Int> = when (this) {
        Any -> range.toList()
        is Step -> (range step n).toList()
        is Values -> values
    }

    /** 周几里的 7 换成 0（都是周日）。 */
    fun normalizingSunday(): CronField =
        if (this is Values) Values(values.map { if (it == 7) 0 else it }.toSortedSet().toList()) else this

    companion object {
        val WEEKDAY_NAMES: Map<String, Int> = mapOf(
            "SUN" to 0, "MON" to 1, "TUE" to 2, "WED" to 3, "THU" to 4, "FRI" to 5, "SAT" to 6,
        )
        val MONTH_NAMES: Map<String, Int> = mapOf(
            "JAN" to 1, "FEB" to 2, "MAR" to 3, "APR" to 4, "MAY" to 5, "JUN" to 6,
            "JUL" to 7, "AUG" to 8, "SEP" to 9, "OCT" to 10, "NOV" to 11, "DEC" to 12,
        )

        /** 解析一段；格式不对、超出 [range] 返回 null。 */
        fun parse(raw: String, range: IntRange, names: Map<String, Int> = emptyMap()): CronField? {
            if (raw == "*" || raw == "?") return Any
            if (raw.startsWith("*/")) {
                val n = raw.substring(2).toIntOrNull() ?: return null
                if (n <= 0) return null
                return if (n == 1) Any else Step(n)
            }
            fun value(s: String): Int? = s.toIntOrNull() ?: names[s.uppercase()]
            val out = sortedSetOf<Int>()
            for (item in raw.split(',')) {
                val stepParts = item.split('/', limit = 2)
                val step = if (stepParts.size == 2) stepParts[1].toIntOrNull() ?: return null else 1
                if (step <= 0) return null
                val bounds = stepParts[0].split('-', limit = 2)
                val lo: Int
                val hi: Int
                when {
                    bounds.size == 2 -> {
                        lo = value(bounds[0]) ?: return null
                        hi = value(bounds[1]) ?: return null
                        if (lo > hi) return null
                    }
                    stepParts[0] == "*" -> {
                        lo = range.first
                        hi = range.last
                    }
                    else -> {
                        lo = value(bounds[0]) ?: return null
                        hi = if (stepParts.size == 2) range.last else lo
                    }
                }
                if (lo !in range || hi !in range) return null
                out.addAll((lo..hi step step).toList())
            }
            if (out.isEmpty()) return null
            return Values(out.toList())
        }
    }
}

/**
 * 五段 cron（分 时 日 月 周）的触发计算，croner 的语义（服务端 crates/orchestrator/src/schedule.rs）：按规则的时区；
 * “日”和“周”都不是 `*`（或 `?`）时两者满足一个就算；夏令时跳过的那段里的固定时刻，在跳过之后的第一刻触发；
 * `L`、`W`、`#`、`@daily` 这类写法算不了（[parse] 返回 null）。
 */
class CronSchedule private constructor(
    val minutes: List<Int>,
    val hours: List<Int>,
    val days: Set<Int>,
    val months: Set<Int>,
    /** 周几：0 是周日（7 也换成 0）。 */
    val weekdays: Set<Int>,
    val dayIsStar: Boolean,
    val weekdayIsStar: Boolean,
    val zone: ZoneId,
) {
    /** 一天里只有一个时刻（夏令时跳过时挪到跳过之后，不丢）。 */
    val isFixedTime: Boolean get() = minutes.size == 1 && hours.size == 1

    /** 这一天符不符合“日”“月”“周”三段。[weekday] 0 是周日。 */
    fun matches(month: Int, day: Int, weekday: Int): Boolean {
        if (month !in months) return false
        val dayMatches = day in days
        val weekdayMatches = weekday in weekdays
        return when {
            dayIsStar && weekdayIsStar -> true
            weekdayIsStar -> dayMatches
            dayIsStar -> weekdayMatches
            else -> dayMatches || weekdayMatches
        }
    }

    /** 严格晚于 [after] 的下一次触发；找不到（规则永远不会触发）为 null。 */
    fun next(after: Instant): Instant? {
        var day: LocalDate = after.atZone(zone).toLocalDate()
        var checked = 0
        while (checked < SEARCH_DAYS) {
            checked++
            if (day.monthValue !in months) {
                // 这个月整个不符合：直接跳到下个月 1 日。
                day = day.withDayOfMonth(1).plusMonths(1)
                continue
            }
            if (matches(day.monthValue, day.dayOfMonth, day.dayOfWeek.value % 7)) {
                for (hour in hours) {
                    for (minute in minutes) {
                        val t = ScheduleForecast.localInstant(day, hour, minute, 0, zone, fixedTime = isFixedTime) ?: continue
                        if (t > after) return t
                    }
                }
            }
            day = day.plusDays(1)
        }
        return null
    }

    companion object {
        /** 最多往后找几天：够覆盖“每年 2 月 29 日”。 */
        const val SEARCH_DAYS = 366 * 8

        /** 解析；时区认不出、格式不对、写法算不了时返回 null。 */
        fun parse(expression: String, timeZone: String): CronSchedule? {
            val zone = ScheduleForecast.zone(timeZone) ?: return null
            val parts = expression.trim().split(Regex("\\s+"))
            if (parts.size != 5) return null
            val minute = CronField.parse(parts[0], 0..59) ?: return null
            val hour = CronField.parse(parts[1], 0..23) ?: return null
            val day = CronField.parse(parts[2], 1..31) ?: return null
            val month = CronField.parse(parts[3], 1..12, CronField.MONTH_NAMES) ?: return null
            val weekday = CronField.parse(parts[4], 0..7, CronField.WEEKDAY_NAMES) ?: return null
            return CronSchedule(
                minutes = minute.expanded(0..59),
                hours = hour.expanded(0..23),
                days = day.expanded(1..31).toSet(),
                months = month.expanded(1..12).toSet(),
                weekdays = weekday.expanded(0..7).map { if (it == 7) 0 else it }.toSet(),
                dayIsStar = parts[2] == "*" || parts[2] == "?",
                weekdayIsStar = parts[4] == "*" || parts[4] == "?",
                zone = zone,
            )
        }
    }
}
