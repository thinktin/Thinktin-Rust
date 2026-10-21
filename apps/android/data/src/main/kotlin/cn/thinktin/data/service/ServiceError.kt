package cn.thinktin.data.service

import cn.thinktin.core.ClientException

/**
 * ThinktinService 抛出的错误。界面按类型显示文案（:app 的 ErrorText），`message` 只进日志。
 * 由 client-core 的 ClientException 映射而来（[toServiceError]）。
 */
sealed class ServiceError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** 网络不通、超时：Snackbar 重试，离线时用缓存。 */
    class Network(val detail: String, cause: Throwable? = null) : ServiceError("network: $detail", cause)

    /** 没登录或登录失效：回登录页。 */
    class SignedOut(cause: Throwable? = null) : ServiceError("signed out", cause)

    /** 客户端版本太老：提示升级。 */
    class UpgradeRequired(cause: Throwable? = null) : ServiceError("upgrade required", cause)

    /** 账号被冻结：显示冻结说明页。 */
    class AccountFrozen(cause: Throwable? = null) : ServiceError("account frozen", cause)

    /** 服务端返回的错误；[code] 是 not_found、conflict、rate_limited…… */
    class Api(
        val status: Int,
        val code: String,
        val detail: String,
        val retryAfterSecs: Long?,
        cause: Throwable? = null,
    ) : ServiceError("api $status $code: $detail", cause)

    /** 消息里有像密码的内容，没发出去：先存进保险箱。 */
    class ContainsSecrets(val count: Int, cause: Throwable? = null) : ServiceError("contains $count secrets", cause)

    /** 服务端已有、client-core 还没接的操作（真实服务里调用会抛这个）。 */
    class Unsupported(val operation: String) : ServiceError("unsupported: $operation")

    /** 其余（解析、缓存、参数、内部错误）。[kind] 是来源类型，只用于日志。 */
    class Other(val kind: String, val detail: String, cause: Throwable? = null) : ServiceError("$kind: $detail", cause)
}

/** ClientException（UniFFI）→ ServiceError。 */
fun ClientException.toServiceError(): ServiceError = when (this) {
    is ClientException.Network -> ServiceError.Network(message, this)
    is ClientException.SignedOut -> ServiceError.SignedOut(this)
    is ClientException.UpgradeRequired -> ServiceError.UpgradeRequired(this)
    is ClientException.AccountFrozen -> ServiceError.AccountFrozen(this)
    is ClientException.Api -> ServiceError.Api(
        status = status.toInt(),
        code = code,
        detail = message,
        retryAfterSecs = retryAfterSecs?.let { if (it > Long.MAX_VALUE.toULong()) Long.MAX_VALUE else it.toLong() },
        cause = this,
    )
    is ClientException.ContainsSecrets -> ServiceError.ContainsSecrets(
        count = if (count > Int.MAX_VALUE.toUInt()) Int.MAX_VALUE else count.toInt(),
        cause = this,
    )
    is ClientException.Decode -> ServiceError.Other("decode", message, this)
    is ClientException.Cache -> ServiceError.Other("cache", message, this)
    is ClientException.InvalidArgument -> ServiceError.Other("invalid_argument", message, this)
    is ClientException.Internal -> ServiceError.Other("internal", message, this)
}

/** 任意异常 → ServiceError（已经是的原样返回）。 */
fun Throwable.asServiceError(): ServiceError = when (this) {
    is ServiceError -> this
    is ClientException -> toServiceError()
    else -> ServiceError.Other(this::class.java.simpleName, message.orEmpty(), this)
}
