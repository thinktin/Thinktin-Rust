package cn.thinktin.data.schedule

import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/**
 * RRULE 的触发计算（RFC 5545 的一个子集，和 iOS 的 `RecurrenceRule` 一致；服务端用 rrule crate）：FREQ 是 YEARLY、MONTHLY、
 * WEEKLY、DAILY、HOURLY，带 INTERVAL、COUNT、UNTIL、BYMONTH、BYMONTHDAY、BYDAY（MONTHLY、YEARLY 里可以带序号，比如 `1MO`、
 * `-1FR`）、BYHOUR、BYMINUTE、WKST；DTSTART 本身不符合规则时不算一次。BYSETPOS、BYWEEKNO、BYYEARDAY、BYSECOND、EXDATE、
 * EXRULE 算不了（[parse] 返回 null）。
 */
class RecurrenceRule private constructor(
    val frequency: Frequency,
    val interval: Int,
    val count: Int?,
    val until: Instant?,
    val byMonth: List<Int>?,
    val byMonthDay: List<Int>?,
    val byDay: List<WeekdayRule>?,
    val byHour: List<Int>?,
    val byMinute: List<Int>?,
    /** 一周从周几开始（WKST，默认周一；0 是周日）。 */
    val weekStart: Int,
    val start: Instant,
    val zone: ZoneId,
) {
    enum class Frequency { YEARLY, MONTHLY, WEEKLY, DAILY, HOURLY }

    /** BYDAY 的一项：周几（0 是周日）和可选的序号。 */
    data class WeekdayRule(val weekday: Int, val ordinal: Int?)

    /** 最多往后数多少个周期（十年上下），免得永远不会触发的规则算太久。 */
    private val maxPeriods: Int
        get() = when (frequency) {
            Frequency.YEARLY -> 30
            Frequency.MONTHLY -> 360
            Frequency.WEEKLY -> 1600
            Frequency.DAILY -> 3700
            Frequency.HOURLY -> 24 * 370
        }

    /** 严格晚于 [after] 的前 [limit] 次触发。 */
    fun occurrences(after: Instant, limit: Int): List<Instant> {
        if (limit <= 0) return emptyList()
        val s = start.atZone(zone)
        val second = s.second
        val hours = (byHour ?: listOf(s.hour)).sorted()
        val minutes = (byMinute ?: listOf(s.minute)).sorted()
        val fixedTime = hours.size == 1 && minutes.size == 1
        val startDay = s.toLocalDate()
        val startWeekday = s.dayOfWeek.value % 7

        val out = mutableListOf<Instant>()
        var produced = 0

        /** 收下一个候选；返回 false 时停止（COUNT 用完、过了 UNTIL、收够了）。 */
        fun take(t: Instant): Boolean {
            if (t < start) return true
            if (until != null && t > until) return false
            produced++
            if (t > after) out += t
            if (out.size >= limit) return false
            if (count != null && produced >= count) return false
            return true
        }

        /** 一天里的各个时刻（BYHOUR × BYMINUTE，默认 DTSTART 的时分）。 */
        fun emit(day: LocalDate): Boolean {
            for (hour in hours) {
                for (minute in minutes) {
                    val t = ScheduleForecast.localInstant(day, hour, minute, second, zone, fixedTime) ?: continue
                    if (!take(t)) return false
                }
            }
            return true
        }

        fun passes(day: LocalDate): Boolean {
            if (byMonth != null && day.monthValue !in byMonth) return false
            if (byMonthDay != null && byMonthDay.none { resolve(it, day.lengthOfMonth()) == day.dayOfMonth }) return false
            if (byDay != null && byDay.none { it.weekday == day.dayOfWeek.value % 7 }) return false
            return true
        }

        when (frequency) {
            Frequency.DAILY, Frequency.WEEKLY -> {
                var periodStart = startDay
                if (frequency == Frequency.WEEKLY) {
                    val back = (startWeekday - weekStart + 7) % 7
                    periodStart = startDay.minusDays(back.toLong())
                }
                val weekdays = byDay?.map { it.weekday } ?: listOf(startWeekday)
                val step = if (frequency == Frequency.DAILY) interval else 7 * interval
                val span = if (frequency == Frequency.DAILY) 1 else 7
                for (k in 0 until maxPeriods) {
                    val first = periodStart.plusDays(k.toLong() * step)
                    for (offset in 0 until span) {
                        val day = first.plusDays(offset.toLong())
                        if (frequency == Frequency.WEEKLY && day.dayOfWeek.value % 7 !in weekdays) continue
                        if (!passes(day)) continue
                        if (!emit(day)) return out
                    }
                }
            }
            Frequency.MONTHLY, Frequency.YEARLY -> {
                for (k in 0 until maxPeriods) {
                    val months: List<Pair<Int, Int>> = if (frequency == Frequency.MONTHLY) {
                        val total = s.year * 12 + (s.monthValue - 1) + k * interval
                        listOf(total / 12 to total % 12 + 1)
                    } else {
                        val year = s.year + k * interval
                        val list = byMonth ?: if (byMonthDay != null || byDay != null) (1..12).toList() else listOf(s.monthValue)
                        list.sorted().map { year to it }
                    }
                    for ((year, month) in months) {
                        if (byMonth != null && month !in byMonth) continue
                        for (day in days(year, month, s.dayOfMonth)) {
                            if (!emit(LocalDate.of(year, month, day))) return out
                        }
                    }
                }
            }
            Frequency.HOURLY -> {
                for (k in 0 until maxPeriods) {
                    val base = s.plusHours(k.toLong() * interval)
                    if (byHour != null && base.hour !in byHour) continue
                    val day = base.toLocalDate()
                    if (!passes(day)) continue
                    for (minute in minutes) {
                        val t = ScheduleForecast.localInstant(day, base.hour, minute, second, zone, fixedTime = false) ?: continue
                        if (!take(t)) return out
                    }
                }
            }
        }
        return out
    }

    /**
     * MONTHLY、YEARLY 的一个月里哪几天（升序）：BYMONTHDAY（负数从月底数）、BYDAY（带序号是第几个，不带是每个），
     * 两个都给时取交集；都没给是 DTSTART 那一天（这个月没有这一天就跳过）。
     */
    private fun days(year: Int, month: Int, defaultDay: Int): List<Int> {
        val first = LocalDate.of(year, month, 1)
        val length = first.lengthOfMonth()
        val firstWeekday = first.dayOfWeek.value % 7
        var candidates: Set<Int>? = byMonthDay?.mapNotNull { resolve(it, length) }?.toSet()
        if (byDay != null) {
            val set = mutableSetOf<Int>()
            for (rule in byDay) {
                val firstMatch = 1 + (rule.weekday - firstWeekday + 7) % 7
                val all = (firstMatch..length step 7).toList()
                val n = rule.ordinal
                if (n != null) {
                    val index = if (n > 0) n - 1 else all.size + n
                    if (index in all.indices) set += all[index]
                } else {
                    set += all
                }
            }
            candidates = candidates?.intersect(set) ?: set
        }
        if (candidates != null) return candidates.sorted()
        return if (defaultDay <= length) listOf(defaultDay) else emptyList()
    }

    /** BYMONTHDAY 的取值换成这个月的第几天（-1 是最后一天）；这个月没有这一天为 null。 */
    private fun resolve(value: Int, length: Int): Int? {
        val day = if (value > 0) value else length + 1 + value
        return if (day in 1..length) day else null
    }

    companion object {
        val WEEKDAY_CODES = listOf("SU", "MO", "TU", "WE", "TH", "FR", "SA")

        private val SUPPORTED = setOf(
            "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYMONTH", "BYMONTHDAY", "BYDAY", "BYHOUR", "BYMINUTE", "WKST",
        )

        /** 解析 DTSTART + RRULE 文本。算不了的写法、格式不对的都返回 null。 */
        fun parse(text: String): RecurrenceRule? {
            var startLine: String? = null
            var ruleLine: String? = null
            for (raw in text.lines()) {
                val line = raw.trim()
                if (line.isEmpty()) continue
                val upper = line.uppercase()
                when {
                    upper.startsWith("DTSTART") -> {
                        if (startLine != null) return null
                        startLine = line
                    }
                    upper.startsWith("RRULE:") -> {
                        if (ruleLine != null) return null
                        ruleLine = line.substring(6)
                    }
                    upper.startsWith("FREQ=") || (':' !in upper && "FREQ=" in upper) -> {
                        if (ruleLine != null) return null
                        ruleLine = line
                    }
                    // EXDATE、RDATE、EXRULE 之类：算不了。
                    else -> return null
                }
            }
            val (start, zone) = parseStart(startLine ?: return null) ?: return null
            val fields = mutableMapOf<String, String>()
            for (pair in (ruleLine ?: return null).split(';')) {
                if (pair.isEmpty()) continue
                val kv = pair.split('=', limit = 2).map { it.uppercase() }
                if (kv.size != 2 || kv[0] in fields) return null
                fields[kv[0]] = kv[1]
            }
            if (!SUPPORTED.containsAll(fields.keys)) return null
            val frequency = fields["FREQ"]?.let { f -> Frequency.entries.firstOrNull { it.name == f } } ?: return null

            var invalid = false
            fun ints(key: String, range: IntRange, allowNegative: Boolean = false): List<Int>? {
                val raw = fields[key] ?: return null
                val out = raw.split(',').map { item ->
                    val n = item.toIntOrNull()
                    if (n == null || !(n in range || (allowNegative && -n in range))) {
                        invalid = true
                        return null
                    }
                    n
                }
                if (out.isEmpty()) invalid = true
                return out
            }
            val interval = fields["INTERVAL"]?.let { it.toIntOrNull()?.takeIf { n -> n >= 1 } ?: return null } ?: 1
            val count = fields["COUNT"]?.let { it.toIntOrNull()?.takeIf { n -> n >= 1 } ?: return null }
            val until = fields["UNTIL"]?.let { parseDateTime(it, zone, endOfDayForDates = true) ?: return null }
            val byMonth = ints("BYMONTH", 1..12)
            val byMonthDay = ints("BYMONTHDAY", 1..31, allowNegative = true)
            val byHour = ints("BYHOUR", 0..23)
            val byMinute = ints("BYMINUTE", 0..59)
            if (invalid) return null
            val weekStart = fields["WKST"]?.let { WEEKDAY_CODES.indexOf(it).takeIf { i -> i >= 0 } ?: return null } ?: 1
            val byDay = fields["BYDAY"]?.let { raw ->
                raw.split(',').map { item ->
                    if (item.length < 2) return null
                    val weekday = WEEKDAY_CODES.indexOf(item.takeLast(2)).takeIf { it >= 0 } ?: return null
                    val prefix = item.dropLast(2)
                    if (prefix.isEmpty()) {
                        WeekdayRule(weekday, null)
                    } else {
                        val n = prefix.toIntOrNull() ?: return null
                        if (n == 0 || kotlin.math.abs(n) !in 1..53) return null
                        WeekdayRule(weekday, n)
                    }
                }
            }
            // 带序号的 BYDAY 只认 MONTHLY，以及带了 BYMONTH 的 YEARLY（按月里的第几个算）。
            if (byDay != null && byDay.any { it.ordinal != null }) {
                val ok = frequency == Frequency.MONTHLY || (frequency == Frequency.YEARLY && byMonth != null)
                if (!ok) return null
            }
            // WEEKLY 不能带 BYMONTHDAY（RFC 5545）。
            if (frequency == Frequency.WEEKLY && byMonthDay != null) return null
            return RecurrenceRule(
                frequency, interval, count, until, byMonth, byMonthDay, byDay, byHour, byMinute, weekStart, start, zone,
            )
        }

        /**
         * DTSTART 行：`DTSTART;TZID=Asia/Shanghai:20261022T090000`、`DTSTART:20261022T010000Z`。
         * 不带时区的（浮动时间）、只有日期的服务端不收，这里也不算。
         */
        fun parseStart(line: String): Pair<Instant, ZoneId>? {
            val colon = line.lastIndexOf(':')
            if (colon < 0) return null
            val params = line.substring(0, colon).split(';').drop(1)
            val value = line.substring(colon + 1).trim()
            var zone: ZoneId? = null
            for (param in params) {
                val kv = param.split('=', limit = 2)
                if (kv.size != 2) continue
                when (kv[0].uppercase()) {
                    "TZID" -> zone = ScheduleForecast.zone(kv[1])
                    "VALUE" -> if (kv[1].uppercase() == "DATE") return null
                }
            }
            if (value.uppercase().endsWith("Z")) zone = ZoneOffset.UTC
            val z = zone ?: return null
            val instant = parseDateTime(value, z, endOfDayForDates = false) ?: return null
            return instant to z
        }

        /**
         * `20261022T090000`（按 [zone]）、`20261022T010000Z`（UTC）、`20261022`（只有日期：[endOfDayForDates] 时取这一天的
         * 最后一秒，UNTIL 用）。日期不存在（2 月 30 日）返回 null。
         */
        fun parseDateTime(raw: String, zone: ZoneId, endOfDayForDates: Boolean): Instant? {
            val value = raw.uppercase()
            val utc = value.endsWith("Z")
            val body = if (utc) value.dropLast(1) else value
            val parts = body.split('T')
            val datePart = parts[0]
            if (datePart.length != 8 || datePart.any { !it.isDigit() }) return null
            val ymd = datePart.toInt()
            var time = LocalTime.MIDNIGHT
            when (parts.size) {
                1 -> if (endOfDayForDates) time = LocalTime.of(23, 59, 59)
                2 -> {
                    val t = parts[1]
                    if (t.length != 6 || t.any { !it.isDigit() }) return null
                    val hms = t.toInt()
                    val second = hms % 100
                    time = try {
                        LocalTime.of(hms / 10000, hms / 100 % 100, if (second == 60) 59 else second)
                    } catch (_: DateTimeException) {
                        return null
                    }
                }
                else -> return null
            }
            val date = try {
                LocalDate.of(ymd / 10000, ymd / 100 % 100, ymd % 100)
            } catch (_: DateTimeException) {
                return null
            }
            val z = if (utc) ZoneOffset.UTC else zone
            return ZonedDateTime.ofLocal(LocalDateTime.of(date, time), z, null).toInstant().truncatedTo(ChronoUnit.SECONDS)
        }
    }
}
