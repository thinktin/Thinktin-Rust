package cn.thinktin.data

import cn.thinktin.core.ClientException
import cn.thinktin.core.NoHandle
import cn.thinktin.core.ThinktinClient
import cn.thinktin.core.ThinktinClientInterface
import cn.thinktin.data.core.CoreThinktinService
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.ReportReason
import cn.thinktin.data.model.RunFilter
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.WaitCode
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TemplateMember
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import cn.thinktin.core.Artifact as CoreArtifact
import cn.thinktin.core.ContentReport as CoreContentReport
import cn.thinktin.core.Credential as CoreCredential
import cn.thinktin.core.DeviceInfo as CoreDeviceInfo
import cn.thinktin.core.DeviceMessage as CoreDeviceMessage
import cn.thinktin.core.InboxItem as CoreInboxItem
import cn.thinktin.core.Instance as CoreInstance
import cn.thinktin.core.InstanceEvent as CoreInstanceEvent
import cn.thinktin.core.Plan as CorePlan
import cn.thinktin.core.PlanChange as CorePlanChange
import cn.thinktin.core.Run as CoreRun
import cn.thinktin.core.RunFilter as CoreRunFilter
import cn.thinktin.core.Schedule as CoreSchedule
import cn.thinktin.core.Team as CoreTeam
import cn.thinktin.core.TeamMember as CoreTeamMember
import cn.thinktin.core.TeamTemplate as CoreTeamTemplate
import cn.thinktin.core.TemplateMember as CoreTemplateMember
import cn.thinktin.core.Trigger as CoreTrigger
import cn.thinktin.core.User as CoreUser

/**
 * 11.7 / 11.8 / 5.5 接上的方法：CoreThinktinService 把参数原样（换成 core 的类型）交给 client-core，
 * 结果映射回 App 模型，不再抛 Unsupported。假的 client 记下每次调用。
 */
class CoreServiceAppApiTest {

