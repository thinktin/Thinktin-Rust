package cn.thinktin.app.ui.usage

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.UsageBucket
import cn.thinktin.data.model.UsageGroup
import cn.thinktin.data.model.UsageSummary
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/** 时间段：今天、最近 7 天、最近 30 天（都含今天）、自定义（按天，含首尾）。 */
enum class UsageRange(val days: Long) {
    Today(1),
    Week(7),
    Month(30),
    Custom(0),
}

/** 一段时间（含首尾两天，设备时区）。 */
data class DateSpan(val start: LocalDate, val end: LocalDate) {
    val days: Long get() = ChronoUnit.DAYS.between(start, end) + 1
}

/** 按天的一根柱子：没有用量的天也有（高度 0）。 */
data class DayBar(val date: LocalDate, val bucket: UsageBucket?) {
    val tokens: Long get() = bucket?.chargedTokens ?: 0
}

/**
 * 表格的一行。[name] 是解析出来的名字（实例名、key 标签、模型），解析不了时为 null，界面显示 [UsageBucket.key]；
 * [vendor] 是厂商显示名（按模型、按 key 时），[last4] 是 key 的后 4 位。按天时 [date] 是那一天。
 */
data class UsageRow(
    val bucket: UsageBucket,
    val name: String? = null,
    val vendor: String? = null,
    val last4: String? = null,
    val date: LocalDate? = null,
    /** 实例已经删除、key 已经删除（名字表里找不到）。 */
    val gone: Boolean = false,
)

data class UsageUiState(
    val range: UsageRange = UsageRange.Week,
    val group: UsageGroup = UsageGroup.Day,
    /** 当前查询的日期范围。 */
    val span: DateSpan? = null,
    /** 自定义时间段的选择面板开着。 */
    val pickingCustom: Boolean = false,
    val loading: Boolean = true,
    val error: UiText? = null,
    val summary: UsageSummary? = null,
    val rows: List<UsageRow> = emptyList(),
    /** 按天时的柱子（时间段内每天一根）。 */
    val bars: List<DayBar> = emptyList(),
)

/**
 * 用量看板（13.4，路由 usage）：时间段（今天 / 7 天 / 30 天 / 自定义）× 分组（按天 / 实例 / 模型 / key），
 * 总计卡片 + 按天柱状图 / 其他分组的表格。按设备时区切天（usage 的 tz 参数）。
 * 实例名、key 标签、厂商名只用来显示，拉不到就显示 id。
 */
