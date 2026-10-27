package cn.thinktin.design.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.HighlightOff
import androidx.compose.material.icons.outlined.HourglassBottom
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinTextStyles
import cn.thinktin.design.theme.ThinktinTheme

/*
 * 审批卡片（13.16，第 4.3、8.5 节）：对话页内嵌（13.5）和审批中心共用。:design 不依赖数据层，
 * 所以卡片有自己的界面模型 [ApprovalCardUi]，由 :app 从审批记录 / 事件映射过来。
 */

/** 选项的种类（`ApprovalOption.kind`）：批准类是主按钮，拒绝类和不认识的是次按钮。 */
enum class ApprovalOptionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
    Other,
    ;

    val isAllow: Boolean get() = this == AllowOnce || this == AllowAlways
}

/** 一个选项。[name] 是 agent 给的名字，只在 [kind] 是 [ApprovalOptionKind.Other] 时显示（其余用本地文案）。 */
@Immutable
data class ApprovalCardOption(val id: String, val name: String, val kind: ApprovalOptionKind)

/** 卡片状态。[Superseded]：运行已经开始了更新的尝试，这条请求作废。 */
enum class ApprovalCardState {
    Pending,
    Approved,
    Rejected,
    Expired,
    Cancelled,
    Superseded,
    Unknown,
}

/** 谁决定的。 */
enum class ApprovalDecidedBy {
    /** 用户（本机或别的设备）。 */
    You,

    /** 预授权策略。 */
    Policy,

    /** 平台超时。 */
    Timeout,

    /** 尝试结束、运行停了。 */
    System,
}

/**
 * 卡片的界面模型。
 * - [title]：agent 写的审批标题（标 AI 生成）；没有时用工具调用的标题。
 * - [toolTitle] / [toolKind] / [toolArguments]：工具调用摘要；[rawJson] 是展开后显示的原始请求。
 * - [source]：审批中心里标注的实例名（对话页里不用）。
 * - [decidedAtText]：已决定的时间（“3 分钟前”，:app 用相对时间格式化好）。
 */
@Immutable
data class ApprovalCardUi(
    val title: String?,
    val toolTitle: String?,
    val toolKind: String?,
    val toolArguments: String?,
    val rawJson: String?,
    val options: List<ApprovalCardOption>,
    val state: ApprovalCardState,
    val expiresAtMs: Long?,
    val decidedOption: ApprovalCardOption? = null,
    val decidedBy: ApprovalDecidedBy? = null,
    val decidedAtText: String? = null,
    val source: String? = null,
)

const val APPROVAL_CARD_TEST_TAG = "approval-card"
const val APPROVAL_CARD_STATUS_TEST_TAG = "approval-card-status"

/** 还剩多少时间（到期倒计时）。 */
sealed interface ApprovalCountdown {
    data class HoursMinutes(val hours: Int, val minutes: Int) : ApprovalCountdown
    data class Minutes(val minutes: Int) : ApprovalCountdown
    data object UnderAMinute : ApprovalCountdown
    data object Overdue : ApprovalCountdown

    /** 不到一小时：警告色。 */
    val urgent: Boolean get() = this !is HoursMinutes

    companion object {
        fun of(expiresAtMs: Long, nowMs: Long): ApprovalCountdown {
            val left = expiresAtMs - nowMs
            if (left <= 0) return Overdue
            val minutes = left / 60_000
            return when {
                minutes < 1 -> UnderAMinute
                minutes < 60 -> Minutes(minutes.toInt())
                else -> HoursMinutes((minutes / 60).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), (minutes % 60).toInt())
            }
        }
    }
}

@Composable
fun ApprovalCountdown.asString(): String = when (this) {
    is ApprovalCountdown.HoursMinutes -> stringResource(R.string.design_approval_expires_hm, hours, minutes)
    is ApprovalCountdown.Minutes -> stringResource(R.string.design_approval_expires_m, minutes)
    ApprovalCountdown.UnderAMinute -> stringResource(R.string.design_approval_expiring)
    ApprovalCountdown.Overdue -> stringResource(R.string.design_approval_overdue)
}

/** 选项的显示文字：四种已知的用本地文案（第 8.1 节），不认识的用 agent 给的名字。 */
@Composable
fun ApprovalCardOption.label(): String = when (kind) {
    ApprovalOptionKind.AllowOnce -> stringResource(R.string.design_approval_allow_once)
    ApprovalOptionKind.AllowAlways -> stringResource(R.string.design_approval_allow_always)
    ApprovalOptionKind.RejectOnce -> stringResource(R.string.design_approval_reject_once)
    ApprovalOptionKind.RejectAlways -> stringResource(R.string.design_approval_reject_always)
    ApprovalOptionKind.Other -> name.ifBlank { stringResource(R.string.design_approval_option_unnamed) }
}

