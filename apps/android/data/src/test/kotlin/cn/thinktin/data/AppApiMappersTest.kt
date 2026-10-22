package cn.thinktin.data

import cn.thinktin.data.core.toCore
import cn.thinktin.data.core.toModel
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.DevicePlatform
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.model.ReportReason
import cn.thinktin.data.model.ReportState
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TemplateMember
import cn.thinktin.data.model.string
import cn.thinktin.data.service.ServiceError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import cn.thinktin.core.ContentReport as CoreContentReport
import cn.thinktin.core.DeviceInfo as CoreDeviceInfo
import cn.thinktin.core.DeviceMessage as CoreDeviceMessage
import cn.thinktin.core.NewPlan as CoreNewPlan
import cn.thinktin.core.Plan as CorePlan
import cn.thinktin.core.PlanChange as CorePlanChange
import cn.thinktin.core.PlanPolicy as CorePlanPolicy
import cn.thinktin.core.PlanStep as CorePlanStep
import cn.thinktin.core.Schedule as CoreSchedule
import cn.thinktin.core.Team as CoreTeam
import cn.thinktin.core.TeamMember as CoreTeamMember
import cn.thinktin.core.TeamTemplate as CoreTeamTemplate
import cn.thinktin.core.TemplateMember as CoreTemplateMember

/** 11.7 / 11.8 / 5.5 新接口的映射（两个方向）。 */
class AppApiMappersTest {
    private val now = 1_760_000_000_000L

    private fun expectInvalid(block: () -> Unit) {
        try {
            block()
            fail("Unknown 不能发给服务端")
        } catch (e: ServiceError.Other) {
            assertEquals("invalid_argument", e.kind)
        }
    }

    @Test
    fun deviceInfoMapsPlatformAndFlags() {
        val core = CoreDeviceInfo("d1", "macos", "MacBook", null, current = false, online = true, now - 5, now)
        val model = core.toModel()
        assertEquals(DevicePlatform.Macos, model.platform)
        assertTrue(model.online)
        assertNull(model.pushChannel)
        assertEquals(now - 5, model.createdAtMs)
        assertEquals(now, model.lastSeenAtMs)
        assertEquals(DevicePlatform.Unknown, core.copy(platform = "windows").toModel().platform)
        assertEquals("fcm", core.copy(pushChannel = "fcm").toModel().pushChannel)
    }

    @Test
    fun deviceMessageParsesBodyAndKind() {
        val core = CoreDeviceMessage("m1", "mac", "phone", "approval_request", """{"summary":"rm"}""", now, now + 60_000)
        val model = core.toModel()
        assertEquals(DeviceMessageKind.ApprovalRequest, model.kind)
        assertEquals("rm", model.body.string("summary"))
        assertEquals("""{"summary":"rm"}""", model.bodyJson)
        assertEquals(now + 60_000, model.expiresAtMs)
        val odd = core.copy(kind = "telepathy", bodyJson = "not json").toModel()
        assertEquals(DeviceMessageKind.Unknown, odd.kind)
        assertTrue(odd.body.isEmpty())
    }

    @Test
    fun planPolicyRoundTripsAndDefaultsMatchCore() {
        // 两边的默认值必须一致：PlanPolicy() 就是服务端的默认策略。
        assertEquals(PlanPolicy(), CorePlanPolicy().toModel())
        assertEquals(CorePlanPolicy(), PlanPolicy().toCore())

        val core = CorePlanPolicy(
            preauthorizedTools = listOf("read", "edit"),
            approvalTimeoutSecs = 600uL,
            onApprovalTimeout = "skip",
            maxTokens = 50_000uL,
            maxDurationSecs = 1_800uL,
            maxSteps = 40u,
            dailyTokenLimit = ULong.MAX_VALUE,
            waitTimeoutSecs = 3_600uL,
        )
        val model = core.toModel()
        assertEquals(ApprovalTimeoutAction.Skip, model.onApprovalTimeout)
        assertEquals(40, model.maxSteps)
        assertEquals(Long.MAX_VALUE, model.dailyTokenLimit)
        assertEquals(core.copy(dailyTokenLimit = Long.MAX_VALUE.toULong()), model.toCore())
        assertEquals(ApprovalTimeoutAction.Unknown, core.copy(onApprovalTimeout = "explode").toModel().onApprovalTimeout)

        // 负数按 0。
        val negative = PlanPolicy(approvalTimeoutSecs = -1, maxTokens = -5, maxSteps = -2).toCore()
        assertEquals(0uL, negative.approvalTimeoutSecs)
        assertEquals(0uL, negative.maxTokens)
        assertEquals(0u, negative.maxSteps)

        expectInvalid { PlanPolicy(onApprovalTimeout = ApprovalTimeoutAction.Unknown).toCore() }
    }

