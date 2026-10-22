package cn.thinktin.app.ui.chat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.automirrored.outlined.EventNote
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Timelapse
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.app.ui.common.WaitText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.formatTokens
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.data.model.HistoryGap
import cn.thinktin.data.model.PlanEntry
import cn.thinktin.data.model.PromptAuthor
import cn.thinktin.data.model.RunBlock
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.SystemLine
import cn.thinktin.data.model.TimelineItem
import cn.thinktin.data.model.ToolCallState
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.MarkdownText
import cn.thinktin.design.component.MessageBubble
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.ToolCallCard
import cn.thinktin.design.component.ToolCallStatus
import cn.thinktin.design.component.aiGeneratedLabel
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinTheme

const val CHAT_RUN_HEADER_TEST_TAG = "chat-run-header-"
const val CHAT_AGENT_TEXT_TEST_TAG = "chat-agent-text"
const val CHAT_USER_PROMPT_TEST_TAG = "chat-user-prompt"
const val CHAT_VAULT_REQUEST_TEST_TAG = "chat-vault-request-"
const val CHAT_ARTIFACT_TEST_TAG = "chat-artifact-"
const val CHAT_SYSTEM_TEST_TAG = "chat-system"

/** 耗时的文字（秒 / 分秒 / 时分）。 */
@Composable
fun durationText(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return when {
        h > 0 -> stringResource(R.string.chat_duration_hours, h.toInt(), m.toInt())
        m > 0 -> stringResource(R.string.chat_duration_minutes, m.toInt(), s.toInt())
        else -> stringResource(R.string.chat_duration_seconds, s.toInt())
    }
}

fun RunSource.labelRes(): Int = when (this) {
    RunSource.User -> R.string.chat_source_user
    RunSource.Plan -> R.string.chat_source_plan
    RunSource.Pipeline -> R.string.chat_source_pipeline
    RunSource.Delegate -> R.string.chat_source_delegate
    RunSource.Unknown -> R.string.chat_source_unknown
}

