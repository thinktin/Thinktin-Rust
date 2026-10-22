package cn.thinktin.data

import cn.thinktin.data.mock.MockData
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.ReportReason
import cn.thinktin.data.model.ReportState
import cn.thinktin.data.model.RunFilter
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.TriggerDisabledReason
import cn.thinktin.data.model.WaitCode
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TemplateMember
import cn.thinktin.data.model.long
import cn.thinktin.data.model.obj
import cn.thinktin.data.model.parseJsonObject
import cn.thinktin.data.model.string
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** 演示服务里 11.7 / 11.8 / 5.5 新接口的行为（和真实服务的语义一致）。 */
class MockAppApiTest {
    private val now = 1_760_000_000_000L
    private fun service() = MockThinktinService(eventIntervalMs = 1_000, clock = { now })

    private suspend fun expectApi(status: Int, block: suspend () -> Unit) {
        try {
            block()
            fail("应该抛 ServiceError.Api($status)")
        } catch (e: ServiceError.Api) {
            assertEquals(status, e.status)
        }
    }

    @Test
    fun devicesAndAccount() = runTest {
        val s = service()
        val devices = s.devices()
        assertEquals(3, devices.size)
        assertEquals("最近活跃的在前", devices.sortedByDescending { it.lastSeenAtMs }, devices)
        assertEquals(1, devices.count { it.current })
        assertTrue("电脑在线", devices.single { it.id == "dev-mac" }.online)

        assertEquals("小新", s.updateProfile("小新").displayName)
        assertEquals(null, s.updateProfile(null).displayName)

        s.revokeDevice("dev-iphone")
        assertEquals(2, s.devices().size)
        expectApi(404) { s.revokeDevice("dev-iphone") }
        assertEquals(AuthState.SignedIn, s.authState.value)

        val result = s.signOutOtherDevices(stopAgents = false)
        assertEquals(1L, result.devicesSignedOut)
        assertEquals(listOf("dev-this"), s.devices().map { it.id })

        s.sendSelfCode(SelfCodePurpose.DeleteAccount)
        expectApi(400) { s.deleteAccount("12") }
        s.deleteAccount("123456")
        assertEquals(AuthState.SignedOut, s.authState.value)
    }

    @Test
    fun revokingTheCurrentDeviceSignsOut() = runTest {
        val s = service()
        s.revokeDevice("dev-this")
        assertEquals(AuthState.SignedOut, s.authState.value)
    }

    @Test
    fun deviceMessagesQueueAndAck() = runTest {
        val s = service()
        val inbox = s.deviceMessages()
        assertEquals(DeviceMessageKind.ApprovalRequest, inbox.single().kind)
        assertEquals("dev-mac", inbox.single().fromDeviceId)
        assertTrue(inbox.single().body.string("summary")!!.isNotEmpty())
        assertEquals(1L, s.ackDeviceMessages(listOf(inbox.single().id, "unknown")))
        assertTrue(s.deviceMessages().isEmpty())

        val sent = s.sendDeviceMessage("dev-mac", DeviceMessageKind.ApprovalDecision, """{"approved":true}""")
        assertEquals("dev-this", sent.fromDeviceId)
        assertTrue(sent.expiresAtMs > sent.createdAtMs)
        expectApi(404) { s.sendDeviceMessage("dev-nope", DeviceMessageKind.Capability, "{}") }
        expectApi(422) { s.sendDeviceMessage("dev-mac", DeviceMessageKind.Unknown, "{}") }
    }

    @Test
    fun instanceArtifactsAndRuns() = runTest {
        val s = service()
        assertEquals("inst-coder", s.instance("inst-coder").id)
        expectApi(404) { s.instance("inst-nope") }
        val artifacts = s.instanceArtifacts("inst-coder")
        assertTrue(artifacts.isNotEmpty())
        assertEquals(artifacts.sortedByDescending { it.createdAtMs }, artifacts)
        assertEquals(1, s.instanceArtifacts("inst-coder", limit = 1).size)
        s.deleteArtifact(artifacts.first().id)
        assertEquals(artifacts.size - 1, s.instanceArtifacts("inst-coder").size)
        expectApi(404) { s.deleteArtifact(artifacts.first().id) }

        val runs = s.runs("inst-coder")
        val older = s.olderRuns("inst-coder", runs.first().id)
        assertEquals(runs.drop(1), older)
    }

    @Test
    fun cachedEventsBeforePagesBackwards() = runTest {
        val s = service()
        val all = s.cachedEvents("inst-coder")
        assertTrue(all.size > 4)
        // 最后一屏：最新的几条，旧的在前。
        val last = s.cachedEventsBefore("inst-coder", limit = 3)
        assertEquals(all.takeLast(3), last)
        // 往上翻：比已显示的最小 seq 更早的。
        val previous = s.cachedEventsBefore("inst-coder", beforeSeq = last.first().seq, limit = 2)
        assertEquals(all.dropLast(3).takeLast(2), previous)
        assertTrue(s.cachedEventsBefore("inst-coder", beforeSeq = all.first().seq).isEmpty())
        assertTrue(s.cachedEventsBefore("inst-coder", limit = 0).isEmpty())
    }

