package cn.thinktin.data.schedule

import cn.thinktin.data.model.Schedule
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** 触发规则保存前要改的问题（和服务端的校验对应；服务端回的英文说明不给用户看）。 */
sealed interface TriggerProblem {
    data object OnceInPast : TriggerProblem
    data object UnknownTimeZone : TriggerProblem
    data object NoWeekdays : TriggerProblem
    data object NoMonthDays : TriggerProblem
    data object CronEmpty : TriggerProblem
    data object CronFieldCount : TriggerProblem
    data object CronInvalid : TriggerProblem
    data object RruleEmpty : TriggerProblem
    data class RruleTooLong(val max: Int) : TriggerProblem
    data object RruleExtraDates : TriggerProblem
    data object RruleMultipleRules : TriggerProblem
    data object RruleNoFrequency : TriggerProblem
    data object RruleTooFrequent : TriggerProblem
    data object RruleNoTimeZone : TriggerProblem
    data object RruleStartOutOfRange : TriggerProblem

    /** 再也不会触发（时间都过去了、COUNT 用完了、2 月 30 日这种）。 */
    data object NeverFires : TriggerProblem

    /** 比服务端允许的更频繁（默认最少隔 5 分钟）。 */
    data class TooFrequent(val minimumMinutes: Int) : TriggerProblem
}

/**
 * 触发器编辑器里正在编的一条规则（13.6，和 iOS 的 `TriggerDraft` 一致）：常用的几种（每天、每周几、每月几号、一次性）
 * 和高级的 cron、RRULE，时区默认是设备的时区。[schedule] 生成服务端要的 [Schedule]；[from] 把已有的规则拆回来（认得出的
 * cron 拆成常用写法，认不出的进“高级 cron”）；[withKind] 在几种写法之间换时尽量带上已经填的内容。
 */
