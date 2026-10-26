package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
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
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.plans.PIPELINE_STEP_TEST_TAG
import cn.thinktin.app.ui.teams.TEAM_MEMBER_TEST_TAG
import cn.thinktin.app.ui.teams.TEAM_ROW_TEST_TAG
import cn.thinktin.app.ui.teams.TEMPLATE_ROW_TEST_TAG
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 13.7 的界面：抽屉进团队（我的团队、模板），进团队详情（负责人、成员），用团队建流水线（计划编辑里按成员预填步骤）。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class TeamsUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test
    fun teamDetailAndPipelineFromTeam() {
        val app = ApplicationProvider.getApplicationContext<DemoTestApp>()
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasText("团队与流水线") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasTestTag(TEAM_ROW_TEST_TAG + "team-research"))
        compose.onNode(hasTestTag(TEMPLATE_ROW_TEST_TAG + "tpl-research")).assertIsDisplayed()
        compose.onNode(hasTestTag(TEAM_ROW_TEST_TAG + "team-research")).performClick()
        waitFor(hasTestTag(TEAM_MEMBER_TEST_TAG + "inst-research"))
        compose.onNode(hasText("负责人")).assertExists()
        compose.onNode(hasText("用这个团队建流水线")).performScrollTo().performClick()
        waitFor(hasText("新建计划"))
        // 每个成员一步、负责人汇总一步。
        val stepCard = SemanticsMatcher("流水线步骤") {
            it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(PIPELINE_STEP_TEST_TAG) == true
        }
        waitFor(stepCard)
        compose.onAllNodes(stepCard).assertCountEquals(2)
    }
}
