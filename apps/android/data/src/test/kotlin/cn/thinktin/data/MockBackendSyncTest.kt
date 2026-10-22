package cn.thinktin.data

import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.model.RouteFallback
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TemplateMember
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** 演示服务跟上 backend-core 11.9 的语义（每日上限、厂商表的两张表、实例数上限、删除实例、停用 key 留在别名里）。 */
class MockBackendSyncTest {
    private val now = 1_760_000_000_000L
    private fun service(instanceLimit: Int = 0) = MockThinktinService(clock = { now }, instanceLimit = instanceLimit)

    private suspend fun expectApi(status: Int, code: String? = null, block: suspend () -> Unit): ServiceError.Api {
        try {
            block()
        } catch (e: ServiceError.Api) {
            assertEquals(status, e.status)
            code?.let { assertEquals(it, e.code) }
            return e
        }
        fail("应该抛 ServiceError.Api($status)")
        error("unreachable")
    }

    @Test
    fun dailyLimitCanBeChangedAndCleared() = runTest {
        val s = service()
        assertEquals(2_000_000L, s.credentials().first { it.id == "cred-work" }.dailyTokenLimit)
        assertEquals(5_000_000L, s.setCredentialDailyLimit("cred-work", 5_000_000).dailyTokenLimit)
        assertNull(s.setCredentialDailyLimit("cred-work", null).dailyTokenLimit)
        assertNull(s.credentials().first { it.id == "cred-work" }.dailyTokenLimit)
        assertEquals(10L, s.setCredentialDailyLimit("cred-home", 10).dailyTokenLimit)
        // 0 报 422（和服务端一样），不认识的 key 404
        expectApi(422, "invalid") { s.setCredentialDailyLimit("cred-work", 0) }
        expectApi(422, "invalid") { s.setCredentialDailyLimit("cred-work", -1) }
        expectApi(404) { s.setCredentialDailyLimit("cred-nope", 10) }
        assertEquals(10L, s.credentials().first { it.id == "cred-home" }.dailyTokenLimit)
    }

    @Test
    fun vendorsCarrySubscriptionPrefixesAndPlanBases() = runTest {
        val s = service()
        val vendors = s.vendors().associateBy { it.id }
        assertEquals(listOf("sk-sp-"), vendors.getValue("qwen-cn").subscriptionKeyPrefixes)
        assertEquals(listOf("sk-ant-oat", "sk-ant-ort"), vendors.getValue("anthropic").subscriptionKeyPrefixes)
        assertEquals(listOf("https://open.bigmodel.cn/api/coding"), vendors.getValue("glm-cn").planOnlyBases)
        assertTrue(vendors.getValue("deepseek").subscriptionKeyPrefixes.isEmpty())
        // Mock 的服务端检查用的是同一份厂商数据
        expectApi(422) { s.addCredential(NewCredential("minimax-cn", "", "sk-cp-0123456789")) }
        val plan = expectApi(422) {
            s.addCredential(NewCredential("custom", "", "sk-0123456789", openaiBase = "https://ark.cn-beijing.volces.com/api/plan/v3"))
        }
        assertTrue(plan.detail.startsWith("openai_base"))
        assertTrue("plan" in plan.detail)
        expectApi(422) {
            s.addCredential(NewCredential("custom", "", "sk-0123456789", anthropicBase = " HTTPS://open.bigmodel.cn/api/coding "))
        }
        // 只是前缀相同、路径段不同的不算
        s.addCredential(NewCredential("custom", "", "sk-0123456789", openaiBase = "https://ark.cn-beijing.volces.com/api/planner"))
    }

    @Test
    fun adoptStopsAtInstanceLimit() = runTest {
        val s = service(instanceLimit = 3)
        s.adopt("agent-coder", "第三个")
        val e = expectApi(409, "instance_limit") { s.adopt("agent-coder", "第四个") }
        assertTrue(e.code.endsWith("_limit"))
        assertEquals(3, s.instances().size)
        // 删掉一个就能再领养（已删除的不算）
        s.deleteInstance("inst-coder")
        s.adopt("agent-coder", "第四个")
        // 不限（默认 0）
        val unlimited = service()
        repeat(5) { unlimited.adopt("agent-coder", "实例 $it") }
        assertEquals(7, unlimited.instances().size)
    }

