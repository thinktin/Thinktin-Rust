package cn.thinktin.app

import cn.thinktin.app.computer.ComputerLinkStore
import cn.thinktin.app.computer.InMemoryComputerLinkStorage
import cn.thinktin.app.ui.computer.ComputerLinkError
import cn.thinktin.app.ui.computer.ComputerLinkEvent
import cn.thinktin.app.ui.computer.ComputerLinkViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.CapabilityRules
import cn.thinktin.data.model.DeviceMessage
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.DeviceSignerException
import cn.thinktin.data.model.PairingCodecException
import cn.thinktin.data.model.PairingEncoding
import cn.thinktin.data.model.obj
import cn.thinktin.data.model.string
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** 13.9：手机控制电脑的视图模型（和 iOS 的 ComputerLinkModelTests 同一批场景）。 */
@OptIn(ExperimentalCoroutinesApi::class)
class ComputerLinkViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private var nowMs = DemoTestApp.FIXED_CLOCK.millis()
    private val mock = MockThinktinService(clock = { nowMs })
    private val storage = InMemoryComputerLinkStorage()
    private val store = ComputerLinkStore(storage)
    private val signer = FakeSigner()
    private val phone = "dev-this"
    private val mac = "dev-mac"
    private val phoneKey = PairingEncoding.base64url("phone-key-1".toByteArray())

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun nowSecs() = nowMs / 1000

    private fun code(desktop: String, nonce: String = "n1", expiresIn: Long = 600) = "pair:$desktop:$nonce:${nowSecs() + expiresIn}"

    private fun make(
        store: ComputerLinkStore = this.store,
        signer: FakeSigner = this.signer,
    ) = ComputerLinkViewModel(mock, FakeCodec(::nowSecs), signer, store, clock = { nowMs })

    private fun deliver(kind: DeviceMessageKind, body: JsonObject, from: String = mac): DeviceMessage =
        mock.deliverDeviceMessage(from, kind, body.toString())

    private fun confirmBody(vm: ComputerLinkViewModel) = buildJsonObject {
        val pending = vm.uiState.value.link.pending!!
        put("nonce", pending.offer.nonce)
        put("signature", PairingEncoding.base64url(FakeCodec.confirmation(pending.offer, phone, pending.phoneKey).toByteArray()))
    }

    private fun request(id: String, from: String = mac, expiresIn: Long = 600) = buildJsonObject {
        put(
            "request",
            buildJsonObject {
                put("desktop_id", from); put("request_id", id); put("tool", "delete_files")
                put("arguments_json", """{"paths":["/tmp/a"]}"""); put("summary", "删除 /tmp/a")
                put("issued_at", nowSecs()); put("expires_at", nowSecs() + expiresIn)
            },
        )
    }

    private fun sent(): DeviceMessage = mock.sentDeviceMessages().last()

    private fun signatureText(message: DeviceMessage): String =
        String(PairingEncoding.fromBase64url(message.body.string("signature")!!)!!)

    private suspend fun TestScope.pairMac(vm: ComputerLinkViewModel) {
        vm.pair(code(mac), "配对")
        advanceUntilIdle()
        deliver(DeviceMessageKind.PairConfirm, confirmBody(vm))
        vm.sync()
        advanceUntilIdle()
        assertNotNull(vm.uiState.value.paired(mac))
    }

    @Test
    fun pairs() = runTest(dispatcher) {
        val vm = make()
        advanceUntilIdle()
        val s0 = vm.uiState.value
        assertEquals(listOf(mac), s0.computers.map { it.id })
        assertTrue(s0.canSign)
        // 演示数据里那条（电脑没配对）收下就确认掉了，不显示。
        assertTrue(mock.deviceMessages().isEmpty())
        assertTrue(s0.pendingRequests(nowMs).isEmpty())

        vm.pair(code(mac), "配对电脑")
        advanceUntilIdle()
        assertTrue(vm.uiState.value.isPairing)
        val response = sent()
        assertEquals(DeviceMessageKind.PairResponse, response.kind)
        assertEquals(mac, response.toDeviceId)
        assertEquals("n1", response.body.string("nonce"))
        assertEquals(phoneKey, response.body.string("phone_key"))
        assertEquals("signed:response|$mac|n1|$phone|$phoneKey", signatureText(response))
        assertEquals(listOf("配对电脑"), signer.reasons)

        // 别的随机数（旧邀请）的确认不算，但也确认掉。
        deliver(DeviceMessageKind.PairConfirm, buildJsonObject { put("nonce", "old"); put("signature", "eA") })
        vm.sync()
        assertTrue(vm.uiState.value.isPairing)
        assertTrue(mock.deviceMessages().isEmpty())

        deliver(DeviceMessageKind.PairConfirm, confirmBody(vm))
        vm.sync()
        advanceUntilIdle()
        val s = vm.uiState.value
        assertFalse(s.isPairing)
        assertEquals("dk-$mac", s.paired(mac)?.desktopKey)
        assertEquals(phoneKey, s.paired(mac)?.phoneKey)
        assertNull(s.error)
    }

    @Test
    fun pairingErrors() = runTest(dispatcher) {
        val vm = make()
        advanceUntilIdle()
        suspend fun attempt(code: String): ComputerLinkError? {
            vm.pair(code, "")
            advanceUntilIdle()
            return vm.uiState.value.error
        }
        assertEquals(ComputerLinkError.NotYourComputer, attempt(code("dev-elsewhere")))
        assertTrue((attempt("https://example.com") as ComputerLinkError.Pairing).error is PairingCodecException.Malformed)
        assertTrue((attempt(code(mac, expiresIn = -60)) as ComputerLinkError.Pairing).error is PairingCodecException.Expired)
        signer.failNext = DeviceSignerException.Cancelled()
        assertTrue((attempt(code(mac)) as ComputerLinkError.Signer).error is DeviceSignerException.Cancelled)
        assertFalse(vm.uiState.value.isPairing)
        assertTrue(mock.sentDeviceMessages().isEmpty())

        assertNull(attempt(code(mac)))
        deliver(DeviceMessageKind.PairConfirm, buildJsonObject { put("nonce", "n1"); put("signature", "Zm9yZ2Vk") })
        vm.sync()
        advanceUntilIdle()
        assertTrue((vm.uiState.value.error as ComputerLinkError.Pairing).error is PairingCodecException.BadSignature)
        assertFalse(vm.uiState.value.isPairing)
        assertNull(vm.uiState.value.paired(mac))
    }

    @Test
    fun awaitsConfirmationAndTimesOut() = runTest(dispatcher) {
        val vm = make()
        advanceUntilIdle()
        vm.pair(code(mac), "")
        advanceUntilIdle()
        val waiting = launch { vm.awaitConfirmation(intervalMs = 1_000) }
        advanceTimeBy(2_500)
        assertTrue(waiting.isActive)
        deliver(DeviceMessageKind.PairConfirm, confirmBody(vm))
        advanceUntilIdle()
        assertFalse(waiting.isActive)
        assertNotNull(vm.uiState.value.paired(mac))

        // 邀请过期（加上 5 分钟的时钟误差）还没等到：算失败，不再等。
        vm.pair(code(mac, nonce = "n2", expiresIn = 60), "")
        advanceUntilIdle()
        assertTrue(vm.uiState.value.isPairing)
        nowMs += 20 * 60_000
        vm.sync()
        advanceUntilIdle()
        assertFalse(vm.uiState.value.isPairing)
        assertEquals(ComputerLinkError.PairingTimedOut, vm.uiState.value.error)
    }

    @Test
    fun approvals() = runTest(dispatcher) {
        val vm = make()
        advanceUntilIdle()
        // 还没配对：不收。
        deliver(DeviceMessageKind.ApprovalRequest, request("r0"))
        vm.sync()
        advanceUntilIdle()
        assertTrue(vm.uiState.value.pendingRequests(nowMs).isEmpty())

        pairMac(vm)
        deliver(DeviceMessageKind.ApprovalRequest, request("r1"))
        deliver(DeviceMessageKind.ApprovalRequest, request("r1"))
        deliver(DeviceMessageKind.ApprovalRequest, request("r2", expiresIn = -1))
        deliver(DeviceMessageKind.ApprovalRequest, request("r3", from = "dev-iphone"), from = "dev-iphone")
        deliver(DeviceMessageKind.ApprovalRequest, request("r4", from = "dev-iphone"))
        deliver(DeviceMessageKind.ApprovalRequest, buildJsonObject { put("request", "not an object") })
        vm.sync()
        advanceUntilIdle()
        assertEquals(listOf("r1"), vm.uiState.value.pendingRequests(nowMs).map { it.requestId })
        // 收下的都确认掉了，请求自己存着：重新打开 App（新的存储对象读同一份数据）还在。
        assertTrue(mock.deviceMessages().isEmpty())
        val reopened = make(store = ComputerLinkStore(storage))
        advanceUntilIdle()
        assertEquals(listOf("r1"), reopened.uiState.value.pendingRequests(nowMs).map { it.requestId })
        val sibling = make()
        advanceUntilIdle()
        assertEquals(listOf("r1"), sibling.uiState.value.pendingRequests(nowMs).map { it.requestId })

        val events = mutableListOf<ComputerLinkEvent>()
        val collecting = launch { vm.events.collect { events += it } }
        val r1 = vm.uiState.value.pendingRequests(nowMs).single()
        vm.decide(r1, approve = false, reason = "拒绝")
        advanceUntilIdle()
        val decision = sent()
        assertEquals(DeviceMessageKind.ApprovalDecision, decision.kind)
        assertEquals("r1", decision.body.string("request_id"))
        assertEquals(false, decision.body["approve"]?.jsonPrimitive?.booleanOrNull)
        assertEquals("signed:approval|r1|false", signatureText(decision))
        assertTrue(vm.uiState.value.pendingRequests(nowMs).isEmpty())
        assertEquals(listOf<ComputerLinkEvent>(ComputerLinkEvent.Decided(r1, false)), events)
        // 另一个视图模型（审批中心）用的是同一个存储对象，看到的是同一份：已经没了。
        assertTrue(sibling.uiState.value.pendingRequests(nowMs).isEmpty())

        // 过期的直接拿掉，不签名。
        deliver(DeviceMessageKind.ApprovalRequest, request("r5", expiresIn = 30))
        vm.sync()
        advanceUntilIdle()
        val r5 = vm.uiState.value.pendingRequests(nowMs).single()
        nowMs += 60_000
        val signed = signer.reasons.size
        vm.decide(r5, approve = true, reason = "")
        advanceUntilIdle()
        assertEquals(signed, signer.reasons.size)
        assertTrue((vm.uiState.value.error as ComputerLinkError.Pairing).error is PairingCodecException.Expired)
        assertTrue(vm.uiState.value.link.requests.isEmpty())
        collecting.cancel()
    }

    @Test
    fun grants() = runTest(dispatcher) {
        val vm = make()
        advanceUntilIdle()
        vm.issueGrant(mac, listOf("/Users/me"), emptyList(), 3600, "")
        assertEquals(ComputerLinkError.NotPaired, vm.uiState.value.error)
        pairMac(vm)

        for (dirs in listOf(listOf("relative/path"), listOf("/Users/me/../x"), listOf(" "))) {
            vm.issueGrant(mac, dirs, emptyList(), 3600, "")
            assertEquals(ComputerLinkError.InvalidGrant, vm.uiState.value.error)
        }
        val event = nextOf(vm.events)
        vm.issueGrant(mac, listOf(" /Users/me/Documents ", "/Users/me/Documents", ""), listOf("com.apple.Safari"), 3600, "授权")
        advanceUntilIdle()
        val issued = (event.await() as ComputerLinkEvent.GrantIssued).grant
        assertEquals(listOf("/Users/me/Documents"), issued.grant.dirs)
        assertEquals(listOf("com.apple.Safari"), issued.grant.apps)
        assertEquals(nowSecs() + 3600, issued.grant.expiresAt)
        val capability = sent()
        assertEquals(DeviceMessageKind.Capability, capability.kind)
        assertEquals(issued.grant.tokenId, capability.body.obj("grant")?.string("token_id"))
        // Unix 秒是整数（服务端是 u64）。
        assertTrue(capability.bodyJson, Regex(""""expires_at":[0-9]+[,}]""").containsMatchIn(capability.bodyJson))
        assertEquals("signed:capability|${issued.grant.tokenId}|/Users/me/Documents", signatureText(capability))
        assertEquals(listOf(issued.grant.tokenId), vm.uiState.value.activeGrants(mac, nowMs).map { it.grant.tokenId })

        vm.revoke(issued)
        advanceUntilIdle()
        val revocation = sent()
        assertEquals(DeviceMessageKind.Revocation, revocation.kind)
        assertEquals(issued.grant.tokenId, revocation.body.string("token_id"))
        assertTrue(vm.uiState.value.activeGrants(mac, nowMs).isEmpty())
    }

    @Test
    fun keyChangesResetAndUnpairing() = runTest(dispatcher) {
        val vm = make()
        advanceUntilIdle()
        pairMac(vm)
        vm.issueGrant(mac, listOf("/Users/me"), emptyList(), 3600, "")
        advanceUntilIdle()
        val issued = vm.uiState.value.activeGrants(mac, nowMs).single()

        // 录了新指纹（密钥换了）：重新打开时要重新配对。
        signer.key = "new-key".toByteArray()
        val reopened = make()
        advanceUntilIdle()
        assertTrue(reopened.uiState.value.needsRepair)
        signer.failNext = DeviceSignerException.KeyInvalidated()
        reopened.issueGrant(mac, listOf("/x"), emptyList(), 3600, "")
        advanceUntilIdle()
        assertTrue((reopened.uiState.value.error as ComputerLinkError.Signer).error is DeviceSignerException.KeyInvalidated)
        reopened.resetKey()
        advanceUntilIdle()
        assertTrue(mock.sentDeviceMessages().any { it.kind == DeviceMessageKind.Revocation && issued.grant.tokenId in it.bodyJson })
        assertTrue(reopened.uiState.value.link.computers.isEmpty())
        assertFalse(reopened.uiState.value.needsRepair)
        assertTrue(vm.uiState.value.activeGrants(mac, nowMs).isEmpty())

        // 解除配对：先吊销发给它的令牌。
        val fresh = make(store = ComputerLinkStore(InMemoryComputerLinkStorage()), signer = FakeSigner())
        advanceUntilIdle()
        pairMac(fresh)
        fresh.issueGrant(mac, listOf("/Users/me"), emptyList(), 3600, "")
        advanceUntilIdle()
        val token = fresh.uiState.value.activeGrants(mac, nowMs).single().grant.tokenId
        fresh.unpair(mac)
        advanceUntilIdle()
        assertNull(fresh.uiState.value.paired(mac))
        assertTrue(mock.sentDeviceMessages().any { it.kind == DeviceMessageKind.Revocation && token in it.bodyJson })
        assertTrue(issued.grant.tokenId != token)
    }

    @Test
    fun cannotSignWithoutStrongBiometrics() = runTest(dispatcher) {
        signer.available = false
        val vm = make()
        advanceUntilIdle()
        assertFalse(vm.uiState.value.canSign)
    }

    @Test
    fun durationsAreTheSameAsOnIos() {
        assertEquals(listOf(3600L, 28_800L, 86_400L, 604_800L), CapabilityRules.DURATIONS)
    }

    /** 等 [flow] 的下一个值（在后台收）。 */
    private fun <T> TestScope.nextOf(flow: Flow<T>) = backgroundScope.async { flow.first() }
}
