package cn.thinktin.app.ui.computer

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.computer.ComputerLinkStore
import cn.thinktin.data.model.CapabilityGrant
import cn.thinktin.data.model.CapabilityRules
import cn.thinktin.data.model.ComputerApprovalRequest
import cn.thinktin.data.model.ComputerLinkState
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.DeviceMessage
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.DeviceSigner
import cn.thinktin.data.model.DeviceSignerException
import cn.thinktin.data.model.IssuedGrant
import cn.thinktin.data.model.PairedComputer
import cn.thinktin.data.model.PairingCodec
import cn.thinktin.data.model.PairingCodecException
import cn.thinktin.data.model.PairingEncoding
import cn.thinktin.data.model.PendingPairing
import cn.thinktin.data.model.string
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/** 手机控制电脑出的错。 */
sealed interface ComputerLinkError {
    data class Service(val error: ServiceError) : ComputerLinkError

    data class Pairing(val error: PairingCodecException) : ComputerLinkError

    data class Signer(val error: DeviceSignerException) : ComputerLinkError

    /** 二维码里的电脑没登录这个账号（或者已经下线）。 */
    data object NotYourComputer : ComputerLinkError

    /** 这台电脑还没配对。 */
    data object NotPaired : ComputerLinkError

    /** 等电脑确认的时候邀请过期了（电脑没在线、没收到）。 */
    data object PairingTimedOut : ComputerLinkError

    /** 能力令牌的目录、应用不对（见 [CapabilityRules]）。 */
    data object InvalidGrant : ComputerLinkError
}

/** 一次性的结果（界面关掉编辑框、提示）。 */
sealed interface ComputerLinkEvent {
    data class GrantIssued(val grant: IssuedGrant) : ComputerLinkEvent

    data class Decided(val request: ComputerApprovalRequest, val approve: Boolean) : ComputerLinkEvent
}

data class ComputerLinkUiState(
    /** 这个账号登录着的电脑（devices() 里的 macOS 设备）。 */
    val computers: List<DeviceInfo> = emptyList(),
    val link: ComputerLinkState = ComputerLinkState(),
    val hasLoaded: Boolean = false,
    val loading: Boolean = false,
    /** 正在签名、发送（按钮转圈、不能重复点）。 */
    val working: Boolean = false,
    val error: ComputerLinkError? = null,
    /** 这台设备能签名（有安全硬件、录了强生物识别）。 */
    val canSign: Boolean = true,
    /** 密钥换了（录入了新指纹、人脸）：配过的电脑要重新配对。 */
    val needsRepair: Boolean = false,
) {
    val isPairing: Boolean get() = link.pending != null

    fun paired(desktopId: String): PairedComputer? = link.computers.firstOrNull { it.desktopId == desktopId }

    fun name(desktopId: String): String? = computers.firstOrNull { it.id == desktopId }?.name

    /** 还没处理、没过期的审批请求，快过期的在前。 */
    fun pendingRequests(nowMs: Long): List<ComputerApprovalRequest> =
        link.requests.filter { !it.isExpired(nowMs / 1000) }.sortedBy { it.expiresAt }

    /** 还有效的令牌（没吊销、没过期），新的在前。 */
    fun activeGrants(desktopId: String, nowMs: Long): List<IssuedGrant> =
        link.grants.filter { it.grant.desktopId == desktopId && it.isActive(nowMs / 1000) }.sortedByDescending { it.issuedAtMs }
}

/**
 * 手机控制电脑（13.9，docs/pairing.md），和 iOS 12.9 的 ComputerLinkModel 一样：
 *
 * - **配对**：扫电脑上的二维码（[pair]）→ 解析邀请、确认是自己账号的电脑 → Keystore 签配对回复（要生物识别）→ 经平台发给电脑
 *   （`pair_response`）→ 等电脑签的确认（`pair_confirm`，用二维码里的电脑公钥验）→ 记下电脑。等确认时每隔几秒收一次消息
 *   （[awaitConfirmation]，配对框开着时跑），邀请过期了还没等到就算失败。
 * - **审批**：电脑的删除、执行命令这类操作发来 `approval_request`；只收配好的电脑发来的、没过期的。批准或拒绝都要签名
 *   （签的是参数和说明的摘要、决定），发回 `approval_decision`。收下的请求马上在服务端确认掉，存在本机（[ComputerLinkStore]），
 *   处理了或过期了再删。
 * - **能力令牌**：给配好的电脑签发普通操作能碰的目录、应用和有效期（`capability`），随时吊销（`revocation`，不用签名）。
 * - 密钥录入了新指纹、人脸后失效（[ComputerLinkUiState.needsRepair]）：要重新生成、重新配对。
 *
 * 状态存在 App 唯一的 [ComputerLinkStore] 里：设备页和审批中心各有一个视图模型，改的是同一份。
 */