/**
 * 审批卡片：AI 生成标识 + 标题（agent 写的）、工具调用摘要（图标、标题、参数，可展开看原始请求）、
 * 待处理时是选项按钮（批准类主按钮在前、拒绝类次按钮）和到期倒计时，决定之后是结果（谁决定的、选了什么）。
 *
 * @param nowMs 当前时间（倒计时用；调用方每分钟更新一次）。
 * @param busyOptionId 正在提交的选项：它转圈，其余按钮不可点。
 * @param enabled 为假时按钮全不可点（比如对不上审批记录，只能看）。
 * @param onOption 点了某个选项（批准前的确认和生物识别由调用方做）。
 * @param onOpen 点卡片头（审批中心进详情页）；为 null 时头部不可点。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ApprovalCard(
    card: ApprovalCardUi,
    nowMs: Long,
    onOption: (ApprovalCardOption) -> Unit,
    modifier: Modifier = Modifier,
    busyOptionId: String? = null,
    enabled: Boolean = true,
    onOpen: (() -> Unit)? = null,
    initiallyExpanded: Boolean = false,
) {
    val pending = card.state == ApprovalCardState.Pending
    val stateText = approvalStateText(card)
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag(APPROVAL_CARD_TEST_TAG),
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(
            1.dp,
            if (pending) ThinktinTheme.extendedColors.warning else MaterialTheme.colorScheme.outline,
        ),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Header(card, stateText, onOpen)
            ToolSummary(card, initiallyExpanded)
            if (pending) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // 批准类在前（主按钮），拒绝类在后（次按钮）；同类保持 agent 给的顺序。
                    val ordered = card.options.sortedBy { if (it.kind.isAllow) 0 else 1 }
                    for (option in ordered) {
                        val label = option.label()
                        val busy = busyOptionId == option.id
                        val clickable = enabled && busyOptionId == null
                        if (option.kind.isAllow) {
                            PrimaryButton(text = label, onClick = { onOption(option) }, enabled = clickable, loading = busy)
                        } else {
                            SecondaryButton(text = label, onClick = { onOption(option) }, enabled = clickable, loading = busy)
                        }
                    }
                }
                card.expiresAtMs?.let { expires ->
                    val countdown = ApprovalCountdown.of(expires, nowMs)
                    StatusLine(
                        icon = Icons.Outlined.Schedule,
                        text = countdown.asString(),
                        color = if (countdown.urgent) {
                            ThinktinTheme.extendedColors.warning
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
            } else {
                val (icon, color) = stateIcon(card.state)
                StatusLine(
                    icon = icon,
                    text = listOfNotNull(stateText, card.decidedAtText).joinToString(" · "),
                    color = color,
                    modifier = Modifier
                        .testTag(APPROVAL_CARD_STATUS_TEST_TAG)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

@Composable
private fun Header(card: ApprovalCardUi, stateText: String, onOpen: (() -> Unit)?) {
    val title = card.title ?: card.toolTitle ?: stringResource(R.string.design_approval_untitled)
    val agentWritten = card.title != null || card.toolTitle != null
    val aiLabel = aiGeneratedLabel()
    val heading = stringResource(R.string.design_approval_heading)
    val description = listOfNotNull(card.source, heading, if (agentWritten) aiLabel + title else title)
        .joinToString("，")
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClick = onOpen) else Modifier)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                stateDescription = stateText
                heading()
            },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(
                Icons.Outlined.VerifiedUser,
                contentDescription = null,
                tint = ThinktinTheme.extendedColors.warning,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = listOfNotNull(card.source, heading).joinToString(" · "),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (agentWritten) AiGeneratedLabel()
        }
        Text(text = title, style = MaterialTheme.typography.titleMedium)
    }
}

@Composable
private fun ToolSummary(card: ApprovalCardUi, initiallyExpanded: Boolean) {
    val hasRaw = !card.rawJson.isNullOrBlank()
    if (card.toolTitle == null && card.toolArguments == null && !hasRaw) return
    var expanded by rememberSaveable(card.rawJson) { mutableStateOf(initiallyExpanded) }
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(toolCallIcon(card.toolKind), contentDescription = null, modifier = Modifier.size(18.dp))
                Text(
                    text = card.toolTitle ?: stringResource(R.string.design_approval_tool_call),
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                card.toolKind?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            card.toolArguments?.let {
                Text(
                    text = it,
                    style = ThinktinTextStyles.Code,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (hasRaw) {
                val label = stringResource(if (expanded) R.string.design_approval_hide_raw else R.string.design_approval_show_raw)
                Row(
                    modifier = Modifier
                        .clickable(role = Role.Button, onClickLabel = label) { expanded = !expanded }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary)
                    Icon(
                        if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.secondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
                AnimatedVisibility(visible = expanded) {
                    Text(
                        text = card.rawJson.orEmpty(),
                        style = ThinktinTextStyles.Code,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        softWrap = false,
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusLine(icon: ImageVector, text: String, color: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = color)
    }
}

@Composable
private fun stateIcon(state: ApprovalCardState): Pair<ImageVector, Color> = when (state) {
    ApprovalCardState.Approved -> Icons.Outlined.CheckCircle to ThinktinTheme.extendedColors.success
    ApprovalCardState.Rejected -> Icons.Outlined.HighlightOff to MaterialTheme.colorScheme.error
    ApprovalCardState.Expired -> Icons.Outlined.HourglassBottom to MaterialTheme.colorScheme.onSurfaceVariant
    ApprovalCardState.Cancelled, ApprovalCardState.Superseded, ApprovalCardState.Unknown ->
        Icons.Outlined.Block to MaterialTheme.colorScheme.onSurfaceVariant
    ApprovalCardState.Pending -> Icons.Outlined.Schedule to ThinktinTheme.extendedColors.warning
}

/** 状态的一句话（也给读屏用）：待处理 / 你批准了（一直允许）/ 按策略拒绝 / 超时未处理 / 已作废…… */
@Composable
fun approvalStateText(card: ApprovalCardUi): String {
    // 只有“一直允许 / 一直拒绝”和不认识的选项才值得说出来（“你已批准（批准）”是废话）。
    val option = card.decidedOption
        ?.takeIf { it.kind != ApprovalOptionKind.AllowOnce && it.kind != ApprovalOptionKind.RejectOnce }
        ?.label()
    return when (card.state) {
        ApprovalCardState.Pending -> stringResource(R.string.design_approval_state_pending)
        ApprovalCardState.Approved -> when (card.decidedBy) {
            ApprovalDecidedBy.Policy -> stringResource(R.string.design_approval_approved_policy)
            else -> option?.let { stringResource(R.string.design_approval_approved_you_option, it) }
                ?: stringResource(R.string.design_approval_approved_you)
        }
        ApprovalCardState.Rejected -> when (card.decidedBy) {
            ApprovalDecidedBy.Policy -> stringResource(R.string.design_approval_rejected_policy)
            else -> option?.let { stringResource(R.string.design_approval_rejected_you_option, it) }
                ?: stringResource(R.string.design_approval_rejected_you)
        }
        ApprovalCardState.Expired -> stringResource(R.string.design_approval_state_expired)
        ApprovalCardState.Cancelled -> stringResource(R.string.design_approval_state_cancelled)
        ApprovalCardState.Superseded -> stringResource(R.string.design_approval_state_superseded)
        ApprovalCardState.Unknown -> stringResource(R.string.design_approval_state_unknown)
    }
}