    private class RecordingClient(
        private val base: ThinktinClient = ThinktinClient(NoHandle),
    ) : ThinktinClientInterface by base {
        val calls = mutableListOf<List<Any?>>()
        var deleteAccountError: Exception? = null

        private fun record(vararg args: Any?) {
            calls += args.toList()
        }

        /** 吊销本机后 client-core 自己清登录态（11.8）：这里模拟成吊销 d1（本机）后变成未登录。 */
        var signedIn = true
        var upgrade = false

        override fun signedIn(): Boolean = signedIn

        override fun upgradeRequired(): Boolean = upgrade

        override fun setAcceptLanguage(acceptLanguage: String?) = record("setAcceptLanguage", acceptLanguage)

        override suspend fun listRuns(filter: CoreRunFilter, beforeRunId: String?, limit: UInt): List<CoreRun> {
            record("listRuns", filter, beforeRunId, limit)
            return listOf(run("r9").copy(state = "waiting_quota", waitCode = "no_balance"))
        }

        var loginError: Exception? = null
        var meError: Exception? = null

        override suspend fun login(
            phone: String,
            code: String,
            pushChannel: String?,
            pushToken: String?,
        ): cn.thinktin.core.LoginResult {
            record("login", phone, code, pushChannel, pushToken)
            loginError?.let { throw it }
            signedIn = true
            return cn.thinktin.core.LoginResult(CoreUser("u1", phone, null, "active", "en", 1), true)
        }

        override suspend fun me(): CoreUser {
            meError?.let { throw it }
            return CoreUser("u1", "+86 138", null, "active", "zh-CN", 1)
        }

        override suspend fun updateProfile(displayName: String?): CoreUser {
            record("updateProfile", displayName)
            return CoreUser("u1", "+86 138", displayName, "active", "zh-CN", 1)
        }

        override suspend fun devices(): List<CoreDeviceInfo> {
            record("devices")
            return listOf(CoreDeviceInfo("d1", "android", "Pixel", "fcm", true, false, 1, 2))
        }

        override suspend fun revokeDevice(deviceId: String) {
            record("revokeDevice", deviceId)
            if (deviceId == "d1") signedIn = false
        }

        override suspend fun sendSelfCode(purpose: String) = record("sendSelfCode", purpose)

        override suspend fun deleteAccount(code: String) {
            record("deleteAccount", code)
            deleteAccountError?.let { throw it }
        }

        override suspend fun sendDeviceMessage(toDeviceId: String, kind: String, bodyJson: String): CoreDeviceMessage {
            record("sendDeviceMessage", toDeviceId, kind, bodyJson)
            return CoreDeviceMessage("m1", "phone", toDeviceId, kind, bodyJson, 1, 2)
        }

        override suspend fun deviceMessages(): List<CoreDeviceMessage> {
            record("deviceMessages")
            return listOf(CoreDeviceMessage("m2", "mac", "phone", "pair_confirm", "{}", 1, 2))
        }

        override suspend fun ackDeviceMessages(ids: List<String>): ULong {
            record("ackDeviceMessages", ids)
            return ids.size.toULong()
        }

        override suspend fun instance(instanceId: String): CoreInstance {
            record("instance", instanceId)
            return CoreInstance(instanceId, "a1", "1.0", "codex", "小码", "running", 1, 2)
        }

        override suspend fun olderRuns(instanceId: String, beforeRunId: String, limit: UInt): List<CoreRun> {
            record("olderRuns", instanceId, beforeRunId, limit)
            return listOf(run("r0"))
        }

        override suspend fun instanceArtifacts(instanceId: String, limit: UInt): List<CoreArtifact> {
            record("instanceArtifacts", instanceId, limit)
            return listOf(CoreArtifact("a1", instanceId, "r1", "x.md", 2u, "text/markdown", 10uL, "00", 3))
        }

        override suspend fun deleteArtifact(artifactId: String) = record("deleteArtifact", artifactId)

        override fun cachedEventsBefore(instanceId: String, beforeSeq: ULong?, limit: UInt): List<CoreInstanceEvent> {
            record("cachedEventsBefore", instanceId, beforeSeq, limit)
            return listOf(CoreInstanceEvent(instanceId, 9uL, null, "agent.message", """{"text":"hi"}""", true, 1))
        }

        override suspend fun updatePlan(planId: String, change: CorePlanChange): CorePlan {
            record("updatePlan", planId, change)
            return CorePlan(
                id = planId, instanceId = "i1", title = change.title ?: "t", goal = "g", paused = false,
                createdBy = "user", awaitingConfirmation = false, revision = 2u, policyJson = "{}",
                policy = change.policy ?: cn.thinktin.core.PlanPolicy(), catchUp = change.catchUp ?: "once",
                createdAtMs = 1, triggers = emptyList(), steps = emptyList(),
            )
        }

        override suspend fun addTrigger(planId: String, schedule: CoreSchedule): CoreTrigger {
            record("addTrigger", planId, schedule)
            return CoreTrigger("trg1", schedule, true, 5, null)
        }

        override suspend fun deleteTrigger(triggerId: String) = record("deleteTrigger", triggerId)

        override suspend fun teams(): List<CoreTeam> {
            record("teams")
            return listOf(team)
        }

        override suspend fun team(teamId: String): CoreTeam {
            record("team", teamId)
            return team
        }

        override suspend fun createTeam(name: String, members: List<CoreTeamMember>): CoreTeam {
            record("createTeam", name, members)
            return team.copy(name = name, members = members)
        }

        override suspend fun updateTeam(teamId: String, name: String?, members: List<CoreTeamMember>?): CoreTeam {
            record("updateTeam", teamId, name, members)
            return team
        }

        override suspend fun deleteTeam(teamId: String) = record("deleteTeam", teamId)

        override suspend fun teamTemplates(): List<CoreTeamTemplate> {
            record("teamTemplates")
            return listOf(template)
        }

        override suspend fun createTeamTemplate(name: String, members: List<CoreTemplateMember>): CoreTeamTemplate {
            record("createTeamTemplate", name, members)
            return template.copy(name = name, members = members)
        }

        override suspend fun createTeamTemplateFromTeam(name: String, teamId: String): CoreTeamTemplate {
            record("createTeamTemplateFromTeam", name, teamId)
            return template.copy(name = name)
        }

        override suspend fun deleteTeamTemplate(templateId: String) = record("deleteTeamTemplate", templateId)

        override suspend fun adoptTeamTemplate(templateId: String, name: String?): CoreTeam {
            record("adoptTeamTemplate", templateId, name)
            return team.copy(name = name ?: template.name)
        }

        override suspend fun inboxItem(itemId: String): CoreInboxItem {
            record("inboxItem", itemId)
            return CoreInboxItem(itemId, null, null, null, null, "info", "标题", "正文", false, true, 1)
        }

        override suspend fun markInboxUnread(itemId: String): Long {
            record("markInboxUnread", itemId)
            return 7
        }

        override suspend fun deleteInboxItem(itemId: String) = record("deleteInboxItem", itemId)

        override suspend fun updateCredential(credentialId: String, label: String?, disabled: Boolean?): CoreCredential {
            record("updateCredential", credentialId, label, disabled)
            return credential.copy(label = label ?: credential.label, disabled = disabled ?: credential.disabled)
        }

        override suspend fun replaceCredentialSecret(credentialId: String, apiKey: String): CoreCredential {
            record("replaceCredentialSecret", credentialId, apiKey)
            return credential.copy(last4 = apiKey.takeLast(4))
        }

        override suspend fun reportContent(
            runId: String,
            eventSeq: ULong?,
            artifactId: String?,
            reason: String,
            note: String?,
        ): CoreContentReport {
            record("reportContent", runId, eventSeq, artifactId, reason, note)
            return CoreContentReport("rep1", runId, "i1", eventSeq, artifactId, reason, note, "open", null, 1, null)
        }

        override suspend fun reports(): List<CoreContentReport> {
            record("reports")
            return listOf(CoreContentReport("rep1", "r1", "i1", null, null, "other", null, "closed", "ok", 1, 2))
        }

        companion object {
            val team = CoreTeam("t1", "调研小组", listOf(CoreTeamMember("i1", "lead", 0u)), 1)
            val template = CoreTeamTemplate("tpl", "模板", listOf(CoreTemplateMember("a1", null, "研究员", "lead")), 1)
            val credential = CoreCredential("c1", "anthropic", "工作", "abcd", null, false, 1)

            fun run(id: String) = CoreRun(
                id = id, kind = "agent", instanceId = "i1", planId = null, parentRunId = null, rootRunId = id,
                stepKey = null, source = "user", prompt = "p", state = "succeeded", stateReason = null, attempt = 1u,
                tokensUsed = 0uL, summary = null, error = null, createdAtMs = 1, startedAtMs = null, finishedAtMs = null,
            )
        }
    }

