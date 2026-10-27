package cn.thinktin.app.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import cn.thinktin.app.R
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** 相对时间（第 5 节）：刚刚、5 分钟前、3 小时前、昨天 20:30、3 天前，超过一周显示日期。 */
sealed interface RelativeTime {
    data object JustNow : RelativeTime
    data class MinutesAgo(val minutes: Int) : RelativeTime
    data class HoursAgo(val hours: Int) : RelativeTime
    data class Yesterday(val time: String) : RelativeTime
    data class DaysAgo(val days: Int) : RelativeTime
    data class Date(val date: String) : RelativeTime

    companion object {
        private val timeFormat = DateTimeFormatter.ofPattern("HH:mm")

        fun of(thenMs: Long, nowMs: Long, zone: ZoneId): RelativeTime {
            val diff = (nowMs - thenMs).coerceAtLeast(0)
            val minutes = diff / 60_000
            val then = Instant.ofEpochMilli(thenMs).atZone(zone)
            val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
            val thenDay: LocalDate = then.toLocalDate()
            return when {
                minutes < 1 -> JustNow
                minutes < 60 -> MinutesAgo(minutes.toInt())
                thenDay == today -> HoursAgo((minutes / 60).toInt())
                thenDay == today.minusDays(1) -> Yesterday(then.format(timeFormat))
                thenDay.isAfter(today.minusDays(7)) -> DaysAgo((today.toEpochDay() - thenDay.toEpochDay()).toInt())
                else -> Date(then.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)))
            }
        }
    }
}

@Composable
fun RelativeTime.asString(): String = when (this) {
    RelativeTime.JustNow -> stringResource(R.string.time_just_now)
    is RelativeTime.MinutesAgo -> pluralStringResource(R.plurals.time_minutes_ago, minutes, minutes)
    is RelativeTime.HoursAgo -> pluralStringResource(R.plurals.time_hours_ago, hours, hours)
    is RelativeTime.Yesterday -> stringResource(R.string.time_yesterday, time)
    is RelativeTime.DaysAgo -> pluralStringResource(R.plurals.time_days_ago, days, days)
    is RelativeTime.Date -> date
}
