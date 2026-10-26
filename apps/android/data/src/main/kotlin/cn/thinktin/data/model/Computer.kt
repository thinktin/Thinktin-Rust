package cn.thinktin.data.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.Base64

// 手机控制电脑（13.9，docs/pairing.md）：配对、高危操作的签名审批、普通操作的能力令牌。
// 编码、解析、验签在 client-core（[PairingCodec]，真实现是 CorePairingCodec），签名在 Keystore 里（[DeviceSigner]，
// App 的 KeystoreSigner），这里只有类型和规则。和 iOS 12.9 的 ThinktinKit 同一套。

/** 电脑给出的配对邀请（二维码 `thinktin-pair:v1?…` 里的内容）。 */
@Serializable
data class PairingOffer(
    val desktopId: String,
    /** 电脑的公钥（SEC1，base64url）。 */
    val desktopKey: String,
    /** 一次性随机数（base64url）。 */
    val nonce: String,
    /** 过期时间（Unix 秒）。 */
    val expiresAt: Long,
)

/** 电脑请手机签名批准的高危操作。经设备中继转发时是消息正文 `{"request": …}`。 */
@Serializable
data class ComputerApprovalRequest(
    val desktopId: String,
    val requestId: String,
    /** 工具名，比如 `delete_files`。 */
    val tool: String,
    /** 工具参数（JSON 文本）；签的是规范化之后的摘要。 */
    val argumentsJson: String,
    /** 给人看的说明（agent 写的）；签的是它的摘要，界面上显示的和电脑要执行的对得上。 */
    val summary: String,
    /** 签发和过期时间（Unix 秒）。 */
    val issuedAt: Long,
    val expiresAt: Long,
) {
    fun isExpired(nowSecs: Long): Boolean = expiresAt <= nowSecs

    /**
     * 执行命令、删除要做什么（从参数里取；参数在签名覆盖的范围里，手机按界面语言说出来和电脑要做的对得上——电脑发来的
     * [summary] 是英文的）。别的工具、参数不全、不是 JSON 时为 null，界面用 [summary]（也在签名里）。
     */
    fun action(): ComputerAction? {
        val args = arguments() ?: return null
        return when (tool) {
            "computer_run" -> args.string("command")?.let { ComputerAction.Run(it, args.string("cwd")) }
            "computer_delete" -> args.string("path")?.let { ComputerAction.Delete(it) }
            else -> null
        }
    }

    /** agent 写的理由（原话；空的不算）。 */
    fun reason(): String? = arguments()?.string("reason")?.takeIf { it.isNotEmpty() }

    private fun arguments(): JsonObject? =
        runCatching { Json.parseToJsonElement(argumentsJson) as? JsonObject }.getOrNull()

    companion object {
        /** 从消息正文解析；格式不对时为 null。 */
        fun fromBody(body: JsonObject): ComputerApprovalRequest? {
            val r = body.obj("request") ?: return null
            return ComputerApprovalRequest(
                desktopId = r.string("desktop_id") ?: return null,
                requestId = r.string("request_id") ?: return null,
                tool = r.string("tool") ?: return null,
                argumentsJson = r.string("arguments_json") ?: return null,
                summary = r.string("summary") ?: return null,
                issuedAt = r.long("issued_at") ?: return null,
                expiresAt = r.long("expires_at") ?: return null,
            )
        }
    }
}

/** 电脑高危操作要做的事（审批卡片按手机的界面语言说）。 */
sealed interface ComputerAction {
    data class Run(val command: String, val cwd: String?) : ComputerAction

    data class Delete(val path: String) : ComputerAction
}

/** 手机签发给电脑的能力令牌：普通操作能碰哪些目录、哪些应用，到什么时候。 */
@Serializable
data class CapabilityGrant(
    val desktopId: String,
    val tokenId: String,
    /** 能读写的目录（绝对路径）。 */
    val dirs: List<String>,
    /** 能操作的应用（bundle id）。 */
    val apps: List<String>,
    /** Unix 秒。 */
    val expiresAt: Long,
) {
    /** 消息正文里的样子。 */
    fun toJson(): JsonObject = JsonObject(
        mapOf(
            "desktop_id" to JsonPrimitive(desktopId),
            "token_id" to JsonPrimitive(tokenId),
            "dirs" to JsonArray(dirs.map(::JsonPrimitive)),
            "apps" to JsonArray(apps.map(::JsonPrimitive)),
            "expires_at" to JsonPrimitive(expiresAt),
        ),
    )
}

/** 编码、解析、验签出的错（client-core 的 `PairingError`）。 */
sealed class PairingCodecException(message: String) : Exception(message) {
    /** 格式不对：二维码、公钥、字段、签名的编码。 */
    class Malformed(val detail: String) : PairingCodecException("malformed: $detail")
    class Expired : PairingCodecException("expired")
    class BadSignature : PairingCodecException("bad signature")
}

/**
 * client-core 的配对与验签（docs/pairing.md）：要签的字节、二维码解析、验电脑的签名。手机、电脑两边用同一份实现，
 * 签的字节一定一致。真实现是 [cn.thinktin.data.core.CorePairingCodec]，测试里是假的。都抛 [PairingCodecException]。
 */
