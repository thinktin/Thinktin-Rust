package cn.thinktin.data.model

object ImVendors {
    const val FEISHU = "feishu"
    const val LARK = "lark"
    const val WECOM = "wecom"
    const val DINGTALK = "dingtalk"
    val ALL = listOf(FEISHU, LARK, WECOM, DINGTALK)
}

object ImEvents {
    const val RUN_FINISHED = "run_finished"
    const val RUN_FAILED = "run_failed"
    const val APPROVAL = "approval"
    val ALL = listOf(RUN_FINISHED, RUN_FAILED, APPROVAL)
}

/**
 * IM 渠道的规则（13.15）：和服务端一样（crates/proto/src/im.rs、gateway 的 `routes/im_channels.rs`），App 在本地先拦，
 * Mock 照着校验。
 *
 * - webhook 地址要一字不差地以官方前缀开头（https、官方域名、官方路径），后面只能跟 token（8 到 128 个字母、数字、
 *   `-`、`_`）；首尾的空白不算。
 * - 签名密钥：飞书、Lark、钉钉可以有，企业微信没有；8 到 128 个可见 ASCII 字符，钉钉的以 `SEC` 开头。空的就是没有。
 * - 备注 0 到 64 个码点，不能有控制字符；事件至少一种。
 * - 每个账号最多 20 个渠道；测试消息每小时最多 10 条（多了 429）。
 */
object ImChannelRules {
    const val MAX_CHANNELS = 20
    const val MAX_LABEL = 64
    const val TESTS_PER_HOUR = 10
    const val MAX_WEBHOOK = 512

    enum class Problem { UnknownAddress, BadToken, SecretNotSupported, BadSecret, BadLabel, NoEvents }

    data class ParsedWebhook(val vendor: String, val token: String)

    private val TOKEN = Regex("^[A-Za-z0-9_-]{8,128}$")

    fun webhookBase(vendor: String): String? = when (vendor) {
        ImVendors.FEISHU -> "https://open.feishu.cn/open-apis/bot/v2/hook/"
        ImVendors.LARK -> "https://open.larksuite.com/open-apis/bot/v2/hook/"
        ImVendors.WECOM -> "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key="
        ImVendors.DINGTALK -> "https://oapi.dingtalk.com/robot/send?access_token="
        else -> null
    }

    /** 有没有“加签”：企业微信没有（地址里的 key 就是凭证）。 */
    fun supportsSecret(vendor: String): Boolean = vendor != ImVendors.WECOM

    /** 粘贴时认出是哪家（还没粘完整也认得出）。 */
    fun vendorOf(url: String): String? {
        val trimmed = url.trim()
        return ImVendors.ALL.firstOrNull { vendor -> webhookBase(vendor)?.let { trimmed.startsWith(it) } == true }
    }

    /** 解析地址：平台和 token；不对时为 null（原因看 [webhookProblem]）。 */
    fun parseWebhook(url: String): ParsedWebhook? {
        val trimmed = url.trim()
        val vendor = vendorOf(trimmed) ?: return null
        val token = trimmed.removePrefix(webhookBase(vendor)!!)
        return if (TOKEN.matches(token)) ParsedWebhook(vendor, token) else null
    }

    fun webhookProblem(url: String): Problem? = when {
        vendorOf(url) == null -> Problem.UnknownAddress
        parseWebhook(url) == null -> Problem.BadToken
        else -> null
    }

    /** 签名密钥（去掉首尾空白后为空就是没有，返回 null）。 */
    fun secretProblem(secret: String, vendor: String): Problem? {
        val trimmed = secret.trim()
        if (trimmed.isEmpty()) return null
        if (!supportsSecret(vendor)) return Problem.SecretNotSupported
        val visible = trimmed.all { it in '!'..'~' }
        if (trimmed.length !in 8..128 || !visible) return Problem.BadSecret
        if (vendor == ImVendors.DINGTALK && !trimmed.startsWith("SEC")) return Problem.BadSecret
        return null
    }

    fun labelProblem(label: String): Problem? = when {
        VaultRules.length(label) > MAX_LABEL -> Problem.BadLabel
        VaultRules.hasControlCharacters(label) -> Problem.BadLabel
        else -> null
    }

    fun eventsProblem(events: List<String>): Problem? = if (events.isEmpty()) Problem.NoEvents else null

    /** 给用户辨认用的提示（和服务端一样）：token 后 4 位。 */
    fun hint(token: String): String = "…" + token.takeLast(4)
}
