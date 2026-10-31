package cn.thinktin.app.push

import android.util.Log
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** 推送通道（服务端的 `PushChannelKind`）和令牌。极光报 `unipush`，FCM 报 `fcm`。 */
data class PushToken(val channel: String, val token: String)

/**
 * 推送令牌和点开过的通知（13.8，在 [cn.thinktin.app.AppContainer] 里，进程里一份）：
 *
 * - 推送 SDK 给了令牌（[onNewToken]，每次启动都有，可能比服务就绪早）：登录着就报给服务端（`set_push_token`），
 *   同一个服务、同一个令牌只报一次；没登录时登录带上（[token]），登录成功后再报一次也没关系。
 * - 点开了通知（[onOpened]）：那条收件箱通知等登录着时标已读（冷启动时服务还没就绪）。
 *
 * [sync] 由根界面在服务就绪、登录状态变化、令牌或待标已读变化时调。
 */
class PushCoordinator {
    private val tokenState = MutableStateFlow<PushToken?>(null)
    val token: StateFlow<PushToken?> = tokenState.asStateFlow()

    private val readsState = MutableStateFlow<Set<String>>(emptySet())

    /** 点开过、还没标已读的收件箱通知。 */
    val pendingReads: StateFlow<Set<String>> = readsState.asStateFlow()

    private val restoreState = MutableStateFlow(false)
    val pendingAccountRestore: StateFlow<Boolean> = restoreState.asStateFlow()

    private val mutex = Mutex()

    /** 已经报过的（服务按对象认：切换演示模式换了服务要重新报）。 */
    private var reported: Pair<ThinktinService, PushToken>? = null

    fun onNewToken(channel: String, token: String) {
        if (token.isBlank()) return
        tokenState.value = PushToken(channel, token.trim())
    }

    fun onOpened(message: PushMessage) {
        if (message.subtype == "account_restored") restoreState.value = true
        val id = message.inboxId ?: return
        readsState.update { it + id }
    }

    /** 登录着：报令牌、标已读；没登录：忘掉报过的（下次登录要再报）。 */
    suspend fun sync(service: ThinktinService) = mutex.withLock {
        if (restoreState.compareAndSet(true, false) && service.authState.value == AuthState.Frozen) {
            try {
                service.me()
            } catch (e: ServiceError) {
                Log.w(TAG, "重新检查账号状态失败", e)
            }
        }
        if (service.authState.value != AuthState.SignedIn) {
            if (reported?.first === service) reported = null
            return@withLock
        }
        val token = tokenState.value
        val last = reported
        if (token != null && !(last != null && last.first === service && last.second == token)) {
            try {
                service.setPushToken(token.channel, token.token)
                reported = service to token
            } catch (e: ServiceError) {
                // 下次启动、令牌变了、重新登录时再报。
                Log.w(TAG, "上报推送令牌失败", e)
            }
        }
        val reads = readsState.value
        if (reads.isNotEmpty()) {
            try {
                service.markInboxRead(reads.toList())
                readsState.update { it - reads }
            } catch (e: ServiceError) {
                // 断网：留着下次再标；其余（通知删了、不是这个账号的）不再试。
                if (e !is ServiceError.Network) readsState.update { it - reads }
            }
        }
    }

    private companion object {
        const val TAG = "PushCoordinator"
    }
}
