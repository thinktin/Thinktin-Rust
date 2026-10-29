package cn.thinktin.data

import cn.thinktin.data.model.Schedule
import cn.thinktin.data.schedule.CronField
import cn.thinktin.data.schedule.CronSchedule
import cn.thinktin.data.schedule.RecurrenceRule
import cn.thinktin.data.schedule.ScheduleForecast
import cn.thinktin.data.schedule.TriggerDraft
import cn.thinktin.data.schedule.TriggerProblem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** 13.6 的触发规则：cron / RRULE 的本地预测、触发器草稿（期望值由 Python zoneinfo 独立算出）。 */
class ScheduleTest {
    private val shanghai = ZoneId.of("Asia/Shanghai")

    /** 2026-10-25（周日）08:00，上海。 */
    private val now = 1_792_886_400_000L

    @Test
    fun cronFieldParsesNamesRangesStepsAndLists() {
        assertEquals(CronField.Any, CronField.parse("*", 0..59))
        assertEquals(CronField.Any, CronField.parse("?", 0..7))
        assertEquals(CronField.Step(15), CronField.parse("*/15", 0..59))
        assertEquals(CronField.Any, CronField.parse("*/1", 0..59))
        assertEquals(CronField.Values(listOf(1, 2, 3, 4, 5)), CronField.parse("MON-FRI", 0..7, CronField.WEEKDAY_NAMES))
        assertEquals(CronField.Values(listOf(0, 10, 20, 30)), CronField.parse("0-30/10", 0..59))
        assertEquals(CronField.Values(listOf(5, 25, 45)), CronField.parse("5/20", 0..59))
        assertEquals(CronField.Values(listOf(1, 15)), CronField.parse("15,1,15", 1..31))
        assertEquals(CronField.Values(listOf(0)), CronField.parse("7", 0..7)?.normalizingSunday())
        assertNull(CronField.parse("60", 0..59))
        assertNull(CronField.parse("5-1", 0..59))
        assertNull(CronField.parse("*/0", 0..59))
        assertNull(CronField.parse("1,,2", 0..59))
        assertNull(CronField.parse("L", 1..31))
    }

    @Test
    fun cronWeekdaysInTheRuleTimeZone() {
        val fires = ScheduleForecast.nextFires(Schedule.Cron("0 9 * * 1-5", "Asia/Shanghai"), now, 2)
        assertEquals(listOf(1_792_976_400_000L, 1_793_062_800_000L), fires)
        // 每天：当天 09:00 还没到。
        assertEquals(listOf(1_792_890_000_000L), ScheduleForecast.nextFires(Schedule.Cron("0 9 * * *", "Asia/Shanghai"), now, 1))
    }

    @Test
    fun cronDayAndWeekdayBothSetMeansEither() {
        val afterNov10 = 1_794_240_000_000L
        val fires = ScheduleForecast.nextFires(Schedule.Cron("0 9 13 * 5", "Asia/Shanghai"), afterNov10, 6)
        assertEquals(
            listOf(1_794_531_600_000L, 1_795_136_400_000L, 1_795_741_200_000L, 1_796_346_000_000L, 1_796_950_800_000L, 1_797_123_600_000L),
            fires,
        )
    }

    @Test
    fun cronDaylightSavingGapFiresAtTheTransitionAndOverlapOnce() {
        // 2026-03-08 纽约 02:00 → 03:00：02:30 不存在，在跳过之后的第一刻（07:00Z）触发。
        val gap = ScheduleForecast.nextFires(Schedule.Cron("30 2 * * *", "America/New_York"), 1_772_884_800_000L, 1)
        assertEquals(listOf(1_772_953_200_000L), gap)
        // 2026-11-01 01:30 出现两次：取较早的（EDT），第二天照常。
        val overlap = ScheduleForecast.nextFires(Schedule.Cron("30 1 * * *", "America/New_York"), 1_793_448_000_000L, 2)
        assertEquals(listOf(1_793_511_000_000L, 1_793_601_000_000L), overlap)
    }

