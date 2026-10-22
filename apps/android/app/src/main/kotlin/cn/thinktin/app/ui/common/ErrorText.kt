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
        error.isRateLimited ->
            error.retryAfterSecs?.let { UiText(R.string.error_rate_limited, listOf(it.toInt())) }
                ?: UiText(R.string.error_rate_limited_plain)
        error.code == "not_found" || error.status == 404 -> UiText(R.string.error_not_found)
        error.code == "conflict" || error.status == 409 -> UiText(R.string.error_conflict)
        error.code == "forbidden" || error.status == 403 -> UiText(R.string.error_forbidden)
        error.code.startsWith("quota") || error.code == "budget_exceeded" -> UiText(R.string.error_quota)
        error.isInvalid -> UiText(R.string.error_invalid)
        else -> UiText(R.string.error_server, listOf(error.code.ifEmpty { error.status.toString() }))
    }
}

/** 限频（rate_limited / 429）：[ServiceError.Api.retryAfterSecs] 是剩余秒数。 */
val ServiceError.Api.isRateLimited: Boolean get() = code == "rate_limited" || status == 429

/** 请求不合法（invalid…、400、422）：表单页按字段提示。 */
val ServiceError.Api.isInvalid: Boolean get() = code.startsWith("invalid") || status == 400 || status == 422

/** 限频的剩余秒数（没给时为 null），换成 Int 方便倒计时。 */
val ServiceError.Api.retryAfterSeconds: Int?
    get() = retryAfterSecs?.takeIf { it > 0 }?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()

/** 值得原样重试的错误（网络不通、服务暂时不可用）：Snackbar 带“重试”。 */
val ServiceError.isRetryable: Boolean
    get() = this is ServiceError.Network ||
        (this is ServiceError.Api && (code == "unavailable" || code == "internal" || status >= 500))

@Composable
fun UiText.asString(): String = stringResource(resId, *args.toTypedArray())

@Composable
fun errorText(error: ServiceError): String = ErrorText.of(error).asString()
