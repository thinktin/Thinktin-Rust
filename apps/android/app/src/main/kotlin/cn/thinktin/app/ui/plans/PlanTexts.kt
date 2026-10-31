package cn.thinktin.app.ui.plans

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.asString
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.schedule.TriggerDraft
import cn.thinktin.data.schedule.TriggerProblem
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.util.Locale

/** 计划是什么状态（列表、详情的标签）。 */
enum class PlanStatus { Awaiting, Paused, Active }

val Plan.status: PlanStatus
    get() = when {
        awaitingConfirmation -> PlanStatus.Awaiting
        paused -> PlanStatus.Paused
        else -> PlanStatus.Active
    }

fun PlanStatus.labelRes(): Int = when (this) {
    PlanStatus.Awaiting -> R.string.plan_status_awaiting
    PlanStatus.Paused -> R.string.plan_status_paused
    PlanStatus.Active -> R.string.plan_status_active
}

/** agent 建的计划：标题、目标带 AI 生成标识（第 8.4 节）。 */
val Plan.byAgent: Boolean get() = createdBy == "agent"

@Composable
private fun locale(): Locale = LocalConfiguration.current.locales[0] ?: Locale.getDefault()

/** 时刻 `09:05`。 */
fun clockTime(hour: Int, minute: Int): String = "%02d:%02d".format(hour, minute)

/** 一个时刻（日期 + 时间，按设备时区、界面语言）。 */
@Composable
fun dateTimeText(ms: Long, zone: ZoneId): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .withLocale(locale())
        .format(Instant.ofEpochMilli(ms).atZone(zone))

/** 计划列表和历史显示相对时间；计划编辑器里的规则预览仍显示绝对时间。 */
@Composable
fun relativePlanTime(ms: Long, zone: ZoneId): String {
    val now = cn.thinktin.app.ui.common.LocalAppContainer.current.clock.millis()
    if (ms <= now) return cn.thinktin.app.ui.common.RelativeTime.of(ms, now, zone).asString()
    val minutes = ((ms - now) / 60_000).coerceAtLeast(1)
    val at = Instant.ofEpochMilli(ms).atZone(zone)
    val days = at.toLocalDate().toEpochDay() - Instant.ofEpochMilli(now).atZone(zone).toLocalDate().toEpochDay()
    return when {
        minutes < 60 -> pluralStringResource(R.plurals.plan_in_minutes, minutes.toInt(), minutes.toInt())
        days == 0L -> pluralStringResource(R.plurals.plan_in_hours, (minutes / 60).toInt(), (minutes / 60).toInt())
        days == 1L -> stringResource(R.string.plan_tomorrow, at.format(DateTimeFormatter.ofPattern("HH:mm", locale())))
        days < 7 -> pluralStringResource(R.plurals.plan_in_days, days.toInt(), days.toInt())
        else -> dateTimeText(ms, zone)
    }
}

/** 周几的短名（0 是周日），按界面语言。 */
@Composable
fun weekdayName(day: Int): String =
    DayOfWeek.of(if (day == 0) 7 else day).getDisplayName(TextStyle.SHORT, locale())

/** 周几按周一开头排（周日在最后）。 */
val WEEK_ORDER = listOf(1, 2, 3, 4, 5, 6, 0)

/**
 * 触发规则的一句话描述：认得出的 cron 说成“每天 09:00”“工作日 09:00”“每周一、三 09:00”“每月 1、15 日 09:00”，
 * 一次性的说时间，其余原样显示 cron / RRULE。规则的时区和设备的不一样时带上时区。
 */
@Composable
fun scheduleSummary(schedule: Schedule, deviceZone: ZoneId): String {
    val separator = stringResource(R.string.plan_list_separator)
    return when (schedule) {
        is Schedule.Once -> stringResource(R.string.plan_schedule_once, dateTimeText(schedule.atMs, deviceZone))
        is Schedule.Rrule -> {
            val body = schedule.rule.lines().map { it.trim() }.firstOrNull { it.uppercase().startsWith("RRULE:") }
                ?.substring(6) ?: schedule.rule.lines().lastOrNull { it.isNotBlank() }.orEmpty()
            stringResource(R.string.plan_schedule_rrule, body)
        }
        is Schedule.Cron -> {
            val zoneSuffix = if (schedule.tz.isNotEmpty() && schedule.tz != deviceZone.id) {
                stringResource(R.string.plan_schedule_zone, schedule.tz)
            } else {
                ""
            }
            val adopted = TriggerDraft.new(deviceZone, 0).adoptCron(schedule.expr)
            val text = if (adopted == null) {
                stringResource(R.string.plan_schedule_cron, schedule.expr)
            } else {
                val (d, kind) = adopted
                val time = clockTime(d.hour, d.minute)
                when (kind) {
                    TriggerDraft.Kind.Weekly -> when (d.weekdays) {
                        setOf(1, 2, 3, 4, 5) -> stringResource(R.string.plan_schedule_workdays, time)
                        setOf(0, 6) -> stringResource(R.string.plan_schedule_weekends, time)
                        else -> stringResource(
                            R.string.plan_schedule_weekly,
                            WEEK_ORDER.filter { it in d.weekdays }.map { weekdayName(it) }.joinToString(separator),
                            time,
                        )
                    }
                    TriggerDraft.Kind.Monthly -> stringResource(
                        R.string.plan_schedule_monthly,
                        d.monthDays.sorted().joinToString(separator),
                        time,
                    )
                    else -> stringResource(R.string.plan_schedule_daily, time)
                }
            }
            text + zoneSuffix
        }
    }
}