/** 运行区块头：来源 · 状态 · 耗时 · token（第 4.3 节）。点进运行详情。 */
@Composable
fun RunHeaderRow(block: RunBlock, nowMs: Long, onOpenRun: (String) -> Unit) {
    val stateLabel = stringResource(block.state.labelRes())
    val parts = buildList {
        add(stringResource((block.run?.source ?: RunSource.Unknown).labelRes()))
        add(stateLabel)
        block.run?.durationMs(nowMs)?.let { add(durationText(it)) }
        block.run?.tokensUsed?.takeIf { it > 0 }?.let { add(stringResource(R.string.chat_block_tokens, formatTokens(it))) }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .clickable(role = Role.Button, onClickLabel = stringResource(R.string.page_run)) { onOpenRun(block.runId) }
            .padding(vertical = 6.dp)
            .testTag(CHAT_RUN_HEADER_TEST_TAG + block.runId)
            .semantics { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusDot(block.state)
        Text(
            text = parts.joinToString(" · "),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Icon(
            Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** 用户那句话：自己说的是右侧气泡；计划 / 流水线 / 委派触发的标出来源，agent 写的标 AI 生成、不显示成“你”。 */
@Composable
fun PromptRow(item: TimelineItem.Prompt) {
    if (item.author == PromptAuthor.User) {
        MessageBubble(text = item.text, fromUser = true, modifier = Modifier.testTag(CHAT_USER_PROMPT_TEST_TAG))
        return
    }
    val caption = when (item.author) {
        PromptAuthor.Delegate -> R.string.chat_prompt_delegate
        PromptAuthor.Pipeline -> R.string.chat_prompt_pipeline
        PromptAuthor.Plan -> R.string.chat_prompt_plan
        else -> R.string.chat_source_unknown
    }
    Box(Modifier.fillMaxWidth(), contentAlignment = if (item.aiGenerated) Alignment.CenterStart else Alignment.CenterEnd) {
        Surface(
            shape = ThinktinShapes.Bubble,
            color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            modifier = Modifier.widthIn(max = 340.dp),
        ) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    stringResource(caption),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (item.aiGenerated) AiGeneratedLabel()
                Text(item.text, style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

/** agent 的回复：左对齐、无气泡、Markdown；长按复制（末尾追加 AI 生成标识）。 */
@Composable
fun AgentTextRow(item: TimelineItem.AgentText, streaming: Boolean, onCopied: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    val label = aiGeneratedLabel()
    val suffix = if (item.aiGenerated) label else ""
    val copyLabel = stringResource(R.string.chat_copy_action)
    val copy = {
        clipboard.setText(AnnotatedString(withLabel(item.text, suffix)))
        onCopied()
    }
    // 流式输出时文字一直在变：手势里取最新的。
    val latestCopy by rememberUpdatedState(copy)
    // 长按复制；读屏用自定义操作“复制”。不用 combinedClickable：它会把整段（含代码块、链接）合成一个节点，
    // 还多出一个什么也不做的“点按”。
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(CHAT_AGENT_TEXT_TEST_TAG)
            .pointerInput(item.key) { detectTapGestures(onLongPress = { latestCopy() }) }
            .semantics {
                customActions = listOf(
                    CustomAccessibilityAction(copyLabel) {
                        copy()
                        true
                    },
                )
            },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (item.aiGenerated) AiGeneratedLabel()
        MarkdownText(markdown = item.text, copySuffix = suffix, onCopied = onCopied)
        if (streaming) {
            val replying = stringResource(R.string.chat_streaming)
            CircularProgressIndicator(
                modifier = Modifier
                    .size(14.dp)
                    .semantics { contentDescription = replying },
                strokeWidth = 2.dp,
            )
        }
    }
}

/** 复制 agent 输出时在末尾追加标识（第 8.4 节、docs/compliance.md）。 */
fun withLabel(text: String, label: String): String = if (label.isEmpty()) text else text.trimEnd() + "\n\n" + label

/** 思考过程：默认收起。 */
@Composable
fun ThoughtRow(item: TimelineItem.Thought) {
    var expanded by rememberSaveable(item.key) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .clickable(role = Role.Button) { expanded = !expanded }
                .heightIn(min = 40.dp)
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (item.aiGenerated) AiGeneratedLabel()
            Text(
                stringResource(R.string.chat_thought),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Icon(
                if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                contentDescription = stringResource(if (expanded) cn.thinktin.design.R.string.design_collapse else cn.thinktin.design.R.string.design_expand),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
        if (expanded) {
            Text(
                item.text,
                style = MaterialTheme.typography.bodyMedium.copy(fontStyle = FontStyle.Italic),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

fun ToolCallState.toUi(): ToolCallStatus = when (this) {
    ToolCallState.Pending -> ToolCallStatus.Pending
    ToolCallState.InProgress -> ToolCallStatus.InProgress
    ToolCallState.Completed -> ToolCallStatus.Completed
    ToolCallState.Failed -> ToolCallStatus.Failed
}

@Composable
fun ToolCallRow(item: TimelineItem.ToolCall) {
    ToolCallCard(
        title = item.title ?: item.summary.title ?: item.kind ?: item.toolCallId,
        kind = item.kind,
        status = item.status.toUi(),
        details = item.rawJson.takeIf { it.isNotBlank() },
        summary = item.summary.arguments,
        // 工具调用的标题是 agent 写的（第 8.4 节）。
        aiGenerated = item.title != null || item.summary.title != null,
    )
}

@Composable
fun PlatformToolCallRow(item: TimelineItem.PlatformToolCall) {
    ToolCallCard(
        title = item.title ?: stringResource(R.string.chat_platform_tool, item.name),
        kind = "other",
        status = null,
        details = item.rawJson.takeIf { it.isNotBlank() },
        summary = if (item.title != null) stringResource(R.string.chat_platform_tool, item.name) else null,
        aiGenerated = item.title != null,
    )
}

/** agent 的计划清单。 */
@Composable
fun AgentPlanRow(item: TimelineItem.AgentPlan) {
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (item.aiGenerated) AiGeneratedLabel()
                Text(
                    stringResource(R.string.chat_plan_title),
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.semantics { heading() },
                )
            }
            item.entries.forEach { PlanEntryRow(it) }
        }
    }
}

@Composable
private fun PlanEntryRow(entry: PlanEntry) {
    val status = stringResource(
        when {
            entry.done -> R.string.chat_plan_done
            entry.inProgress -> R.string.chat_plan_in_progress
            else -> R.string.chat_plan_pending
        },
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics(mergeDescendants = true) {},
    ) {
        Icon(
            when {
                entry.done -> Icons.Outlined.CheckCircle
                entry.inProgress -> Icons.Outlined.Timelapse
                else -> Icons.Outlined.RadioButtonUnchecked
            },
            contentDescription = status,
            tint = if (entry.done) ThinktinTheme.extendedColors.success else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Text(
            entry.content,
            style = MaterialTheme.typography.bodyMedium,
            textDecoration = if (entry.done) TextDecoration.LineThrough else null,
            color = if (entry.done) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
        )
    }
}

/** agent 的账号密码填写请求：用途是 agent 写的（标 AI 生成）；待处理的有“填写”“拒绝”。 */
@Composable
fun VaultRequestRow(item: TimelineItem.VaultRequestCard, onFill: () -> Unit, onDecline: () -> Unit) {
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(CHAT_VAULT_REQUEST_TEST_TAG + item.requestId),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.Key, contentDescription = null, modifier = Modifier.size(18.dp))
                Text(
                    stringResource(R.string.chat_vault_request_title, item.name),
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier
                        .weight(1f)
                        .semantics { heading() },
                )
            }
            item.purpose?.let { purpose ->
                AiGeneratedLabel()
                Text(purpose, style = MaterialTheme.typography.bodyMedium)
            }
            if (item.fields.isNotEmpty()) {
                val names = item.fields.map { field ->
                    when (field) {
                        "username" -> stringResource(R.string.chat_vault_field_username)
                        "password" -> stringResource(R.string.chat_vault_field_password)
                        else -> field
                    }
                }
                Text(
                    stringResource(R.string.chat_vault_request_fields, names.joinToString("、")),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(
                stringResource(
                    when (item.status) {
                        VaultRequestStatus.Pending -> R.string.chat_vault_status_pending
                        VaultRequestStatus.Fulfilled -> R.string.chat_vault_status_fulfilled
                        VaultRequestStatus.Declined -> R.string.chat_vault_status_declined
                        VaultRequestStatus.Expired -> R.string.chat_vault_status_expired
                        VaultRequestStatus.Unknown -> R.string.run_state_unknown
                    },
                ),
                style = MaterialTheme.typography.labelMedium,
                color = if (item.status == VaultRequestStatus.Pending) {
                    ThinktinTheme.extendedColors.warning
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
            if (item.status == VaultRequestStatus.Pending) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PrimaryButton(text = stringResource(R.string.chat_vault_fill), onClick = onFill)
                    SecondaryButton(text = stringResource(R.string.chat_vault_decline), onClick = onDecline)
                }
            }
        }
    }
}

@Composable
fun VaultUsedRow(item: TimelineItem.VaultUsed) {
    SmallLine(icon = { Icon(Icons.Outlined.Lock, contentDescription = null, modifier = Modifier.size(14.dp)) }) {
        Text(
            stringResource(R.string.chat_vault_used, item.names.joinToString("、")),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 文件大小（B / KB / MB）。 */
fun formatSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> String.format(java.util.Locale.ROOT, "%.1f KB", bytes / 1024.0)
    else -> String.format(java.util.Locale.ROOT, "%.1f MB", bytes / (1024.0 * 1024.0))
}

/** 产出物卡片：名字（agent 起的，标 AI 生成）、大小、版本；点开下载并打开，右侧分享。下载时只转圈。 */
@Composable
fun ArtifactRow(item: TimelineItem.Artifact, downloading: Boolean, onOpen: () -> Unit, onShare: () -> Unit) {
    val openLabel = stringResource(R.string.chat_artifact_open, item.name)
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(CHAT_ARTIFACT_TEST_TAG + item.artifactId),
    ) {
        Row(
            modifier = Modifier
                .clickable(enabled = !downloading, role = Role.Button, onClickLabel = openLabel, onClick = onOpen)
                .padding(start = 12.dp, top = 8.dp, bottom = 8.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Outlined.Description, contentDescription = null)
            Column(Modifier.weight(1f)) {
                AiGeneratedLabel()
                Text(item.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    text = item.size?.let { stringResource(R.string.chat_artifact_meta, formatSize(it), item.version) }
                        ?: stringResource(R.string.chat_artifact_meta_no_size, item.version),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (downloading) {
                val label = stringResource(R.string.chat_artifact_downloading)
                CircularProgressIndicator(
                    modifier = Modifier
                        .size(24.dp)
                        .semantics { contentDescription = label },
                    strokeWidth = 2.dp,
                )
            } else {
                IconButton(onClick = onShare) {
                    Icon(Icons.Outlined.Share, contentDescription = stringResource(R.string.chat_artifact_share))
                }
            }
        }
    }
}

/** 子运行入口（流水线步骤、委派）：点进运行树。 */
@Composable
fun ChildRunRow(item: TimelineItem.ChildRun, onOpenRun: (String) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClickLabel = stringResource(R.string.chat_child_open)) { onOpenRun(item.childRunId) }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Outlined.AccountTree, contentDescription = null, modifier = Modifier.size(18.dp))
        Column(Modifier.weight(1f)) {
            Text(
                if (item.delegated) {
                    stringResource(R.string.chat_child_delegate, item.to ?: item.instanceId.orEmpty())
                } else {
                    stringResource(R.string.chat_child_pipeline, item.step ?: item.childRunId)
                },
                style = MaterialTheme.typography.bodyMedium,
            )
            item.title?.let { title ->
                // 委派的标题是负责人 agent 写的（第 8.4 节）。
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    AiGeneratedLabel()
                    Text(title, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        Icon(
            Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 运行状态行：等待（带 wait_code 文案）、重试、失败、取消、新的一次尝试。 */
@Composable
fun RunStateRow(item: TimelineItem.RunStateLine) {
    val label = stringResource(item.state.labelRes())
    val text = buildString {
        if (item.newAttempt) append(stringResource(R.string.chat_state_attempt, item.attempt)).append(" · ")
        append(label)
        if (item.state == RunState.WaitingChildren && item.steps != null) {
            append(" · ").append(pluralStringResource(R.plurals.chat_state_steps, item.steps!!, item.steps!!))
        }
        val wait = WaitText.of(item.waitCode)?.asString()
        if (wait != null) append(" · ").append(wait)
    }
    SmallLine(icon = { StatusDot(item.state) }) {
        Column {
            Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            val reason = item.reason
            // waiting_quota 有码时用本地文案；否则 reason 原样（waiting_approval 的是 agent 写的标题）。
            if (reason != null && !(item.state == RunState.WaitingQuota && item.waitCode != null)) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (item.reasonAiGenerated) AiGeneratedLabel()
                    Text(
                        stringResource(R.string.chat_state_reason, reason),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** 计划卡片（agent 建 / 改的计划等确认；取消的只告知）。 */
@Composable
fun PlanCardRow(item: TimelineItem.PlanCard, onOpenPlan: (String) -> Unit) {
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.AutoMirrored.Outlined.EventNote, contentDescription = null, modifier = Modifier.size(18.dp))
                Text(
                    stringResource(
                        when {
                            !item.needsConfirmation -> R.string.chat_plan_cancelled
                            item.change == "created" || item.change == null -> R.string.chat_plan_needs_confirmation
                            else -> R.string.chat_plan_updated
                        },
                    ),
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f),
                )
            }
            item.title?.let { title ->
                // agent 建的计划标题（plan.needs_confirmation.title，第 8.4 节）。
                if (item.needsConfirmation) AiGeneratedLabel()
                Text(title, style = MaterialTheme.typography.bodyMedium)
            }
            if (item.needsConfirmation) {
                PrimaryButton(text = stringResource(R.string.chat_plan_confirm), onClick = { onOpenPlan(item.planId) })
            } else {
                SecondaryButton(text = stringResource(R.string.chat_plan_open), onClick = { onOpenPlan(item.planId) })
            }
        }
    }
}

/** 系统提示行（灰色小字；agent.error 用错误色）。 */
@Composable
fun SystemRow(line: SystemLine) {
    val text = when (line) {
        is SystemLine.AgentError -> line.message?.takeIf { it.isNotBlank() }?.let { stringResource(R.string.chat_sys_agent_error, it) }
            ?: stringResource(R.string.chat_sys_agent_error_plain)
        is SystemLine.SessionLost -> stringResource(R.string.chat_sys_session_lost)
        is SystemLine.Exited -> stringResource(if (line.willRestart) R.string.chat_sys_exited_restart else R.string.chat_sys_exited)
        is SystemLine.LogTruncated -> stringResource(R.string.chat_sys_log_truncated)
        is SystemLine.TurnStopped -> when (line.stopReason) {
            "max_tokens" -> stringResource(R.string.chat_sys_stop_max_tokens)
            "max_turn_requests" -> stringResource(R.string.chat_sys_stop_max_turn_requests)
            "refusal" -> stringResource(R.string.chat_sys_stop_refusal)
            else -> stringResource(R.string.chat_sys_stop_other, line.stopReason)
        }
        is SystemLine.Unknown -> stringResource(R.string.chat_sys_unknown, line.kind)
    }
    val color = if (line.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
    SmallLine(
        icon = {
            Icon(
                if (line.isError) Icons.Outlined.ErrorOutline else Icons.Outlined.Info,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(14.dp),
            )
        },
        modifier = Modifier.testTag(CHAT_SYSTEM_TEST_TAG),
    ) {
        Text(text, style = MaterialTheme.typography.bodySmall, color = color)
    }
}

/** 缺过程记录的运行：说明一句。 */
@Composable
fun GapRow(gap: HistoryGap) {
    SmallLine(icon = { Icon(Icons.Outlined.Info, contentDescription = null, modifier = Modifier.size(14.dp)) }) {
        Text(
            stringResource(if (gap == HistoryGap.Expired) R.string.chat_history_expired else R.string.chat_history_missing),
            style = MaterialTheme.typography.bodySmall.copy(fontStyle = FontStyle.Italic),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 运行的结果：摘要（agent 写的，标 AI 生成）、失败原因（平台诊断，不标）。 */
@Composable
fun OutcomeRow(block: RunBlock) {
    val run = block.run ?: return
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        run.summary?.let { summary ->
            AiGeneratedLabel()
            Text(summary, style = MaterialTheme.typography.bodyMedium)
        }
        run.error?.let { error ->
            Text(
                stringResource(R.string.chat_run_error, error),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}

@Composable
private fun SmallLine(
    icon: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) { icon() }
        Box(Modifier.weight(1f)) { content() }
    }
}