    @Test
    fun plansPolicyCatchUpAndTriggers() = runTest {
        val s = service()
        val daily = s.getPlan("plan-daily")
        assertEquals(ApprovalTimeoutAction.Skip, daily.policy.onApprovalTimeout)
        assertEquals(50_000L, daily.policy.maxTokens)
        // policyJson 和结构化的 policy 一致（服务端的 JSON 形状）。
        assertEquals(50_000L, parseJsonObject(daily.policyJson).obj("budget")?.long("max_tokens"))

        val created = s.createPlan(NewPlan("inst-coder", "t", "g", listOf(Schedule.Once(now + 1))))
        assertEquals(PlanPolicy(), created.policy)
        assertEquals(CatchUp.Once, created.catchUp)
        val custom = s.createPlan(
            NewPlan("inst-coder", "t", "g", emptyList(), policy = PlanPolicy(maxSteps = 5), catchUp = CatchUp.All),
        )
        assertEquals(5, custom.policy.maxSteps)
        assertEquals(CatchUp.All, custom.catchUp)

        val changed = s.updatePlan(
            daily.id,
            PlanChange(goal = "新目标", policy = PlanPolicy(onApprovalTimeout = ApprovalTimeoutAction.Fail), catchUp = CatchUp.Skip),
        )
        assertEquals(daily.title, changed.title)
        assertEquals("新目标", changed.goal)
        assertEquals(ApprovalTimeoutAction.Fail, changed.policy.onApprovalTimeout)
        assertEquals("fail", parseJsonObject(changed.policyJson).string("on_approval_timeout"))
        assertEquals(CatchUp.Skip, changed.catchUp)
        assertEquals(daily.revision + 1, changed.revision)

        val trigger = s.addTrigger(daily.id, Schedule.Cron("0 18 * * *", "Asia/Shanghai"))
        assertTrue(s.getPlan(daily.id).triggers.any { it.id == trigger.id })
        s.deleteTrigger(trigger.id)
        assertFalse(s.getPlan(daily.id).triggers.any { it.id == trigger.id })
        expectApi(404) { s.deleteTrigger(trigger.id) }
        repeat(9) { s.addTrigger(custom.id, Schedule.Once(now + it)) }
        s.addTrigger(custom.id, Schedule.Once(now + 100))
        expectApi(422) { s.addTrigger(custom.id, Schedule.Once(now + 200)) }
    }

    @Test
    fun teamsAndTemplates() = runTest {
        val s = service()
        val team = s.team("team-research")
        assertEquals(TeamRole.Lead, team.members.first().role)
        expectApi(404) { s.team("team-nope") }

        val fromTeam = s.createTeamTemplateFromTeam("复制的模板", team.id)
        assertEquals(team.members.size, fromTeam.members.size)
        assertEquals(TeamRole.Lead, fromTeam.members.first().role)

        val custom = s.createTeamTemplate("单人", listOf(TemplateMember("agent-coder", null, "小码", TeamRole.Lead)))
        assertEquals(3, s.teamTemplates().size)
        val adopted = s.adoptTeamTemplate(custom.id, name = "新团队")
        assertEquals("新团队", adopted.name)
        assertEquals("单人", s.adoptTeamTemplate(custom.id).name)
        s.deleteTeamTemplate(custom.id)
        assertEquals(2, s.teamTemplates().size)
    }

    @Test
    fun inboxItemUnreadAndDelete() = runTest {
        val s = service()
        val read = s.syncInbox().items.first { it.read }
        assertEquals(read, s.inboxItem(read.id))
        val unreadBefore = s.cachedUnread()
        assertEquals(unreadBefore + 1, s.markInboxUnread(read.id))
        assertFalse(s.inboxItem(read.id).read)
        s.deleteInboxItem(read.id)
        expectApi(404) { s.inboxItem(read.id) }
        expectApi(404) { s.markInboxUnread(read.id) }
    }

    @Test
    fun credentialsUpdateAndReplaceSecret() = runTest {
        val s = service()
        val updated = s.updateCredential("cred-work", CredentialUpdate(label = "公司", disabled = true))
        assertEquals("公司", updated.label)
        assertTrue(updated.disabled)
        assertEquals(2_000_000L, updated.dailyTokenLimit)
        val replaced = s.replaceCredentialSecret("cred-work", "sk-ant-new-0000-5678")
        assertEquals("5678", replaced.last4)
        assertEquals("公司", replaced.label)
        expectApi(422) { s.replaceCredentialSecret("cred-work", "short") }
        expectApi(404) { s.replaceCredentialSecret("cred-nope", "sk-long-enough") }
    }