    @Test
    fun teamTemplateAdoptionIsAllOrNothing() = runTest {
        // 模板有两个成员，账号已有 2 个实例：上限 3 放不下整个团队 → 409，一个都不建
        val s = service(instanceLimit = 3)
        expectApi(409, "instance_limit") { s.adoptTeamTemplate("tpl-research") }
        assertEquals(2, s.instances().size)
        assertEquals(1, s.teams().size)
        // 团队名不合法 → 422，一个都不建
        val roomy = service(instanceLimit = 4)
        expectApi(422, "invalid") { roomy.adoptTeamTemplate("tpl-research", name = "  ") }
        expectApi(422, "invalid") { roomy.adoptTeamTemplate("tpl-research", name = "名".repeat(65)) }
        assertEquals(2, roomy.instances().size)
        // 有成员领养不了（接入方式不对）→ 一个都不建
        val broken = roomy.createTeamTemplate(
            "坏模板",
            listOf(
                TemplateMember("agent-coder", null, "小码 2", TeamRole.Lead),
                TemplateMember("agent-coder", "no-such-harness", "小码 3", TeamRole.Member),
            ),
        )
        expectApi(422, "invalid") { roomy.adoptTeamTemplate(broken.id) }
        assertEquals(2, roomy.instances().size)
        // 放得下：整个团队一起建好
        val team = roomy.adoptTeamTemplate("tpl-research", name = " 新团队 ")
        assertEquals("新团队", team.name)
        assertEquals(2, team.members.size)
        assertEquals(4, roomy.instances().size)
        expectApi(404) { roomy.adoptTeamTemplate("tpl-nope") }
    }

    @Test
    fun deletingAnInstanceRetiresItsPlansAndRoutes() = runTest {
        val s = service()
        val own = s.plans("inst-coder")
        assertTrue("演示数据里小码有自己的计划", own.isNotEmpty())
        val pipeline = s.createPlan(
            NewPlan(
                instanceId = "inst-research",
                title = "周报流水线",
                goal = "收集后写代码",
                triggers = emptyList(),
                steps = listOf(
                    PlanStep("collect", "inst-research", "收集", emptyList()),
                    PlanStep("code", "inst-coder", "写代码", listOf("collect")),
                ),
            ),
        )
        assertFalse(pipeline.paused)
        val untouched = s.plans("inst-research").filter { it.id != pipeline.id }

        s.deleteInstance("inst-coder")

        // 它自己的计划标记删除：列表、详情都看不到
        assertTrue(s.plans().none { it.instanceId == "inst-coder" })
        for (plan in own) expectApi(404) { s.getPlan(plan.id) }
        // 别的实例的流水线有一步在它上面：暂停，恢复、确认报 409，改了步骤才行
        val paused = s.getPlan(pipeline.id)
        assertTrue(paused.paused)
        assertNull(paused.nextFireAtMs)
        val e = expectApi(409, "conflict") { s.setPlanPaused(pipeline.id, false) }
        assertTrue("step code" in e.detail)
        expectApi(409, "conflict") { s.confirmPlan(pipeline.id, paused.revision) }
        s.updatePlan(pipeline.id, PlanChange(steps = listOf(PlanStep("collect", "inst-research", "收集", emptyList()))))
        assertFalse(s.setPlanPaused(pipeline.id, false).paused)
        // 和它无关的计划不动
        assertEquals(untouched.map { it.id to it.paused }, s.plans("inst-research").filter { it.id != pipeline.id }.map { it.id to it.paused })
        // 别名一起删掉，删 key 不再被它挡住
        assertTrue(s.modelRoutes("inst-coder").isEmpty())
        s.setModelRoutes("inst-research", emptyList())
        s.deleteCredential("cred-home")
        s.deleteCredential("cred-work")
        assertTrue(s.credentials().isEmpty())
        expectApi(404) { s.deleteInstance("inst-coder") }
    }

    @Test
    fun disabledKeyAlreadyInUseCanStayInRoutes() = runTest {
        val s = service()
        // 小码：main = cred-work，降级 cred-home
        s.updateCredential("cred-home", CredentialUpdate(disabled = true))
        val spare = s.addCredential(NewCredential("openai", "备用", "sk-proj-0123456789"))
        s.updateCredential(spare.id, CredentialUpdate(disabled = true))
        // 原来就用着的停用 key 留着：可以保存
        s.setModelRoutes(
            "inst-coder",
            listOf(ModelRoute("main", "cred-work", "claude-opus-4", listOf(RouteFallback("cred-home", "deepseek-chat")))),
        )
        // 换到别的别名里也算“原来就用着”（服务端按整个实例算）
        s.setModelRoutes(
            "inst-coder",
            listOf(
                ModelRoute("main", "cred-work", "claude-opus-4", emptyList()),
                ModelRoute("fast", "cred-home", "deepseek-chat", emptyList()),
            ),
        )
        // 新引用停用的 key：422
        expectApi(422, "invalid") {
            s.setModelRoutes("inst-coder", listOf(ModelRoute("main", "cred-work", "m", listOf(RouteFallback(spare.id, "gpt-4.1")))))
        }
        // 别的实例没用过 cred-home：新引用也是 422
        s.setModelRoutes("inst-research", emptyList())
        expectApi(422, "invalid") { s.setModelRoutes("inst-research", listOf(ModelRoute("main", "cred-home", "m", emptyList()))) }
        // 去掉以后再加回来就是新引用了
        s.setModelRoutes("inst-coder", listOf(ModelRoute("main", "cred-work", "m", emptyList())))
        expectApi(422, "invalid") {
            s.setModelRoutes("inst-coder", listOf(ModelRoute("main", "cred-work", "m", listOf(RouteFallback("cred-home", "x")))))
        }
    }
}