    private val fake = RecordingClient()

    @Test
    fun accountAndDevices() = runTest {
        val s = CoreThinktinService(fake)
        assertEquals("昵称", s.updateProfile("昵称").displayName)
        assertEquals("Pixel", s.devices().single().name)
        s.revokeDevice("d2")
        s.sendSelfCode(SelfCodePurpose.DeleteAccount)
        assertEquals(
            listOf(
                listOf("updateProfile", "昵称"),
                listOf("devices"),
                listOf("revokeDevice", "d2"),
                listOf("sendSelfCode", "delete_account"),
            ),
            fake.calls,
        )
    }

    @Test
    fun revokingThisDeviceSignsOut() = runTest {
        val s = CoreThinktinService(fake)
        s.revokeDevice("d2")
        assertEquals("吊销别的设备不影响本机", AuthState.SignedIn, s.authState.value)
        s.revokeDevice("d1")
        assertEquals("吊销本机：client-core 已清掉登录态，跟着回登录页", AuthState.SignedOut, s.authState.value)
    }

    @Test
    fun listRunsAcrossInstances() = runTest {
        val s = CoreThinktinService(fake)
        val run = s.listRuns(RunFilter(planId = "p1", rootsOnly = true), beforeRunId = "r5", limit = 30).single()
        assertEquals(RunState.WaitingQuota, run.state)
        assertEquals(WaitCode.NoBalance, run.waitCode)
        s.listRuns()
        assertEquals(
            listOf(
                listOf("listRuns", CoreRunFilter(planId = "p1", activeOnly = false, rootsOnly = true), "r5", 30u),
                listOf("listRuns", CoreRunFilter(), null, 50u),
            ),
            fake.calls,
        )
    }

