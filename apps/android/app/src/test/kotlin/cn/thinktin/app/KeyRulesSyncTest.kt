package cn.thinktin.app

import cn.thinktin.app.ui.keys.KeyRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * [KeyRules] 里抄了一份服务端的订阅 key 前缀和套餐专用地址（client-core 的 VendorInfo 不带这些）：
 * 和 crates/proto/src/vendors.rs 比对，那边改了这里没跟上就失败（文件路径由 app/build.gradle.kts 传进来）。
 */
class KeyRulesSyncTest {
    private val source: String by lazy {
        val path = System.getProperty("thinktin.vendorsRs") ?: error("thinktin.vendorsRs 没设（见 app/build.gradle.kts）")
        File(path).readText()
    }

    private fun strings(list: String): List<String> = Regex("\"([^\"]*)\"").findAll(list).map { it.groupValues[1] }.toList()

    @Test
    fun subscriptionPrefixesMatchProto() {
        // 每个厂商的 id 和它后面第一个 subscription_key_prefixes 配对，只留非空的。
        val pattern = Regex(
            """\bid:\s*"([^"]+)"[\s\S]*?subscription_key_prefixes:\s*&\[([^\]]*)\]""",
        )
        val parsed = pattern.findAll(source)
            .map { it.groupValues[1] to strings(it.groupValues[2]) }
            .filter { it.second.isNotEmpty() }
            .toMap()
        assertTrue("vendors.rs 里应该有订阅前缀（解析失败？）", parsed.isNotEmpty())
        assertEquals(parsed, KeyRules.SUBSCRIPTION_PREFIXES)
    }

    @Test
    fun planOnlyBasesMatchProto() {
        val block = Regex("""PLAN_ONLY_BASES:\s*&\[&str\]\s*=\s*&\[([\s\S]*?)\];""").find(source)
            ?: error("vendors.rs 里找不到 PLAN_ONLY_BASES")
        val parsed = strings(block.groupValues[1])
        assertTrue(parsed.isNotEmpty())
        assertEquals(parsed, KeyRules.PLAN_ONLY_BASES)
    }
}
