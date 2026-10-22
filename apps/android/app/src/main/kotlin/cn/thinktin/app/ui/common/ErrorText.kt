package cn.thinktin.app.ui.common

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import cn.thinktin.app.R
import cn.thinktin.data.service.ServiceError

/** 一条要显示的文案：字符串资源 + 格式参数。 */
data class UiText(@StringRes val resId: Int, val args: List<Any> = emptyList())

/**
 * ServiceError → 界面文案（第 5 节：服务端错误按 code 映射到本地文案，message 只进日志）。
 */
object ErrorText {
    fun of(error: ServiceError): UiText = when (error) {
        is ServiceError.Network -> UiText(R.string.error_network)
        is ServiceError.SignedOut -> UiText(R.string.error_signed_out)
        is ServiceError.UpgradeRequired -> UiText(R.string.error_upgrade_required)
        is ServiceError.AccountFrozen -> UiText(R.string.error_account_frozen)
        is ServiceError.ContainsSecrets -> UiText(R.string.error_contains_secrets, listOf(error.count))
        is ServiceError.Unsupported -> UiText(R.string.error_unsupported)
        is ServiceError.TlsUnavailable -> UiText(R.string.error_tls_unavailable)
        is ServiceError.Other -> UiText(R.string.error_other)
        is ServiceError.Api -> api(error)
    }

    private fun api(error: ServiceError.Api): UiText = when {
        error.code == "rate_limited" || error.status == 429 ->
            error.retryAfterSecs?.let { UiText(R.string.error_rate_limited, listOf(it.toInt())) }
                ?: UiText(R.string.error_rate_limited_plain)
        error.code == "not_found" || error.status == 404 -> UiText(R.string.error_not_found)
        error.code == "conflict" || error.status == 409 -> UiText(R.string.error_conflict)
        error.code == "forbidden" || error.status == 403 -> UiText(R.string.error_forbidden)
        error.code.startsWith("quota") || error.code == "budget_exceeded" -> UiText(R.string.error_quota)
        error.code.startsWith("invalid") || error.status == 400 || error.status == 422 -> UiText(R.string.error_invalid)
        else -> UiText(R.string.error_server, listOf(error.code.ifEmpty { error.status.toString() }))
    }
}

@Composable
fun UiText.asString(): String = stringResource(resId, *args.toTypedArray())

@Composable
fun errorText(error: ServiceError): String = ErrorText.of(error).asString()
