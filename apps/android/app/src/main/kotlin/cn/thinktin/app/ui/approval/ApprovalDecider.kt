package cn.thinktin.app.ui.approval

import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.isReject
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService

/** 一次决定：哪条审批、选哪个选项。 */
data class Decision(val approval: Approval, val option: ApprovalOption) {
    /** 批准类（和不认识的选项）要先过身份确认；拒绝类直接发。 */
    val needsVerification: Boolean get() = !option.kind.isReject
}

/** [ApprovalDecider.decide] 的结果。 */
sealed interface DecisionOutcome {
    /** 服务端接受了；[approval] 是返回的记录（已批准 / 已拒绝）。 */
    data class Decided(val approval: Approval) : DecisionOutcome

    /** 用户取消了身份确认：什么都没发。 */
    data object Cancelled : DecisionOutcome

    /** 设备没有锁屏凭证：不许批准，提示先设置。 */
    data object NoCredential : DecisionOutcome

    /** 身份确认失败（被锁定、硬件不可用……）：什么都没发。 */
    data class VerificationFailed(val result: GateResult) : DecisionOutcome

    /**
     * 已经处理过 / 过期 / 被取消了（服务端 409、404……）：[latest] 是重新查到的记录（显示结果，不当错误）；
     * 查不到（审批没了）时为 null。
     */
    data class AlreadyHandled(val latest: Approval?) : DecisionOutcome

    /** 其他错误（网络、服务端暂时不可用……）：可以重试，[verified] 表示这次已经过了身份确认。 */
    data class Failed(val error: ServiceError, val verified: Boolean) : DecisionOutcome
}

/**
 * “（确认之后）→ 身份确认 → decideApproval”（第 8.5 节）。确认框在页面上（ViewModel 的状态），这里从身份确认开始：
 * 批准类先过 [gate]，拒绝类直接发；服务端说已经处理过、过期、不存在时重新 [ThinktinService.getApproval]
 * 拿最新结果。审批中心、审批详情和对话页（13.5）共用。
 */
class ApprovalDecider(private val service: ThinktinService, private val gate: ApprovalGate) {
    /** 现在能不能批准（没有锁屏凭证时界面直接提示，不弹确认框）。 */
    fun availability(): GateAvailability = gate.availability()

    /**
     * @param alreadyVerified 这次决定已经过了身份确认（网络失败后重试同一个决定），不再弹一次。
     */
    suspend fun decide(decision: Decision, alreadyVerified: Boolean = false): DecisionOutcome {
        var verified = alreadyVerified
        if (decision.needsVerification && !verified) {
            val request = GateRequest(
                approvalTitle = decision.approval.title,
                optionKind = decision.option.kind,
                optionName = decision.option.name,
            )
            when (val result = gate.authenticate(request)) {
                GateResult.Success -> verified = true
                GateResult.Cancelled -> return DecisionOutcome.Cancelled
                GateResult.NoCredential -> return DecisionOutcome.NoCredential
                GateResult.Lockout, GateResult.Error -> return DecisionOutcome.VerificationFailed(result)
            }
        }
        return try {
            DecisionOutcome.Decided(service.decideApproval(decision.approval.id, decision.option.optionId))
        } catch (e: ServiceError) {
            if (e.isAlreadyHandled) {
                DecisionOutcome.AlreadyHandled(latest(decision.approval.id))
            } else {
                DecisionOutcome.Failed(e, verified)
            }
        }
    }

    private suspend fun latest(approvalId: String): Approval? = try {
        service.getApproval(approvalId)
    } catch (_: ServiceError) {
        null
    }

    companion object {
        /** 服务端说这条审批已经不能决定了：已处理（409）、不存在（404）、过期（410 / expired）。 */
        val ServiceError.isAlreadyHandled: Boolean
            get() = this is ServiceError.Api &&
                (status == 409 || status == 404 || status == 410 || code == "conflict" || code == "not_found" ||
                    code.contains("expired"))
    }
}