    @Test
    fun acceptLanguageAndUpgradeFlag() {
        val s = CoreThinktinService(fake)
        // 空列表不拼请求头（不调 client-core 的 accept_language_header），直接清掉。
        s.setAcceptLanguage(emptyList())
        assertEquals(listOf(listOf("setAcceptLanguage", null)), fake.calls)
        assertEquals(false, s.upgradeRequired())
        fake.upgrade = true
        assertEquals(true, s.upgradeRequired())
    }

    @Test
    fun deleteAccountSignsOutOnlyOnSuccess() = runTest {
        val s = CoreThinktinService(fake)
        fake.deleteAccountError = ClientException.Api(400u, "invalid_code", "wrong code", null)
        try {
            s.deleteAccount("000000")
            fail("验证码错误应该抛异常")
        } catch (e: ServiceError.Api) {
            assertEquals("invalid_code", e.code)
        }
        assertEquals(AuthState.SignedIn, s.authState.value)
        fake.deleteAccountError = null
        s.deleteAccount("123456")
        assertEquals(AuthState.SignedOut, s.authState.value)
    }

    @Test
    fun loginFrozenStaysSignedOutAndSuccessSignsIn() = runTest {
        fake.signedIn = false
        val s = CoreThinktinService(fake)
        assertEquals(AuthState.SignedOut, s.authState.value)
        // 登录时报冻结：没有会话，仍是未登录（登录流自己显示冻结说明），不进“登录态保留”的冻结页。
        fake.loginError = ClientException.AccountFrozen()
        try {
            s.login("+8613800138000", "123456")
            fail("冻结应该抛异常")
        } catch (_: ServiceError.AccountFrozen) {
        }
        assertEquals(AuthState.SignedOut, s.authState.value)
        fake.loginError = null
        val result = s.login("+8613800138000", "123456")
        assertEquals("en", result.user.locale)
        assertEquals(true, result.newUser)
        assertEquals(AuthState.SignedIn, s.authState.value)
        assertEquals(listOf("login", "+8613800138000", "123456", null, null), fake.calls.last())
    }

    @Test
    fun meAfterFrozenUnfreezes() = runTest {
        val s = CoreThinktinService(fake)
        fake.meError = ClientException.AccountFrozen()
        try {
            s.me()
            fail("冻结应该抛异常")
        } catch (_: ServiceError.AccountFrozen) {
        }
        assertEquals("已登录的账号被冻结：登录态保留", AuthState.Frozen, s.authState.value)
        fake.meError = null
        s.me()
        assertEquals("解冻后“重新检查”回到已登录", AuthState.SignedIn, s.authState.value)
    }

    @Test
    fun deviceMessages() = runTest {
        val s = CoreThinktinService(fake)
        val sent = s.sendDeviceMessage("mac", DeviceMessageKind.ApprovalDecision, """{"ok":true}""")
        assertEquals(DeviceMessageKind.ApprovalDecision, sent.kind)
        assertEquals(DeviceMessageKind.PairConfirm, s.deviceMessages().single().kind)
        assertEquals(2L, s.ackDeviceMessages(listOf("m1", "m2")))
        assertEquals(listOf("sendDeviceMessage", "mac", "approval_decision", """{"ok":true}"""), fake.calls[0])
        try {
            s.sendDeviceMessage("mac", DeviceMessageKind.Unknown, "{}")
            fail("Unknown 不能发")
        } catch (e: ServiceError.Other) {
            assertEquals("invalid_argument", e.kind)
        }
        assertEquals("没发出去就不该调 client-core", 3, fake.calls.size)
    }

    @Test
    fun instancesRunsArtifactsAndCachedEvents() = runTest {
        val s = CoreThinktinService(fake, io = StandardTestDispatcher(testScheduler))
        assertEquals("小码", s.instance("i1").name)
        assertEquals("r0", s.olderRuns("i1", "r5", limit = 20).single().id)
        assertEquals(2, s.instanceArtifacts("i1").single().version)
        s.deleteArtifact("a1")
        assertEquals(9L, s.cachedEventsBefore("i1").single().seq)
        s.cachedEventsBefore("i1", beforeSeq = 40, limit = -3)
        assertEquals(
            listOf(
                listOf("instance", "i1"),
                listOf("olderRuns", "i1", "r5", 20u),
                listOf("instanceArtifacts", "i1", 50u),
                listOf("deleteArtifact", "a1"),
                listOf("cachedEventsBefore", "i1", null, 100u),
                listOf("cachedEventsBefore", "i1", 40uL, 0u),
            ),
            fake.calls,
        )
    }