interface PairingCodec {
    fun parseOffer(uri: String): PairingOffer
    fun responseMessage(offer: PairingOffer, phoneId: String, phoneKey: String): ByteArray
    fun verifyConfirmation(offer: PairingOffer, phoneId: String, phoneKey: String, signature: ByteArray)
    fun approvalMessage(request: ComputerApprovalRequest, approve: Boolean): ByteArray
    fun capabilityMessage(grant: CapabilityGrant): ByteArray

    /** SEC1 公钥 → base64url（顺便检查是不是合法的 P-256 公钥）。 */
    fun encodePublicKey(sec1: ByteArray): String
}

/** Keystore 里的签名密钥出的错。 */
sealed class DeviceSignerException(message: String) : Exception(message) {
    /** 设备没有安全硬件，或者没设置生物识别 / 锁屏。 */
    class Unavailable : DeviceSignerException("unavailable")
    class Cancelled : DeviceSignerException("cancelled")

    /** 密钥失效了（录入了新的指纹、人脸）：要重新生成、重新配对。 */
    class KeyInvalidated : DeviceSignerException("key invalidated")

    /** 生物识别失败次数太多被锁定了：稍后再试（或先用锁屏密码解锁）。 */
    class Lockout : DeviceSignerException("lockout")
    class Failed(val detail: String) : DeviceSignerException(detail)
}

/** Keystore 里的 P-256 签名密钥（13.9）：私钥不出安全硬件，每次签名都要生物识别。都抛 [DeviceSignerException]。 */
interface DeviceSigner {
    fun isAvailable(): Boolean

    /** 公钥（SEC1，不压缩 65 字节）。没有密钥时先生成。 */
    suspend fun publicKey(): ByteArray

    /** 验证通过后签 [message]（SHA256withECDSA），返回 DER。[reason] 显示在系统的验证框上。 */
    suspend fun sign(message: ByteArray, reason: String): ByteArray

    /** 删掉密钥（失效了、重置时）；下次 [publicKey] 生成新的。 */
    suspend fun resetKey()
}

/** 消息正文里的二进制（签名）：不带填充的 base64url。 */
object PairingEncoding {
    fun base64url(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun fromBase64url(text: String): ByteArray? = try {
        Base64.getUrlDecoder().decode(text.trimEnd('='))
    } catch (_: IllegalArgumentException) {
        null
    }
}

/**
 * 能力令牌的规则：和电脑那边（`desktop` 的 `policy.rs`、client-core 的 `capability_allows_path`）一样
 * 目录要是绝对路径、不能有 `..`；应用是 bundle id。至少给一个目录或一个应用。
 */
object CapabilityRules {
    /** 有效期可选的几档（秒）。 */
    val DURATIONS: List<Long> = listOf(3600L, 8 * 3600L, 24 * 3600L, 7 * 24 * 3600L)

    private val BUNDLE_PART = Regex("^[\\p{L}\\p{N}_-]+$")

    fun isValidDirectory(path: String): Boolean =
        path.startsWith("/") && '\n' !in path && path.split('/').none { it == ".." }

    fun isValidBundleId(id: String): Boolean {
        val parts = id.split('.')
        return parts.size >= 2 && parts.all { BUNDLE_PART.matches(it) }
    }

    /** 整理用户填的：去掉首尾空白、空行、重复的。 */
    fun cleaned(items: List<String>): List<String> = items.map { it.trim() }.filter { it.isNotEmpty() }.distinct()

    fun isValid(dirs: List<String>, apps: List<String>): Boolean =
        (dirs.isNotEmpty() || apps.isNotEmpty()) && dirs.all(::isValidDirectory) && apps.all(::isValidBundleId)
}

/** 配对好的一台电脑（手机这边记下的）。 */
@Serializable
data class PairedComputer(
    val desktopId: String,
    /** 电脑的公钥（二维码里来的）。 */
    val desktopKey: String,
    /** 配对时手机的公钥：密钥换了就对不上，要重新配对。 */
    val phoneKey: String,
    val pairedAtMs: Long,
)

/** 扫了码、发了配对回复、等电脑确认。 */
@Serializable
data class PendingPairing(val offer: PairingOffer, val phoneKey: String, val sentAtMs: Long)

/** 签发出去的一个能力令牌。 */
@Serializable
data class IssuedGrant(val grant: CapabilityGrant, val issuedAtMs: Long, val revoked: Boolean = false) {
    fun isActive(nowSecs: Long): Boolean = !revoked && grant.expiresAt > nowSecs
}

/**
 * 手机和电脑之间的状态，存在本机（按账号分开）：配好的电脑、等确认的配对、收到还没处理的审批请求、签发过的令牌。
 * 审批请求从服务端收下就确认掉了（不确认会一直重发），所以要自己存着，处理了或过期了再删。
 */
@Serializable
data class ComputerLinkState(
    val computers: List<PairedComputer> = emptyList(),
    val pending: PendingPairing? = null,
    val requests: List<ComputerApprovalRequest> = emptyList(),
    val grants: List<IssuedGrant> = emptyList(),
)