private val previewOptions = listOf(
    ApprovalCardOption("allow", "Allow", ApprovalOptionKind.AllowOnce),
    ApprovalCardOption("always", "Always", ApprovalOptionKind.AllowAlways),
    ApprovalCardOption("reject", "Reject", ApprovalOptionKind.RejectOnce),
)

@Preview(showBackground = true)
@Composable
internal fun ApprovalCardPreview() {
    ThinktinTheme {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ApprovalCard(
                card = ApprovalCardUi(
                    title = "删除 build/ 下 30 天前的文件",
                    toolTitle = "Bash",
                    toolKind = "execute",
                    toolArguments = "find build -mtime +30 -delete",
                    rawJson = "{\n  \"command\": \"find build -mtime +30 -delete\"\n}",
                    options = previewOptions,
                    state = ApprovalCardState.Pending,
                    expiresAtMs = 23 * 3_600_000L + 41 * 60_000L,
                    source = "小码",
                ),
                nowMs = 0,
                onOption = {},
            )
            ApprovalCard(
                card = ApprovalCardUi(
                    title = "写入 README.en.md",
                    toolTitle = "Write",
                    toolKind = "edit",
                    toolArguments = "README.en.md",
                    rawJson = null,
                    options = previewOptions,
                    state = ApprovalCardState.Approved,
                    expiresAtMs = null,
                    decidedOption = previewOptions[0],
                    decidedBy = ApprovalDecidedBy.You,
                    decidedAtText = "3 小时前",
                ),
                nowMs = 0,
                onOption = {},
            )
        }
    }
}