    @Test
    fun cronThatCannotBeForecast() {
        assertNull(CronSchedule.parse("0 9 L * *", "Asia/Shanghai"))
        assertNull(CronSchedule.parse("0 9 * *", "Asia/Shanghai"))
        assertNull(CronSchedule.parse("0 9 * * *", "Mars/Olympus"))
        assertFalse(ScheduleForecast.canForecast(Schedule.Cron("@daily", "UTC")))
        // 2 月 30 日：永远不会触发。
        assertEquals(emptyList<Long>(), ScheduleForecast.nextFires(Schedule.Cron("0 9 30 2 *", "UTC"), now, 1))
    }

    @Test
    fun rruleWeeklyByDay() {
        val rule = "DTSTART;TZID=Asia/Shanghai:20261026T083000\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE"
        val fires = ScheduleForecast.nextFires(Schedule.Rrule(rule), now, 4)
        assertEquals(listOf(1_792_974_600_000L, 1_793_147_400_000L, 1_793_579_400_000L, 1_793_752_200_000L), fires)
        // COUNT 算上 DTSTART 那一次。
        val counted = ScheduleForecast.nextFires(Schedule.Rrule("$rule;COUNT=3"), now, 10)
        assertEquals(listOf(1_792_974_600_000L, 1_793_147_400_000L, 1_793_579_400_000L), counted)
    }

    @Test
    fun rruleMonthlyLastFriday() {
        val rule = "DTSTART;TZID=Asia/Shanghai:20261101T090000\nRRULE:FREQ=MONTHLY;BYDAY=-1FR"
        assertEquals(
            listOf(1_795_741_200_000L, 1_798_160_400_000L, 1_801_184_400_000L),
            ScheduleForecast.nextFires(Schedule.Rrule(rule), now, 3),
        )
    }

    @Test
    fun rruleUntilAndUnsupportedParts() {
        val until = "DTSTART;TZID=Asia/Shanghai:20261026T083000\nRRULE:FREQ=DAILY;UNTIL=20261027"
        assertEquals(2, ScheduleForecast.nextFires(Schedule.Rrule(until), now, 10)?.size)
        assertNull(RecurrenceRule.parse("DTSTART;TZID=Asia/Shanghai:20261026T083000\nRRULE:FREQ=MONTHLY;BYSETPOS=1;BYDAY=MO"))
        assertNull(RecurrenceRule.parse("DTSTART:20261026T083000\nRRULE:FREQ=DAILY"))
        assertNull(RecurrenceRule.parse("DTSTART;TZID=Asia/Shanghai:20260230T083000\nRRULE:FREQ=DAILY"))
        assertNull(RecurrenceRule.parse("DTSTART;TZID=Asia/Shanghai:20261026T083000\nRRULE:FREQ=WEEKLY;BYDAY=1MO"))
        assertNotNull(RecurrenceRule.parse("DTSTART:20261026T003000Z\nRRULE:FREQ=HOURLY;INTERVAL=2"))
    }

    @Test
    fun minimumGap() {
        assertEquals(60_000L, ScheduleForecast.minimumGapMs(Schedule.Cron("* * * * *", "UTC"), now))
        assertEquals(86_400_000L, ScheduleForecast.minimumGapMs(Schedule.Cron("0 9 * * *", "UTC"), now))
        assertNull(ScheduleForecast.minimumGapMs(Schedule.Once(now + 1000), now))
    }

    @Test
    fun newDraftIsDailyAtNineInTheDeviceZone() {
        val d = TriggerDraft.new(shanghai, now)
        assertEquals(TriggerDraft.Kind.Daily, d.kind)
        assertEquals(Schedule.Cron("0 9 * * *", "Asia/Shanghai"), d.schedule)
        assertEquals(setOf(0), d.weekdays)
        assertEquals(setOf(25), d.monthDays)
        assertEquals(LocalDate.of(2026, 10, 25), d.startDay)
        assertEquals(now + 3_600_000L, d.onceAtMs)
        assertNull(d.problem(now))
    }

