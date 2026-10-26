package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.vault.VAULT_ITEM_ROW_TEST_TAG
import cn.thinktin.app.ui.vault.VAULT_REQUEST_ROW_TEST_TAG
import cn.thinktin.app.ui.vault.VaultEditorViewModel
import cn.thinktin.app.ui.vault.VaultEvent
import cn.thinktin.app.ui.vault.VaultFormProblem
import cn.thinktin.app.ui.vault.VaultRequestViewModel
import cn.thinktin.app.ui.vault.VaultViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VaultRules
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 13.14：保险箱的规则、Mock 按服务端校验、列表 / 新建（重名换名、满 200 条）/ 修改 / 填写请求（已有同名条目、别处处理过）
 * 的视图模型，以及界面上从设置进保险箱、新建、填写请求的流程。
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class VaultTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val dispatcher = StandardTestDispatcher()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val inDialog = hasAnyAncestor(isDialog())

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        scenario?.close()
        Dispatchers.resetMain()
    }

    private fun mock() = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })

    private val now: Long get() = DemoTestApp.FIXED_CLOCK.millis()

    private fun apiCode(block: suspend () -> Unit): String? = runBlocking {
        try {
            block()
            null
        } catch (e: ServiceError.Api) {
            e.code
        }
    }

    @Test
    fun rulesMatchTheServer() {
        assertTrue(VaultRules.isValidName("github"))
        assertTrue(VaultRules.isValidName("a-b_c9"))
        assertFalse(VaultRules.isValidName("_x"))
        assertFalse(VaultRules.isValidName("GitHub"))
        assertFalse(VaultRules.isValidName("a".repeat(65)))
        assertEquals("my-token", VaultRules.cleanName("My Token!"))
        assertEquals(VaultRules.PasswordProblem.TooShort, VaultRules.passwordProblem("abc"))
        assertNull(VaultRules.passwordProblem("密码四位"))
        assertEquals(VaultRules.PasswordProblem.TooLong, VaultRules.passwordProblem("a".repeat(4097)))
        assertEquals(VaultRules.PasswordProblem.ControlCharacters, VaultRules.passwordProblem("ab\tcd"))
    }

    @Test
    fun mockChecksLikeTheServer() {
        val s = mock()
        assertEquals("invalid", apiCode { s.createVaultItem(NewVaultItem("pypi", "", "", "abc")) })
        assertEquals("invalid", apiCode { s.createVaultItem(NewVaultItem("Bad Name", "", "", "abcd")) })
        assertEquals("invalid", apiCode { s.createVaultItem(NewVaultItem("pypi", "长".repeat(201), "", "abcd")) })
        // 先查密码，再查重名（服务端的顺序）。
        assertEquals("invalid", apiCode { s.createVaultItem(NewVaultItem("github", "", "", "x")) })
        assertEquals("conflict", apiCode { s.createVaultItem(NewVaultItem("github", "", "", "abcd")) })
        // 填写请求：已有同名条目就更新它；处理过的再处理报 409。
        runBlocking {
            s.createVaultItem(NewVaultItem("aliyun_oss", "旧的", "old", "oldpass", listOf("inst-coder")))
            val done = s.fulfillVaultRequest("vreq-pending", "me", "newpass")
            val item = s.vaultItems().single { it.name == "aliyun_oss" }
            assertEquals(item.id, done.itemId)
            assertEquals("上传调研报告", item.purpose)
            assertEquals(listOf("inst-coder", "inst-research"), item.instanceIds)
            assertEquals("me", s.vaultItem(item.id).username)
        }
        assertEquals("conflict", apiCode { s.declineVaultRequest("vreq-pending") })
        assertEquals("conflict", apiCode { s.fulfillVaultRequest("vreq-pending", "", "abcd1234") })
    }

    @Test
    fun listSplitsRequestsAndDeletes() = runTest(dispatcher) {
        val vm = VaultViewModel(mock())
        advanceUntilIdle()
        val state = vm.uiState.value
        assertEquals(listOf("github", "npm_token", "zotero"), state.items.map { it.name })
        assertEquals(listOf("vreq-pending"), state.pending(now).map { it.id })
        assertEquals(listOf("vreq-done"), state.past(now).map { it.id })
        // 过了期限的算过期。
        assertTrue(state.pending(now + 25L * 60 * 60 * 1000).isEmpty())
        assertFalse(state.isFull)
        vm.delete(state.items.first())
        advanceUntilIdle()
        assertEquals(listOf("npm_token", "zotero"), vm.uiState.value.items.map { it.name })
    }

    @Test
    fun editorCreatesRenamesAndRespectsTheLimit() = runTest(dispatcher) {
        val s = mock()
        val vm = VaultEditorViewModel(s, null)
        advanceUntilIdle()
        vm.onName("GitHub")
        assertEquals("github", vm.uiState.value.name)
        vm.onPassword("ghp_123456")
        // 重名：换个名字，提示一句，先不存。
        vm.save()
        assertEquals("github_2", vm.uiState.value.name)
        assertEquals("github_2", vm.uiState.value.renamedTo)
        vm.setAllInstances(false)
        vm.save()
        assertEquals(listOf(VaultFormProblem.NoInstances), vm.uiState.value.visibleProblems)
        vm.toggle("inst-coder")
        vm.events.let { events ->
            vm.save()
            advanceUntilIdle()
            val saved = events.first() as VaultEvent.Saved
            assertEquals("github_2", saved.item.name)
            assertEquals(listOf("inst-coder"), saved.item.instanceIds)
        }
        // 满 200 条：拦下。
        runBlocking {
            var i = 0
            while (s.vaultItems().size < VaultRules.MAX_ITEMS) s.createVaultItem(NewVaultItem("item${i++}", "", "", "abcd"))
        }
        val full = VaultEditorViewModel(s, null)
        advanceUntilIdle()
        full.onName("one-more")
        full.onPassword("abcd1234")
        full.save()
        assertTrue(VaultFormProblem.Full in full.uiState.value.visibleProblems)
    }

    @Test
    fun editorEditsOnlyWhatChanged() = runTest(dispatcher) {
        val s = mock()
        val vm = VaultEditorViewModel(s, "vault-github")
        advanceUntilIdle()
        val state = vm.uiState.value
        assertTrue(state.editing)
        assertEquals("demo-user", state.username)
        assertFalse(state.allInstances)
        assertFalse(state.hasChanges)
        assertTrue("修改时密码可以不填", state.problems.isEmpty())
        vm.setAllInstances(true)
        vm.save()
        advanceUntilIdle()
        val item = s.vaultItems().single { it.id == "vault-github" }
        assertTrue(item.instanceIds.isEmpty())
        assertEquals("demo-user", s.vaultItem("vault-github").username)
        vm.onPassword("ab")
        vm.save()
        assertEquals(listOf(VaultFormProblem.Password(VaultRules.PasswordProblem.TooShort)), vm.uiState.value.visibleProblems)
    }

    @Test
    fun requestFillWarnsAboutSameNamedItemsAndHandlesConflicts() = runTest(dispatcher) {
        val s = mock()
        s.createVaultItem(NewVaultItem("aliyun_oss", "", "", "oldpass"))
        val vm = VaultRequestViewModel(s, "vreq-pending") { now }
        advanceUntilIdle()
        assertEquals("aliyun_oss", vm.uiState.value.existing?.name)
        assertEquals(VaultRequestStatus.Pending, vm.status())
        vm.onPassword("abc")
        vm.fulfill()
        assertEquals(
            listOf(VaultFormProblem.Password(VaultRules.PasswordProblem.TooShort)),
            vm.uiState.value.visibleProblems,
        )
        // 别处已经拒绝了：重新拉、显示结果。
        s.declineVaultRequest("vreq-pending")
        vm.onPassword("abcd1234")
        vm.fulfill()
        advanceUntilIdle()
        assertEquals(VaultRequestStatus.Declined, vm.status())

        val missing = VaultRequestViewModel(s, "nope") { now }
        advanceUntilIdle()
        assertTrue(missing.uiState.value.missing)
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test
    fun settingsToVaultCreateAndFillRequest() {
        Dispatchers.resetMain()
        val app = ApplicationProvider.getApplicationContext<DemoTestApp>()
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("外观"))
        compose.onNode(hasText("密码保险箱")).performScrollTo().performClick()
        waitFor(hasTestTag(VAULT_ITEM_ROW_TEST_TAG + "vault-github"))
        compose.onNode(hasText("条目（3 / 200）")).assertExists()
        compose.onNode(hasTestTag(VAULT_REQUEST_ROW_TEST_TAG + "vreq-pending")).assertExists()

        // 条目详情：只显示账号。
        compose.onNode(hasTestTag(VAULT_ITEM_ROW_TEST_TAG + "vault-github")).performClick()
        waitFor(hasText("[vault:github]"))
        compose.onNode(hasText("demo-user")).assertExists()
        compose.onNode(hasText("已加密保存，谁都看不到明文（包括你）")).assertExists()
        compose.onNode(hasContentDescription("返回")).performClick()

        // 新建：密码太短先标出来。
        waitFor(hasContentDescription("新建条目"))
        compose.onNode(hasContentDescription("新建条目")).performClick()
        waitFor(hasContentDescription("条目名") and hasSetTextAction())
        compose.onNode(hasContentDescription("条目名") and hasSetTextAction()).performTextInput("pypi")
        compose.onNode(hasContentDescription("密码") and hasSetTextAction()).performTextInput("abc")
        compose.onNode(hasText("保存")).performClick()
        waitFor(hasText("密码至少 4 个字符"))
        compose.onNode(hasContentDescription("密码") and hasSetTextAction()).performTextInput("defg")
        compose.onNode(hasText("保存")).performClick()
        waitFor(hasTestTag(VAULT_ITEM_ROW_TEST_TAG + "vault-demo-1"))

        // 填写请求。
        compose.onNode(hasTestTag(VAULT_REQUEST_ROW_TEST_TAG + "vreq-pending")).performScrollTo().performClick()
        waitFor(hasText("上传调研报告"))
        compose.onNode(hasContentDescription("密码") and hasSetTextAction()).performTextInput("s3cret")
        compose.onNode(hasText("保存并交给 agent")).performScrollTo().performClick()
        waitFor(hasText("已填写"))
        assertTrue(compose.onAllNodes(hasText("保存并交给 agent")).fetchSemanticsNodes().isEmpty())
        compose.onNode(hasText("查看条目")).assertExists()
        if (compose.onAllNodes(inDialog).fetchSemanticsNodes().isNotEmpty()) fail("没有对话框")
    }
}
