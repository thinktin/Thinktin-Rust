package cn.thinktin.app.ui.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.errorText
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.service.ServiceError
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.BannerTone
import cn.thinktin.design.component.Composer
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.component.WarningBanner
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles
import java.time.ZoneId

/** 首页（第 4.2 节）：衬线问候、实例选择、最近运行、底部输入框。 */
@Composable
fun HomeScreen(
    onOpenDrawer: () -> Unit,
    onOpenChat: (String) -> Unit,
    onOpenRun: (String) -> Unit,
    onOpenCatalog: () -> Unit,
    onOpenInstanceSettings: (String) -> Unit,
) {
    val service = LocalThinktinService.current
    val container = LocalAppContainer.current
    val viewModel: HomeViewModel = viewModel(
        factory = viewModelFactory { initializer { HomeViewModel(service, container.clock) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current

    LaunchedEffect(viewModel) {
        viewModel.uiEvents.collect { event ->
            when (event) {
                is HomeEvent.OpenChat -> onOpenChat(event.instanceId)
                is HomeEvent.ShowError -> {
                    val text = ErrorText.of(event.error)
                    snackbar.showSnackbar(context.getString(text.resId, *text.args.toTypedArray()))
                }
            }
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            HomeTopBar(
                state = state,
                onOpenDrawer = onOpenDrawer,
                onSelectInstance = viewModel::selectInstance,
                onOpenCatalog = onOpenCatalog,
                onOpenInstanceSettings = onOpenInstanceSettings,
            )
        },
        bottomBar = {
            val selected = state.selectedInstance
            if (selected != null) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .imePadding()
                        .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                ) {
                    Composer(
                        value = state.draft,
                        onValueChange = viewModel::onDraftChange,
                        onSend = viewModel::send,
                        onAttach = {},
                        enabled = !state.sending,
                        placeholder = stringResource(R.string.home_composer_placeholder, selected.name),
                    )
                }
            }
        },
    ) { padding ->
        when {
            state.loading && state.instances.isEmpty() -> Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
            state.instances.isEmpty() -> NoInstances(state, Modifier.padding(padding), onOpenCatalog)
            else -> HomeContent(state, Modifier.padding(padding), onOpenRun)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeTopBar(
    state: HomeUiState,
    onOpenDrawer: () -> Unit,
    onSelectInstance: (String) -> Unit,
    onOpenCatalog: () -> Unit,
    onOpenInstanceSettings: (String) -> Unit,
) {
    var switcherOpen by remember { mutableStateOf(false) }
    var overflowOpen by remember { mutableStateOf(false) }
    CenterAlignedTopAppBar(
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = MaterialTheme.colorScheme.background),
        navigationIcon = {
            IconButton(onClick = onOpenDrawer) {
                Icon(TopBarIcons.Menu, contentDescription = stringResource(R.string.action_open_menu))
            }
        },
        title = {
            val selected = state.selectedInstance
            if (selected != null) {
                Box {
                    val switchLabel = stringResource(R.string.home_switch_instance)
                    Row(
                        modifier = Modifier
                            .clickable(role = Role.Button, onClickLabel = switchLabel) { switcherOpen = true }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        StatusDot(selected.state)
                        Text(selected.name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                        Icon(Icons.Outlined.ArrowDropDown, contentDescription = null)
                    }
                    DropdownMenu(expanded = switcherOpen, onDismissRequest = { switcherOpen = false }) {
                        state.instances.forEach { instance ->
                            DropdownMenuItem(
                                text = { Text(instance.name) },
                                leadingIcon = { StatusDot(instance.state) },
                                onClick = {
                                    switcherOpen = false
                                    onSelectInstance(instance.id)
                                },
                            )
                        }
                    }
                }
            }
        },
        actions = {
            Box {
                IconButton(onClick = { overflowOpen = true }) {
                    Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.action_more))
                }
                DropdownMenu(expanded = overflowOpen, onDismissRequest = { overflowOpen = false }) {
                    state.selectedInstanceId?.let { id ->
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.home_instance_settings)) },
                            onClick = {
                                overflowOpen = false
                                onOpenInstanceSettings(id)
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.home_catalog)) },
                        onClick = {
                            overflowOpen = false
                            onOpenCatalog()
                        },
                    )
                }
            }
        },
    )
}

