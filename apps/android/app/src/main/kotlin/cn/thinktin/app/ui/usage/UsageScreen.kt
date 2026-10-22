package cn.thinktin.app.ui.usage

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DateRangePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberDateRangePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.TokenFormat
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.formatTokens
import cn.thinktin.data.model.UsageBucket
import cn.thinktin.data.model.UsageGroup
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.LocalDate
import java.time.ZoneOffset

/** 测试用：柱状图的 testTag。 */
const val USAGE_CHART_TEST_TAG = "usage-chart"

/** 测试用：表格行的 testTag 前缀（后接 bucket 的 key）。 */
const val USAGE_ROW_TEST_TAG = "usage-row-"

/** 用量看板（第 4.5 节，路由 usage）。入口：设置页“用量”、key 列表顶栏。 */
@Composable
fun UsageScreen(onBack: () -> Unit) {
    val service = LocalThinktinService.current
    val container = LocalAppContainer.current
    val viewModel: UsageViewModel = viewModel(
        factory = viewModelFactory { initializer { UsageViewModel(service, container.clock) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_usage),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            ChipRow(
                label = stringResource(R.string.usage_range),
                options = UsageRange.entries.map { it to stringResource(rangeLabel(it)) },
                selected = if (state.pickingCustom) UsageRange.Custom else state.range,
                onSelect = viewModel::selectRange,
            )
            ChipRow(
                label = stringResource(R.string.usage_group),
                options = UsageGroup.entries.map { it to stringResource(groupLabel(it)) },
                selected = state.group,
                onSelect = viewModel::selectGroup,
            )
            if (state.pickingCustom) {
                CustomRangePanel(viewModel = viewModel, modifier = Modifier.weight(1f))
            } else {
                UsageContent(state = state, onRetry = viewModel::load, modifier = Modifier.weight(1f))
            }
        }
    }
}

private fun rangeLabel(range: UsageRange): Int = when (range) {
    UsageRange.Today -> R.string.usage_range_today
    UsageRange.Week -> R.string.usage_range_week
    UsageRange.Month -> R.string.usage_range_month
    UsageRange.Custom -> R.string.usage_range_custom
}

private fun groupLabel(group: UsageGroup): Int = when (group) {
    UsageGroup.Day -> R.string.usage_group_day
    UsageGroup.Instance -> R.string.usage_group_instance
    UsageGroup.Model -> R.string.usage_group_model
    UsageGroup.Credential -> R.string.usage_group_credential
}

/** 一排单选的小标签（时间段、分组），放不下时横向滚动。 */
@Composable
private fun <T> ChipRow(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = ThinktinSpacing.Page)
            .selectableGroup()
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { (value, text) ->
            FilterChip(
                selected = value == selected,
                onClick = { onSelect(value) },
                label = { Text(text) },
                modifier = Modifier.semantics { role = Role.RadioButton },
            )
        }
    }
}

@Composable
private fun formatDate(date: LocalDate): String = stringResource(R.string.usage_date, date.monthValue, date.dayOfMonth)

@Composable
private fun UsageContent(state: UsageUiState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxWidth()) {
        val summary = state.summary
        when {
            state.loading && summary == null -> {
                val label = stringResource(R.string.loading)
                CircularProgressIndicator(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .semantics { contentDescription = label },
                )
            }
            state.error != null && summary == null -> EmptyState(
                title = stringResource(R.string.usage_load_failed),
                message = state.error.asString(),
                actionLabel = stringResource(R.string.action_retry),
                onAction = onRetry,
                modifier = Modifier.align(Alignment.Center),
            )
            summary != null -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                item {
                    state.span?.let { span ->
                        val text = if (span.start == span.end) {
                            formatDate(span.start)
                        } else {
                            stringResource(R.string.usage_span, formatDate(span.start), formatDate(span.end))
                        }
                        Text(
                            text = text,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                        )
                    }
                }
                if (state.loading) {
                    item {
                        val label = stringResource(R.string.loading)
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                        }
                    }
                }
                state.error?.let { error ->
                    item {
                        Text(
                            text = error.asString(),
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier
                                .padding(horizontal = ThinktinSpacing.Page)
                                .semantics { liveRegion = LiveRegionMode.Polite },
                        )
                    }
                }
                item { TotalCard(summary.total) }
                if (state.group == UsageGroup.Day && state.bars.isNotEmpty()) {
                    item { DayChart(state.bars) }
                }
                item {
                    SectionHeader(
                        title = stringResource(groupTitle(state.group)),
                        modifier = Modifier.padding(start = ThinktinSpacing.Page, end = ThinktinSpacing.Page, top = 12.dp),
                    )
                }
                if (state.rows.isEmpty()) {
                    item {
                        Text(
                            text = stringResource(R.string.usage_empty),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(ThinktinSpacing.Page),
                        )
                    }
                } else {
                    item { TableHeader(state.group) }
                    items(state.rows, key = { it.bucket.key }) { row -> UsageTableRow(row, state.group) }
                }
            }
        }
    }
}

