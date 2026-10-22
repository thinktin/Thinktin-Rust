package cn.thinktin.app.ui.keys

import cn.thinktin.app.R
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.VendorInfo
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI

/**
 * 保存 key、填自定义接口地址、配模型别名之前的本地校验（和服务端一致，见 docs/llm-gateway.md 第 8、11 节：
 * gateway 的 credentials.rs、proto 的 vendors.rs、store 的别名约束）。服务端照样会查，这里只是早点在字段下提示。
 */
object KeyRules {
    /** 自定义接口（vLLM、OneAPI、中转站等）的厂商 id。 */
    const val CUSTOM_VENDOR = "custom"

    /** 默认别名：叫 main 的别名是 agent 的默认模型（orchestrator 的 executor）。 */
    const val MAIN_ALIAS = "main"

    const val MIN_KEY_LENGTH = 8
    const val MAX_KEY_LENGTH = 4096
    const val MAX_LABEL_LENGTH = 64
    const val MAX_MODEL_LENGTH = 128
    const val MAX_BASE_LENGTH = 512
    const val MAX_ALIASES = 16
    const val MAX_FALLBACKS = 3

    /** 每日 token 限额的上限（只防手滑多打几个 0）。 */
    const val MAX_DAILY_LIMIT = 1_000_000_000_000L

    /** 协议名，顺序就是界面上的顺序（proto::vendors::PROTOCOLS）。 */
    val PROTOCOLS = listOf("anthropic", "chat", "responses")

    /**
     * 订阅类 key（编程套餐、订阅套餐）的前缀：按厂商条款只能在官方工具里用，平台不能中转，保存时拒绝
     * （proto::vendors 的 subscription_key_prefixes）。
     */
    val SUBSCRIPTION_PREFIXES: Map<String, List<String>> = mapOf(
        "qwen-cn" to listOf("sk-sp-"),
        "qwen-intl" to listOf("sk-sp-"),
        "qwen-us" to listOf("sk-sp-"),
        "qwen-hk" to listOf("sk-sp-"),
        "minimax-cn" to listOf("sk-cp-"),
        "minimax-intl" to listOf("sk-cp-"),
        "anthropic" to listOf("sk-ant-oat", "sk-ant-ort"),
        "hunyuan-cn" to listOf("sk-tp-"),
        "hunyuan-intl" to listOf("sk-tp-"),
    )

    /** 套餐专用地址（proto::vendors::PLAN_ONLY_BASES）：自定义接口填这些地址时拒绝。 */
    val PLAN_ONLY_BASES = listOf(
        "https://ark.cn-beijing.volces.com/api/coding",
        "https://ark.cn-beijing.volces.com/api/plan",
        "https://ark.ap-southeast.bytepluses.com/api/coding",
        "https://qianfan.baidubce.com/v2/coding",
        "https://qianfan.baidubce.com/anthropic/coding",
        "https://api.lkeap.cloud.tencent.com/plan",
        "https://tokenhub-intl.tencentcloudmaas.com/plan",
        "https://api.stepfun.com/step_plan",
        "https://open.bigmodel.cn/api/coding",
        "https://api.z.ai/api/coding",
    )

    /** 模型别名的格式（库里的 CHECK 约束）：小写字母或数字开头，最多 64 个字符。 */
    private val ALIAS = Regex("^[a-z0-9][a-z0-9._-]{0,63}$")

    /** 不是公网的主机名后缀。 */
    private val LOCAL_SUFFIXES = listOf(".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp")

    // ---- key ----