    @Test
    fun calendarKindsMakeCron() {
        val d = TriggerDraft.new(shanghai, now)
        assertEquals("30 7 * * 1-5", d.copy(kind = TriggerDraft.Kind.Weekly, hour = 7, minute = 30, weekdays = setOf(1, 2, 3, 4, 5)).calendarCron)
        assertEquals("0 9 * * 0,6", d.copy(kind = TriggerDraft.Kind.Weekly, weekdays = setOf(6, 0)).calendarCron)
        assertEquals("0 9 * * *", d.copy(kind = TriggerDraft.Kind.Weekly, weekdays = (0..6).toSet()).calendarCron)
        assertEquals("0 9 1,15 * *", d.copy(kind = TriggerDraft.Kind.Monthly, monthDays = setOf(15, 1)).calendarCron)
    }

    @Test
    fun existingSchedulesAreSplitBack() {
        val weekly = TriggerDraft.from(Schedule.Cron("15 8 * * MON,WED", "Asia/Tokyo"), shanghai, now)
        assertEquals(TriggerDraft.Kind.Weekly, weekly.kind)
        assertEquals(setOf(1, 3), weekly.weekdays)
        assertEquals(8 to 15, weekly.hour to weekly.minute)
        assertEquals("Asia/Tokyo", weekly.timeZoneId)
        val monthly = TriggerDraft.from(Schedule.Cron("0 6 1,15 * *", "Asia/Shanghai"), shanghai, now)
        assertEquals(TriggerDraft.Kind.Monthly, monthly.kind)
        assertEquals(setOf(1, 15), monthly.monthDays)
        val advanced = TriggerDraft.from(Schedule.Cron("*/30  9-17 * * 1-5", "Asia/Shanghai"), shanghai, now)
        assertEquals(TriggerDraft.Kind.Cron, advanced.kind)
        assertEquals("*/30 9-17 * * 1-5", advanced.cronExpression)
        val rrule = TriggerDraft.from(
            Schedule.Rrule("DTSTART;TZID=Europe/Paris:20261030T074500\nRRULE:FREQ=WEEKLY;BYDAY=FR"),
            shanghai,
            now,
        )
        assertEquals(TriggerDraft.Kind.Rrule, rrule.kind)
        assertEquals("FREQ=WEEKLY;BYDAY=FR", rrule.rruleText)
        assertEquals("Europe/Paris", rrule.timeZoneId)
        assertEquals(LocalDate.of(2026, 10, 30), rrule.startDay)
        assertEquals(7 to 45, rrule.hour to rrule.minute)
        assertEquals("DTSTART;TZID=Europe/Paris:20261030T074500\nRRULE:FREQ=WEEKLY;BYDAY=FR", rrule.composedRRule)
        val once = TriggerDraft.from(Schedule.Once(now + 7_200_000L), shanghai, now)
        assertEquals(TriggerDraft.Kind.Once, once.kind)
        assertEquals(10 to 0, once.hour to once.minute)
    }

    @Test
    fun switchingKindsCarriesWhatWasFilledIn() {
        val weekly = TriggerDraft.new(shanghai, now).copy(kind = TriggerDraft.Kind.Weekly, weekdays = setOf(0, 1, 3), hour = 7)
        val asRrule = weekly.withKind(TriggerDraft.Kind.Rrule, now)
        assertEquals("FREQ=WEEKLY;BYDAY=MO,WE,SU", asRrule.rruleText)
        assertEquals("DTSTART;TZID=Asia/Shanghai:20261025T070000\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE,SU", asRrule.composedRRule)
        val asCron = weekly.withKind(TriggerDraft.Kind.Cron, now)
        assertEquals("0 7 * * 0,1,3", asCron.cronExpression)
        // cron 换回常用写法：拆得出就用拆出来的。
        val back = asCron.copy(cronExpression = "45 18 * * 2,4").withKind(TriggerDraft.Kind.Daily, now)
        assertEquals(setOf(2, 4), back.weekdays)
        assertEquals(18 to 45, back.hour to back.minute)
        // RRULE 换回每月：BYMONTHDAY、BYHOUR 拿过来。
        val monthly = asRrule.copy(rruleText = "FREQ=MONTHLY;BYMONTHDAY=3,20;BYHOUR=6").withKind(TriggerDraft.Kind.Monthly, now)
        assertEquals(setOf(3, 20), monthly.monthDays)
        assertEquals(6, monthly.hour)
        // 换成一次性：时间已经过去了，改成下一个这个时刻。
        val past = weekly.copy(onceAtMs = now - 1000).withKind(TriggerDraft.Kind.Once, now)
        assertEquals(1_792_976_400_000L - 2 * 3_600_000L, past.onceAtMs)
        // 每周没选日子时补一个周一。
        assertEquals(setOf(1), TriggerDraft.new(shanghai, now).copy(weekdays = emptySet()).withKind(TriggerDraft.Kind.Weekly, now).weekdays)
    }

