package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.common.TokenFormat
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.keys.AddKeyEvent
import cn.thinktin.app.ui.keys.AddKeyField
import cn.thinktin.app.ui.keys.AddKeyStep
import cn.thinktin.app.ui.keys.AddKeyViewModel
import cn.thinktin.app.ui.keys.KeyEditViewModel
import cn.thinktin.app.ui.keys.KeyFormEvent
import cn.thinktin.app.ui.keys.KeyRules
import cn.thinktin.app.ui.keys.KeySecretViewModel
import cn.thinktin.app.ui.keys.KeyUsage
import cn.thinktin.app.ui.keys.KeysEvent
import cn.thinktin.app.ui.keys.KeysViewModel
import cn.thinktin.app.ui.routes.ModelRoutesEvent
import cn.thinktin.app.ui.routes.ModelRoutesViewModel
import cn.thinktin.app.ui.usage.UsageRange
import cn.thinktin.app.ui.usage.UsageViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.RouteFallback
import cn.thinktin.data.model.UsageGroup
import cn.thinktin.data.model.UsageSummary
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/**
 * 13.4 的服务替身：数据来自 Mock（行为和服务端一致：订阅 key、地址、删除在用的 key 都会被拒），
 * [fail] 让某个方法下一次调用抛指定错误（只抛一次），并记下调用。
 */
private class KeyService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    private val failures = mutableMapOf<String, ServiceError>()
    val added = mutableListOf<NewCredential>()
    val updates = mutableListOf<Pair<String, CredentialUpdate>>()
    val replaced = mutableListOf<Pair<String, String>>()
    val deleted = mutableListOf<String>()
    val routeSets = mutableListOf<Pair<String, List<ModelRoute>>>()
    val usageCalls = mutableListOf<UsageCall>()
    val auth = MutableStateFlow(AuthState.SignedIn)

    data class UsageCall(val group: UsageGroup, val fromMs: Long?, val toMs: Long?, val tz: String?)

    override val isDemo: Boolean = false
    override val authState: StateFlow<AuthState> get() = auth

    fun fail(method: String, error: ServiceError) {
        failures[method] = error
    }

    private fun maybeFail(method: String) {
        failures.remove(method)?.let { throw it }
    }

    override suspend fun vendors(): List<VendorInfo> {
        maybeFail("vendors")
        return mock.vendors()
    }

    override suspend fun credentials(): List<Credential> {
        maybeFail("credentials")
        return mock.credentials()
    }

    override suspend fun instances(): List<Instance> {
        maybeFail("instances")
        return mock.instances()
    }

    override suspend fun addCredential(credential: NewCredential): Credential {
        added += credential
        maybeFail("addCredential")
        return mock.addCredential(credential)
    }

    override suspend fun updateCredential(credentialId: String, update: CredentialUpdate): Credential {
        updates += credentialId to update
        maybeFail("updateCredential")
        return mock.updateCredential(credentialId, update)
    }

    override suspend fun replaceCredentialSecret(credentialId: String, apiKey: String): Credential {
        replaced += credentialId to apiKey
        maybeFail("replaceCredentialSecret")
        return mock.replaceCredentialSecret(credentialId, apiKey)
    }

    override suspend fun deleteCredential(credentialId: String) {
        deleted += credentialId
        maybeFail("deleteCredential")
        mock.deleteCredential(credentialId)
    }

    override suspend fun modelRoutes(instanceId: String): List<ModelRoute> {
        maybeFail("modelRoutes")
        return mock.modelRoutes(instanceId)
    }

    override suspend fun setModelRoutes(instanceId: String, routes: List<ModelRoute>) {
        routeSets += instanceId to routes
        maybeFail("setModelRoutes")
        mock.setModelRoutes(instanceId, routes)
    }

    override suspend fun usage(group: UsageGroup, fromMs: Long?, toMs: Long?, tz: String?): UsageSummary {
        usageCalls += UsageCall(group, fromMs, toMs, tz)
        maybeFail("usage")
        return mock.usage(group, fromMs, toMs, tz)
    }
}

