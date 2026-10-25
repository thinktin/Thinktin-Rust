package cn.thinktin.app.navigation

import android.content.Intent
import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 待处理的深链（thinktin://…）。冷启动（onCreate）和热启动（singleTask 的 onNewIntent）都放进这里，
 * 由主界面（[MainNavigation]）在导航图建好之后交给 NavController 处理，处理完就清掉。
 *
 * 未登录时主界面不在，深链先留着，登录后再跳；同一条深链只处理一次（不会因为主界面重建而重复跳转）。
 */
class DeepLinkInbox {
    private val pending = MutableStateFlow<Uri?>(null)

    val current: StateFlow<Uri?> = pending.asStateFlow()

    /** 是我们的深链就收下并返回真。 */
    fun offer(intent: Intent?): Boolean {
        val uri = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data ?: return false
        if (uri.scheme != DeepLinks.SCHEME) return false
        pending.value = uri
        return true
    }

    fun restore(uri: Uri?) {
        if (uri != null && pending.value == null) pending.value = uri
    }

    /** 处理完 [uri] 之后清掉（期间又来了新的就保留新的）。 */
    fun consume(uri: Uri) {
        pending.compareAndSet(uri, null)
    }

    companion object {
        /**
         * 交给 NavController.handleDeepLink 的 intent。带 NEW_TASK | CLEAR_TASK：返回栈重建成“首页 → 目标页”
         * （和冷启动一样，返回键回首页）；只带 NEW_TASK 时 Navigation 会重启整个 Activity。
         */
        fun navigationIntent(uri: Uri): Intent =
            Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
    }
}