    @Test
    fun problemsMatchTheServerRules() {
        val d = TriggerDraft.new(shanghai, now)
        assertEquals(TriggerProblem.OnceInPast, d.copy(kind = TriggerDraft.Kind.Once, onceAtMs = now).problem(now))
        assertEquals(TriggerProblem.UnknownTimeZone, d.copy(timeZoneId = "Mars/Olympus").problem(now))
        assertEquals(TriggerProblem.NoWeekdays, d.copy(kind = TriggerDraft.Kind.Weekly, weekdays = emptySet()).problem(now))
        val cron = d.copy(kind = TriggerDraft.Kind.Cron)
        assertEquals(TriggerProblem.CronEmpty, cron.copy(cronExpression = "  ").problem(now))
        assertEquals(TriggerProblem.CronFieldCount, cron.copy(cronExpression = "0 9 * *").problem(now))
        assertEquals(TriggerProblem.CronInvalid, cron.copy(cronExpression = "0 25 * * *").problem(now))
        assertEquals(TriggerProblem.TooFrequent(5), cron.copy(cronExpression = "* * * * *").problem(now))
        assertNull(cron.copy(cronExpression = "*/5 * * * *").problem(now))
        assertEquals(TriggerProblem.NeverFires, cron.copy(cronExpression = "0 9 30 2 *").problem(now))
        // 算不了的写法交给服务端：不拦，只提示。
        val lastDay = cron.copy(cronExpression = "0 9 L * *")
        assertNull(lastDay.problem(now))
        assertTrue(lastDay.cannotPreview)
        val rrule = d.copy(kind = TriggerDraft.Kind.Rrule)
        assertEquals(TriggerProblem.RruleEmpty, rrule.copy(rruleText = "").problem(now))
        assertEquals(TriggerProblem.RruleNoFrequency, rrule.copy(rruleText = "BYDAY=MO").problem(now))
        assertEquals(TriggerProblem.RruleTooFrequent, rrule.copy(rruleText = "FREQ=SECONDLY").problem(now))
        assertEquals(TriggerProblem.TooFrequent(5), rrule.copy(rruleText = "FREQ=MINUTELY").problem(now))
        assertEquals(TriggerProblem.TooFrequent(5), rrule.copy(rruleText = "FREQ=MINUTELY;INTERVAL=2").problem(now))
        assertNull(rrule.copy(rruleText = "FREQ=MINUTELY;INTERVAL=5").problem(now))
        assertEquals(TriggerProblem.RruleStartOutOfRange, rrule.copy(startDay = LocalDate.of(2026, 10, 20)).problem(now))
        assertEquals(
            TriggerProblem.RruleExtraDates,
            rrule.copy(rruleText = "DTSTART;TZID=Asia/Shanghai:20261026T090000\nRRULE:FREQ=DAILY\nRDATE:20261101T090000Z").problem(now),
        )
        assertEquals(
            TriggerProblem.RruleMultipleRules,
            rrule.copy(rruleText = "DTSTART;TZID=Asia/Shanghai:20261026T090000\nRRULE:FREQ=DAILY\nRRULE:FREQ=WEEKLY").problem(now),
        )
        assertEquals(TriggerProblem.RruleNoTimeZone, rrule.copy(rruleText = "DTSTART:20261026T090000\nRRULE:FREQ=DAILY").problem(now))
        assertEquals(TriggerProblem.RruleTooLong(1000), rrule.copy(rruleText = "FREQ=DAILY;" + "X".repeat(1000)).problem(now))
        assertNull(rrule.copy(rruleText = "rrule:freq=weekly; byday=mo").problem(now))
        assertEquals(TriggerProblem.TooFrequent(5), rrule.copy(rruleText = "FREQ=HOURLY;BYMINUTE=0,1").problem(now))
    }
}
