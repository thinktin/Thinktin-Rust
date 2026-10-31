package cn.thinktin.data

import cn.thinktin.data.model.ImChannelRules
import cn.thinktin.data.model.ImChannelRules.Problem
import cn.thinktin.data.model.ImVendors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** IM 渠道的规则（13.15）：和 crates/proto/src/im.rs 的测试同一批例子，iOS 的 ImChannelRulesTests 也是。 */
class ImChannelRulesTest {
    @Test
    fun officialAddressesParseToVendorAndToken() {
        val cases = listOf(
            Triple(
                "https://open.feishu.cn/open-apis/bot/v2/hook/2f8a6c1e-1111-4a2b-9c3d-0123456789ab",
                ImVendors.FEISHU, "2f8a6c1e-1111-4a2b-9c3d-0123456789ab",
            ),
            Triple("https://open.larksuite.com/open-apis/bot/v2/hook/abcdef1234567890", ImVendors.LARK, "abcdef1234567890"),
            Triple(
                " https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa\n",
                ImVendors.WECOM, "693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa",
            ),
            Triple(
                "https://oapi.dingtalk.com/robot/send?access_token=0123456789abcdef0123456789abcdef",
                ImVendors.DINGTALK, "0123456789abcdef0123456789abcdef",
            ),
        )
        for ((url, vendor, token) in cases) {
            assertEquals(url, ImChannelRules.ParsedWebhook(vendor, token), ImChannelRules.parseWebhook(url))
            assertNull(url, ImChannelRules.webhookProblem(url))
        }
        assertEquals("…cdef", ImChannelRules.hint("0123456789abcdef"))
    }

    @Test
    fun lookalikesAreRejected() {
        val token = "0123456789abcdef"
        for (url in listOf(
            "https://open.feishu.cn.evil.com/open-apis/bot/v2/hook/$token",
            "https://open.feishu.cn./open-apis/bot/v2/hook/$token",
            "https://OPEN.FEISHU.CN/open-apis/bot/v2/hook/$token",
            "https://open.feishu.cn:8443/open-apis/bot/v2/hook/$token",
            "https://user@open.feishu.cn/open-apis/bot/v2/hook/$token",
            "https://evil.com/?https://open.feishu.cn/open-apis/bot/v2/hook/$token",
            "https://open.feishu.cn/open-apis/bot/hook/$token",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?debug=1&key=$token",
            "http://open.feishu.cn/open-apis/bot/v2/hook/$token",
            "",
        )) {
            assertEquals(url, Problem.UnknownAddress, ImChannelRules.webhookProblem(url))
        }
        for (url in listOf(
            "https://open.feishu.cn/open-apis/bot/v2/hook/$token/x",
            "https://open.feishu.cn/open-apis/bot/v2/hook/$token?x=1",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=$token&debug=1",
            "https://oapi.dingtalk.com/robot/send?access_token=short",
            "https://oapi.dingtalk.com/robot/send?access_token=" + "a".repeat(129),
            "https://open.feishu.cn/open-apis/bot/v2/hook/",
        )) {
            assertEquals(url, Problem.BadToken, ImChannelRules.webhookProblem(url))
        }
        // 没粘完整也认得出是哪家。
        assertEquals(ImVendors.FEISHU, ImChannelRules.vendorOf("https://open.feishu.cn/open-apis/bot/v2/hook/"))
        assertNull(ImChannelRules.vendorOf("https://example.com"))
    }

    @Test
    fun secrets() {
        assertNull(ImChannelRules.secretProblem("  ", ImVendors.WECOM))
        assertEquals(Problem.SecretNotSupported, ImChannelRules.secretProblem("SEC12345", ImVendors.WECOM))
        assertNull(ImChannelRules.secretProblem("abcdefgh", ImVendors.FEISHU))
        assertEquals(Problem.BadSecret, ImChannelRules.secretProblem("abc", ImVendors.FEISHU))
        assertEquals(Problem.BadSecret, ImChannelRules.secretProblem("abcd efgh", ImVendors.FEISHU))
        assertEquals(Problem.BadSecret, ImChannelRules.secretProblem("密钥密钥密钥密钥", ImVendors.LARK))
        assertEquals(Problem.BadSecret, ImChannelRules.secretProblem("a".repeat(129), ImVendors.FEISHU))
        assertEquals(Problem.BadSecret, ImChannelRules.secretProblem("12345678", ImVendors.DINGTALK))
        assertNull(ImChannelRules.secretProblem("SEC12345", ImVendors.DINGTALK))
    }

    @Test
    fun labelsAndEvents() {
        assertNull(ImChannelRules.labelProblem(""))
        assertNull(ImChannelRules.labelProblem("群".repeat(64)))
        assertEquals(Problem.BadLabel, ImChannelRules.labelProblem("群".repeat(65)))
        assertEquals(Problem.LabelControl, ImChannelRules.labelProblem("研发\n群"))
        assertEquals(Problem.NoEvents, ImChannelRules.eventsProblem(emptyList()))
        assertNull(ImChannelRules.eventsProblem(listOf("approval")))
    }
}