    @Test
    fun reportsDeduplicateOpenReports() = runTest {
        val s = service()
        assertEquals(ReportState.Closed, s.reports().single().state)
        val report = s.reportContent("run-done", ReportReason.Harmful, eventSeq = 3, note = "危险操作")
        assertEquals(ReportState.Open, report.state)
        assertEquals("inst-coder", report.instanceId)
        // 同一条内容再举报：返回那一条待处理的。
        assertEquals(report.id, s.reportContent("run-done", ReportReason.Other, eventSeq = 3).id)
        assertEquals(2, s.reports().size)
        assertEquals(report.id, s.reports().first().id)
        expectApi(404) { s.reportContent("run-nope", ReportReason.Other) }
        expectApi(422) { s.reportContent("run-done", ReportReason.Unknown) }
        expectApi(422) { s.reportContent("run-done", ReportReason.Other, note = "x".repeat(1001)) }
    }

    // ---- 11.8 ----

    @Test
    fun listRunsFiltersAndPages() = runTest {
        val s = service()
        val all = s.listRuns()
        assertEquals("新的在前", all.sortedByDescending { it.createdAtMs }, all)
        assertEquals(setOf("inst-coder", "inst-research"), all.map { it.instanceId }.toSet())

        val active = s.listRuns(RunFilter(activeOnly = true))
        assertTrue(active.isNotEmpty())
        assertTrue(active.all { it.state.isActive })
        val quota = active.single { it.id == MockData.RUN_QUOTA }
        assertEquals(RunState.WaitingQuota, quota.state)
        assertEquals(WaitCode.NoBalance, quota.waitCode)

        val weekly = s.listRuns(RunFilter(planId = MockData.PLAN_WEEKLY))
        assertEquals(listOf(MockData.RUN_QUOTA), weekly.map { it.id })
        assertTrue(s.listRuns(RunFilter(rootsOnly = true)).all { it.parentRunId == null })

        val first = s.listRuns(limit = 2)
        assertEquals(all.take(2), first)
        assertEquals(all.drop(2).take(2), s.listRuns(beforeRunId = first.last().id, limit = 2))
        assertTrue("不认识的游标：空页", s.listRuns(beforeRunId = "nope").isEmpty())
    }

    @Test
    fun planScheduleSummary() = runTest {
        val s = service()
        val daily = s.getPlan(MockData.PLAN_DAILY)
        assertEquals(1, daily.invalidTriggers)
        assertEquals(TriggerDisabledReason.InvalidRule, daily.triggers.single { !it.enabled }.disabledReason)
        assertEquals(daily.triggers.single { it.enabled }.nextFireAtMs, daily.nextFireAtMs)
        assertEquals("等确认的计划不会按时运行", null, s.getPlan(MockData.PLAN_WEEKLY).nextFireAtMs)

        assertEquals("暂停后没有下一次", null, s.setPlanPaused(MockData.PLAN_DAILY, true).nextFireAtMs)
        assertEquals(daily.nextFireAtMs, s.setPlanPaused(MockData.PLAN_DAILY, false).nextFireAtMs)
        s.deleteTrigger("trg-daily-broken")
        assertEquals(0, s.getPlan(MockData.PLAN_DAILY).invalidTriggers)
        val once = s.addTrigger(MockData.PLAN_DAILY, Schedule.Once(now + 60_000))
        assertEquals(now + 60_000, once.nextFireAtMs)
        assertEquals(now + 60_000, s.getPlan(MockData.PLAN_DAILY).nextFireAtMs)
    }

    @Test
    fun agentsAndCredentialsCarryProtocols() = runTest {
        val s = service()
        val agents = s.agents()
        assertTrue(agents.all { it.description.isNotEmpty() && it.upstream.startsWith("https://") })
        assertTrue("运行时用的协议在 agent 能说的里面", agents.all { it.activeProtocol in it.protocols })
        assertTrue("专有许可证必有许可说明", agents.filter { it.license == null }.all { it.licenseNote != null })
        val known = setOf("anthropic", "chat", "responses")
        assertTrue(s.vendors().all { known.containsAll(it.protocols) })
        assertTrue(s.credentials().all { it.protocols.isNotEmpty() && known.containsAll(it.protocols) })
        val added = s.addCredential(NewCredential("openai", "备用", "sk-12345678"))
        assertEquals(listOf("chat", "responses"), added.protocols)
    }

    @Test
    fun acceptLanguageIsRecordedAndUpgradeNeverRequired() {
        val s = service()
        s.setAcceptLanguage(listOf("zh-CN", "en"))
        assertEquals(listOf("zh-CN", "en"), s.acceptLanguageTags)
        assertFalse(s.upgradeRequired())
    }
}
