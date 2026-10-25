package cn.thinktin.app.ui.plans

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimeInput
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.ui.chat.BottomPanel
import cn.thinktin.data.schedule.ScheduleForecast
import cn.thinktin.data.schedule.TriggerDraft
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

const val TRIGGER_SHEET_TEST_TAG = "trigger-sheet"
const val TRIGGER_KIND_TEST_TAG = "trigger-kind-"

/** 触发规则编辑面板的操作。 */
data class TriggerEditorActions(
    val onKind: (TriggerDraft.Kind) -> Unit,
    val onChange: ((TriggerDraft) -> TriggerDraft) -> Unit,
    val onApply: () -> Unit,
    val onDismiss: () -> Unit,
)

/**
 * 编一条触发规则（13.6）：常用写法（每天、每周几、每月几号、一次性）和高级的 cron、RRULE，时区默认设备的；
 * 下面预览接下来几次（按设备时区显示），App 算不了的写法只说“保存时由服务端检查”。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun TriggerEditorSheet(
    editing: TriggerEditing,
    deviceZone: ZoneId,
    nowMs: Long,
    actions: TriggerEditorActions,
) {
    val draft = editing.draft
    BottomPanel(
        title = stringResource(if (editing.itemId == null) R.string.trigger_add_title else R.string.trigger_edit_title),
        onDismiss = actions.onDismiss,
        testTag = TRIGGER_SHEET_TEST_TAG,
    ) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TriggerDraft.Kind.entries.forEach { kind ->
                FilterChip(
                    selected = draft.kind == kind,
                    onClick = { actions.onKind(kind) },
                    label = { Text(stringResource(kind.labelRes())) },
                    modifier = Modifier.testTag(TRIGGER_KIND_TEST_TAG + kind.name),
                )
            }
        }
        when (draft.kind) {
            TriggerDraft.Kind.Daily, TriggerDraft.Kind.Weekly, TriggerDraft.Kind.Monthly -> {
                if (draft.kind == TriggerDraft.Kind.Weekly) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        WEEK_ORDER.forEach { day ->
                            FilterChip(
                                selected = day in draft.weekdays,
                                onClick = { actions.onChange { d -> d.copy(weekdays = d.weekdays.toggle(day)) } },
                                label = { Text(weekdayName(day)) },
                            )
                        }
                    }
                }
                if (draft.kind == TriggerDraft.Kind.Monthly) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        (1..31).forEach { day ->
                            FilterChip(
                                selected = day in draft.monthDays,
                                onClick = { actions.onChange { d -> d.copy(monthDays = d.monthDays.toggle(day)) } },
                                label = { Text(day.toString()) },
                            )
                        }
                    }
                    Hint(stringResource(R.string.trigger_month_days_hint))
                }
                TimeField(editing, draft.hour, draft.minute) { h, m -> actions.onChange { it.copy(hour = h, minute = m) } }
                ZoneField(draft, deviceZone, actions)
            }
            TriggerDraft.Kind.Once -> {
                val local = Instant.ofEpochMilli(draft.onceAtMs).atZone(deviceZone)
                DateField(editing, local.toLocalDate()) { date ->
                    actions.onChange { it.withOnce(date, local.hour, local.minute, deviceZone) }
                }
                TimeField(editing, local.hour, local.minute) { h, m ->
                    actions.onChange { it.withOnce(local.toLocalDate(), h, m, deviceZone) }
                }
            }
            TriggerDraft.Kind.Cron -> {
                OutlinedTextField(
                    value = draft.cronExpression,
                    onValueChange = { v -> actions.onChange { it.copy(cronExpression = v) } },
                    label = { Text(stringResource(R.string.trigger_cron_label)) },
                    supportingText = { Text(stringResource(R.string.trigger_cron_hint)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
                    modifier = Modifier.fillMaxWidth(),
                )
                ZoneField(draft, deviceZone, actions)
            }
            TriggerDraft.Kind.Rrule -> {
                OutlinedTextField(
                    value = draft.rruleText,
                    onValueChange = { v -> actions.onChange { it.copy(rruleText = v) } },
                    label = { Text(stringResource(R.string.trigger_rrule_label)) },
                    supportingText = { Text(stringResource(R.string.trigger_rrule_hint)) },
                    minLines = 2,
                    keyboardOptions = KeyboardOptions(
                        autoCorrectEnabled = false,
                        capitalization = KeyboardCapitalization.Characters,
                        keyboardType = KeyboardType.Ascii,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (draft.rruleHasOwnStart) {
                    Hint(stringResource(R.string.trigger_rrule_own_start))
                } else {
                    Text(stringResource(R.string.trigger_rrule_start), style = MaterialTheme.typography.labelLarge)
                    DateField(editing, draft.startDay) { date -> actions.onChange { it.copy(startDay = date) } }
                    TimeField(editing, draft.hour, draft.minute) { h, m -> actions.onChange { it.copy(hour = h, minute = m) } }
                    ZoneField(draft, deviceZone, actions)
                }
            }
        }
        Preview(draft, deviceZone, nowMs)
        editing.problem?.let { problem ->
            Text(
                problem.message(),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph)) {
            SecondaryButton(text = stringResource(R.string.action_cancel), onClick = actions.onDismiss, modifier = Modifier.weight(1f))
            PrimaryButton(text = stringResource(R.string.trigger_apply), onClick = actions.onApply, modifier = Modifier.weight(1f))
        }
    }
}

/** 一次性的时间：按设备时区的日期 + 时刻（夏令时跳过的时刻挪到跳过之后）。 */
fun TriggerDraft.withOnce(date: LocalDate, hour: Int, minute: Int, zone: ZoneId): TriggerDraft {
    val at = ScheduleForecast.localInstant(date, hour, minute, 0, zone, fixedTime = true) ?: return this
    return copy(onceAtMs = at.toEpochMilli(), hour = hour, minute = minute)
}

