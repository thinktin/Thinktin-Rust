package cn.thinktin.app.ui.approval

import android.app.admin.DevicePolicyManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.ApprovalCardData
import cn.thinktin.data.model.ApprovalCardStatus
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.DecisionSource
import cn.thinktin.data.model.OptionKind
import cn.thinktin.design.component.ApprovalCard
import cn.thinktin.design.component.ApprovalCardOption
import cn.thinktin.design.component.ApprovalCardState
import cn.thinktin.design.component.ApprovalCardUi
import cn.thinktin.design.component.ApprovalDecidedBy
import cn.thinktin.design.component.ApprovalOptionKind
import cn.thinktin.design.component.aiGeneratedLabel
import cn.thinktin.design.component.label
import kotlinx.coroutines.delay
import java.time.Clock

/** 数据层的卡片 → :design 的界面模型。[source] 是审批中心标注的实例名，[decidedAtText] 是格式化好的决定时间。 */
fun ApprovalCardData.toUi(source: String? = null, decidedAtText: String? = null): ApprovalCardUi = ApprovalCardUi(
    title = title,
    toolTitle = toolCall.title,
    toolKind = toolCall.kind,
    toolArguments = toolCall.arguments,
    rawJson = toolCall.rawJson.takeIf { it.isNotBlank() },
    options = options.map { it.toUi() },
    state = when (status) {
        ApprovalCardStatus.Pending -> ApprovalCardState.Pending
        ApprovalCardStatus.Approved -> ApprovalCardState.Approved
        ApprovalCardStatus.Rejected -> ApprovalCardState.Rejected
        ApprovalCardStatus.Expired -> ApprovalCardState.Expired
        ApprovalCardStatus.Cancelled -> ApprovalCardState.Cancelled
        ApprovalCardStatus.Superseded -> ApprovalCardState.Superseded
        ApprovalCardStatus.Unknown -> ApprovalCardState.Unknown
    },
    expiresAtMs = expiresAtMs,
    decidedOption = decidedOptionInfo?.toUi(),
    decidedBy = when (decidedBy) {
        DecisionSource.User -> ApprovalDecidedBy.You
        DecisionSource.Policy -> ApprovalDecidedBy.Policy
        DecisionSource.Timeout -> ApprovalDecidedBy.Timeout
        DecisionSource.Cancelled -> ApprovalDecidedBy.System
        DecisionSource.Unknown, null -> null
    },
    decidedAtText = decidedAtText,
    source = source,
)

fun ApprovalOption.toUi(): ApprovalCardOption = ApprovalCardOption(
    id = optionId,
    name = name,
    kind = when (kind) {
        OptionKind.AllowOnce -> ApprovalOptionKind.AllowOnce
        OptionKind.AllowAlways -> ApprovalOptionKind.AllowAlways
        OptionKind.RejectOnce -> ApprovalOptionKind.RejectOnce
        OptionKind.RejectAlways -> ApprovalOptionKind.RejectAlways
        OptionKind.Unknown -> ApprovalOptionKind.Other
    },
)

/** 当前时间，每 [intervalMs] 更新一次（倒计时用；测试里时钟是固定的）。 */
@Composable
fun rememberNowMs(clock: Clock, intervalMs: Long = 30_000): State<Long> = produceState(clock.millis(), clock) {
    while (true) {
        delay(intervalMs)
        value = clock.millis()
    }
}

/**
 * 一张审批卡片（带操作）：[actions] 的提交状态决定哪个按钮转圈；对不上审批记录（只从事件来）的不能点。
 */
@Composable
fun ApprovalCardItem(
    card: ApprovalCardData,
    nowMs: Long,
    clock: Clock,
    actionState: ApprovalActionState,
    actions: ApprovalActions,
    modifier: Modifier = Modifier,
    source: String? = null,
    onOpen: (() -> Unit)? = null,
    initiallyExpanded: Boolean = false,
) {
    val decidedAt = card.decidedAtMs?.takeIf { card.status.isFinal }?.let {
        RelativeTime.of(it, nowMs, clock.zone).asString()
    }
    val submitting = actionState.submitting
    ApprovalCard(
        card = card.toUi(source = source, decidedAtText = decidedAt),
        nowMs = nowMs,
        onOption = { option ->
            val approval = card.approval ?: return@ApprovalCard
            val chosen = approval.options.firstOrNull { it.optionId == option.id } ?: return@ApprovalCard
            actions.onOption(approval, chosen)
        },
        modifier = modifier,
        busyOptionId = submitting?.takeIf { it.approvalId == card.approvalId }?.optionId,
        enabled = card.canDecide && submitting == null,
        onOpen = onOpen,
        initiallyExpanded = initiallyExpanded,
    )
}

/** 审批操作的对话框（确认批准、没有锁屏凭证、无法验证）。 */
@Composable
fun ApprovalDialogs(state: ApprovalActionState, actions: ApprovalActions) {
    val context = LocalContext.current
    when (val dialog = state.dialog) {
        null -> Unit
        is ApprovalDialog.Confirm -> {
            val option = dialog.decision.option.toUi().label()
            val title = dialog.decision.approval.title?.takeIf { it.isNotBlank() }
            ConfirmDialog(
                title = stringResource(R.string.approval_confirm_title),
                text = stringResource(R.string.approval_confirm_text, option),
                confirm = stringResource(R.string.approval_confirm_action),
                onConfirm = actions::confirm,
                onDismiss = actions::dismissDialog,
                extra = {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (title != null) {
                            // agent 写的标题（第 8.4 节）。
                            Text(aiGeneratedLabel() + title, style = MaterialTheme.typography.bodyMedium)
                        }
                        if (dialog.decision.option.kind == OptionKind.AllowAlways) {
                            Text(
                                stringResource(R.string.approval_confirm_always_hint),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
            )
        }
        ApprovalDialog.NoCredential -> ConfirmDialog(
            title = stringResource(R.string.approval_no_credential_title),
            text = stringResource(R.string.approval_no_credential_text),
            confirm = stringResource(R.string.approval_no_credential_action),
            onConfirm = {
                actions.dismissDialog()
                openLockScreenSettings(context)
            },
            onDismiss = actions::dismissDialog,
        )
        ApprovalDialog.Unavailable -> ConfirmDialog(
            title = stringResource(R.string.approval_unavailable_title),
            text = stringResource(R.string.approval_unavailable_text),
            confirm = stringResource(R.string.action_ok),
            onConfirm = actions::dismissDialog,
            onDismiss = actions::dismissDialog,
        )
    }
}

/** 把 [actions] 的结果提示显示在 [snackbar] 上（带“重试”的点了就重试）。 */
@Composable
fun ApprovalMessages(actions: ApprovalActions, snackbar: SnackbarHostState) {
    val context = LocalContext.current
    LaunchedEffect(actions) {
        actions.messages.collect { message ->
            val result = snackbar.showSnackbar(
                message = message.text.resolve(context),
                actionLabel = message.retry?.let { context.getString(R.string.action_retry) },
                duration = if (message.retry != null) SnackbarDuration.Long else SnackbarDuration.Short,
            )
            if (result == SnackbarResult.ActionPerformed) message.retry?.invoke()
        }
    }
}

/** 去设置锁屏密码；没有那个页面就打开安全设置。 */
private fun openLockScreenSettings(context: Context) {
    val intents = listOf(
        Intent(DevicePolicyManager.ACTION_SET_NEW_PASSWORD),
        Intent(Settings.ACTION_SECURITY_SETTINGS),
        Intent(Settings.ACTION_SETTINGS),
    )
    for (intent in intents) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (_: ActivityNotFoundException) {
        }
    }
}
