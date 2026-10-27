package cn.thinktin.design

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import cn.thinktin.design.component.APPROVAL_CARD_STATUS_TEST_TAG
import cn.thinktin.design.component.ApprovalCard
import cn.thinktin.design.component.ApprovalCardOption
import cn.thinktin.design.component.ApprovalCardState
import cn.thinktin.design.component.ApprovalCardUi
import cn.thinktin.design.component.ApprovalCountdown
import cn.thinktin.design.component.ApprovalDecidedBy
import cn.thinktin.design.component.ApprovalOptionKind
import cn.thinktin.design.theme.ThinktinTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** :design 的审批卡片（13.16）：按钮按选项种类、倒计时、AI 标识、原始请求展开、已决定 / 作废的显示。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN")
class ApprovalCardTest {
    @get:Rule
    val compose = createComposeRule()

    private val options = listOf(
        ApprovalCardOption("reject", "Reject", ApprovalOptionKind.RejectOnce),
        ApprovalCardOption("allow", "Allow", ApprovalOptionKind.AllowOnce),
        ApprovalCardOption("always", "Always", ApprovalOptionKind.AllowAlways),
        ApprovalCardOption("custom", "Ask later", ApprovalOptionKind.Other),
    )

    private fun card(state: ApprovalCardState = ApprovalCardState.Pending, expiresAtMs: Long? = HOUR * 23 + MINUTE * 41) =
        ApprovalCardUi(
            title = "删除 build/ 下 30 天前的文件",
            toolTitle = "Bash",
            toolKind = "execute",
            toolArguments = "find build -mtime +30 -delete",
            rawJson = "{\"command\": \"find build -mtime +30 -delete\"}",
            options = options,
            state = state,
            expiresAtMs = expiresAtMs,
        )

    @Test
    fun pendingCardShowsOptionsCountdownAndAiLabel() {
        val clicked = mutableListOf<String>()
        compose.setContent {
            ThinktinTheme { ApprovalCard(card = card(), nowMs = 0, onOption = { clicked += it.id }) }
        }
        compose.onNodeWithText("【AI 生成】", substring = true, useUnmergedTree = true).assertExists()
        compose.onNodeWithText("删除 build/ 下 30 天前的文件", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("find build -mtime +30 -delete").assertIsDisplayed()
        compose.onNodeWithText("23 小时 41 分钟后过期").assertIsDisplayed()
        // 已知种类用本地文案，不认识的用 agent 给的名字
        compose.onNode(hasText("批准") and hasClickAction()).assertIsEnabled()
        compose.onNode(hasText("一直允许") and hasClickAction()).assertIsDisplayed()
        compose.onNode(hasText("拒绝") and hasClickAction()).assertIsDisplayed()
        compose.onNode(hasText("Ask later") and hasClickAction()).assertIsDisplayed()
        compose.onNode(hasText("拒绝") and hasClickAction()).performClick()
        compose.onNode(hasText("批准") and hasClickAction()).performClick()
        assertEquals(listOf("reject", "allow"), clicked)

        // 原始请求默认收起，点开显示
        compose.onAllNodesWithText("{\"command\"", substring = true).assertCountEquals(0)
        compose.onNodeWithText("查看原始请求").performClick()
        compose.onNodeWithText("{\"command\"", substring = true).assertIsDisplayed()
        compose.onNodeWithText("收起原始请求").assertIsDisplayed()
    }

    @Test
    fun busyOptionDisablesOthersAndDisabledCardCannotBeClicked() {
        compose.setContent {
            ThinktinTheme { ApprovalCard(card = card(), nowMs = 0, onOption = {}, busyOptionId = "allow") }
        }
        compose.onNode(hasText("拒绝") and hasClickAction()).assertIsNotEnabled()
        compose.onNode(hasText("一直允许") and hasClickAction()).assertIsNotEnabled()
    }

    @Test
    fun decidedCardShowsResultInsteadOfButtons() {
        compose.setContent {
            ThinktinTheme {
                ApprovalCard(
                    card = card(ApprovalCardState.Approved).copy(
                        decidedOption = options[2],
                        decidedBy = ApprovalDecidedBy.You,
                        decidedAtText = "3 分钟前",
                    ),
                    nowMs = 0,
                    onOption = {},
                )
            }
        }
        compose.onNodeWithTag(APPROVAL_CARD_STATUS_TEST_TAG).assertIsDisplayed()
        compose.onNodeWithText("你已批准（一直允许） · 3 分钟前").assertIsDisplayed()
        compose.onAllNodes(hasText("批准") and hasClickAction()).assertCountEquals(0)
        compose.onAllNodesWithText("过期", substring = true).assertCountEquals(0)
    }

    @Test
    fun expiredSupersededAndPolicyTexts() {
        val texts = mapOf(
            card(ApprovalCardState.Expired).copy(decidedBy = ApprovalDecidedBy.Timeout) to "已过期：超时没有处理",
            card(ApprovalCardState.Superseded) to "已作废：运行已重试，这次请求不再有效",
            card(ApprovalCardState.Cancelled) to "已取消：运行已结束或已停止",
            card(ApprovalCardState.Rejected).copy(decidedBy = ApprovalDecidedBy.Policy) to "已按预授权策略拒绝",
            card(ApprovalCardState.Rejected).copy(decidedBy = ApprovalDecidedBy.You, decidedOption = options[0]) to "你已拒绝",
        )
        compose.setContent {
            ThinktinTheme {
                androidx.compose.foundation.layout.Column {
                    texts.keys.forEach { ApprovalCard(card = it, nowMs = 0, onOption = {}) }
                }
            }
        }
        texts.values.forEach { compose.onNodeWithText(it).assertExists() }
    }

    @Test
    fun countdownBuckets() {
        assertEquals(ApprovalCountdown.HoursMinutes(23, 59), ApprovalCountdown.of(DAY - 1, 0))
        assertEquals(ApprovalCountdown.Minutes(59), ApprovalCountdown.of(HOUR - 1, 0))
        assertEquals(ApprovalCountdown.UnderAMinute, ApprovalCountdown.of(MINUTE - 1, 0))
        assertEquals(ApprovalCountdown.Overdue, ApprovalCountdown.of(0, 0))
        assertEquals(ApprovalCountdown.Overdue, ApprovalCountdown.of(0, 5))
        assertFalse(ApprovalCountdown.HoursMinutes(1, 0).urgent)
        assertTrue(ApprovalCountdown.Minutes(5).urgent)
    }

    @Test
    fun urgentCountdownText() {
        compose.setContent {
            ThinktinTheme { ApprovalCard(card = card(expiresAtMs = 30 * MINUTE + 5), nowMs = 0, onOption = {}) }
        }
        compose.onNodeWithText("30 分钟后过期").assertIsDisplayed()
    }

    private companion object {
        const val MINUTE = 60_000L
        const val HOUR = 60 * MINUTE
        const val DAY = 24 * HOUR
    }
}
