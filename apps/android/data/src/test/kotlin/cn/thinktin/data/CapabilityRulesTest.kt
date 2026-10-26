package cn.thinktin.data

import cn.thinktin.data.model.CapabilityRules
import cn.thinktin.data.model.ComputerApprovalRequest
import cn.thinktin.data.model.parseJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 能力令牌的规则、审批请求的正文解析（13.9，和 iOS 的 ComputerLinkModelTests 同一批例子）。 */
class CapabilityRulesTest {
    @Test
    fun directoriesAndBundleIds() {
        assertTrue(CapabilityRules.isValidDirectory("/Users/me"))
        assertFalse(CapabilityRules.isValidDirectory("Users/me"))
        assertFalse(CapabilityRules.isValidDirectory("/Users/../etc"))
        assertTrue(CapabilityRules.isValidBundleId("com.apple.Safari"))
        assertFalse(CapabilityRules.isValidBundleId("Safari"))
        assertFalse(CapabilityRules.isValidBundleId("com..apple"))
        assertFalse(CapabilityRules.isValid(emptyList(), emptyList()))
        assertEquals(listOf("/a"), CapabilityRules.cleaned(listOf(" /a ", "/a", "")))
    }

    @Test
    fun approvalRequestsParseFromTheBody() {
        val body = parseJsonObject(
            """{"request":{"desktop_id":"mac-1","request_id":"r1","tool":"delete_files","arguments_json":"{}",
               "summary":"删除","issued_at":1760000000,"expires_at":1760000600}}""",
        )
        val request = ComputerApprovalRequest.fromBody(body)!!
        assertEquals("r1", request.requestId)
        assertEquals(1_760_000_600L, request.expiresAt)
        assertNull(ComputerApprovalRequest.fromBody(parseJsonObject("""{"request":"x"}""")))
    }
}