    /** 检查一把 key；没问题返回 null。[vendor] 是厂商 id（自定义接口不查订阅前缀）。 */
    fun checkKey(vendor: String, key: String): UiText? {
        if (key.isEmpty()) return UiText(R.string.key_error_key_empty)
        // 服务端按字节数算；可打印 ASCII 以外的字符本来就不允许，先查字符。
        if (key.any { it.code !in 0x21..0x7e }) return UiText(R.string.key_error_key_chars)
        if (key.length < MIN_KEY_LENGTH) return UiText(R.string.key_error_key_short, listOf(MIN_KEY_LENGTH))
        if (key.length > MAX_KEY_LENGTH) return UiText(R.string.key_error_key_long, listOf(MAX_KEY_LENGTH))
        subscriptionPrefix(vendor, key)?.let { return UiText(R.string.key_error_subscription, listOf(it)) }
        return null
    }

    /** [key] 是 [vendor] 的订阅类 key 时返回命中的前缀。 */
    fun subscriptionPrefix(vendor: String, key: String): String? =
        SUBSCRIPTION_PREFIXES[vendor]?.firstOrNull { key.startsWith(it) }

    /**
     * 粘贴进来的 key 常带着多余的东西：首尾空白和换行、引号、`Bearer `、`export NAME=` / `NAME=`。去掉它们。
     */
    fun cleanPastedKey(raw: String): String {
        var key = raw.trim()
        Regex("^(?:export\\s+)?[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*").find(key)?.let { key = key.substring(it.range.last + 1) }
        key = key.trim().trim('"', '\'', '`').trim()
        if (key.startsWith("Bearer ", ignoreCase = true)) key = key.substring("Bearer ".length).trim()
        return key
    }

    // ---- 其他字段 ----

    /** 字数按 Unicode 码点算（服务端 check_len 用 chars().count()）：emoji、扩展区汉字算一个。 */
    fun length(text: String): Int = text.codePointCount(0, text.length)

    /** 按码点截到 [max] 个字（不会把代理对截一半）。 */
    fun clip(text: String, max: Int): String =
        if (length(text) <= max) text else text.substring(0, text.offsetByCodePoints(0, max))

    fun checkLabel(label: String): UiText? =
        if (length(label) > MAX_LABEL_LENGTH) UiText(R.string.key_error_label_long, listOf(MAX_LABEL_LENGTH)) else null

    /** 每日 token 限额：空表示不限；否则正整数（可以带千分位逗号和空格）。 */
    sealed interface DailyLimit {
        data object None : DailyLimit

        data class Value(val tokens: Long) : DailyLimit

        data class Invalid(val error: UiText) : DailyLimit
    }

    fun parseDailyLimit(text: String): DailyLimit {
        val digits = text.filterNot { it == ',' || it == '，' || it.isWhitespace() || it == '_' }
        if (digits.isEmpty()) return DailyLimit.None
        if (digits.any { it !in '0'..'9' }) return DailyLimit.Invalid(UiText(R.string.key_error_limit_number))
        val value = digits.trimStart('0').ifEmpty { "0" }
        if (value.length > 13) return DailyLimit.Invalid(UiText(R.string.key_error_limit_too_large))
        val tokens = value.toLong()
        return when {
            tokens <= 0 -> DailyLimit.Invalid(UiText(R.string.key_error_limit_positive))
            tokens > MAX_DAILY_LIMIT -> DailyLimit.Invalid(UiText(R.string.key_error_limit_too_large))
            else -> DailyLimit.Value(tokens)
        }
    }

    // ---- 自定义接口地址 ----