/** 13.4：本地校验规则、key 列表 / 添加 / 编辑 / 换 key / 删除、模型别名编辑与保存、用量分组与格式化。 */
@OptIn(ExperimentalCoroutinesApi::class)
class KeysViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun api(status: Int, code: String, detail: String = "") = ServiceError.Api(status, code, detail, null)

    // ---- 本地校验 ----

    @Test
    fun baseUrlMustBeHttpsAndPublic() {
        assertNull(KeyRules.checkBase("https://api.example.com/v1"))
        assertNull(KeyRules.checkBase("https://8.8.8.8/v1"))
        assertNull(KeyRules.checkBase("https://[2606:4700::1111]/v1"))
        assertNull(KeyRules.checkBase("https://my_relay.example.com:8443/openai"))
        assertEquals(R.string.key_error_base_empty, KeyRules.checkBase("  ")?.resId)
        assertEquals(R.string.key_error_base_https, KeyRules.checkBase("http://api.example.com/v1")?.resId)
        assertEquals(R.string.key_error_base_https, KeyRules.checkBase("HTTPS://api.example.com")?.resId)
        assertEquals(R.string.key_error_base_extra, KeyRules.checkBase("https://user:pw@api.example.com")?.resId)
        assertEquals(R.string.key_error_base_extra, KeyRules.checkBase("https://api.example.com/v1?x=1")?.resId)
        assertEquals(R.string.key_error_base_extra, KeyRules.checkBase("https://api.example.com/v1#a")?.resId)
        assertEquals(R.string.key_error_base_invalid, KeyRules.checkBase("https:///v1")?.resId)
        val private = listOf(
            "https://localhost:8000/v1", "https://api.localhost/v1", "https://gpu.local/v1", "https://llm.internal/v1",
            "https://intranet/v1", "https://127.0.0.1/v1", "https://10.0.0.8/v1", "https://172.20.1.1/v1",
            "https://192.168.1.10/v1", "https://169.254.169.254/latest", "https://100.100.100.200/v1",
            "https://0.0.0.0/v1", "https://224.0.0.1/v1", "https://198.18.0.1/v1", "https://[::1]/v1",
            "https://[fd00::1]/v1", "https://[fe80::1]/v1", "https://[2001:db8::1]/v1", "https://[::ffff:10.0.0.1]/v1",
            "https://0x7f.1/v1", "https://2130706433/v1", "https://127.1/v1",
        )
        for (url in private) assertEquals(url, R.string.key_error_base_private, KeyRules.checkBase(url)?.resId)
        // 套餐专用地址（按路径段匹配）
        val plan = KeyRules.checkBase("https://ark.cn-beijing.volces.com/api/coding/v3")
        assertEquals(R.string.key_error_base_plan, plan?.resId)
        assertEquals(listOf("https://ark.cn-beijing.volces.com/api/coding"), plan?.args)
        assertNull(KeyRules.checkBase("https://ark.cn-beijing.volces.com/api/codingx"))
        assertNull(KeyRules.checkBase("https://ark.cn-beijing.volces.com/api/v3"))
    }

    @Test
    fun keyFormatAndSubscriptionPrefixes() {
        assertNull(KeyRules.checkKey("deepseek", "sk-0123456789abcdef"))
        assertEquals(R.string.key_error_key_empty, KeyRules.checkKey("deepseek", "")?.resId)
        assertEquals(R.string.key_error_key_short, KeyRules.checkKey("deepseek", "sk-1234")?.resId)
        assertEquals(R.string.key_error_key_chars, KeyRules.checkKey("deepseek", "sk-abc def123")?.resId)
        assertEquals(R.string.key_error_key_chars, KeyRules.checkKey("deepseek", "sk-密钥12345678")?.resId)
        assertEquals(R.string.key_error_key_long, KeyRules.checkKey("deepseek", "k".repeat(4097))?.resId)
        val qwen = KeyRules.checkKey("qwen-cn", "sk-sp-abcdef0123456789")
        assertEquals(R.string.key_error_subscription, qwen?.resId)
        assertEquals(listOf("sk-sp-"), qwen?.args)
        assertEquals(R.string.key_error_subscription, KeyRules.checkKey("qwen-intl", "sk-sp-abcdef0123")?.resId)
        assertEquals(R.string.key_error_subscription, KeyRules.checkKey("minimax-cn", "sk-cp-abcdef0123")?.resId)
        assertNull(KeyRules.checkKey("minimax-cn", "sk-api-abcdef0123"))
        assertEquals(R.string.key_error_subscription, KeyRules.checkKey("hunyuan-intl", "sk-tp-abcdef0123")?.resId)
        assertEquals(R.string.key_error_subscription, KeyRules.checkKey("anthropic", "sk-ant-oat01-abcdef")?.resId)
        assertEquals(R.string.key_error_subscription, KeyRules.checkKey("anthropic", "sk-ant-ort01-abcdef")?.resId)
        assertNull(KeyRules.checkKey("anthropic", "sk-ant-api03-abcdef"))
        // 自定义接口、别的厂商不按前缀拒
        assertNull(KeyRules.checkKey(KeyRules.CUSTOM_VENDOR, "sk-sp-whatever"))
        assertNull(KeyRules.checkKey("deepseek", "sk-sp-whatever"))
    }

    @Test
    fun pastedKeysAreCleaned() {
        assertEquals("sk-abc123456", KeyRules.cleanPastedKey("  sk-abc123456\n"))
        assertEquals("sk-abc123456", KeyRules.cleanPastedKey("\"sk-abc123456\""))
        assertEquals("sk-abc123456", KeyRules.cleanPastedKey("export DEEPSEEK_API_KEY=sk-abc123456"))
        assertEquals("sk-abc123456", KeyRules.cleanPastedKey("OPENAI_API_KEY = 'sk-abc123456'"))
        assertEquals("sk-abc123456", KeyRules.cleanPastedKey("Bearer sk-abc123456"))
        assertEquals("sk-abc=123", KeyRules.cleanPastedKey("sk-abc=123"))
    }

    @Test
    fun dailyLimitParsing() {
        assertEquals(KeyRules.DailyLimit.None, KeyRules.parseDailyLimit("  "))
        assertEquals(KeyRules.DailyLimit.Value(2_000_000), KeyRules.parseDailyLimit("2,000,000"))
        assertEquals(KeyRules.DailyLimit.Value(500), KeyRules.parseDailyLimit(" 500 "))
        assertTrue(KeyRules.parseDailyLimit("0") is KeyRules.DailyLimit.Invalid)
        assertTrue(KeyRules.parseDailyLimit("1.5") is KeyRules.DailyLimit.Invalid)
        assertTrue(KeyRules.parseDailyLimit("-3") is KeyRules.DailyLimit.Invalid)
        assertTrue(KeyRules.parseDailyLimit("99999999999999999999") is KeyRules.DailyLimit.Invalid)
    }

    @Test
    fun aliasAndModelRules() {
        assertNull(KeyRules.checkAlias("main"))
        assertNull(KeyRules.checkAlias("fast-2.v1_x"))
        assertEquals(R.string.routes_error_alias_empty, KeyRules.checkAlias("")?.resId)
        assertEquals(R.string.routes_error_alias_format, KeyRules.checkAlias("Main")?.resId)
        assertEquals(R.string.routes_error_alias_format, KeyRules.checkAlias("-main")?.resId)
        assertEquals(R.string.routes_error_alias_format, KeyRules.checkAlias("a".repeat(65))?.resId)
        assertEquals(R.string.routes_error_model_empty, KeyRules.checkModel("")?.resId)
        assertEquals(R.string.routes_error_model_long, KeyRules.checkModel("m".repeat(129))?.resId)
    }

    @Test
    fun detachPromotesFirstFallbackAndDropsLonelyAliases() {
        val routes = listOf(
            ModelRoute("main", "k1", "m1", listOf(RouteFallback("k2", "m2"), RouteFallback("k3", "m3"))),
            ModelRoute("fast", "k2", "m2", listOf(RouteFallback("k1", "m1"))),
            ModelRoute("solo", "k1", "m1", emptyList()),
        )
        val detached = KeyRules.detachCredential(routes, "k1")
        assertEquals(
            listOf(
                ModelRoute("main", "k2", "m2", listOf(RouteFallback("k3", "m3"))),
                ModelRoute("fast", "k2", "m2", emptyList()),
            ),
            detached,
        )
        assertEquals(routes, KeyRules.detachCredential(routes, "k9"))
    }

    @Test
    fun vendorsAreGroupedByProtocols() {
        val vendors = listOf(
            VendorInfo("openai", "OpenAI", listOf("chat", "responses"), emptyList(), ""),
            VendorInfo("deepseek", "DeepSeek", listOf("anthropic", "chat", "responses"), emptyList(), ""),
            VendorInfo("gemini", "Gemini", listOf("chat"), emptyList(), ""),
            VendorInfo("qwen-cn", "百炼", listOf("responses", "chat", "anthropic"), emptyList(), ""),
            VendorInfo("anthropic", "Anthropic", listOf("anthropic", "chat"), emptyList(), ""),
            VendorInfo("custom", "自定义", emptyList(), emptyList(), ""),
        )
        val groups = KeyRules.groupVendors(vendors)
        assertEquals(
            listOf(listOf("anthropic", "chat", "responses"), listOf("anthropic", "chat"), listOf("chat", "responses"), listOf("chat")),
            groups.map { it.protocols },
        )
        assertEquals(listOf("deepseek", "qwen-cn"), groups.first().vendors.map { it.id })
        assertTrue(groups.none { g -> g.vendors.any { it.id == "custom" } })
    }

    @Test
    fun tokenFormatting() {
        val cjk: (TokenFormat.Unit, String) -> String = { unit, n ->
            when (unit) {
                TokenFormat.Unit.TenThousand -> "$n 万"
                TokenFormat.Unit.HundredMillion -> "$n 亿"
                else -> error("cjk uses 万 / 亿 only")
            }
        }
        val western: (TokenFormat.Unit, String) -> String = { unit, n ->
            when (unit) {
                TokenFormat.Unit.Thousand -> "${n}k"
                TokenFormat.Unit.Million -> "${n}M"
                TokenFormat.Unit.Billion -> "${n}B"
                else -> error("western uses k / M / B only")
            }
        }
        assertEquals("0", TokenFormat.format(0, TokenFormat.Style.Cjk, cjk))
        assertEquals("9,999", TokenFormat.format(9_999, TokenFormat.Style.Cjk, cjk))
        assertEquals("9,999", TokenFormat.format(9_999, TokenFormat.Style.Western, western))
        assertEquals("1.2 万", TokenFormat.format(12_345, TokenFormat.Style.Cjk, cjk))
        assertEquals("12.3k", TokenFormat.format(12_345, TokenFormat.Style.Western, western))
        assertEquals("12k", TokenFormat.format(12_000, TokenFormat.Style.Western, western))
        assertEquals("10 万", TokenFormat.format(99_999, TokenFormat.Style.Cjk, cjk))
        assertEquals("123 万", TokenFormat.format(1_234_567, TokenFormat.Style.Cjk, cjk))
        assertEquals("1.2M", TokenFormat.format(1_234_567, TokenFormat.Style.Western, western))
        assertEquals("2.5 亿", TokenFormat.format(250_000_000, TokenFormat.Style.Cjk, cjk))
        assertEquals("1,200 亿", TokenFormat.format(120_000_000_000, TokenFormat.Style.Cjk, cjk))
        assertEquals("3B", TokenFormat.format(3_000_000_000, TokenFormat.Style.Western, western))
        assertEquals("-1.5 万", TokenFormat.format(-15_000, TokenFormat.Style.Cjk, cjk))
        assertEquals("12,345,678", TokenFormat.grouped(12_345_678))
        assertEquals(TokenFormat.Style.Western, TokenFormat.styleOf("western"))
        assertEquals(TokenFormat.Style.Cjk, TokenFormat.styleOf("cjk"))
    }

    // ---- key 列表 ----

    @Test
    fun keysListLoadsWithVendors() = test {
        val vm = KeysViewModel(KeyService())
        assertTrue(vm.uiState.value.loading)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertFalse(s.loading)
        assertEquals(listOf("cred-work", "cred-home"), s.credentials.map { it.id })
        assertEquals("Anthropic", s.vendors["anthropic"]?.name)
    }

    @Test
    fun keysListErrorAndVendorFailureIsTolerated() = test {
        val service = KeyService()
        service.fail("credentials", ServiceError.Network("offline"))
        service.fail("vendors", ServiceError.Network("offline"))
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        assertEquals(R.string.error_network, vm.uiState.value.loadError?.resId)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertEquals(2, vm.uiState.value.credentials.size)
    }

    @Test
    fun disableAndEnableKey() = test {
        val service = KeyService()
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            val work = vm.uiState.value.credentials.first { it.id == "cred-work" }
            vm.setDisabled(work, true)
            advanceUntilIdle()
            assertEquals(UiText(R.string.keys_disabled_done, listOf("工作 key")), (awaitItem() as KeysEvent.Message).text)
            assertTrue(vm.uiState.value.credentials.first { it.id == "cred-work" }.disabled)
            assertEquals("cred-work" to CredentialUpdate(disabled = true), service.updates.single())
            vm.setDisabled(vm.uiState.value.credentials.first { it.id == "cred-work" }, false)
            advanceUntilIdle()
            assertEquals(R.string.keys_enabled_done, (awaitItem() as KeysEvent.Message).text.resId)
            assertFalse(vm.uiState.value.credentials.first { it.id == "cred-work" }.disabled)
        }
    }

    @Test
    fun deleteUnusedKey() = test {
        val service = KeyService()
        val spare = service.mock.addCredential(NewCredential("openai", "备用", "sk-proj-0123456789"))
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        vm.askDelete(spare)
        assertEquals(spare.id, vm.uiState.value.checkingUsageFor)
        advanceUntilIdle()
        val dialog = vm.uiState.value.dialog
        assertNotNull(dialog)
        assertTrue(dialog!!.usages.isEmpty())
        vm.confirmDelete()
        advanceUntilIdle()
        assertNull(vm.uiState.value.dialog)
        assertEquals(listOf(spare.id), service.deleted)
        assertTrue(service.routeSets.isEmpty())
        assertTrue(vm.uiState.value.credentials.none { it.id == spare.id })
    }

    @Test
    fun deleteKeyInUseListsAliasesThenDetaches() = test {
        val service = KeyService()
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        val home = vm.uiState.value.credentials.first { it.id == "cred-home" }
        vm.askDelete(home)
        advanceUntilIdle()
        val usages = vm.uiState.value.dialog!!.usages.sortedBy { it.instanceId }
        assertEquals(
            listOf(
                KeyUsage("inst-coder", "小码", "main", primary = false),
                KeyUsage("inst-research", "研究员", "main", primary = true),
            ),
            usages,
        )
        // 服务端（Mock 同样）在有别名用着时拒绝删除：确认后先改别名再删
        vm.confirmDelete()
        advanceUntilIdle()
        assertEquals(listOf("cred-home"), service.deleted)
        assertEquals(
            listOf(ModelRoute("main", "cred-work", "claude-sonnet-4", emptyList())),
            service.mock.modelRoutes("inst-coder"),
        )
        assertTrue("只靠这把 key 的别名被删掉（运行会等 key）", service.mock.modelRoutes("inst-research").isEmpty())
        assertTrue(service.mock.credentials().none { it.id == "cred-home" })
    }

    @Test
    fun deleteStopsWhenDetachIsRejected() = test {
        val service = KeyService()
        // 小码的主 key 停用了：整表替换小码的别名时服务端（Mock 同样）会拒绝
        service.mock.updateCredential("cred-work", CredentialUpdate(disabled = true))
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            vm.askDelete(vm.uiState.value.credentials.first { it.id == "cred-home" })
            advanceUntilIdle()
            vm.confirmDelete()
            advanceUntilIdle()
            assertEquals(UiText(R.string.keys_delete_detach_failed, listOf("小码")), (awaitItem() as KeysEvent.Message).text)
        }
        assertNull(vm.uiState.value.dialog)
        assertFalse(vm.uiState.value.busy)
        assertTrue(service.deleted.isEmpty())
        assertTrue(service.mock.credentials().any { it.id == "cred-home" })
    }

    @Test
    fun deleteBlockedWhenUsageCannotBeChecked() = test {
        val service = KeyService()
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            service.fail("instances", ServiceError.Network("offline"))
            vm.askDelete(vm.uiState.value.credentials.first())
            advanceUntilIdle()
            val message = (awaitItem() as KeysEvent.Message).text
            assertEquals(R.string.keys_usage_check_failed, message.resId)
            assertNull(vm.uiState.value.dialog)
            assertNull(vm.uiState.value.checkingUsageFor)
            assertTrue(service.deleted.isEmpty())
        }
    }

    @Test
    fun deleteConflictAndAlreadyDeleted() = test {
        val service = KeyService()
        val spare = service.mock.addCredential(NewCredential("openai", "备用", "sk-proj-0123456789"))
        val vm = KeysViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            vm.askDelete(spare)
            advanceUntilIdle()
            service.fail("deleteCredential", api(409, "conflict", "credential is used by 1 model route(s)"))
            vm.confirmDelete()
            advanceUntilIdle()
            assertEquals(UiText(R.string.keys_delete_in_use), (awaitItem() as KeysEvent.Message).text)
            assertNull(vm.uiState.value.dialog)

            // 别的设备已经删了：当作成功
            vm.askDelete(spare)
            advanceUntilIdle()
            service.fail("deleteCredential", api(404, "not_found"))
            vm.confirmDelete()
            advanceUntilIdle()
            assertEquals(R.string.keys_deleted, (awaitItem() as KeysEvent.Message).text.resId)
            assertTrue(vm.uiState.value.credentials.none { it.id == spare.id })
        }
    }

    // ---- 添加 key ----

    @Test
    fun addKeyPresetVendorFlow() = test {
        val service = KeyService()
        val vm = AddKeyViewModel(service)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertEquals(AddKeyStep.Vendor, s.step)
        assertEquals(listOf("anthropic", "chat", "responses"), s.groups.first().protocols)
        val deepseek = s.vendors.first { it.id == "deepseek" }
        vm.selectVendor(deepseek)
        assertEquals(AddKeyStep.Details, vm.uiState.value.step)
        assertEquals("DeepSeek", vm.uiState.value.label)
        vm.onKeyChange("sk-0123456789abcdef")
        vm.onDailyLimitChange("2,000,000")
        vm.events.test {
            vm.submit()
            assertTrue(vm.uiState.value.submitting)
            advanceUntilIdle()
            val added = (awaitItem() as AddKeyEvent.Added).credential
            assertEquals("cdef", added.last4)
            assertEquals(2_000_000L, added.dailyTokenLimit)
        }
        assertEquals(NewCredential("deepseek", "DeepSeek", "sk-0123456789abcdef", dailyTokenLimit = 2_000_000), service.added.single())
    }

    @Test
    fun addKeyRejectsSubscriptionKeyOnPasteAndSubmit() = test {
        val service = KeyService()
        val vm = AddKeyViewModel(service)
        advanceUntilIdle()
        vm.selectVendor(vm.uiState.value.vendors.first { it.id == "qwen-cn" })
        assertTrue(vm.uiState.value.refusesSubscriptionKeys)
        // 粘贴：整理空白并马上检查
        vm.onKeyChange("  sk-sp-abcdef0123456789\n")
        val key = vm.uiState.value.key
        assertEquals("sk-sp-abcdef0123456789", key.value)
        assertTrue(key.pasted)
        assertTrue(key.cleaned)
        assertEquals(R.string.key_error_subscription, key.error?.resId)
        vm.submit()
        advanceUntilIdle()
        assertTrue("本地拦下，不提交", service.added.isEmpty())
        // 手打一个字符：不打扰，错误清掉
        vm.onKeyChange(vm.uiState.value.key.value + "x")
        assertNull(vm.uiState.value.key.error)
        assertFalse(vm.uiState.value.key.pasted)
        // 换厂商时重新按新厂商检查已填的 key
        vm.backToVendors()
        assertEquals(AddKeyStep.Vendor, vm.uiState.value.step)
        vm.selectVendor(vm.uiState.value.vendors.first { it.id == "deepseek" })
        assertNull(vm.uiState.value.key.error)
        assertEquals("sk-sp-abcdef0123456789x", vm.uiState.value.key.value)
    }

    @Test
    fun addKeyLocalFieldErrors() = test {
        val service = KeyService()
        val vm = AddKeyViewModel(service)
        advanceUntilIdle()
        vm.selectVendor(vm.uiState.value.vendors.first { it.id == "openai" })
        vm.onKeyChange("short")
        vm.onLabelChange("x".repeat(65))
        vm.onDailyLimitChange("abc")
        vm.submit()
        val s = vm.uiState.value
        assertEquals(R.string.key_error_key_short, s.key.error?.resId)
        assertEquals(R.string.key_error_label_long, s.errors[AddKeyField.Label]?.resId)
        assertEquals(R.string.key_error_limit_number, s.errors[AddKeyField.DailyLimit]?.resId)
        assertTrue(service.added.isEmpty())
        // 改哪个字段就清哪个字段的错误
        vm.onLabelChange("备用")
        assertNull(vm.uiState.value.errors[AddKeyField.Label])
        assertNotNull(vm.uiState.value.errors[AddKeyField.DailyLimit])
    }

    @Test
    fun addCustomEndpointValidatesBases() = test {
        val service = KeyService()
        val vm = AddKeyViewModel(service)
        advanceUntilIdle()
        vm.selectCustom()
        val s = vm.uiState.value
        assertTrue(s.custom)
        assertEquals("custom", s.vendorId)
        assertEquals("", s.label)
        assertEquals(setOf("chat"), s.customProtocols)
        vm.onKeyChange("sk-sp-whatever-123")
        vm.onBaseChange("chat", "http://relay.example.com/v1")
        vm.submit()
        assertEquals(R.string.key_error_base_https, vm.uiState.value.errors[AddKeyField.OpenaiBase]?.resId)
        vm.onBaseChange("chat", "https://192.168.1.5/v1")
        vm.submit()
        assertEquals(R.string.key_error_base_private, vm.uiState.value.errors[AddKeyField.OpenaiBase]?.resId)
        vm.toggleProtocol("chat")
        vm.submit()
        assertEquals(R.string.key_error_protocols_empty, vm.uiState.value.errors[AddKeyField.Protocols]?.resId)
        assertTrue(service.added.isEmpty())

        vm.toggleProtocol("anthropic")
        vm.onBaseChange("anthropic", "https://relay.example.com/anthropic/")
        vm.events.test {
            vm.submit()
            advanceUntilIdle()
            val added = (awaitItem() as AddKeyEvent.Added).credential
            assertEquals(listOf("anthropic"), added.protocols)
        }
        val request = service.added.single()
        assertEquals("custom", request.vendor)
        assertEquals("https://relay.example.com/anthropic", request.anthropicBase)
        assertNull(request.openaiBase)
        assertEquals("relay.example.com", request.label)
    }

    @Test
    fun addKeyServerErrorsGoUnderFields() = test {
        val service = KeyService()
        val vm = AddKeyViewModel(service)
        advanceUntilIdle()
        vm.selectCustom()
        vm.onKeyChange("sk-0123456789")
        vm.onBaseChange("chat", "https://relay.example.com/v1")

        service.fail("addCredential", api(422, "invalid", "openai_base: https://x/plan is a coding or subscription plan address"))
        vm.submit()
        advanceUntilIdle()
        assertEquals(R.string.key_error_base_plan_server, vm.uiState.value.errors[AddKeyField.OpenaiBase]?.resId)

        service.fail("addCredential", api(422, "invalid", "Kimi subscription keys (sk-kimi-...) can only be used in the vendor's own tools"))
        vm.submit()
        advanceUntilIdle()
        assertEquals(R.string.key_error_subscription_server, vm.uiState.value.key.error?.resId)

        service.fail("addCredential", api(422, "invalid", "something else"))
        vm.submit()
        advanceUntilIdle()
        assertEquals(R.string.key_error_rejected, vm.uiState.value.formError?.resId)

        vm.events.test {
            service.fail("addCredential", ServiceError.Network("offline"))
            vm.submit()
            advanceUntilIdle()
            assertEquals(R.string.error_network, (awaitItem() as AddKeyEvent.Message).text.resId)
        }
        assertFalse(vm.uiState.value.submitting)
    }

    @Test
    fun addKeyVendorLoadFailureRetries() = test {
        val service = KeyService()
        service.fail("vendors", ServiceError.Network("offline"))
        val vm = AddKeyViewModel(service)
        advanceUntilIdle()
        assertEquals(R.string.error_network, vm.uiState.value.loadError?.resId)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertTrue(vm.uiState.value.vendors.isNotEmpty())
    }

    // ---- 编辑与换 key ----

    @Test
    fun editLabelAndDisable() = test {
        val service = KeyService()
        val vm = KeyEditViewModel(service, "cred-work")
        advanceUntilIdle()
        assertEquals("工作 key", vm.uiState.value.label)
        vm.onLabelChange("x".repeat(65))
        vm.save()
        assertEquals(R.string.key_error_label_long, vm.uiState.value.labelError?.resId)
        assertTrue(service.updates.isEmpty())
        vm.onLabelChange("  公司  ")
        vm.onDisabledChange(true)
        vm.events.test {
            vm.save()
            advanceUntilIdle()
            val saved = (awaitItem() as KeyFormEvent.Saved).credential
            assertEquals("公司", saved.label)
            assertTrue(saved.disabled)
        }
        assertEquals("cred-work" to CredentialUpdate(label = "公司", disabled = true), service.updates.single())
    }

    @Test
    fun editWithoutChangesDoesNotCall() = test {
        val service = KeyService()
        val vm = KeyEditViewModel(service, "cred-home")
        advanceUntilIdle()
        vm.events.test {
            vm.save()
            assertTrue(awaitItem() is KeyFormEvent.Saved)
        }
        assertTrue(service.updates.isEmpty())
    }

    @Test
    fun editMissingKey() = test {
        val vm = KeyEditViewModel(KeyService(), "cred-nope")
        advanceUntilIdle()
        assertTrue(vm.uiState.value.missing)
        assertNull(vm.uiState.value.credential)
    }

    @Test
    fun replaceSecretChecksPrefixAndMapsServerErrors() = test {
        val service = KeyService()
        val vm = KeySecretViewModel(service, "cred-work")
        advanceUntilIdle()
        vm.onKeyChange("sk-ant-oat01-0123456789")
        assertEquals(R.string.key_error_subscription, vm.uiState.value.key.error?.resId)
        vm.save()
        assertTrue(service.replaced.isEmpty())

        vm.onKeyChange("")
        vm.onKeyChange("sk-ant-api03-new-5678")
        service.fail("replaceCredentialSecret", api(422, "invalid", "api_key must not contain spaces"))
        vm.save()
        advanceUntilIdle()
        assertEquals(R.string.key_error_key_rejected, vm.uiState.value.key.error?.resId)

        vm.events.test {
            vm.save()
            advanceUntilIdle()
            assertEquals("5678", (awaitItem() as KeyFormEvent.Saved).credential.last4)
        }
        assertEquals("cred-work" to "sk-ant-api03-new-5678", service.replaced.last())
        assertEquals("", vm.uiState.value.key.value)
    }

    // ---- 模型别名 ----

    @Test
    fun routesLoadExistingAliases() = test {
        val vm = ModelRoutesViewModel(KeyService(), "inst-coder")
        advanceUntilIdle()
        val s = vm.uiState.value
        assertFalse(s.loading)
        assertFalse(s.mainMissing)
        assertEquals("anthropic", s.activeProtocol)
        val main = s.drafts.single()
        assertEquals("main", main.alias)
        assertEquals("cred-work", main.credentialId)
        assertEquals("claude-sonnet-4", main.model)
        assertEquals(listOf("cred-home"), main.fallbacks.map { it.credentialId })
        assertFalse(s.dirty)
    }

    @Test
    fun routesMainRequiredWhenMissing() = test {
        val service = KeyService()
        val adopted = service.mock.adopt("agent-coder", "新实例")
        val vm = ModelRoutesViewModel(service, adopted.id)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertTrue("服务端没有 main：顶部警告", s.mainMissing)
        val draft = s.drafts.single()
        assertEquals("main", draft.alias)
        assertNull(draft.credentialId)

        vm.save()
        val errors = vm.uiState.value.errors.getValue(draft.id)
        assertEquals(R.string.routes_error_key_empty, errors.credential?.resId)
        assertEquals(R.string.routes_error_model_empty, errors.model?.resId)

        // 改名成别的：main 必填
        vm.onAliasChange(draft.id, "Default")
        assertEquals("default", vm.uiState.value.drafts.single().alias)
        vm.onCredentialChange(draft.id, "cred-work")
        assertEquals("选 key 时填上厂商推荐的第一个模型", "claude-sonnet-4", vm.uiState.value.drafts.single().model)
        vm.save()
        assertEquals(R.string.routes_error_main_required, vm.uiState.value.formError?.resId)
        assertTrue(service.routeSets.isEmpty())

        vm.onAliasChange(draft.id, "main")
        vm.events.test {
            vm.save()
            advanceUntilIdle()
            assertEquals(UiText(R.string.routes_saved), (awaitItem() as ModelRoutesEvent.Message).text)
        }
        assertEquals(listOf(ModelRoute("main", "cred-work", "claude-sonnet-4", emptyList())), service.routeSets.single().second)
        assertFalse(vm.uiState.value.mainMissing)
        assertFalse(vm.uiState.value.dirty)
    }

    @Test
    fun routesValidateAliasesKeysAndFallbacks() = test {
        val service = KeyService()
        val openai = service.mock.addCredential(NewCredential("openai", "OpenAI", "sk-proj-0123456789"))
        service.mock.updateCredential("cred-home", CredentialUpdate(disabled = true))
        val vm = ModelRoutesViewModel(service, "inst-coder")
        advanceUntilIdle()
        val s = vm.uiState.value
        assertEquals("只列能用的 key（没停用、支持 anthropic）", listOf("cred-work"), s.usableCredentials.map { it.id })
        val main = s.drafts.single()

        vm.addRoute()
        val second = vm.uiState.value.drafts.last()
        assertEquals("", second.alias)
        vm.onAliasChange(second.id, "main")
        vm.onCredentialChange(second.id, openai.id)
        vm.save()
        var errors = vm.uiState.value.errors
        assertEquals(R.string.routes_error_alias_duplicate, errors.getValue(second.id).alias?.resId)
        assertEquals(R.string.routes_error_key_protocol, errors.getValue(second.id).credential?.resId)
        // 主 key 的降级项用了停用的 key
        assertEquals(R.string.routes_error_key_disabled, errors.getValue(main.id).fallbacks.getValue(0).first?.resId)

        vm.removeRoute(second.id)
        vm.removeFallback(main.id, 0)
        vm.addFallback(main.id)
        vm.onFallbackCredentialChange(main.id, 0, "cred-work")
        assertEquals("claude-sonnet-4", vm.uiState.value.drafts.single().fallbacks.single().model)
        vm.save()
        errors = vm.uiState.value.errors
        assertEquals(R.string.routes_error_fallback_same, errors.getValue(main.id).fallbacks.getValue(0).first?.resId)
        assertTrue(service.routeSets.isEmpty())
    }

    @Test
    fun routesFallbacksReorderAndCap() = test {
        val service = KeyService()
        val vm = ModelRoutesViewModel(service, "inst-coder")
        advanceUntilIdle()
        val id = vm.uiState.value.drafts.single().id
        vm.addFallback(id)
        vm.onFallbackCredentialChange(id, 1, "cred-work")
        vm.onFallbackModelChange(id, 1, "claude-opus-4")
        vm.addFallback(id)
        vm.addFallback(id)
        assertEquals("最多 3 个", 3, vm.uiState.value.drafts.single().fallbacks.size)
        vm.removeFallback(id, 2)
        vm.moveFallback(id, 1, up = true)
        assertEquals(listOf("cred-work", "cred-home"), vm.uiState.value.drafts.single().fallbacks.map { it.credentialId })
        vm.moveFallback(id, 0, up = true)
        assertEquals("第一个不能再上移", "cred-work", vm.uiState.value.drafts.single().fallbacks.first().credentialId)
        assertTrue(vm.uiState.value.dirty)
        vm.save()
        advanceUntilIdle()
        assertEquals(
            listOf(
                ModelRoute(
                    "main", "cred-work", "claude-sonnet-4",
                    listOf(RouteFallback("cred-work", "claude-opus-4"), RouteFallback("cred-home", "deepseek-chat")),
                ),
            ),
            service.mock.modelRoutes("inst-coder"),
        )
        val savedId = vm.uiState.value.drafts.single().id
        vm.addFallback(savedId)
        assertTrue(vm.uiState.value.dirty)
        vm.reset()
        assertEquals(2, vm.uiState.value.drafts.single().fallbacks.size)
        assertFalse(vm.uiState.value.dirty)
    }

    @Test
    fun routesSaveRejectedByServer() = test {
        val service = KeyService()
        val vm = ModelRoutesViewModel(service, "inst-research")
        advanceUntilIdle()
        service.fail("setModelRoutes", api(422, "invalid", "credential is disabled"))
        vm.save()
        advanceUntilIdle()
        assertEquals(R.string.routes_error_rejected, vm.uiState.value.formError?.resId)
        assertFalse(vm.uiState.value.saving)
        vm.events.test {
            service.fail("setModelRoutes", ServiceError.Network("offline"))
            vm.save()
            advanceUntilIdle()
            assertEquals(R.string.error_network, (awaitItem() as ModelRoutesEvent.Message).text.resId)
        }
    }

    @Test
    fun routesLoadError() = test {
        val service = KeyService()
        service.fail("modelRoutes", ServiceError.Network("offline"))
        val vm = ModelRoutesViewModel(service, "inst-coder")
        advanceUntilIdle()
        assertEquals(R.string.error_network, vm.uiState.value.loadError?.resId)
        assertFalse(vm.uiState.value.mainMissing)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertEquals(1, vm.uiState.value.drafts.size)
    }

    // ---- 用量 ----

    private val zone: ZoneId = ZoneId.of("Asia/Shanghai")
    private fun startOf(date: String) = LocalDate.parse(date).atStartOfDay(zone).toInstant().toEpochMilli()

    @Test
    fun usageDefaultsToSevenDaysByDay() = test {
        val service = KeyService()
        val vm = UsageViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertEquals(UsageRange.Week, s.range)
        assertEquals(UsageGroup.Day, s.group)
        val call = service.usageCalls.single()
        assertEquals(startOf("2026-10-16"), call.fromMs)
        assertEquals(DemoTestApp.FIXED_CLOCK.millis(), call.toMs)
        assertEquals("Asia/Shanghai", call.tz)
        assertEquals(7, s.bars.size)
        assertEquals(LocalDate.parse("2026-10-16"), s.bars.first().date)
        assertEquals(LocalDate.parse("2026-10-22"), s.bars.last().date)
        assertEquals(84_000L, s.bars.last().tokens)
        assertEquals("按天的表格新的在前", LocalDate.parse("2026-10-22"), s.rows.first().date)
        assertEquals(s.rows.sumOf { it.bucket.chargedTokens }, s.summary!!.total.chargedTokens)
        assertEquals(3L, s.summary!!.total.failedRequests)
    }

    @Test
    fun usageGroupsResolveNames() = test {
        val service = KeyService()
        val vm = UsageViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        vm.selectGroup(UsageGroup.Instance)
        advanceUntilIdle()
        var s = vm.uiState.value
        assertTrue(s.bars.isEmpty())
        assertEquals(listOf("小码", "研究员"), s.rows.map { it.name })
        assertEquals(UsageGroup.Instance, service.usageCalls.last().group)

        vm.selectGroup(UsageGroup.Model)
        advanceUntilIdle()
        s = vm.uiState.value
        assertEquals(listOf("claude-sonnet-4", "deepseek-chat", "deepseek-reasoner"), s.rows.map { it.name })
        assertEquals(listOf("Anthropic", "DeepSeek", "DeepSeek"), s.rows.map { it.vendor })

        vm.selectGroup(UsageGroup.Credential)
        advanceUntilIdle()
        s = vm.uiState.value
        assertEquals(listOf("工作 key", "个人"), s.rows.map { it.name })
        assertEquals(listOf("a1b2", "9z8y"), s.rows.map { it.last4 })
        assertEquals(listOf("Anthropic", "DeepSeek"), s.rows.map { it.vendor })
    }

    @Test
    fun usageDeletedInstanceIsMarked() = test {
        val service = KeyService()
        service.mock.deleteInstance("inst-research")
        val vm = UsageViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        vm.selectGroup(UsageGroup.Instance)
        advanceUntilIdle()
        val research = vm.uiState.value.rows.first { it.bucket.key == "inst-research" }
        assertTrue(research.gone)
        assertNull(research.name)
    }

    @Test
    fun usageRanges() = test {
        val service = KeyService()
        val vm = UsageViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        vm.selectRange(UsageRange.Today)
        advanceUntilIdle()
        assertEquals(startOf("2026-10-22"), service.usageCalls.last().fromMs)
        assertEquals(1, vm.uiState.value.bars.size)
        assertEquals(1, vm.uiState.value.rows.size)

        vm.selectRange(UsageRange.Month)
        advanceUntilIdle()
        assertEquals(startOf("2026-09-23"), service.usageCalls.last().fromMs)
        assertEquals(30, vm.uiState.value.bars.size)
        assertEquals("没用量的天也有柱子（高度 0）", 23, vm.uiState.value.bars.count { it.tokens == 0L })

        // 自定义：先打开选择面板，不查
        val calls = service.usageCalls.size
        vm.selectRange(UsageRange.Custom)
        assertTrue(vm.uiState.value.pickingCustom)
        assertEquals(calls, service.usageCalls.size)
        fun utc(date: String) = LocalDate.parse(date).atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()
        assertEquals(R.string.usage_custom_pick, vm.applyCustom(null, null)?.resId)
        assertEquals(R.string.usage_custom_future, vm.applyCustom(utc("2026-10-20"), utc("2026-10-23"))?.resId)
        assertEquals(R.string.usage_custom_too_long, vm.applyCustom(utc("2025-01-01"), utc("2026-10-01"))?.resId)
        assertEquals(R.string.usage_custom_order, vm.applyCustom(utc("2026-10-20"), utc("2026-10-18"))?.resId)
        vm.cancelCustom()
        assertFalse(vm.uiState.value.pickingCustom)
        assertEquals(UsageRange.Month, vm.uiState.value.range)

        vm.selectRange(UsageRange.Custom)
        assertNull(vm.applyCustom(utc("2026-10-18"), utc("2026-10-20")))
        advanceUntilIdle()
        val s = vm.uiState.value
        assertEquals(UsageRange.Custom, s.range)
        assertFalse(s.pickingCustom)
        assertEquals(startOf("2026-10-18"), service.usageCalls.last().fromMs)
        assertEquals(startOf("2026-10-21"), service.usageCalls.last().toMs)
        assertEquals(3, s.bars.size)
        assertEquals(3, s.rows.size)
    }

    @Test
    fun usageErrorKeepsPreviousData() = test {
        val service = KeyService()
        val vm = UsageViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        service.fail("usage", ServiceError.Network("offline"))
        vm.selectGroup(UsageGroup.Model)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertEquals(R.string.error_network, s.error?.resId)
        assertNotNull(s.summary)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.error)
        assertEquals(3, vm.uiState.value.rows.size)
    }
}
