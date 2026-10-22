package cn.thinktin.app

import cn.thinktin.app.ui.approval.ApprovalGate
import cn.thinktin.app.ui.approval.GateAvailability
import cn.thinktin.app.ui.approval.GateRequest
import cn.thinktin.app.ui.approval.GateResult
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.parseJsonObject
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService

/** 假的身份确认：[availability] 和 [result] 由测试设；记下每次弹出的请求。 */
class FakeApprovalGate(
    var availability: GateAvailability = GateAvailability.Available,
    var result: GateResult = GateResult.Success,
) : ApprovalGate {
    val requests = mutableListOf<GateRequest>()

    override fun availability(): GateAvailability = availability

    override suspend fun authenticate(request: GateRequest): GateResult {
        requests += request
        return result
    }
}

/**
 * 审批的服务替身：数据来自 Mock，[extraApprovals] 加别的实例的审批（Mock 里只有一条待处理的），
 * [failNext] 让某个方法下一次抛错，记下每次 decideApproval。
 */
class ApprovalService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    val decisions = mutableListOf<Pair<String, String>>()
    val extraApprovals = mutableListOf<Approval>()
    val runAttempts = mutableMapOf<String, Int>()
    private val failures = mutableMapOf<String, ServiceError>()
    var approvalsCalls = 0
        private set

    fun failNext(method: String, error: ServiceError) {
        synchronized(failures) { failures[method] = error }
    }

    private fun maybeFail(method: String) {
        synchronized(failures) { failures.remove(method) }?.let { throw it }
    }

    override suspend fun approvals(): List<Approval> {
        approvalsCalls++
        maybeFail("approvals")
        return mock.approvals() + extraApprovals.filter { it.state == ApprovalState.Pending }
    }

    override suspend fun getApproval(approvalId: String): Approval {
        maybeFail("getApproval")
        return extraApprovals.firstOrNull { it.id == approvalId } ?: mock.getApproval(approvalId)
    }

    override suspend fun decideApproval(approvalId: String, optionId: String): Approval {
        decisions += approvalId to optionId
        maybeFail("decideApproval")
        val i = extraApprovals.indexOfFirst { it.id == approvalId }
        if (i >= 0) {
            val a = extraApprovals[i]
            if (a.state != ApprovalState.Pending) throw ServiceError.Api(409, "conflict", "already decided", null)
            val option = a.options.first { it.optionId == optionId }
            return a.copy(
                state = if (option.kind.isAllow) ApprovalState.Approved else ApprovalState.Rejected,
                decidedOption = optionId,
                decidedAtMs = DemoTestApp.FIXED_CLOCK.millis(),
            ).also { extraApprovals[i] = it }
        }
        return mock.decideApproval(approvalId, optionId)
    }

    override suspend fun getRun(runId: String): Run {
        maybeFail("getRun")
        val run = mock.getRun(runId)
        return runAttempts[runId]?.let { run.copy(attempt = it) } ?: run
    }

    override suspend fun instances(): List<Instance> {
        maybeFail("instances")
        return mock.instances()
    }

    override suspend fun instance(instanceId: String): Instance {
        maybeFail("instance")
        return mock.instance(instanceId)
    }

    /** 研究员的一条待处理审批（跨实例分组用），挂在研究员的 run-quota 上（第 [attempt] 次尝试）。 */
    fun addResearchApproval(id: String = "approval-research", attempt: Int = 1, createdAgoMs: Long = 60_000) {
        val now = DemoTestApp.FIXED_CLOCK.millis()
        val json = """{"title":"Fetch","kind":"fetch","rawInput":{"url":"https://example.com/news"}}"""
        extraApprovals += Approval(
            id = id, runId = "run-quota", instanceId = "inst-research", title = "抓取行业新闻网站",
            options = listOf(
                ApprovalOption("ok", "Allow", OptionKind.AllowOnce),
                ApprovalOption("no", "Reject", OptionKind.RejectOnce),
            ),
            toolCallJson = json, toolCall = parseJsonObject(json),
            state = ApprovalState.Pending, expiresAtMs = now - createdAgoMs + 86_400_000, createdAtMs = now - createdAgoMs,
            requestId = "perm-1", attempt = attempt,
        )
    }
}

/** Mock 里唯一一条待处理的审批（小码的 run-waiting，第 2 次尝试）。 */
const val APPROVAL_PENDING = "approval-pending"