private fun groupTitle(group: UsageGroup): Int = when (group) {
    UsageGroup.Day -> R.string.usage_table_day
    UsageGroup.Instance -> R.string.usage_table_instance
    UsageGroup.Model -> R.string.usage_table_model
    UsageGroup.Credential -> R.string.usage_table_credential
}

/** 总计：请求数、记账 token、输入、输出、缓存读写、估算的请求、失败的请求。 */
@Composable
private fun TotalCard(total: UsageBucket) {
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ThinktinSpacing.Page),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = stringResource(R.string.usage_total),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            val cells = listOf(
                R.string.usage_requests to TokenOrCount.Count(total.requests),
                R.string.usage_charged to TokenOrCount.Tokens(total.chargedTokens),
                R.string.usage_input to TokenOrCount.Tokens(total.inputTokens),
                R.string.usage_output to TokenOrCount.Tokens(total.outputTokens),
                R.string.usage_cache_read to TokenOrCount.Tokens(total.cacheReadTokens),
                R.string.usage_cache_write to TokenOrCount.Tokens(total.cacheWriteTokens),
                R.string.usage_estimated to TokenOrCount.Count(total.estimatedRequests),
                R.string.usage_failed to TokenOrCount.Count(total.failedRequests),
            )
            cells.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    pair.forEach { (label, value) -> Stat(stringResource(label), value, Modifier.weight(1f)) }
                }
            }
            if (total.estimatedRequests > 0) {
                Text(
                    text = stringResource(R.string.usage_estimated_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** 数字是 token（按第 5 节缩写）还是次数（千分位）。 */
private sealed interface TokenOrCount {
    data class Tokens(val value: Long) : TokenOrCount

    data class Count(val value: Long) : TokenOrCount
}

@Composable
private fun TokenOrCount.text(): String = when (this) {
    is TokenOrCount.Tokens -> formatTokens(value)
    is TokenOrCount.Count -> TokenFormat.grouped(value)
}

@Composable
private fun Stat(label: String, value: TokenOrCount, modifier: Modifier = Modifier) {
    val text = value.text()
    val description = stringResource(R.string.usage_stat_a11y, label, text)
    Column(modifier = modifier.clearAndSetSemantics { contentDescription = description }) {
        Text(text = label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text = text, style = MaterialTheme.typography.titleLarge)
    }
}

/**
 * 按天的柱状图（记账 token）：Compose Canvas，柱子用主色，没有用量的天画一条描边色的底线。
 * 读屏读一句汇总（天数、最多的一天）。
 */
@Composable
private fun DayChart(bars: List<DayBar>) {
    val primary = MaterialTheme.colorScheme.primary
    val outline = MaterialTheme.colorScheme.outline
    val max = bars.maxOf { it.tokens }
    val peak = bars.maxByOrNull { it.tokens }
    val description = if (peak == null || max == 0L) {
        stringResource(R.string.usage_chart_empty_a11y, bars.size)
    } else {
        stringResource(R.string.usage_chart_a11y, bars.size, formatDate(peak.date), formatTokens(max))
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ThinktinSpacing.Page, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = stringResource(R.string.usage_chart_title, formatTokens(max)),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .height(140.dp)
                .testTag(USAGE_CHART_TEST_TAG)
                .clearAndSetSemantics { contentDescription = description },
        ) {
            val slot = size.width / bars.size
            val barWidth = (slot * 0.7f).coerceAtLeast(1f)
            val baseline = size.height
            bars.forEachIndexed { i, bar ->
                val x = i * slot + (slot - barWidth) / 2
                if (bar.tokens > 0 && max > 0) {
                    val h = (bar.tokens.toFloat() / max * baseline).coerceAtLeast(2f)
                    drawRoundRect(
                        color = primary,
                        topLeft = Offset(x, baseline - h),
                        size = Size(barWidth, h),
                        cornerRadius = CornerRadius(minOf(barWidth / 2, 4.dp.toPx())),
                    )
                } else {
                    drawRect(color = outline, topLeft = Offset(x, baseline - 2f), size = Size(barWidth, 2f))
                }
            }
            drawLine(color = outline, start = Offset(0f, baseline), end = Offset(size.width, baseline), strokeWidth = 1.dp.toPx())
        }
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = formatDate(bars.first().date),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            if (bars.size > 1) {
                Text(
                    text = formatDate(bars.last().date),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun TableHeader(group: UsageGroup) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
    ) {
        val style = MaterialTheme.typography.labelMedium
        val color = MaterialTheme.colorScheme.onSurfaceVariant
        Text(stringResource(groupLabel(group)), style = style, color = color, modifier = Modifier.weight(1f))
        Text(stringResource(R.string.usage_charged), style = style, color = color)
    }
}

/** 表格的一行：名字（按天是日期）+ 记账 token；下面一行是请求、输入、输出、缓存、失败。 */
@Composable
private fun UsageTableRow(row: UsageRow, group: UsageGroup) {
    val b = row.bucket
    val name = when {
        group == UsageGroup.Day -> row.date?.let { formatDate(it) } ?: b.key
        row.gone && group == UsageGroup.Instance -> stringResource(R.string.usage_instance_gone, b.key)
        row.gone && group == UsageGroup.Credential -> stringResource(R.string.usage_credential_gone)
        else -> row.name ?: b.key
    }
    val sub = when (group) {
        UsageGroup.Credential -> row.vendor?.let { vendor -> row.last4?.let { stringResource(R.string.keys_vendor_last4, vendor, it) } }
        UsageGroup.Model -> row.vendor
        else -> null
    }
    val details = stringResource(
        R.string.usage_row_details,
        TokenFormat.grouped(b.requests),
        formatTokens(b.inputTokens),
        formatTokens(b.outputTokens),
        formatTokens(b.cacheReadTokens + b.cacheWriteTokens),
    )
    Column(
        modifier = Modifier
            .testTag(USAGE_ROW_TEST_TAG + b.key)
            .semantics(mergeDescendants = true) {},
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                // 实例名、key 标签是用户起的，模型名是厂商的：都不标 AI 生成。
                Text(text = name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                sub?.let {
                    Text(text = it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(text = details, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (b.failedRequests > 0) {
                    Text(
                        text = stringResource(R.string.usage_row_failed, TokenFormat.grouped(b.failedRequests)),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
            Text(
                text = formatTokens(b.chargedTokens),
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Medium),
            )
        }
        HorizontalDivider(modifier = Modifier.padding(horizontal = ThinktinSpacing.Page), color = MaterialTheme.colorScheme.outline)
    }
}

/**
 * 自定义时间段：页面里的日期范围选择（不是对话框）；只能选今天及以前，最多 366 天。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CustomRangePanel(viewModel: UsageViewModel, modifier: Modifier = Modifier) {
    val todayUtcMs = viewModel.today.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val pickerState = rememberDateRangePickerState(
        selectableDates = object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long): Boolean = utcTimeMillis <= todayUtcMs
        },
    )
    var error by remember { mutableStateOf<UiText?>(null) }
    Column(modifier = modifier.fillMaxWidth()) {
        DateRangePicker(
            state = pickerState,
            showModeToggle = false,
            title = null,
            modifier = Modifier.weight(1f),
        )
        error?.let {
            Text(
                text = it.asString(),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier
                    .padding(horizontal = ThinktinSpacing.Page)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(ThinktinSpacing.Page),
            horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End),
        ) {
            SecondaryButton(text = stringResource(R.string.action_cancel), onClick = viewModel::cancelCustom)
            PrimaryButton(
                text = stringResource(R.string.usage_custom_apply),
                onClick = {
                    error = viewModel.applyCustom(pickerState.selectedStartDateMillis, pickerState.selectedEndDateMillis)
                },
            )
        }
    }
}