/** 触发规则保存前的问题。 */
@Composable
fun TriggerProblem.message(): String = when (this) {
    TriggerProblem.OnceInPast -> stringResource(R.string.trigger_problem_once_in_past)
    TriggerProblem.UnknownTimeZone -> stringResource(R.string.trigger_problem_time_zone)
    TriggerProblem.NoWeekdays -> stringResource(R.string.trigger_problem_no_weekdays)
    TriggerProblem.NoMonthDays -> stringResource(R.string.trigger_problem_no_month_days)
    TriggerProblem.CronEmpty -> stringResource(R.string.trigger_problem_cron_empty)
    TriggerProblem.CronFieldCount -> stringResource(R.string.trigger_problem_cron_fields)
    TriggerProblem.CronInvalid -> stringResource(R.string.trigger_problem_cron_invalid)
    TriggerProblem.RruleEmpty -> stringResource(R.string.trigger_problem_rrule_empty)
    is TriggerProblem.RruleTooLong -> stringResource(R.string.trigger_problem_rrule_too_long, max)
    TriggerProblem.RruleExtraDates -> stringResource(R.string.trigger_problem_rrule_rdate)
    TriggerProblem.RruleMultipleRules -> stringResource(R.string.trigger_problem_rrule_multiple)
    TriggerProblem.RruleNoFrequency -> stringResource(R.string.trigger_problem_rrule_no_freq)
    TriggerProblem.RruleTooFrequent -> stringResource(R.string.trigger_problem_rrule_secondly)
    TriggerProblem.RruleNoTimeZone -> stringResource(R.string.trigger_problem_rrule_no_zone)
    TriggerProblem.RruleStartOutOfRange -> stringResource(R.string.trigger_problem_rrule_start_range)
    TriggerProblem.NeverFires -> stringResource(R.string.trigger_problem_never_fires)
    is TriggerProblem.TooFrequent -> pluralStringResource(R.plurals.trigger_problem_too_frequent, minimumMinutes, minimumMinutes)
}

/** 表单的问题。 */
@Composable
fun PlanFormProblem.message(): String = when (this) {
    PlanFormProblem.NoInstance -> stringResource(R.string.plan_problem_no_instance)
    is PlanFormProblem.Title -> when (problem) {
        TextProblem.Empty -> stringResource(R.string.plan_problem_title_empty)
        TextProblem.TooLong -> stringResource(R.string.plan_problem_title_long, PlanLimits.MAX_TITLE)
    }
    is PlanFormProblem.Goal -> when (problem) {
        TextProblem.Empty -> stringResource(R.string.plan_problem_goal_empty)
        TextProblem.TooLong -> stringResource(R.string.plan_problem_goal_long, PlanLimits.MAX_GOAL)
    }
    PlanFormProblem.NoTriggers -> stringResource(R.string.plan_problem_no_triggers)
    PlanFormProblem.TooManyTriggers -> stringResource(R.string.plan_problem_too_many_triggers, PlanLimits.MAX_TRIGGERS)
    is PlanFormProblem.Policy -> problem.message()
    PlanFormProblem.Steps -> stringResource(R.string.plan_problem_steps)
}

@Composable
fun PolicyProblem.message(): String = when (this) {
    PolicyProblem.ApprovalAction -> stringResource(R.string.plan_choose_timeout_action)
    PolicyProblem.ApprovalTimeout -> stringResource(R.string.plan_policy_problem_approval_timeout)
    PolicyProblem.WaitTimeout -> stringResource(R.string.plan_policy_problem_wait_timeout)
    PolicyProblem.MaxDuration -> stringResource(R.string.plan_policy_problem_max_duration)
    PolicyProblem.MaxTokens, PolicyProblem.MaxSteps, PolicyProblem.DailyTokenLimit ->
        stringResource(R.string.plan_policy_problem_limit)
}

fun ApprovalTimeoutAction.labelRes(): Int = when (this) {
    ApprovalTimeoutAction.Skip -> R.string.plan_timeout_skip
    ApprovalTimeoutAction.PausePlan, ApprovalTimeoutAction.Unknown -> R.string.plan_timeout_pause
    ApprovalTimeoutAction.Fail -> R.string.plan_timeout_fail
}

fun CatchUp.labelRes(): Int = when (this) {
    CatchUp.Once, CatchUp.Unknown -> R.string.plan_catch_up_once
    CatchUp.All -> R.string.plan_catch_up_all
    CatchUp.Skip -> R.string.plan_catch_up_skip
}

fun CatchUp.detailRes(): Int = when (this) {
    CatchUp.Once, CatchUp.Unknown -> R.string.plan_catch_up_once_detail
    CatchUp.All -> R.string.plan_catch_up_all_detail
    CatchUp.Skip -> R.string.plan_catch_up_skip_detail
}

fun TriggerDraft.Kind.labelRes(): Int = when (this) {
    TriggerDraft.Kind.Daily -> R.string.trigger_kind_daily
    TriggerDraft.Kind.Weekly -> R.string.trigger_kind_weekly
    TriggerDraft.Kind.Monthly -> R.string.trigger_kind_monthly
    TriggerDraft.Kind.Once -> R.string.trigger_kind_once
    TriggerDraft.Kind.Cron -> R.string.trigger_kind_cron
    TriggerDraft.Kind.Rrule -> R.string.trigger_kind_rrule
}

/** ACP 工具种类的名字（预授权的选项）。 */
fun toolKindLabelRes(kind: String): Int? = when (kind) {
    "read" -> R.string.tool_kind_read
    "search" -> R.string.tool_kind_search
    "fetch" -> R.string.tool_kind_fetch
    "edit" -> R.string.tool_kind_edit
    "move" -> R.string.tool_kind_move
    "delete" -> R.string.tool_kind_delete
    "execute" -> R.string.tool_kind_execute
    "think" -> R.string.tool_kind_think
    else -> null
}