    /**
     * 检查自定义接口地址：只收 https、不带用户名密码 / 查询串 / 片段、主机是公网（不是 localhost、内网域名、
     * 私网 / 回环 / 链路本地 / 运营商 NAT / 保留的 IP），也不是套餐专用地址。服务端在请求时还会按解析结果再拦一次（SSRF）。
     */
    fun checkBase(url: String): UiText? {
        val text = url.trim()
        if (text.isEmpty()) return UiText(R.string.key_error_base_empty)
        if (!text.startsWith("https://")) return UiText(R.string.key_error_base_https)
        if (text.length > MAX_BASE_LENGTH) return UiText(R.string.key_error_base_long, listOf(MAX_BASE_LENGTH))
        val uri = try {
            URI(text)
        } catch (_: Exception) {
            return UiText(R.string.key_error_base_invalid)
        }
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
            return UiText(R.string.key_error_base_extra)
        }
        val host = hostOf(uri, text) ?: return UiText(R.string.key_error_base_invalid)
        if (!isPublicHost(host)) return UiText(R.string.key_error_base_private)
        planOnlyBase(text)?.let { return UiText(R.string.key_error_base_plan, listOf(it)) }
        return null
    }

    /** URI 的主机（小写；IPv6 去掉方括号）。主机名里有下划线时 java.net.URI 解析不出 host，退回手动截取。 */
    private fun hostOf(uri: URI, text: String): String? {
        uri.host?.let { return it.lowercase().removePrefix("[").removeSuffix("]") }
        val authority = uri.rawAuthority ?: text.removePrefix("https://").substringBefore('/')
        if (authority.isEmpty() || '@' in authority) return null
        val host = if (authority.startsWith("[")) {
            authority.substringAfter('[').substringBefore(']')
        } else {
            authority.substringBefore(':')
        }
        return host.lowercase().takeIf { it.isNotEmpty() && it.all { c -> c.isLetterOrDigit() || c in ".-_:" } }
    }

    /** 地址是不是套餐专用地址（按路径段匹配，不区分大小写），是的话返回命中的前缀。 */
    fun planOnlyBase(url: String): String? {
        val base = url.trim().lowercase()
        return PLAN_ONLY_BASES.firstOrNull { prefix ->
            base.startsWith(prefix) && (base.length == prefix.length || base[prefix.length] == '/')
        }
    }

    /** 主机是不是公网：域名要有点、不是本地后缀；IP 字面量按第 8 节的网段判断。 */
    fun isPublicHost(host: String): Boolean {
        val h = host.trim().lowercase().trimEnd('.')
        if (h.isEmpty()) return false
        if (':' in h) return isPublicIpv6(h)
        if (h == "localhost" || LOCAL_SUFFIXES.any { h.endsWith(it) }) return false
        val labels = h.split('.')
        // 最后一段是数字（或 0x…）：按 IP 写法处理，只认标准的四段十进制；0x7f.1、2130706433 这种写法一律不收。
        val last = labels.last()
        if (last.all { it.isDigit() } || last.startsWith("0x")) {
            val octets = parseIpv4(h) ?: return false
            return isPublicIpv4(octets)
        }
        if (labels.size < 2) return false
        return labels.all { it.isNotEmpty() && it.length <= 63 && !it.startsWith('-') && !it.endsWith('-') }
    }

    private fun parseIpv4(h: String): IntArray? {
        val parts = h.split('.')
        if (parts.size != 4) return null
        val octets = IntArray(4)
        for ((i, p) in parts.withIndex()) {
            if (p.isEmpty() || p.length > 3 || p.any { !it.isDigit() }) return null
            if (p.length > 1 && p.startsWith('0')) return null
            val v = p.toInt()
            if (v > 255) return null
            octets[i] = v
        }
        return octets
    }

    /** 本网络、私网、回环、运营商 NAT、链路本地、文档和基准测试网段、组播、保留地址都不是公网。 */
    fun isPublicIpv4(o: IntArray): Boolean {
        val (a, b, c) = Triple(o[0], o[1], o[2])
        return when {
            a == 0 || a == 10 || a == 127 -> false
            a == 100 && b in 64..127 -> false
            a == 169 && b == 254 -> false
            a == 172 && b in 16..31 -> false
            a == 192 && b == 0 && (c == 0 || c == 2) -> false
            a == 192 && b == 88 && c == 99 -> false
            a == 192 && b == 168 -> false
            a == 198 && (b == 18 || b == 19) -> false
            a == 198 && b == 51 && c == 100 -> false
            a == 203 && b == 0 && c == 113 -> false
            a >= 224 -> false
            else -> true
        }
    }

    /** IPv6 只放行全球单播 2000::/3，再排除 Teredo（2001::/32）、文档网段（2001:db8::/32）、6to4（2002::/16）。 */
    private fun isPublicIpv6(h: String): Boolean {
        if (h.any { !(it.isDigit() || it in 'a'..'f' || it == ':' || it == '.') }) return false
        val address = try {
            InetAddress.getByName(h) as? Inet6Address
        } catch (_: Exception) {
            null
        } ?: return false
        val bytes = address.address
        val first = bytes[0].toInt() and 0xff
        val second = bytes[1].toInt() and 0xff
        val third = bytes[2].toInt() and 0xff
        val fourth = bytes[3].toInt() and 0xff
        if (first and 0xe0 != 0x20) return false
        if (first == 0x20 && second == 0x01 && third == 0x00 && fourth == 0x00) return false
        if (first == 0x20 && second == 0x01 && third == 0x0d && fourth == 0xb8) return false
        if (first == 0x20 && second == 0x02) return false
        return true
    }

    // ---- 模型别名 ----

    fun checkAlias(alias: String): UiText? = when {
        alias.isEmpty() -> UiText(R.string.routes_error_alias_empty)
        !ALIAS.matches(alias) -> UiText(R.string.routes_error_alias_format)
        else -> null
    }

    fun checkModel(model: String): UiText? = when {
        model.isEmpty() -> UiText(R.string.routes_error_model_empty)
        length(model) > MAX_MODEL_LENGTH -> UiText(R.string.routes_error_model_long, listOf(MAX_MODEL_LENGTH))
        else -> null
    }

    /**
     * 这把 key 能不能给某个 agent 用：没停用，且支持 agent 运行时用的协议（[activeProtocol] 为 null 时不限；
     * 老的服务端不给 key 的协议时也不限）。
     */
    fun usable(credential: Credential, activeProtocol: String?): Boolean =
        !credential.disabled && supports(credential, activeProtocol)

    fun supports(credential: Credential, activeProtocol: String?): Boolean =
        activeProtocol == null || credential.protocols.isEmpty() || activeProtocol in credential.protocols

    // ---- 删除 key ----

    /**
     * 删除 key 之前把它从一个实例的别名里拿掉（服务端在有别名用着它时拒绝删除）：降级链里的直接去掉；
     * 它是主 key 时，第一个备用顶上来当主 key；没有备用的别名整个删掉（这个实例用到它时会等 key）。
     */
    fun detachCredential(routes: List<ModelRoute>, credentialId: String): List<ModelRoute> = routes.mapNotNull { route ->
        val fallbacks = route.fallbacks.filter { it.credentialId != credentialId }
        if (route.credentialId != credentialId) {
            route.copy(fallbacks = fallbacks)
        } else {
            val next = fallbacks.firstOrNull() ?: return@mapNotNull null
            ModelRoute(route.alias, next.credentialId, next.upstreamModel, fallbacks.drop(1))
        }
    }

    // ---- 厂商分组 ----

    /** 一组厂商：支持同样的协议。 */
    data class VendorGroup(val protocols: List<String>, val vendors: List<VendorInfo>)

    /**
     * 添加 key 第一步的厂商列表：按支持的协议分组（协议多的组在前，组内保持服务端的顺序），自定义接口不在这里（界面放最后）。
     */
    fun groupVendors(vendors: List<VendorInfo>): List<VendorGroup> = vendors
        .filter { it.id != CUSTOM_VENDOR }
        .groupBy { vendor -> PROTOCOLS.filter { it in vendor.protocols } + vendor.protocols.filter { it !in PROTOCOLS } }
        .map { (protocols, list) -> VendorGroup(protocols, list) }
        .sortedWith(
            compareByDescending<VendorGroup> { it.protocols.size }
                .thenBy { group -> group.protocols.joinToString(",") { PROTOCOLS.indexOf(it).toString() } },
        )
}
