package cn.thinktin.app.ui.catalog

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.design.theme.ThinktinShapes

/** 测试用：目录卡片的 testTag 前缀（后接 agent id）。 */
const val AGENT_CARD_TEST_TAG = "agent-card-"

/** 协议名（anthropic / chat / responses）的显示文字；不认识的原样显示。 */
@Composable
fun protocolLabel(protocol: String): String = when (protocol) {
    "anthropic" -> stringResource(R.string.protocol_anthropic)
    "chat" -> stringResource(R.string.protocol_chat)
    "responses" -> stringResource(R.string.protocol_responses)
    else -> protocol
}

/** 许可证标签：没有 SPDX 标识的是专有许可（有 licenseNote）。 */
@Composable
fun licenseLabel(agent: AgentInfo): String = agent.license?.takeIf { it.isNotBlank() }
    ?: stringResource(R.string.agent_license_proprietary)

/**
 * 小标签（许可证、接入方式、协议）：surfaceVariant 底、12sp。[accessibleLabel] 给读屏（“许可证：MIT”）。
 * [emphasized] 用主色描边（详情页里“运行时使用”的协议、默认接入方式）。
 */
@Composable
fun Tag(text: String, accessibleLabel: String? = null, emphasized: Boolean = false, modifier: Modifier = Modifier) {
    Surface(
        shape = MaterialTheme.shapes.extraSmall,
        color = MaterialTheme.colorScheme.surfaceVariant,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        border = if (emphasized) BorderStroke(1.dp, MaterialTheme.colorScheme.primary) else null,
        modifier = modifier.then(
            // 读屏只读一遍完整的说明（“许可证：MIT”），不再重复读标签上的字。
            if (accessibleLabel != null) Modifier.clearAndSetSemantics { contentDescription = accessibleLabel } else Modifier,
        ),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

/** 一个 agent 的标签行：许可证、接入方式、协议。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AgentTags(agent: AgentInfo, modifier: Modifier = Modifier) {
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val license = licenseLabel(agent)
        Tag(license, accessibleLabel = stringResource(R.string.agent_license_a11y, license))
        agent.harnesses.forEach { harness ->
            Tag(harness, accessibleLabel = stringResource(R.string.agent_harness_a11y, harness))
        }
        agent.protocols.forEach { protocol ->
            val label = protocolLabel(protocol)
            Tag(label, accessibleLabel = stringResource(R.string.agent_protocol_a11y, label))
        }
    }
}

/**
 * 目录卡片（第 4.4 节）：名字、一句话介绍、标签（许可证、接入方式、协议）。
 * 介绍是上游作者写的，不是 agent 生成的，不标 AI 生成（第 8.4 节）。
 */
@Composable
fun AgentCard(agent: AgentInfo, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val openLabel = stringResource(R.string.catalog_open_agent)
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = modifier
            .fillMaxWidth()
            .testTag(AGENT_CARD_TEST_TAG + agent.id),
    ) {
        Column(
            modifier = Modifier
                .clickable(role = Role.Button, onClickLabel = openLabel, onClick = onClick)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = agent.name,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (agent.description.isNotBlank()) {
                Text(
                    text = agent.description,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            AgentTags(agent, Modifier.padding(top = 4.dp))
        }
    }
}
