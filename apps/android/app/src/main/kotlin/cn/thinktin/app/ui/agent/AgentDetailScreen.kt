package cn.thinktin.app.ui.agent

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.catalog.Tag
import cn.thinktin.app.ui.catalog.licenseLabel
import cn.thinktin.app.ui.catalog.protocolLabel
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.asString
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Instance
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.launch

/** 测试用：领养表单的 testTag。 */
const val ADOPT_SHEET_TEST_TAG = "adopt-sheet"

/**
 * Agent 详情（第 4.4 节，路由 agent/{agentId}）：介绍、接入方式、协议、版本、许可证、上游链接；底部“领养”。
 *
 * 领养表单是盖在页面上的底部面板（不是 ModalBottomSheet / 对话框：弹出窗口里的输入框在 Robolectric 下一直不空闲，
 * 见 README“对话框里不放输入框”）。返回键、点遮罩、“取消”都收起表单（提交中不收）。
 */
@Composable
fun AgentDetailScreen(agentId: String, onBack: () -> Unit, onAdopted: (Instance) -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: AgentDetailViewModel = viewModel(
        key = "agent-$agentId",
        factory = viewModelFactory { initializer { AgentDetailViewModel(service, agentId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is AgentDetailEvent.Adopted -> onAdopted(event.instance)
            }
        }
    }
    BackHandler(enabled = state.adopt != null) { viewModel.closeAdopt() }

    val agent = state.agent
    val noBrowser = stringResource(R.string.agent_no_browser)
    Box(Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            snackbarHost = { SnackbarHost(snackbar) },
            topBar = {
                ThinktinTopBar(
                    title = agent?.name ?: stringResource(R.string.page_agent),
                    navigationIcon = TopBarIcons.Back,
                    navigationContentDescription = stringResource(R.string.action_back),
                    onNavigationClick = onBack,
                )
            },
            bottomBar = {
                if (agent != null && state.adopt == null) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = ThinktinSpacing.Page, vertical = 12.dp),
                    ) {
                        val defaultName = stringResource(R.string.adopt_default_name, agent.name)
                        PrimaryButton(
                            text = stringResource(R.string.agent_adopt),
                            onClick = { viewModel.openAdopt(defaultName) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            },
        ) { padding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                when {
                    agent != null -> AgentDetailContent(
                        agent = agent,
                        onOpenUpstream = { url ->
                            try {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            } catch (_: ActivityNotFoundException) {
                                scope.launch { snackbar.showSnackbar(noBrowser) }
                            }
                        },
                    )
                    state.loading -> {
                        val loading = stringResource(R.string.loading)
                        CircularProgressIndicator(
                            modifier = Modifier
                                .align(Alignment.Center)
                                .semantics { contentDescription = loading },
                        )
                    }
                    state.notFound -> EmptyState(
                        title = stringResource(R.string.agent_not_found_title),
                        message = stringResource(R.string.agent_not_found_message),
                        modifier = Modifier.align(Alignment.Center),
                    )
                    else -> Column(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .padding(ThinktinSpacing.Page),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
                    ) {
                        Text(
                            text = state.loadError?.asString().orEmpty(),
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        )
                        SecondaryButton(text = stringResource(R.string.action_retry), onClick = viewModel::load)
                    }
                }
            }
        }
        // 领养表单：盖在页面上的底部面板（遮罩点一下收起）。
        val form = state.adopt
        if (agent != null && form != null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.scrim.copy(alpha = SCRIM_ALPHA))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = viewModel::closeAdopt,
                    )
                    .clearAndSetSemantics {},
            )
            AdoptSheet(
                agent = agent,
                form = form,
                onNameChange = viewModel::onNameChange,
                onHarnessChange = viewModel::onHarnessChange,
                onSubmit = viewModel::adopt,
                onCancel = viewModel::closeAdopt,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

/** 领养表单后面的遮罩透明度（同 Material 底部面板）。 */
private const val SCRIM_ALPHA = 0.32f

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AgentDetailContent(agent: AgentInfo, onOpenUpstream: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
    ) {
        Text(
            text = agent.name,
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.agent_latest_version, agent.version),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        // 介绍是上游作者写的，不标 AI 生成（第 8.4 节）。
        if (agent.description.isNotBlank()) {
            Text(text = agent.description, style = MaterialTheme.typography.bodyLarge)
        }

        SectionHeader(title = stringResource(R.string.agent_section_harnesses))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            agent.harnesses.forEach { harness ->
                val isDefault = harness == agent.defaultHarness
                val text = if (isDefault) stringResource(R.string.agent_harness_default, harness) else harness
                Tag(text = text, accessibleLabel = stringResource(R.string.agent_harness_a11y, text), emphasized = isDefault)
            }
        }

        if (agent.protocols.isNotEmpty()) {
            SectionHeader(title = stringResource(R.string.agent_section_protocols))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                agent.protocols.forEach { protocol ->
                    val label = protocolLabel(protocol)
                    Tag(
                        text = label,
                        accessibleLabel = stringResource(R.string.agent_protocol_a11y, label),
                        emphasized = protocol == agent.activeProtocol,
                    )
                }
            }
            agent.activeProtocol?.let { active ->
                Text(
                    text = stringResource(R.string.agent_active_protocol, protocolLabel(active)),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        SectionHeader(title = stringResource(R.string.agent_section_versions))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            agent.versions.ifEmpty { listOf(agent.version) }.forEach { version ->
                Text(
                    text = if (version == agent.version) {
                        stringResource(R.string.agent_version_latest, version)
                    } else {
                        version
                    },
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }

        SectionHeader(title = stringResource(R.string.agent_section_license))
        Text(text = licenseLabel(agent), style = MaterialTheme.typography.bodyLarge)
        agent.licenseNote?.takeIf { it.isNotBlank() }?.let { note ->
            Text(text = note, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        if (agent.sites.isNotEmpty()) {
            SectionHeader(title = stringResource(R.string.agent_section_sites))
            Text(text = agent.sites.joinToString(stringResource(R.string.list_separator)), style = MaterialTheme.typography.bodyMedium)
        }

        // 上游链接只认 https（服务端也只给 https）。
        val upstream = agent.upstream.takeIf { it.startsWith("https://") }
        if (upstream != null) {
            SectionHeader(title = stringResource(R.string.agent_section_upstream))
            val openLabel = stringResource(R.string.agent_open_upstream)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Button, onClickLabel = openLabel) { onOpenUpstream(upstream) }
                    .padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = upstream,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.secondary,
                    modifier = Modifier.weight(1f),
                )
                Icon(Icons.AutoMirrored.Outlined.OpenInNew, contentDescription = null, tint = MaterialTheme.colorScheme.secondary)
            }
        }
    }
}

/** 领养表单：名字（默认“<agent 名> 的实例”）、接入方式（多于一种时选）、领养 / 取消。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AdoptSheet(
    agent: AgentInfo,
    form: AdoptForm,
    onNameChange: (String) -> Unit,
    onHarnessChange: (String) -> Unit,
    onSubmit: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val title = stringResource(R.string.adopt_title, agent.name)
    Surface(
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = modifier
            .fillMaxWidth()
            .testTag(ADOPT_SHEET_TEST_TAG)
            .semantics { paneTitle = title },
    ) {
        Column(
            modifier = Modifier
                .navigationBarsPadding()
                .imePadding()
                // 字号放大到 200% 时也能滚到按钮。
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        ) {
            Text(text = title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
            val nameLabel = stringResource(R.string.adopt_name)
            OutlinedTextField(
                value = form.name,
                onValueChange = onNameChange,
                label = { Text(nameLabel) },
                singleLine = true,
                enabled = !form.submitting,
                isError = form.nameError != null,
                supportingText = {
                    Text(form.nameError?.asString() ?: stringResource(R.string.adopt_name_hint, InstanceNames.MAX_LENGTH))
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSubmit() }),
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = nameLabel },
            )
            if (agent.harnesses.size > 1) {
                Text(
                    text = stringResource(R.string.adopt_harness),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    agent.harnesses.forEach { harness ->
                        FilterChip(
                            selected = harness == form.harness,
                            onClick = { onHarnessChange(harness) },
                            enabled = !form.submitting,
                            label = {
                                Text(
                                    if (harness == agent.defaultHarness) {
                                        stringResource(R.string.agent_harness_default, harness)
                                    } else {
                                        harness
                                    },
                                )
                            },
                        )
                    }
                }
            }
            Text(
                text = stringResource(R.string.adopt_model_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            form.error?.let { error ->
                Text(
                    text = error.asString(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph)) {
                SecondaryButton(
                    text = stringResource(R.string.action_cancel),
                    onClick = onCancel,
                    enabled = !form.submitting,
                    modifier = Modifier.weight(1f),
                )
                PrimaryButton(
                    text = stringResource(R.string.adopt_confirm),
                    onClick = onSubmit,
                    loading = form.submitting,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}
