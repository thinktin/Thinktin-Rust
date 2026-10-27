package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.plans.PLAN_DETAIL_TEST_TAG
import cn.thinktin.app.ui.plans.PLAN_EDIT_TEST_TAG
import cn.thinktin.app.ui.plans.PLAN_ROW_TEST_TAG
import cn.thinktin.app.ui.plans.PLAN_RUN_ROW_TEST_TAG
import cn.thinktin.app.ui.plans.PLAN_SAVE_TEST_TAG
import cn.thinktin.app.ui.plans.PLAN_TRIGGER_ROW_TEST_TAG
import cn.thinktin.app.ui.plans.TRIGGER_KIND_TEST_TAG
import cn.thinktin.app.ui.plans.TRIGGER_SHEET_TEST_TAG
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.Schedule
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 13.6 的界面：从抽屉进计划列表（分组、开关暂停）、深链进详情确认 agent 建的计划（返回回首页）、编辑触发规则并保存。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class PlansUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val mock = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })
    private val fake = FakeThinktinService(mock)
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String? = null) {
        app.container = testContainer(app, { fake })
        val intent = Intent(app, MainActivity::class.java)
        if (uri != null) {
            intent.action = Intent.ACTION_VIEW
            intent.data = Uri.parse(uri)
        }
        scenario = ActivityScenario.launch(intent)
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun waitGone(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty() }
    }

    @Test
    fun listFromTheDrawerGroupsAndPauses() {
        launch()
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        // Robolectric 的触摸注入点不到抽屉里的条目（真机正常），用无障碍点击动作。
        compose.onNode(hasText("计划") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasTestTag(PLAN_ROW_TEST_TAG + "plan-daily"))
        compose.onNode(hasText("等你确认")).assertIsDisplayed()
        compose.onNode(hasText("每周一整理行业新闻")).assertIsDisplayed()
        compose.onNode(hasText("查看并确认")).assertIsDisplayed()
        compose.onNode(hasText("在跑")).assertIsDisplayed()
        compose.onNode(hasText("每日依赖检查")).assertIsDisplayed()
        compose.onNode(hasText("有触发规则失效了")).assertIsDisplayed()
        // agent 建的计划标题带标识，用户建的不带。
        compose.onAllNodes(hasText("【AI 生成】")).assertCountEquals(1)
        // 开关：暂停每日依赖检查。
        compose.onNode(hasContentDescription("暂停")).performClick()
        waitFor(hasText("已暂停"))
        assertTrue(runBlocking { mock.getPlan("plan-daily") }.paused)
    }

    @Test
    fun confirmAnAgentPlan() {
        launch("thinktin://plan/plan-weekly")
        waitFor(hasTestTag(PLAN_DETAIL_TEST_TAG))
        compose.onNode(hasText("每周一整理行业新闻")).assertIsDisplayed()
        compose.onNode(hasText("agent 新建或修改了这个计划，你确认之前它不会运行。")).assertIsDisplayed()
        compose.onNode(hasText("重复规则：FREQ=WEEKLY;BYDAY=MO")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("确认，开始按时运行")).performClick()
        waitFor(hasText("暂停"))
        assertFalse(runBlocking { mock.getPlan("plan-weekly") }.awaitingConfirmation)
        // 冷启动深链进来，返回键回首页。
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun editATriggerAndSave() {
        launch("thinktin://plan/plan-daily")
        waitFor(hasTestTag(PLAN_DETAIL_TEST_TAG))
        compose.onNode(hasText("每天 09:00")).assertIsDisplayed()
        compose.onNode(hasTestTag(PLAN_DETAIL_TEST_TAG)).performScrollToNode(hasTestTag(PLAN_RUN_ROW_TEST_TAG + "run-failed"))
        compose.onNode(hasTestTag(PLAN_RUN_ROW_TEST_TAG + "run-failed")).assertIsDisplayed()

        compose.onNode(hasContentDescription("编辑")).performClick()
        waitFor(hasTestTag(PLAN_EDIT_TEST_TAG))
        waitFor(hasText("每日依赖检查"))
        val row = hasTestTag(PLAN_TRIGGER_ROW_TEST_TAG + "trg-daily")
        compose.onNode(hasContentDescription("改触发规则") and hasAnyAncestor(row)).performScrollTo().performClick()
        waitFor(hasTestTag(TRIGGER_SHEET_TEST_TAG))
        // Robolectric 的触摸注入点不到盖在页面上的面板（落到遮罩上，真机正常），用无障碍点击动作（README 已知问题）。
        val inSheet = hasAnyAncestor(hasTestTag(TRIGGER_SHEET_TEST_TAG))
        compose.onNode(hasTestTag(TRIGGER_KIND_TEST_TAG + "Weekly")).performSemanticsAction(SemanticsActions.OnClick)
        compose.onNode(hasText("周四") and inSheet).assertExists()
        compose.onNode(hasText("完成") and inSheet).performSemanticsAction(SemanticsActions.OnClick)
        waitGone(hasTestTag(TRIGGER_SHEET_TEST_TAG))
        compose.onNode(hasText("每周四 09:00")).performScrollTo().assertIsDisplayed()

        compose.onNode(hasTestTag(PLAN_SAVE_TEST_TAG)).performClick()
        waitFor(hasTestTag(PLAN_DETAIL_TEST_TAG))
        waitFor(hasText("每周四 09:00"))
        val schedules = runBlocking { mock.getPlan("plan-daily") }.triggers.map { it.schedule }
        assertEquals(listOf(Schedule.Cron("0 21 * * *", "Mars/Olympus"), Schedule.Cron("0 9 * * 4", "Asia/Shanghai")), schedules)
    }
}