data class TriggerDraft(
    val kind: Kind,
    /** 时刻（每天、每周、每月、RRULE 的开始时间），按 [timeZoneId] 的本地时间。 */
    val hour: Int,
    val minute: Int,
    /** 每周的哪几天：0 是周日，1 到 6 是周一到周六（和 cron 一样）。 */
    val weekdays: Set<Int>,
    /** 每月的哪几号（1 到 31；没有这一天的月份跳过）。 */
    val monthDays: Set<Int>,
    /** 一次性的时间（Unix 毫秒）。 */
    val onceAtMs: Long,
    /** 高级：五段 cron。 */
    val cronExpression: String,
    /** 高级：RRULE 那一行（`FREQ=WEEKLY;BYDAY=MO`，可以带 `RRULE:`）；也可以贴带 DTSTART 的完整规则。 */
    val rruleText: String,
    /** RRULE 的开始日期（DTSTART 的日期部分，时刻用 [hour]、[minute]）。 */
    val startDay: LocalDate,
    /** 规则的时区（IANA 名称）。一次性的规则是绝对时间，不用它。 */
    val timeZoneId: String,
) {
    enum class Kind {
        Daily, Weekly, Monthly, Once, Cron, Rrule;

        /** 常用写法（每天、每周、每月）：用时刻 + 日子拼成 cron。 */
        val isCalendar: Boolean get() = this == Daily || this == Weekly || this == Monthly
    }

    // ---- 生成规则 ----

    /** 按现在填的内容生成规则（没检查过，先看 [problem]）。 */
    val schedule: Schedule
        get() = when (kind) {
            Kind.Daily, Kind.Weekly, Kind.Monthly -> Schedule.Cron(calendarCron, timeZoneId)
            Kind.Once -> Schedule.Once(onceAtMs)
            Kind.Cron -> Schedule.Cron(normalizedCron(cronExpression), timeZoneId)
            Kind.Rrule -> Schedule.Rrule(composedRRule)
        }

    /** 常用写法对应的 cron：每天 `M H * * *`，每周 `M H * * 1-5`，每月 `M H 1,15 * *`。 */
    val calendarCron: String
        get() {
            val time = "$minute $hour"
            return when (kind) {
                Kind.Weekly -> {
                    val days = weekdays.sorted()
                    when {
                        days == listOf(1, 2, 3, 4, 5) -> "$time * * 1-5"
                        days.size == 7 -> "$time * * *"
                        else -> "$time * * " + days.joinToString(",")
                    }
                }
                Kind.Monthly -> "$time " + monthDays.sorted().joinToString(",") + " * *"
                else -> "$time * * *"
            }
        }

    /**
     * RRULE 的完整文本：贴进来的带 DTSTART 就原样用（换行统一成 `\n`），否则按开始日期、时刻、时区补上
     * `DTSTART;TZID=…`（服务端要求 DTSTART 带时区）。
     */
    val composedRRule: String
        get() {
            val text = rruleText.trim()
            val lines = text.lines().map { it.trim() }
            if (lines.any { it.uppercase().startsWith("DTSTART") }) return lines.filter { it.isNotEmpty() }.joinToString("\n")
            var body = text.uppercase().replace(" ", "")
            if (body.startsWith("RRULE:")) body = body.substring(6)
            val stamp = "%04d%02d%02dT%02d%02d00".format(startDay.year, startDay.monthValue, startDay.dayOfMonth, hour, minute)
            return "DTSTART;TZID=$timeZoneId:$stamp\nRRULE:$body"
        }

    /** RRULE 文本里自己带了 DTSTART（开始日期、时刻、时区以贴进来的为准，界面上那几个选择器不起作用）。 */
    val rruleHasOwnStart: Boolean
        get() = rruleText.lines().any { it.trim().uppercase().startsWith("DTSTART") }

    // ---- 换写法 ----

    /**
     * 换一种写法，尽量带上已经填的：常用写法换成 cron 时填好对应的表达式，cron 换回常用写法时拆得出来就用拆出来的；
     * 换成 RRULE 时写好等价的规则；换成一次性时，时间已经过去了就改成下一个这个时刻。
     */
    fun withKind(newKind: Kind, nowMs: Long): TriggerDraft {
        if (newKind == kind) return this
        var d = this
        when (newKind) {
            Kind.Cron -> if (kind.isCalendar) d = d.copy(cronExpression = calendarCron)
            Kind.Rrule -> {
                if (kind.isCalendar) {
                    d = d.copy(rruleText = equivalentRRule(kind), startDay = today(nowMs))
                } else if (kind == Kind.Cron) {
                    adoptCron(cronExpression)?.let { (adopted, found) ->
                        d = adopted.copy(rruleText = adopted.equivalentRRule(found), startDay = today(nowMs))
                    }
                }
            }
            Kind.Once -> if (onceAtMs <= nowMs) d = d.copy(onceAtMs = nextOccurrence(hour, minute, nowMs))
            Kind.Daily, Kind.Weekly, Kind.Monthly -> {
                if (kind == Kind.Cron) adoptCron(cronExpression)?.let { d = it.first }
                if (kind == Kind.Rrule) {
                    val split = d.adoptRRule(composedRRule)
                    d = split.adoptRRuleCalendar(split.rruleText)
                }
            }
        }
        if (newKind == Kind.Weekly && d.weekdays.isEmpty()) d = d.copy(weekdays = setOf(1))
        if (newKind == Kind.Monthly && d.monthDays.isEmpty()) d = d.copy(monthDays = setOf(1))
        return d.copy(kind = newKind)
    }

    /**
     * cron 拆成常用写法：分、时都是一个值，月是 `*`，“日”“周”至少一个是 `*`。拆得出返回填好时刻、日子的草稿和写法。
     */
    fun adoptCron(expression: String): Pair<TriggerDraft, Kind>? {
        val parts = expression.trim().split(Regex("\\s+"))
        if (parts.size != 5 || parts[3] != "*") return null
        val ms = (CronField.parse(parts[0], 0..59) as? CronField.Values)?.values?.takeIf { it.size == 1 } ?: return null
        val hs = (CronField.parse(parts[1], 0..23) as? CronField.Values)?.values?.takeIf { it.size == 1 } ?: return null
        val dayStar = parts[2] == "*"
        val weekStar = parts[4] == "*"
        var d = copy(hour = hs[0], minute = ms[0])
        val found = when {
            dayStar && weekStar -> Kind.Daily
            dayStar -> {
                val days = (CronField.parse(parts[4], 0..7, CronField.WEEKDAY_NAMES)?.normalizingSunday() as? CronField.Values)
                    ?.values ?: return null
                d = d.copy(weekdays = days.toSet())
                if (days.size == 7) Kind.Daily else Kind.Weekly
            }
            weekStar -> {
                val days = (CronField.parse(parts[2], 1..31) as? CronField.Values)?.values ?: return null
                d = d.copy(monthDays = days.toSet())
                Kind.Monthly
            }
            else -> return null
        }
        return d to found
    }

    /**
     * RRULE 那一行拆成常用写法的日子和时刻（换回每天、每周、每月时用）：WEEKLY 的不带序号的 BYDAY、MONTHLY 的
     * 正数 BYMONTHDAY、只有一个值的 BYHOUR / BYMINUTE。拆不出的部分不动。
     */
    fun adoptRRuleCalendar(body: String): TriggerDraft {
        val fields = mutableMapOf<String, String>()
        for (pair in body.uppercase().split(';')) {
            val kv = pair.split('=', limit = 2)
            if (kv.size == 2) fields[kv[0]] = kv[1]
        }
        var d = this
        fields["BYHOUR"]?.toIntOrNull()?.takeIf { it in 0..23 }?.let { d = d.copy(hour = it) }
        fields["BYMINUTE"]?.toIntOrNull()?.takeIf { it in 0..59 }?.let { d = d.copy(minute = it) }
        if (fields["FREQ"] == "WEEKLY") {
            val days = fields["BYDAY"]?.split(',')?.mapNotNull { RecurrenceRule.WEEKDAY_CODES.indexOf(it).takeIf { i -> i >= 0 } }
            if (!days.isNullOrEmpty()) d = d.copy(weekdays = days.toSet())
        }
        if (fields["FREQ"] == "MONTHLY") {
            val days = fields["BYMONTHDAY"]?.split(',')?.mapNotNull { it.toIntOrNull() }?.filter { it in 1..31 }
            if (!days.isNullOrEmpty()) d = d.copy(monthDays = days.toSet())
        }
        return d
    }

    /**
     * RRULE 拆回来：一行带时区的 DTSTART 加一行 RRULE 时，开始日期、时刻、时区放进各自的字段，RRULE 只留那一行；
     * 别的（浮动时间、多行）原样放进文本框。
     */
    fun adoptRRule(text: String): TriggerDraft {
        val lines = text.lines().map { it.trim() }.filter { it.isNotEmpty() }
        val starts = lines.filter { it.uppercase().startsWith("DTSTART") }
        val rules = lines.filter { !it.uppercase().startsWith("DTSTART") }
        val start = if (starts.size == 1 && rules.size == 1) parseStart(starts[0]) else null
        if (start == null) return copy(rruleText = lines.joinToString("\n"))
        var body = rules[0]
        if (body.uppercase().startsWith("RRULE:")) body = body.substring(6)
        return copy(rruleText = body, timeZoneId = start.zoneId, startDay = start.day, hour = start.hour, minute = start.minute)
    }

    /** 常用写法对应的 RRULE 那一行。 */
    fun equivalentRRule(kind: Kind): String {
        val codes = RecurrenceRule.WEEKDAY_CODES
        return when (kind) {
            // 按周一开头排（周日在最后）。
            Kind.Weekly -> "FREQ=WEEKLY;BYDAY=" + weekdays.sortedBy { (it + 6) % 7 }.joinToString(",") { codes[it] }
            Kind.Monthly -> "FREQ=MONTHLY;BYMONTHDAY=" + monthDays.sorted().joinToString(",")
            else -> "FREQ=DAILY"
        }
    }

    // ---- 检查 ----

    /** 保存前要改的问题；没有为 null。 */
    fun problem(nowMs: Long): TriggerProblem? {
        when (kind) {
            Kind.Once -> return if (onceAtMs > nowMs) null else TriggerProblem.OnceInPast
            Kind.Daily, Kind.Weekly, Kind.Monthly -> {
                if (ScheduleForecast.zone(timeZoneId) == null) return TriggerProblem.UnknownTimeZone
                if (kind == Kind.Weekly && weekdays.isEmpty()) return TriggerProblem.NoWeekdays
                if (kind == Kind.Monthly && monthDays.isEmpty()) return TriggerProblem.NoMonthDays
            }
            Kind.Cron -> {
                if (ScheduleForecast.zone(timeZoneId) == null) return TriggerProblem.UnknownTimeZone
                val expression = normalizedCron(cronExpression)
                if (expression.isEmpty()) return TriggerProblem.CronEmpty
                // `L`、`W`、`#`、`@daily` 这些 App 算不了，交给服务端检查（只提示，不拦）。
                if (expression.startsWith("@") || expression.uppercase().any { it in "LW#" }) return null
                if (expression.split(' ').size != 5) return TriggerProblem.CronFieldCount
                if (CronSchedule.parse(expression, timeZoneId) == null) return TriggerProblem.CronInvalid
            }
            Kind.Rrule -> rruleProblem(nowMs)?.let { return it }
        }
        // 能在本地算的：再也不会触发、比服务端允许的更频繁，保存时一定会被拒。
        val schedule = this.schedule
        val fires = ScheduleForecast.nextFires(schedule, nowMs, 1)
        if (fires != null && fires.isEmpty()) return TriggerProblem.NeverFires
        val gap = ScheduleForecast.minimumGapMs(schedule, nowMs)
        if (gap != null && gap < ScheduleForecast.MIN_INTERVAL_MS) {
            return TriggerProblem.TooFrequent((ScheduleForecast.MIN_INTERVAL_MS / 60_000).toInt())
        }
        return null
    }

    /** RRULE 的格式问题（服务端 `Schedule::parse_new` 的几条规矩）。 */
    private fun rruleProblem(nowMs: Long): TriggerProblem? {
        if (rruleText.isBlank()) return TriggerProblem.RruleEmpty
        val full = composedRRule
        // 服务端按字节数算（`rule.len()`）。
        if (full.toByteArray(Charsets.UTF_8).size > MAX_RRULE_LENGTH) return TriggerProblem.RruleTooLong(MAX_RRULE_LENGTH)
        val lines = full.lines().map { it.trim().uppercase() }
        if (lines.any { it.startsWith("RDATE") }) return TriggerProblem.RruleExtraDates
        val ruleLines = lines.filter { it.isNotEmpty() && !it.startsWith("DTSTART") && !it.startsWith("EXDATE") }
        if (ruleLines.size > 1) return TriggerProblem.RruleMultipleRules
        val rule = ruleLines.firstOrNull()
        if (rule == null || "FREQ=" !in rule) return TriggerProblem.RruleNoFrequency
        if ("FREQ=SECONDLY" in rule) return TriggerProblem.RruleTooFrequent
        // 每 N 分钟一次（没有 BY 限定）本地预测不了，但间隔一眼可知：服务端最小间隔 5 分钟，不够的先拦下。
        if ("FREQ=MINUTELY" in rule && "BY" !in rule) {
            val interval = Regex("INTERVAL=(\\d+)").find(rule)?.groupValues?.get(1)?.toLongOrNull() ?: 1L
            if (interval * 60_000 < ScheduleForecast.MIN_INTERVAL_MS) {
                return TriggerProblem.TooFrequent((ScheduleForecast.MIN_INTERVAL_MS / 60_000).toInt())
            }
        }
        val startLine = full.lines().firstOrNull { it.trim().uppercase().startsWith("DTSTART") }
            ?: return TriggerProblem.RruleNoTimeZone
        val (start, _) = RecurrenceRule.parseStart(startLine.trim()) ?: return TriggerProblem.RruleNoTimeZone
        // DTSTART 要在“一天前”到“一年后”之间（服务端怕从很早的 DTSTART 往后数太慢）。
        val now = Instant.ofEpochMilli(nowMs)
        if (start < now.minus(1, ChronoUnit.DAYS) || start > now.plus(366, ChronoUnit.DAYS)) {
            return TriggerProblem.RruleStartOutOfRange
        }
        return null
    }

    /** App 算不了这种写法的触发时间（不拦保存，保存时由服务端检查、算下一次）。 */
    val cannotPreview: Boolean get() = kind != Kind.Once && !ScheduleForecast.canForecast(schedule)

    /** 接下来几次触发（本地算的预览）；算不了为 null。 */
    fun upcoming(nowMs: Long, count: Int = 5): List<Long>? = ScheduleForecast.nextFires(schedule, nowMs, count)

    // ---- 工具 ----

    /** 规则时区里的今天。 */
    private fun today(nowMs: Long): LocalDate =
        Instant.ofEpochMilli(nowMs).atZone(ScheduleForecast.zone(timeZoneId) ?: ZoneId.systemDefault()).toLocalDate()

    /** [nowMs] 之后第一个 `hour:minute`（按规则的时区）。 */
    private fun nextOccurrence(hour: Int, minute: Int, nowMs: Long): Long {
        val zone = ScheduleForecast.zone(timeZoneId) ?: ZoneId.systemDefault()
        val now = Instant.ofEpochMilli(nowMs)
        val today = now.atZone(zone).toLocalDate()
        val todayAt = ScheduleForecast.localInstant(today, hour, minute, 0, zone, fixedTime = true) ?: now
        val next = if (todayAt > now) todayAt else ScheduleForecast.localInstant(today.plusDays(1), hour, minute, 0, zone, true)
        return (next ?: now).toEpochMilli()
    }

    /** DTSTART 行里的本地日期、时刻和时区。 */
    private data class Start(val zoneId: String, val day: LocalDate, val hour: Int, val minute: Int)

    private fun parseStart(line: String): Start? {
        val (instant, zone) = RecurrenceRule.parseStart(line) ?: return null
        val local = instant.atZone(zone)
        // `…Z` 的 DTSTART 写回去用 UTC（服务端的 chrono-tz 认）。
        val id = if (zone.id == "Z" || zone.id == "GMT" || zone.id == "UTC") "UTC" else zone.id
        return Start(id, local.toLocalDate(), local.hour, local.minute)
    }

    companion object {
        /** RRULE 文本最长几个字节（服务端的 `MAX_RULE_LEN`）。 */
        const val MAX_RRULE_LENGTH = 1000

        /** 新的一条：每天 09:00，设备的时区。 */
        fun new(zone: ZoneId, nowMs: Long): TriggerDraft {
            val now = Instant.ofEpochMilli(nowMs)
            val local = now.atZone(zone)
            // 一次性的默认时间：一小时后，往后取整到整分钟。
            val inHour = now.plus(1, ChronoUnit.HOURS)
            val floored = inHour.truncatedTo(ChronoUnit.MINUTES)
            val onceAt = if (floored < inHour) floored.plus(1, ChronoUnit.MINUTES) else floored
            return TriggerDraft(
                kind = Kind.Daily,
                hour = 9,
                minute = 0,
                weekdays = setOf(local.dayOfWeek.value % 7),
                monthDays = setOf(local.dayOfMonth),
                onceAtMs = onceAt.toEpochMilli(),
                cronExpression = "0 9 * * *",
                rruleText = "FREQ=WEEKLY;BYDAY=MO",
                startDay = local.toLocalDate(),
                timeZoneId = zone.id,
            )
        }

        /** 把已有的规则拆回来编辑。[zone] 是设备的时区（规则没写时区、一次性的规则用它）。 */
        fun from(schedule: Schedule, zone: ZoneId, nowMs: Long): TriggerDraft {
            val base = new(zone, nowMs)
            return when (schedule) {
                is Schedule.Cron -> {
                    val expr = normalizedCron(schedule.expr)
                    val d = base.copy(cronExpression = expr, timeZoneId = schedule.tz.ifEmpty { base.timeZoneId })
                    // 认得出的直接用常用写法显示，认不出的进“高级 cron”。
                    d.adoptCron(expr)?.let { (adopted, kind) -> adopted.copy(kind = kind) } ?: d.copy(kind = Kind.Cron)
                }
                is Schedule.Rrule -> base.copy(kind = Kind.Rrule).adoptRRule(schedule.rule)
                is Schedule.Once -> {
                    val local = Instant.ofEpochMilli(schedule.atMs).atZone(zone)
                    base.copy(kind = Kind.Once, onceAtMs = schedule.atMs, hour = local.hour, minute = local.minute)
                }
            }
        }

        /** cron 去掉首尾空白、多个空白并成一个。 */
        fun normalizedCron(expression: String): String = expression.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }
}