@Composable
private fun greetingText(state: HomeUiState): String {
    val greeting = stringResource(
        when (state.greeting) {
            Greeting.Morning -> R.string.home_greeting_morning
            Greeting.Afternoon -> R.string.home_greeting_afternoon
            Greeting.Evening -> R.string.home_greeting_evening
        },
    )
    val name = state.userName
    return if (name.isNullOrBlank()) greeting else stringResource(R.string.home_greeting_with_name, greeting, name)
}

@Composable
private fun HomeContent(state: HomeUiState, modifier: Modifier, onOpenRun: (String) -> Unit) {
    val zone: ZoneId = LocalAppContainer.current.clock.zone
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        item(key = "greeting") {
            Text(
                text = greetingText(state),
                style = ThinktinTextStyles.Greeting,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = ThinktinSpacing.Page, vertical = 24.dp)
                    .semantics { heading() },
            )
        }
        banners(state)
        item(key = "recent-header") {
            SectionHeader(
                title = stringResource(R.string.home_recent_runs),
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
            )
        }
        if (state.recentRuns.isEmpty()) {
            item(key = "no-runs") {
                Text(
                    text = stringResource(R.string.home_no_runs),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                )
            }
        }
        items(state.recentRuns, key = { it.id }) { run ->
            RunRow(run = run, nowMs = state.nowMs, zone = zone, onClick = { onOpenRun(run.id) })
            HorizontalDivider(
                modifier = Modifier.padding(start = ThinktinSpacing.Page + 22.dp),
                color = MaterialTheme.colorScheme.outline,
            )
        }
        item(key = "bottom-space") { Spacer(Modifier.height(16.dp)) }
    }
}

private fun LazyListScope.banners(state: HomeUiState) {
    if (state.isDemo) {
        item(key = "demo-banner") {
            WarningBanner(
                text = stringResource(R.string.home_demo_banner),
                tone = BannerTone.Info,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
            )
        }
    }
    val error = state.refreshError
    if (error != null) {
        item(key = "error-banner") {
            WarningBanner(
                text = if (error is ServiceError.Network) {
                    stringResource(R.string.home_offline_banner)
                } else {
                    errorText(error)
                },
                tone = if (error is ServiceError.Network) BannerTone.Info else BannerTone.Error,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun RunRow(run: Run, nowMs: Long, zone: ZoneId, onClick: () -> Unit) {
    val stateLabel = stringResource(run.state.labelRes())
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = ThinktinSpacing.ListItemMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ThinktinSpacing.Page, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StatusDot(run.state, contentDescription = stateLabel)
        Column(Modifier.weight(1f)) {
            // 第 8.4 节：委派出来的子运行，prompt 是上游 agent 写的，要标 AI 生成。
            LabelledLine(aiGenerated = run.source == RunSource.Delegate) {
                Text(
                    text = run.prompt,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // summary 是 agent 写的，标 AI 生成；error 里分不清 agent 写的和平台诊断，13.5 再细分，先不标。
            val summary = run.summary
            val error = run.error
            if (summary != null || error != null) {
                LabelledLine(aiGenerated = summary != null) {
                    Text(
                        text = summary ?: error.orEmpty(),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Text(
                text = stringResource(
                    R.string.home_run_subtitle,
                    stateLabel,
                    RelativeTime.of(run.createdAtMs, nowMs, zone).asString(),
                ),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** 一行文字，[aiGenerated] 时前面带“【AI 生成】”标识。 */
@Composable
private fun LabelledLine(aiGenerated: Boolean, content: @Composable () -> Unit) {
    if (!aiGenerated) {
        content()
        return
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        AiGeneratedLabel()
        Box(Modifier.weight(1f)) { content() }
    }
}

@Composable
private fun NoInstances(state: HomeUiState, modifier: Modifier, onOpenCatalog: () -> Unit) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.Center,
    ) {
        EmptyState(
            title = greetingText(state),
            message = stringResource(R.string.home_no_instances_message),
            actionLabel = stringResource(R.string.home_adopt),
            onAction = onOpenCatalog,
        )
        if (state.refreshError != null) {
            TextButton(onClick = onOpenCatalog, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Text(errorText(state.refreshError))
            }
        }
    }
}