class ComputerLinkViewModel(
    private val service: ThinktinService,
    private val codec: PairingCodec,
    private val signer: DeviceSigner,
    private val store: ComputerLinkStore,
    private val clock: () -> Long,
) : ViewModel() {
    private val state = MutableStateFlow(ComputerLinkUiState())
    val uiState: StateFlow<ComputerLinkUiState> = state.asStateFlow()

    private val eventChannel = Channel<ComputerLinkEvent>(Channel.BUFFERED)
    val events: Flow<ComputerLinkEvent> = eventChannel.receiveAsFlow()

    private var userId: String? = null
    private var currentDeviceId: String? = null
    private var linkJob: Job? = null
    private var shownOnce = false

    init {
        load()
    }

    /** 页面每次显示时调：第一次已经在 init 里加载了；之后（从别的页面回来）重新拉设备、收消息。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load()
    }

    /** 拉设备列表、收消息、看密钥换没换。 */
    fun load() {
        if (state.value.loading) return
        state.update { it.copy(loading = true) }
        viewModelScope.launch {
            try {
                loadNow()
            } finally {
                state.update { it.copy(loading = false) }
            }
        }
    }

    private suspend fun loadNow() {
        try {
            val (user, devices) = coroutineScope {
                val user = async { service.me() }
                val devices = async { service.devices() }
                user.await() to devices.await()
            }
            attach(user.id)
            currentDeviceId = devices.firstOrNull { it.current }?.id
            state.update { s ->
                s.copy(computers = devices.filter { it.platform.isComputer }, hasLoaded = true)
            }
        } catch (e: ServiceError) {
            fail(e)
            return
        }
        val canSign = signer.isAvailable()
        state.update { it.copy(canSign = canSign) }
        checkKey()
        sync()
    }

    /** 跟着这个账号的状态（第一次知道是谁时）。 */
    private fun attach(id: String) {
        if (userId == id) return
        userId = id
        linkJob?.cancel()
        linkJob = viewModelScope.launch {
            store.state(id).collect { link -> state.update { it.copy(link = link) } }
        }
    }

    private fun link(): ComputerLinkState = userId?.let { store.state(it).value } ?: ComputerLinkState()

    /** 收电脑发来的消息：配对确认、审批请求。收下的都在服务端确认掉（不确认会一直重发）。 */
    suspend fun sync() {
        val me = currentDeviceId ?: return
        val userId = userId ?: return
        val messages = try {
            service.deviceMessages()
        } catch (e: ServiceError) {
            fail(e)
            return
        }
        val nowMs = clock()
        var outcome: ComputerLinkError? = null
        var repaired = false
        store.update(userId) { current ->
            var next = current
            for (message in messages) {
                when (message.kind) {
                    DeviceMessageKind.PairConfirm -> {
                        val pending = next.pending ?: continue
                        if (message.fromDeviceId != pending.offer.desktopId || message.body.string("nonce") != pending.offer.nonce) {
                            continue
                        }
                        next = next.copy(pending = null)
                        when (val result = confirm(pending, message, me)) {
                            null -> {
                                next = next.paired(pending, nowMs)
                                repaired = true
                            }
                            else -> outcome = result
                        }
                    }
                    DeviceMessageKind.ApprovalRequest -> next = next.received(message, nowMs / 1000)
                    else -> Unit
                }
            }
            val pruned = next.pruned(nowMs)
            if (next.pending != null && pruned.pending == null) outcome = ComputerLinkError.PairingTimedOut
            pruned
        }
        state.update { s ->
            s.copy(
                error = outcome ?: s.error,
                needsRepair = if (repaired) false else s.needsRepair,
            )
        }
        for (chunk in messages.map { it.id }.chunked(DeviceMessage.MAX_ACK_COUNT)) {
            try {
                service.ackDeviceMessages(chunk)
            } catch (_: ServiceError) {
                // 没确认掉的下次还会收到；同一个请求不会重复记（按 request_id 去重）。
            }
        }
    }

    /** 验电脑签的确认；对的话返回 null。 */
    private fun confirm(pending: PendingPairing, message: DeviceMessage, me: String): ComputerLinkError? {
        val signature = message.body.string("signature")?.let(PairingEncoding::fromBase64url)
            ?: return ComputerLinkError.Pairing(PairingCodecException.Malformed("signature"))
        return try {
            codec.verifyConfirmation(pending.offer, me, pending.phoneKey, signature)
            null
        } catch (e: PairingCodecException) {
            ComputerLinkError.Pairing(e)
        }
    }

    private suspend fun checkKey() {
        if (!state.value.canSign || link().computers.isEmpty()) return
        val encoded = try {
            codec.encodePublicKey(signer.publicKey())
        } catch (_: DeviceSignerException) {
            return
        } catch (_: PairingCodecException) {
            return
        }
        state.update { s -> s.copy(needsRepair = link().computers.any { it.phoneKey != encoded }) }
    }

    fun clearError() {
        state.update { it.copy(error = null) }
    }

    // ---- 配对 ----

    /** 扫到的二维码（或者粘贴的配对码）：签配对回复发给电脑，之后等确认（[awaitConfirmation]）。 */
    fun pair(code: String, reason: String) {
        val me = currentDeviceId ?: return
        val userId = userId ?: return
        work {
            val offer = codec.parseOffer(code.trim())
            if (state.value.computers.none { it.id == offer.desktopId }) throw LinkFailure(ComputerLinkError.NotYourComputer)
            val phoneKey = currentPublicKey()
            val signature = signer.sign(codec.responseMessage(offer, me, phoneKey), reason)
            val body = buildJsonObject {
                put("nonce", offer.nonce)
                put("phone_key", phoneKey)
                put("signature", PairingEncoding.base64url(signature))
            }
            service.sendDeviceMessage(offer.desktopId, DeviceMessageKind.PairResponse, body.toString())
            store.update(userId) { it.copy(pending = PendingPairing(offer, phoneKey, clock())) }
        }
    }

    /** 等电脑的确认：每隔 [intervalMs] 收一次消息，直到配好、失败或者邀请过期。配对框开着时跑，关了就取消。 */
    suspend fun awaitConfirmation(intervalMs: Long = POLL_INTERVAL_MS) {
        while (link().pending != null) {
            delay(intervalMs)
            sync()
        }
    }

    /** 不等了（取消配对）。 */
    fun cancelPairing() {
        val userId = userId ?: return
        store.update(userId) { it.copy(pending = null) }
    }

    /** 解除和这台电脑的配对：先吊销发给它的令牌（尽力），再忘掉它。电脑那边要在电脑上解除。 */
    fun unpair(desktopId: String) {
        val userId = userId ?: return
        viewModelScope.launch {
            for (grant in state.value.activeGrants(desktopId, clock())) revokeNow(grant)
            store.update(userId) { s ->
                s.copy(
                    computers = s.computers.filterNot { it.desktopId == desktopId },
                    requests = s.requests.filterNot { it.desktopId == desktopId },
                )
            }
        }
    }

    /** 密钥失效后：删掉旧密钥和所有配对（要重新扫码）。 */
    fun resetKey() {
        val userId = userId ?: return
        viewModelScope.launch {
            signer.resetKey()
            store.update(userId) { s ->
                s.copy(computers = emptyList(), requests = emptyList(), grants = s.grants.map { it.copy(revoked = true) })
            }
            state.update { it.copy(needsRepair = false, error = null) }
        }
    }

    // ---- 审批 ----

    /** 批准或拒绝电脑的高危操作：都要签名（拒绝的签名不会被当成批准）。过期了的直接拿掉。 */
    fun decide(request: ComputerApprovalRequest, approve: Boolean, reason: String) {
        val userId = userId ?: return
        if (state.value.working) return
        if (request.isExpired(clock() / 1000)) {
            store.update(userId) { it.without(request) }
            state.update { it.copy(error = ComputerLinkError.Pairing(PairingCodecException.Expired())) }
            return
        }
        work {
            val signature = signer.sign(codec.approvalMessage(request, approve), reason)
            val body = buildJsonObject {
                put("request_id", request.requestId)
                put("approve", approve)
                put("signature", PairingEncoding.base64url(signature))
            }
            service.sendDeviceMessage(request.desktopId, DeviceMessageKind.ApprovalDecision, body.toString())
            store.update(userId) { it.without(request) }
            eventChannel.trySend(ComputerLinkEvent.Decided(request, approve))
        }
    }

    // ---- 能力令牌 ----

    /** 给配好的电脑签发令牌。目录、应用先整理（去空白、去重）再查。 */
    fun issueGrant(desktopId: String, dirs: List<String>, apps: List<String>, durationSecs: Long, reason: String) {
        val userId = userId ?: return
        if (state.value.working) return
        if (state.value.paired(desktopId) == null) {
            state.update { it.copy(error = ComputerLinkError.NotPaired) }
            return
        }
        val cleanDirs = CapabilityRules.cleaned(dirs)
        val cleanApps = CapabilityRules.cleaned(apps)
        if (!CapabilityRules.isValid(cleanDirs, cleanApps)) {
            state.update { it.copy(error = ComputerLinkError.InvalidGrant) }
            return
        }
        work {
            val issuedAtMs = clock()
            val grant = CapabilityGrant(
                desktopId = desktopId, tokenId = UUID.randomUUID().toString(), dirs = cleanDirs, apps = cleanApps,
                expiresAt = issuedAtMs / 1000 + durationSecs,
            )
            val signature = signer.sign(codec.capabilityMessage(grant), reason)
            val body = buildJsonObject {
                put("grant", grant.toJson())
                put("signature", PairingEncoding.base64url(signature))
            }
            service.sendDeviceMessage(desktopId, DeviceMessageKind.Capability, body.toString())
            val issued = IssuedGrant(grant, issuedAtMs)
            store.update(userId) { it.copy(grants = it.grants + issued) }
            eventChannel.trySend(ComputerLinkEvent.GrantIssued(issued))
        }
    }

    /** 吊销（不用签名：吊销只会收紧权限）。电脑不在线时平台排队 24 小时。 */
    fun revoke(issued: IssuedGrant) {
        viewModelScope.launch { revokeNow(issued) }
    }

    private suspend fun revokeNow(issued: IssuedGrant) {
        val userId = userId ?: return
        try {
            val body = buildJsonObject { put("token_id", issued.grant.tokenId) }
            service.sendDeviceMessage(issued.grant.desktopId, DeviceMessageKind.Revocation, body.toString())
            store.update(userId) { s ->
                s.copy(grants = s.grants.map { if (it.grant.tokenId == issued.grant.tokenId) it.copy(revoked = true) else it })
            }
        } catch (e: ServiceError) {
            fail(e)
        }
    }

    // ---- 内部 ----

    private class LinkFailure(val error: ComputerLinkError) : Exception()

    /** 签名、发送：[working] 期间不能重复点；出错写进 [ComputerLinkUiState.error]。 */
    private fun work(block: suspend () -> Unit) {
        if (state.value.working) return
        state.update { it.copy(working = true, error = null) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail(e)
            } finally {
                state.update { it.copy(working = false) }
            }
        }
    }

    private suspend fun currentPublicKey(): String = codec.encodePublicKey(signer.publicKey())

    private fun fail(e: Exception) {
        val error = when (e) {
            is LinkFailure -> e.error
            is ServiceError -> ComputerLinkError.Service(e)
            is PairingCodecException -> ComputerLinkError.Pairing(e)
            is DeviceSignerException -> ComputerLinkError.Signer(e)
            // 不该有别的（签名、编码都包成了自己的错）：当成内部错误显示，不让 App 崩。
            else -> ComputerLinkError.Service(ServiceError.Other("internal", e.toString(), e))
        }
        state.update { s ->
            s.copy(
                error = error,
                needsRepair = s.needsRepair || (error is ComputerLinkError.Signer && error.error is DeviceSignerException.KeyInvalidated),
            )
        }
    }

    companion object {
        const val POLL_INTERVAL_MS = 3_000L

        /** 两台设备的时钟允许差这么多（client-core 的 `CLOCK_SKEW_SECS`）。 */
        const val CLOCK_SKEW_SECS = 5 * 60L

        /** 过期、吊销超过这么久的令牌不再显示。 */
        const val GRANT_HISTORY_SECS = 7 * 24 * 3600L
    }
}