    @Test
    fun planCarriesPolicyAndCatchUp() {
        val core = CorePlan(
            id = "p1", instanceId = "i1", title = "t", goal = "g", paused = false, createdBy = "user",
            awaitingConfirmation = false, revision = 1u, policyJson = "{}",
            policy = CorePlanPolicy(onApprovalTimeout = "fail", maxSteps = 3u), catchUp = "all",
            createdAtMs = now, triggers = emptyList(), steps = emptyList(),
        )
        val plan = core.toModel()
        assertEquals(ApprovalTimeoutAction.Fail, plan.policy.onApprovalTimeout)
        assertEquals(3, plan.policy.maxSteps)
        assertEquals(CatchUp.All, plan.catchUp)
        assertEquals(CatchUp.Skip, core.copy(catchUp = "skip").toModel().catchUp)
        assertEquals(CatchUp.Unknown, core.copy(catchUp = "sometimes").toModel().catchUp)
    }

    @Test
    fun newPlanSendsOptionalPolicyAndCatchUp() {
        val plain = NewPlan("i1", "t", "g", listOf(Schedule.Once(now))).toCore()
        assertEquals(
            CoreNewPlan("i1", "t", "g", listOf(CoreSchedule.Once(now)), emptyList(), policy = null, catchUp = null),
            plain,
        )
        val full = NewPlan(
            "i1", "t", "g", emptyList(),
            steps = listOf(PlanStep("a", "i1", "p", emptyList())),
            policy = PlanPolicy(maxTokens = 10),
            catchUp = CatchUp.Skip,
        ).toCore()
        assertEquals(10uL, full.policy?.maxTokens)
        assertEquals("skip", full.catchUp)
        assertEquals(listOf(CorePlanStep("a", "i1", "p", emptyList())), full.steps)
        expectInvalid { NewPlan("i1", "t", "g", emptyList(), catchUp = CatchUp.Unknown).toCore() }
    }

    @Test
    fun planChangeOnlySendsWhatIsGiven() {
        assertEquals(CorePlanChange(), PlanChange().toCore())
        val change = PlanChange(
            title = "新标题",
            policy = PlanPolicy(onApprovalTimeout = ApprovalTimeoutAction.Skip),
            catchUp = CatchUp.All,
            steps = emptyList(),
        ).toCore()
        assertEquals("新标题", change.title)
        assertNull(change.goal)
        assertEquals("skip", change.policy?.onApprovalTimeout)
        assertEquals("all", change.catchUp)
        // 空列表 ≠ null：空列表表示变回单个 agent 的计划。
        assertEquals(emptyList<CorePlanStep>(), change.steps)
        expectInvalid { PlanChange(catchUp = CatchUp.Unknown).toCore() }
    }

    @Test
    fun teamAndMembersRoundTrip() {
        val core = CoreTeam(
            "t1", "调研小组",
            listOf(CoreTeamMember("i1", "lead", 0u), CoreTeamMember("i2", "member", UInt.MAX_VALUE)),
            now,
        )
        val team = core.toModel()
        assertEquals(TeamRole.Lead, team.members[0].role)
        assertEquals(Int.MAX_VALUE, team.members[1].position)
        assertEquals(TeamRole.Unknown, CoreTeamMember("i3", "boss", 1u).toModel().role)
        assertEquals(CoreTeamMember("i1", "lead", 0u), TeamMember("i1", TeamRole.Lead, 0).toCore())
        assertEquals(CoreTeamMember("i2", "member", 0u), TeamMember("i2", TeamRole.Member, -1).toCore())
        expectInvalid { TeamMember("i1", TeamRole.Unknown, 0).toCore() }
    }

    @Test
    fun templateAndMembersRoundTrip() {
        val core = CoreTeamTemplate(
            "tpl", "调研 + 写作",
            listOf(CoreTemplateMember("agent-a", null, "研究员", "lead"), CoreTemplateMember("agent-b", "cli", "笔杆子", "member")),
            now,
        )
        val template = core.toModel()
        assertEquals(2, template.members.size)
        assertEquals("cli", template.members[1].harness)
        assertEquals(TeamRole.Member, template.members[1].role)
        assertEquals(core.members, template.members.map { it.toCore() })
        expectInvalid { TemplateMember("a", null, "n", TeamRole.Unknown).toCore() }
    }

    @Test
    fun contentReportMapsReasonAndState() {
        val core = CoreContentReport(
            id = "r1", runId = "run", instanceId = "i1", eventSeq = 12uL, artifactId = null, reason = "privacy",
            note = "泄露了手机号", state = "closed", resolution = "已处理", createdAtMs = now, handledAtMs = now + 1,
        )
        val report = core.toModel()
        assertEquals(ReportReason.Privacy, report.reason)
        assertEquals(ReportState.Closed, report.state)
        assertEquals(12L, report.eventSeq)
        assertEquals(now + 1, report.handledAtMs)
        val unknown = core.copy(reason = "spam", state = "escalated", eventSeq = ULong.MAX_VALUE).toModel()
        assertEquals(ReportReason.Unknown, unknown.reason)
        assertEquals(ReportState.Unknown, unknown.state)
        assertEquals(Long.MAX_VALUE, unknown.eventSeq)
        // 每个已知原因的字符串和服务端一致。
        assertEquals(
            listOf("harmful", "illegal", "sexual", "hateful", "privacy", "misinformation", "infringement", "other"),
            ReportReason.entries.filter { it != ReportReason.Unknown }.map { it.wire },
        )
    }
}
