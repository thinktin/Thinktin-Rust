package cn.thinktin.app

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import cn.thinktin.app.ui.approval.ApprovalCenterViewModel
import cn.thinktin.app.ui.approval.ApprovalDetailViewModel
import cn.thinktin.app.ui.approval.ApprovalDialog
import cn.thinktin.app.ui.approval.ApprovalMessage
import cn.thinktin.app.ui.approval.BiometricApprovalGate
import cn.thinktin.app.ui.approval.GateAvailability
import cn.thinktin.app.ui.approval.GateResult
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.ApprovalCardData
import cn.thinktin.data.model.ApprovalCardStatus
import cn.thinktin.data.model.DecisionSource
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 13.16 云端审批的 ViewModel：审批中心（跨实例分组、作废、加载失败 / 刷新失败）、审批详情（待处理、已处理、
 * 过期、不存在、网络错误）、批准前的确认与身份确认（成功 / 取消 / 失败 / 没有锁屏凭证）、拒绝直接发、
 * 已处理时显示最新结果、网络失败重试不再验证。身份确认用 [FakeApprovalGate]。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ApprovalViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val service = ApprovalService()
    private val gate = FakeApprovalGate()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun TestScope.center(): Pair<ApprovalCenterViewModel, MutableList<ApprovalMessage>> {
        val vm = ApprovalCenterViewModel(service, gate)
        val messages = mutableListOf<ApprovalMessage>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.actions.messages.collect { messages += it } }
        advanceUntilIdle()
        return vm to messages
    }

    private fun ApprovalCenterViewModel.card(id: String): ApprovalCardData =
        uiState.value.groups.flatMap { it.cards }.single { it.approvalId == id }

    private fun ApprovalCardData.option(kind: OptionKind) = approval!!.options.first { it.kind == kind }

    // ---- 审批中心 ----

    @Test
    fun centerGroupsPendingApprovalsByInstance() = test {
        service.addResearchApproval(createdAgoMs = 60_000)
        val (vm, _) = center()
        val state = vm.uiState.value
        assertFalse(state.loading)
        assertNull(state.loadError)
        // 研究员那条更新：研究员的组在前
        assertEquals(listOf("inst-research", "inst-coder"), state.groups.map { it.instanceId })
        assertEquals(listOf("研究员", "小码"), state.groups.map { it.instanceName })
        assertEquals(listOf("approval-research"), state.groups[0].cards.map { it.approvalId })
        assertEquals(listOf(APPROVAL_PENDING), state.groups[1].cards.map { it.approvalId })
        assertTrue(state.groups.flatMap { it.cards }.all { it.status == ApprovalCardStatus.Pending && it.canDecide })
        assertEquals(2, state.pendingCount)
        assertEquals("find build -mtime +30 -delete", vm.card(APPROVAL_PENDING).toolCall.arguments)
    }

    @Test
    fun centerVoidsApprovalOfOlderAttempt() = test {
        service.addResearchApproval(attempt = 1)
        service.runAttempts["run-quota"] = 2
        val (vm, _) = center()
        val stale = vm.card("approval-research")
        assertEquals(ApprovalCardStatus.Superseded, stale.status)
        assertFalse(stale.canDecide)
        assertEquals(ApprovalCardStatus.Pending, vm.card(APPROVAL_PENDING).status)
        assertEquals(1, vm.uiState.value.pendingCount)
    }

    @Test
    fun centerStillListsWhenRunLookupFails() = test {
        service.failNext("getRun", ServiceError.Network("down"))
        val (vm, _) = center()
        assertEquals(ApprovalCardStatus.Pending, vm.card(APPROVAL_PENDING).status)
    }

    @Test
    fun centerLoadErrorThenRetry() = test {
        service.failNext("approvals", ServiceError.Network("offline"))
        val (vm, _) = center()
        assertEquals(UiText(R.string.error_network), vm.uiState.value.loadError)
        assertTrue(vm.uiState.value.isEmpty)
        vm.retry()
        assertTrue(vm.uiState.value.loading)
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertEquals(1, vm.uiState.value.groups.size)
    }

    @Test
    fun centerRefreshFailureKeepsListAndNotifies() = test {
        val (vm, _) = center()
        val notices = mutableListOf<UiText>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.notices.collect { notices += it } }
        service.failNext("approvals", ServiceError.Network("offline"))
        vm.refresh()
        assertTrue(vm.uiState.value.refreshing)
        advanceUntilIdle()
        assertFalse(vm.uiState.value.refreshing)
        assertNull(vm.uiState.value.loadError)
        assertEquals(1, vm.uiState.value.groups.size)
        assertEquals(listOf(UiText(R.string.error_network)), notices)
    }

    @Test
    fun centerRefreshesWhenShownAgain() = test {
        val (vm, _) = center()
        val calls = service.approvalsCalls
        vm.onShown() // 第一次显示：init 已经加载过
        advanceUntilIdle()
        assertEquals(calls, service.approvalsCalls)
        vm.onShown() // 从详情页回来
        advanceUntilIdle()
        assertEquals(calls + 1, service.approvalsCalls)
    }

    // ---- 批准：确认 → 身份确认 → decideApproval ----

    @Test
    fun approveAsksConfirmationThenBiometricThenDecides() = test {
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowAlways))
        val dialog = vm.actions.state.value.dialog as ApprovalDialog.Confirm
        assertEquals("always", dialog.decision.option.optionId)
        assertTrue("确认前不弹身份确认", gate.requests.isEmpty())
        assertTrue(service.decisions.isEmpty())

        vm.actions.confirm()
        assertNull(vm.actions.state.value.dialog)
        advanceUntilIdle()
        assertEquals(1, gate.requests.size)
        assertEquals(OptionKind.AllowAlways, gate.requests[0].optionKind)
        assertEquals("删除 build/ 下 30 天前的文件", gate.requests[0].approvalTitle)
        assertEquals(listOf(APPROVAL_PENDING to "always"), service.decisions)
        val decided = vm.card(APPROVAL_PENDING)
        assertEquals(ApprovalCardStatus.Approved, decided.status)
        assertEquals(DecisionSource.User, decided.decidedBy)
        assertEquals("always", decided.decidedOption)
        assertFalse(decided.canDecide)
        assertNull(vm.actions.state.value.submitting)
        assertEquals(listOf(UiText(R.string.approval_decided_approved)), messages.map { it.text })
    }

    @Test
    fun cancelledBiometricSendsNothing() = test {
        gate.result = GateResult.Cancelled
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        vm.actions.confirm()
        advanceUntilIdle()
        assertEquals(1, gate.requests.size)
        assertTrue(service.decisions.isEmpty())
        assertEquals(ApprovalCardStatus.Pending, vm.card(APPROVAL_PENDING).status)
        assertTrue(messages.isEmpty())
    }

    @Test
    fun failedBiometricSendsNothingAndExplains() = test {
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        gate.result = GateResult.Lockout
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        vm.actions.confirm()
        advanceUntilIdle()
        gate.result = GateResult.Error
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        vm.actions.confirm()
        advanceUntilIdle()
        assertTrue(service.decisions.isEmpty())
        assertEquals(
            listOf(UiText(R.string.approval_verify_lockout), UiText(R.string.approval_verify_failed)),
            messages.map { it.text },
        )
    }

    @Test
    fun noScreenLockBlocksApproval() = test {
        gate.availability = GateAvailability.NoCredential
        val (vm, _) = center()
        val card = vm.card(APPROVAL_PENDING)
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        assertEquals(ApprovalDialog.NoCredential, vm.actions.state.value.dialog)
        vm.actions.confirm() // 不是确认框：什么都不做
        advanceUntilIdle()
        assertTrue(gate.requests.isEmpty())
        assertTrue(service.decisions.isEmpty())
        vm.actions.dismissDialog()
        assertNull(vm.actions.state.value.dialog)

        // 系统说可以，提示框里才发现没有凭证（比如刚删了锁屏）：同样提示
        gate.availability = GateAvailability.Available
        gate.result = GateResult.NoCredential
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        vm.actions.confirm()
        advanceUntilIdle()
        assertEquals(ApprovalDialog.NoCredential, vm.actions.state.value.dialog)
        assertTrue(service.decisions.isEmpty())
    }

    @Test
    fun unavailableDeviceCannotApprove() = test {
        gate.availability = GateAvailability.Unavailable
        val (vm, _) = center()
        val card = vm.card(APPROVAL_PENDING)
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        assertEquals(ApprovalDialog.Unavailable, vm.actions.state.value.dialog)
        advanceUntilIdle()
        assertTrue(service.decisions.isEmpty())
    }

    @Test
    fun rejectIsSentDirectlyWithoutVerification() = test {
        gate.availability = GateAvailability.NoCredential // 没有锁屏也能拒绝
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        vm.actions.onOption(card.approval!!, card.option(OptionKind.RejectOnce))
        assertNull(vm.actions.state.value.dialog)
        assertEquals(APPROVAL_PENDING, vm.actions.state.value.submitting?.approvalId)
        advanceUntilIdle()
        assertTrue(gate.requests.isEmpty())
        assertEquals(listOf(APPROVAL_PENDING to "reject"), service.decisions)
        assertEquals(ApprovalCardStatus.Rejected, vm.card(APPROVAL_PENDING).status)
        assertEquals(listOf(UiText(R.string.approval_decided_rejected)), messages.map { it.text })
    }

    @Test
    fun alreadyHandledShowsLatestResult() = test {
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        // 别的设备先批准了
        service.mock.decideApproval(APPROVAL_PENDING, "allow")
        vm.actions.onOption(card.approval!!, card.option(OptionKind.RejectOnce))
        advanceUntilIdle()
        val latest = vm.card(APPROVAL_PENDING)
        assertEquals(ApprovalCardStatus.Approved, latest.status)
        assertEquals("allow", latest.decidedOption)
        assertEquals(listOf(UiText(R.string.approval_already_handled)), messages.map { it.text })
    }

    @Test
    fun goneApprovalIsRemoved() = test {
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        service.failNext("decideApproval", ServiceError.Api(404, "not_found", "gone", null))
        service.failNext("getApproval", ServiceError.Api(404, "not_found", "gone", null))
        vm.actions.onOption(card.approval!!, card.option(OptionKind.RejectOnce))
        advanceUntilIdle()
        assertTrue(vm.uiState.value.isEmpty)
        assertEquals(listOf(UiText(R.string.approval_gone)), messages.map { it.text })
    }

    @Test
    fun networkFailureRetriesWithoutVerifyingAgain() = test {
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        service.failNext("decideApproval", ServiceError.Network("timeout"))
        vm.actions.onOption(card.approval!!, card.option(OptionKind.AllowOnce))
        vm.actions.confirm()
        advanceUntilIdle()
        assertEquals(1, gate.requests.size)
        assertEquals(ApprovalCardStatus.Pending, vm.card(APPROVAL_PENDING).status)
        val failure = messages.single()
        assertEquals(UiText(R.string.error_network), failure.text)
        assertNotNull(failure.retry)
        val retry = failure.retry!!

        retry()
        advanceUntilIdle()
        assertEquals("重试不再弹身份确认", 1, gate.requests.size)
        assertEquals(2, service.decisions.size)
        assertEquals(ApprovalCardStatus.Approved, vm.card(APPROVAL_PENDING).status)
    }

    @Test
    fun nonRetryableErrorHasNoRetry() = test {
        val (vm, messages) = center()
        val card = vm.card(APPROVAL_PENDING)
        service.failNext("decideApproval", ServiceError.Api(422, "invalid", "bad option", null))
        vm.actions.onOption(card.approval!!, card.option(OptionKind.RejectOnce))
        advanceUntilIdle()
        assertNull(messages.single().retry)
        assertEquals(UiText(R.string.error_invalid), messages.single().text)
    }

    // ---- 审批详情 ----

    private fun TestScope.detail(id: String): ApprovalDetailViewModel {
        val vm = ApprovalDetailViewModel(service, gate, id)
        advanceUntilIdle()
        return vm
    }

    @Test
    fun detailLoadsPendingWithRunAndInstance() = test {
        val vm = detail(APPROVAL_PENDING)
        val state = vm.uiState.value
        assertFalse(state.loading)
        assertEquals("小码", state.instanceName)
        assertEquals(2, state.run?.attempt)
        assertEquals(ApprovalCardStatus.Pending, state.card?.status)
        assertTrue(state.card!!.canDecide)

        vm.actions.onOption(state.card!!.approval!!, state.card!!.option(OptionKind.RejectOnce))
        advanceUntilIdle()
        assertEquals(ApprovalCardStatus.Rejected, vm.uiState.value.card?.status)
    }

    @Test
    fun detailShowsHandledAndExpiredWithoutError() = test {
        val done = detail("approval-done").uiState.value
        assertNull(done.loadError)
        assertEquals(ApprovalCardStatus.Approved, done.card?.status)
        assertEquals(DecisionSource.User, done.card?.decidedBy)

        val expired = detail("approval-expired").uiState.value
        assertNull(expired.loadError)
        assertEquals(ApprovalCardStatus.Expired, expired.card?.status)
        assertEquals(DecisionSource.Timeout, expired.card?.decidedBy)
        assertEquals("研究员", expired.instanceName)

        val cancelled = detail("approval-stale").uiState.value
        assertEquals(ApprovalCardStatus.Cancelled, cancelled.card?.status)
    }

    @Test
    fun detailVoidsPendingOfOlderAttempt() = test {
        service.runAttempts["run-waiting"] = 3
        val card = detail(APPROVAL_PENDING).uiState.value.card!!
        assertEquals(ApprovalCardStatus.Superseded, card.status)
        assertFalse(card.canDecide)
    }

    @Test
    fun detailNotFoundAndNetworkError() = test {
        val missing = detail("approval-nope").uiState.value
        assertTrue(missing.notFound)
        assertNull(missing.loadError)
        assertNull(missing.card)

        service.failNext("getApproval", ServiceError.Network("offline"))
        val vm = detail(APPROVAL_PENDING)
        assertEquals(UiText(R.string.error_network), vm.uiState.value.loadError)
        assertFalse(vm.uiState.value.notFound)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertNotNull(vm.uiState.value.card)
    }

    @Test
    fun detailStillShowsApprovalWhenRunAndInstanceFail() = test {
        service.failNext("getRun", ServiceError.Network("x"))
        service.failNext("instance", ServiceError.Network("x"))
        val state = detail(APPROVAL_PENDING).uiState.value
        assertNull(state.loadError)
        assertNull(state.run)
        assertNull(state.instanceName)
        assertEquals(ApprovalCardStatus.Pending, state.card?.status)
    }

    // ---- BiometricApprovalGate 的映射 ----

    @Test
    fun biometricAuthenticatorsAndResultMapping() {
        assertEquals(BIOMETRIC_STRONG or DEVICE_CREDENTIAL, BiometricApprovalGate.authenticatorsFor(26))
        assertEquals(BIOMETRIC_WEAK or DEVICE_CREDENTIAL, BiometricApprovalGate.authenticatorsFor(28))
        assertEquals(BIOMETRIC_WEAK or DEVICE_CREDENTIAL, BiometricApprovalGate.authenticatorsFor(29))
        assertEquals(BIOMETRIC_STRONG or DEVICE_CREDENTIAL, BiometricApprovalGate.authenticatorsFor(30))
        assertEquals(BIOMETRIC_STRONG or DEVICE_CREDENTIAL, BiometricApprovalGate.authenticatorsFor(35))

        assertEquals(GateAvailability.Available, BiometricApprovalGate.availabilityOf(BiometricManager.BIOMETRIC_SUCCESS))
        assertEquals(
            GateAvailability.NoCredential,
            BiometricApprovalGate.availabilityOf(BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED),
        )
        assertEquals(
            GateAvailability.Unavailable,
            BiometricApprovalGate.availabilityOf(BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE),
        )
        assertEquals(
            GateAvailability.Unavailable,
            BiometricApprovalGate.availabilityOf(BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED),
        )

        assertEquals(GateResult.Cancelled, BiometricApprovalGate.resultOf(BiometricPrompt.ERROR_USER_CANCELED))
        assertEquals(GateResult.Cancelled, BiometricApprovalGate.resultOf(BiometricPrompt.ERROR_CANCELED))
        assertEquals(GateResult.NoCredential, BiometricApprovalGate.resultOf(BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL))
        assertEquals(GateResult.Lockout, BiometricApprovalGate.resultOf(BiometricPrompt.ERROR_LOCKOUT_PERMANENT))
        assertEquals(GateResult.Error, BiometricApprovalGate.resultOf(BiometricPrompt.ERROR_HW_UNAVAILABLE))
    }
}