private fun Set<Int>.toggle(value: Int): Set<Int> = if (value in this) this - value else this + value

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** 时刻（24 小时制）。换写法、换一条规则时重建，跟着草稿里的值。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeField(editing: TriggerEditing, hour: Int, minute: Int, onChange: (Int, Int) -> Unit) {
    val state = remember(editing.itemId, editing.draft.kind) { rememberTimeState(hour, minute) }
    LaunchedEffect(state.hour, state.minute) {
        if (state.hour != hour || state.minute != minute) onChange(state.hour, state.minute)
    }
    val label = stringResource(R.string.trigger_time)
    Column(Modifier.semantics { contentDescription = label }) {
        Text(label, style = MaterialTheme.typography.labelLarge)
        TimeInput(state = state)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
private fun rememberTimeState(hour: Int, minute: Int) =
    androidx.compose.material3.TimePickerState(initialHour = hour, initialMinute = minute, is24Hour = true)

/** 日期（日历选择，不带输入模式：输入框在测试里不好用，日历够了）。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateField(editing: TriggerEditing, date: LocalDate, onChange: (LocalDate) -> Unit) {
    val initial = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val state = rememberDatePickerState(initialSelectedDateMillis = initial)
    LaunchedEffect(editing.itemId, editing.draft.kind) { state.selectedDateMillis = initial }
    LaunchedEffect(state.selectedDateMillis) {
        val picked = state.selectedDateMillis?.let { Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
        if (picked != null && picked != date) onChange(picked)
    }
    DatePicker(state = state, showModeToggle = false, title = null, headline = null)
}

/** 规则的时区（IANA 名称）：默认设备的，可以改；“用设备时区”一键改回。 */
@Composable
private fun ZoneField(draft: TriggerDraft, deviceZone: ZoneId, actions: TriggerEditorActions) {
    OutlinedTextField(
        value = draft.timeZoneId,
        onValueChange = { v -> actions.onChange { it.copy(timeZoneId = v.trim()) } },
        label = { Text(stringResource(R.string.trigger_time_zone)) },
        isError = ScheduleForecast.zone(draft.timeZoneId) == null,
        singleLine = true,
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
        modifier = Modifier.fillMaxWidth(),
    )
    if (draft.timeZoneId != deviceZone.id) {
        TextButton(onClick = { actions.onChange { it.copy(timeZoneId = deviceZone.id) } }) {
            Text(stringResource(R.string.trigger_use_device_zone, deviceZone.id))
        }
    }
}

/** 接下来几次（按设备时区显示）；App 算不了的写法、不会再触发的分别说明。 */
@Composable
private fun Preview(draft: TriggerDraft, deviceZone: ZoneId, nowMs: Long) {
    val fires = draft.upcoming(nowMs)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(stringResource(R.string.trigger_upcoming), style = MaterialTheme.typography.labelLarge)
        when {
            fires == null -> Hint(stringResource(R.string.trigger_cannot_preview))
            fires.isEmpty() -> Hint(stringResource(R.string.trigger_problem_never_fires))
            else -> fires.forEach { Hint(dateTimeText(it, deviceZone)) }
        }
    }
}

