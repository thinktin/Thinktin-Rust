package cn.thinktin.data

import cn.thinktin.data.model.CapabilityRules
import cn.thinktin.data.model.ComputerAction
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

    @Test
    fun runAndDeleteAreReadFromTheSignedArguments() {
        fun request(tool: String, arguments: String) = ComputerApprovalRequest(
            desktopId = "mac-1", requestId = "r1", tool = tool, argumentsJson = arguments, summary = "from the Mac",
            issuedAt = 1_760_000_000, expiresAt = 1_760_000_600,
        )
        val run = request("computer_run", """{"command":"rm -rf build","cwd":"/Users/a/app","reason":"clean"}""")
        assertEquals(ComputerAction.Run("rm -rf build", "/Users/a/app"), run.action())
        assertEquals("clean", run.reason())
        assertEquals(ComputerAction.Run("ls", null), request("computer_run", """{"command":"ls"}""").action())
        val delete = request("computer_delete", """{"path":"/Users/a/x.zip","reason":""}""")
        assertEquals(ComputerAction.Delete("/Users/a/x.zip"), delete.action())
        assertNull("空的理由不算", delete.reason())
        // 别的工具、参数不全、不是 JSON：界面用电脑给的说明。
        assertNull(request("computer_type", """{"text":"hi"}""").action())
        assertNull(request("computer_run", """{"cwd":"/"}""").action())
        assertNull(request("computer_delete", "not json").action())
    }
}