    @Test
    fun plansAndTriggers() = runTest {
        val s = CoreThinktinService(fake)
        val plan = s.updatePlan(
            "p1",
            PlanChange(title = "新标题", policy = PlanPolicy(maxTokens = 9), catchUp = CatchUp.Skip),
        )
        assertEquals("新标题", plan.title)
        assertEquals(9L, plan.policy.maxTokens)
        assertEquals(CatchUp.Skip, plan.catchUp)
        val sentChange = fake.calls[0][2] as CorePlanChange
        assertEquals("skip", sentChange.catchUp)
        assertEquals(null, sentChange.steps)

        val trigger = s.addTrigger("p1", Schedule.Cron("0 9 * * *", "Asia/Shanghai"))
        assertEquals(Schedule.Cron("0 9 * * *", "Asia/Shanghai"), trigger.schedule)
        assertEquals(listOf("addTrigger", "p1", CoreSchedule.Cron("0 9 * * *", "Asia/Shanghai")), fake.calls[1])
        s.deleteTrigger("trg1")
        assertEquals(listOf("deleteTrigger", "trg1"), fake.calls[2])
    }

    @Test
    fun teamsAndTemplates() = runTest {
        val s = CoreThinktinService(fake)
        assertEquals(TeamRole.Lead, s.teams().single().members.single().role)
        assertEquals("调研小组", s.team("t1").name)
        val created = s.createTeam("新团队", listOf(TeamMember("i1", TeamRole.Lead, 0), TeamMember("i2", TeamRole.Member, 1)))
        assertEquals(2, created.members.size)
        s.updateTeam("t1", name = "改名")
        s.deleteTeam("t1")
        assertEquals("模板", s.teamTemplates().single().name)
        s.createTeamTemplate("新模板", listOf(TemplateMember("a1", "cli", "小码", TeamRole.Member)))
        assertEquals("从团队", s.createTeamTemplateFromTeam("从团队", "t1").name)
        s.deleteTeamTemplate("tpl")
        assertEquals("模板", s.adoptTeamTemplate("tpl").name)
        assertEquals("自定义", s.adoptTeamTemplate("tpl", name = "自定义").name)
        assertEquals(
            listOf(
                listOf("teams"),
                listOf("team", "t1"),
                listOf("createTeam", "新团队", listOf(CoreTeamMember("i1", "lead", 0u), CoreTeamMember("i2", "member", 1u))),
                listOf("updateTeam", "t1", "改名", null),
                listOf("deleteTeam", "t1"),
                listOf("teamTemplates"),
                listOf("createTeamTemplate", "新模板", listOf(CoreTemplateMember("a1", "cli", "小码", "member"))),
                listOf("createTeamTemplateFromTeam", "从团队", "t1"),
                listOf("deleteTeamTemplate", "tpl"),
                listOf("adoptTeamTemplate", "tpl", null),
                listOf("adoptTeamTemplate", "tpl", "自定义"),
            ),
            fake.calls,
        )
    }

    @Test
    fun inboxCredentialsAndReports() = runTest {
        val s = CoreThinktinService(fake)
        assertTrue(s.inboxItem("n1").read)
        assertEquals(7L, s.markInboxUnread("n1"))
        s.deleteInboxItem("n1")
        assertEquals(true, s.updateCredential("c1", CredentialUpdate(disabled = true)).disabled)
        assertEquals("9876", s.replaceCredentialSecret("c1", "sk-new-key-9876").last4)
        val report = s.reportContent("r1", ReportReason.Harmful, eventSeq = 12, note = "危险")
        assertEquals(ReportReason.Harmful, report.reason)
        assertEquals(12L, report.eventSeq)
        assertEquals(1, s.reports().size)
        assertEquals(
            listOf(
                listOf("inboxItem", "n1"),
                listOf("markInboxUnread", "n1"),
                listOf("deleteInboxItem", "n1"),
                listOf("updateCredential", "c1", null, true),
                listOf("replaceCredentialSecret", "c1", "sk-new-key-9876"),
                listOf("reportContent", "r1", 12uL, null, "harmful", "危险"),
                listOf("reports"),
            ),
            fake.calls,
        )
    }
}