class UsageViewModel(
    private val service: ThinktinService,
    private val clock: Clock,
) : ViewModel() {
    private val state = MutableStateFlow(UsageUiState())
    val uiState: StateFlow<UsageUiState> = state.asStateFlow()

    private var instances: Map<String, Instance>? = null
    private var credentials: Map<String, Credential>? = null
    private var vendors: Map<String, VendorInfo>? = null
    private var customSpan: DateSpan? = null
    private var job: Job? = null

    init {
        load()
    }

    val today: LocalDate get() = LocalDate.now(clock)

    fun selectGroup(group: UsageGroup) {
        if (group == state.value.group) return
        state.update { it.copy(group = group) }
        load()
    }

    fun selectRange(range: UsageRange) {
        if (range == UsageRange.Custom) {
            state.update { it.copy(pickingCustom = true) }
            return
        }
        state.update { it.copy(range = range, pickingCustom = false) }
        load()
    }

    fun cancelCustom() {
        state.update { it.copy(pickingCustom = false) }
    }

    /**
     * 自定义时间段：[startMs]、[endMs] 是日期选择器给的 UTC 零点毫秒（只取日期）。结束不能晚于今天，最多 366 天。
     * 返回错误文案（不合法时）或 null（已应用）。
     */
    fun applyCustom(startMs: Long?, endMs: Long?): UiText? {
        if (startMs == null) return UiText(R.string.usage_custom_pick)
        val start = utcDate(startMs)
        val end = endMs?.let { utcDate(it) } ?: start
        val error = checkSpan(DateSpan(start, end))
        if (error != null) return error
        customSpan = DateSpan(start, end)
        state.update { it.copy(range = UsageRange.Custom, pickingCustom = false) }
        load()
        return null
    }

    private fun checkSpan(span: DateSpan): UiText? = when {
        span.end.isBefore(span.start) -> UiText(R.string.usage_custom_order)
        span.end.isAfter(today) -> UiText(R.string.usage_custom_future)
        span.days > MAX_DAYS -> UiText(R.string.usage_custom_too_long, listOf(MAX_DAYS.toInt()))
        else -> null
    }

    /** 当前时间段的日期范围（含首尾）；[today] 是按查询用的时区算的今天。 */
    fun spanOf(range: UsageRange, today: LocalDate = this.today): DateSpan = when (range) {
        UsageRange.Custom -> customSpan ?: DateSpan(today.minusDays(6), today)
        else -> DateSpan(today.minusDays(range.days - 1), today)
    }

    fun load() {
        val s = state.value
        // 时区每次查询时取（时钟跟着系统时区走，App 活着时换了时区也按新的切天），今天、起止、tz 参数用同一个。
        val zone = clock.zone
        val now = clock.instant()
        val span = spanOf(s.range, now.atZone(zone).toLocalDate())
        val fromMs = span.start.atStartOfDay(zone).toInstant().toEpochMilli()
        // 结束是第二天零点，但不超过现在（服务端要求 from < to），
        // 也不超过 366 × 24 小时（跨夏令时回拨时 366 个日历天会多出一小时，服务端按时长拒绝）。
        val endOfSpan = span.end.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val toMs = minOf(endOfSpan, now.toEpochMilli(), fromMs + MAX_DAYS * DAY_MS).coerceAtLeast(fromMs + 1)
        val group = s.group
        state.update { it.copy(loading = true, error = null, span = span) }
        job?.cancel()
        job = viewModelScope.launch {
            try {
                coroutineScope {
                    val names = async { loadNames(group) }
                    val summary = service.usage(group, fromMs, toMs, zone.id)
                    names.await()
                    state.update { it.copy(loading = false, summary = summary, rows = rowsOf(group, summary), bars = barsOf(group, span, summary)) }
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, error = ErrorText.of(e)) }
            }
        }
    }

    /** 按实例、key、模型分组时取一次名字表（失败不影响：显示 id）。 */
    private suspend fun loadNames(group: UsageGroup) {
        try {
            when (group) {
                UsageGroup.Instance -> if (instances == null) instances = service.instances().associateBy { it.id }
                UsageGroup.Credential -> {
                    if (credentials == null) credentials = service.credentials().associateBy { it.id }
                    if (vendors == null) vendors = service.vendors().associateBy { it.id }
                }
                UsageGroup.Model -> if (vendors == null) vendors = service.vendors().associateBy { it.id }
                UsageGroup.Day -> Unit
            }
        } catch (_: ServiceError) {
            // 名字只是锦上添花。
        }
    }

    private fun rowsOf(group: UsageGroup, summary: UsageSummary): List<UsageRow> = when (group) {
        // 按天：新的在前。
        UsageGroup.Day -> summary.buckets
            .map { UsageRow(it, date = parseDate(it.key)) }
            .sortedByDescending { it.date ?: LocalDate.MIN }
        UsageGroup.Instance -> summary.buckets.map { bucket ->
            val known = instances
            val instance = known?.get(bucket.key)
            UsageRow(bucket, name = instance?.name, gone = known != null && instance == null)
        }.sortedByDescending { it.bucket.chargedTokens }
        UsageGroup.Credential -> summary.buckets.map { bucket ->
            val known = credentials
            val credential = known?.get(bucket.key)
            UsageRow(
                bucket,
                name = credential?.let { it.label.ifBlank { vendorName(it.vendor) } },
                vendor = credential?.let { vendorName(it.vendor) },
                last4 = credential?.last4,
                // key 为空：请求一把 key 都没用上（都停用了、额度用完了）。
                gone = known != null && credential == null && bucket.key.isNotEmpty(),
            )
        }.sortedByDescending { it.bucket.chargedTokens }
        // 模型：key 是“厂商/模型”，厂商换成显示名。
        UsageGroup.Model -> summary.buckets.map { bucket ->
            val vendor = bucket.key.substringBefore('/', missingDelimiterValue = "")
            val model = bucket.key.substringAfter('/')
            UsageRow(bucket, name = model, vendor = vendor.takeIf { it.isNotEmpty() }?.let { vendorName(it) })
        }.sortedByDescending { it.bucket.chargedTokens }
    }

    private fun vendorName(id: String): String = vendors?.get(id)?.name ?: id

    companion object {
        /** 服务端一次最多查 366 天。 */
        const val MAX_DAYS = 366L

        private const val DAY_MS = 86_400_000L

        private fun utcDate(ms: Long): LocalDate =
            java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneOffset.UTC).toLocalDate()

        fun parseDate(key: String): LocalDate? = try {
            LocalDate.parse(key.take(10))
        } catch (_: Exception) {
            null
        }

        /** 按天时把时间段内每天都排上（没有用量的天高度为 0）；其他分组没有柱子。 */
        fun barsOf(group: UsageGroup, span: DateSpan, summary: UsageSummary): List<DayBar> {
            if (group != UsageGroup.Day) return emptyList()
            val byDate = summary.buckets.mapNotNull { b -> parseDate(b.key)?.let { it to b } }.toMap()
            return (0 until span.days).map { offset ->
                val date = span.start.plusDays(offset)
                DayBar(date, byDate[date])
            }
        }
    }
}
