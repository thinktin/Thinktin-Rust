package cn.thinktin.app.ui.approval

import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isRetryable
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 审批操作的对话框（同时只开一个；里面都没有输入框）。 */
sealed interface ApprovalDialog {
    /** 批准前确认：确认后弹身份确认。 */
    data class Confirm(val decision: Decision) : ApprovalDialog

    /** 设备没有锁屏凭证：先去设置，不能批准。 */
    data object NoCredential : ApprovalDialog

    /** 设备现在做不了身份确认：不能批准（拒绝可以）。 */
    data object Unavailable : ApprovalDialog
}

/** 正在提交的决定（这张卡片上这个选项转圈，其他卡片的按钮照常）。 */
data class Submitting(val approvalId: String, val optionId: String)

data class ApprovalActionState(
    val dialog: ApprovalDialog? = null,
    val submitting: Submitting? = null,
)

/** 结果提示（Snackbar）；[retry] 不为空时带“重试”。 */
data class ApprovalMessage(val text: UiText, val retry: (() -> Unit)? = null)

/**
 * 审批卡片上的操作（审批中心、审批详情、对话页共用，挂在各自 ViewModel 的作用域里）：
 * - 点拒绝类选项：直接发（第 8.5 节）；
 * - 点批准类选项：先看能不能做身份确认（没有锁屏凭证 → 提示先设置），能就弹确认框，确认后
 *   [ApprovalDecider] 做身份确认再发；
 * - 结果：成功 / 已处理（拿到最新记录）交给 [onUpdated] 更新卡片；审批没了交给 [onGone]；网络等错误带“重试”
 *   （已经过了身份确认的不再验证一次）。
 */
class ApprovalActions(
    private val scope: CoroutineScope,
    private val decider: ApprovalDecider,
    private val onUpdated: (Approval) -> Unit,
    private val onGone: (approvalId: String) -> Unit = {},
) {
    private val mutable = MutableStateFlow(ApprovalActionState())
    val state: StateFlow<ApprovalActionState> = mutable.asStateFlow()

    private val messageChannel = Channel<ApprovalMessage>(Channel.BUFFERED)
    val messages: Flow<ApprovalMessage> = messageChannel.receiveAsFlow()

    /** 点了 [approval] 的选项 [option]。 */
    fun onOption(approval: Approval, option: ApprovalOption) {
        if (mutable.value.submitting != null) return
        val decision = Decision(approval, option)
        if (!decision.needsVerification) {
            submit(decision, verified = false)
            return
        }
        val dialog = when (decider.availability()) {
            GateAvailability.Available -> ApprovalDialog.Confirm(decision)
            GateAvailability.NoCredential -> ApprovalDialog.NoCredential
            GateAvailability.Unavailable -> ApprovalDialog.Unavailable
        }
        mutable.update { it.copy(dialog = dialog) }
    }

    /** 确认框里的“验证并批准”。 */
    fun confirm() {
        val dialog = mutable.value.dialog as? ApprovalDialog.Confirm ?: return
        mutable.update { it.copy(dialog = null) }
        submit(dialog.decision, verified = false)
    }

    fun dismissDialog() {
        mutable.update { it.copy(dialog = null) }
    }

    private fun submit(decision: Decision, verified: Boolean) {
        if (mutable.value.submitting != null) return
        mutable.update { it.copy(submitting = Submitting(decision.approval.id, decision.option.optionId)) }
        scope.launch {
            val outcome = try {
                decider.decide(decision, alreadyVerified = verified)
            } finally {
                mutable.update { it.copy(submitting = null) }
            }
            handle(decision, outcome)
        }
    }

    private fun handle(decision: Decision, outcome: DecisionOutcome) {
        when (outcome) {
            is DecisionOutcome.Decided -> {
                onUpdated(outcome.approval)
                message(
                    UiText(
                        if (outcome.approval.state == ApprovalState.Rejected) {
                            R.string.approval_decided_rejected
                        } else {
                            R.string.approval_decided_approved
                        },
                    ),
                )
            }
            DecisionOutcome.Cancelled -> Unit
            DecisionOutcome.NoCredential -> mutable.update { it.copy(dialog = ApprovalDialog.NoCredential) }
            is DecisionOutcome.VerificationFailed -> message(
                UiText(
                    if (outcome.result == GateResult.Lockout) R.string.approval_verify_lockout else R.string.approval_verify_failed,
                ),
            )
            is DecisionOutcome.AlreadyHandled -> {
                val latest = outcome.latest
                if (latest == null) {
                    onGone(decision.approval.id)
                    message(UiText(R.string.approval_gone))
                } else {
                    onUpdated(latest)
                    message(
                        UiText(
                            when (latest.state) {
                                ApprovalState.Expired -> R.string.approval_already_expired
                                ApprovalState.Cancelled -> R.string.approval_already_cancelled
                                else -> R.string.approval_already_handled
                            },
                        ),
                    )
                }
            }
            is DecisionOutcome.Failed -> {
                val retry = if (outcome.error.isRetryable) {
                    { submit(decision, verified = outcome.verified) }
                } else {
                    null
                }
                message(ApprovalMessage(ErrorText.of(outcome.error), retry))
            }
        }
    }

    private fun message(text: UiText) = message(ApprovalMessage(text))

    private fun message(message: ApprovalMessage) {
        messageChannel.trySend(message)
    }
}