/** 电脑确认了：记下（重新配对同一台电脑时，电脑那边清掉了之前的令牌，这边也标成吊销）。 */
private fun ComputerLinkState.paired(pending: PendingPairing, nowMs: Long): ComputerLinkState {
    val desktopId = pending.offer.desktopId
    return copy(
        computers = computers.filterNot { it.desktopId == desktopId } +
            PairedComputer(desktopId, pending.offer.desktopKey, pending.phoneKey, nowMs),
        grants = grants.map { if (it.grant.desktopId == desktopId) it.copy(revoked = true) else it },
    )
}

/** 收下一条审批请求：只收配好的电脑自己发来的、没过期的、没收过的。 */
private fun ComputerLinkState.received(message: DeviceMessage, nowSecs: Long): ComputerLinkState {
    val request = ComputerApprovalRequest.fromBody(message.body) ?: return this
    val accepted = request.desktopId == message.fromDeviceId &&
        computers.any { it.desktopId == request.desktopId } &&
        !request.isExpired(nowSecs) &&
        requests.none { it.requestId == request.requestId }
    return if (accepted) copy(requests = requests + request) else this
}

/** 过期的请求、过期的配对邀请去掉；过期超过一周的令牌不再留着。 */
private fun ComputerLinkState.pruned(nowMs: Long): ComputerLinkState {
    val nowSecs = nowMs / 1000
    val pending = pending?.takeIf { it.offer.expiresAt + ComputerLinkViewModel.CLOCK_SKEW_SECS > nowSecs }
    return copy(
        pending = pending,
        requests = requests.filterNot { it.isExpired(nowSecs) },
        grants = grants.filter { it.grant.expiresAt + ComputerLinkViewModel.GRANT_HISTORY_SECS > nowSecs },
    )
}

private fun ComputerLinkState.without(request: ComputerApprovalRequest): ComputerLinkState =
    copy(requests = requests.filterNot { it.requestId == request.requestId })
