package cn.thinktin.app.ui.approval

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

const val APPROVAL_LIST_TEST_TAG = "approval-list"
const val APPROVAL_GROUP_TEST_TAG = "approval-group-"

/**
 * 审批中心（13.16，第 3 节路由 approvals、第 8.5 节）：跨实例的待处理审批，按实例分组，下拉刷新。
 * 卡片上可以直接批准（确认 → 身份确认）/ 拒绝（直接发），点卡片头进详情。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ApprovalCenterScreen(onBack: () -> Unit, onOpenApproval: (String) -> Unit) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val viewModel: ApprovalCenterViewModel = viewModel(
        factory = viewModelFactory { initializer { ApprovalCenterViewModel(service, container.approvalGate) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val actionState by viewModel.actions.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) { viewModel.notices.collect { snackbar.showSnackbar(it.resolve(context)) } }
    ApprovalMessages(viewModel.actions, snackbar)
    val now by rememberNowMs(container.clock)

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_approvals),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = viewModel::refresh,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            val error = state.loadError
            when {
                state.loading && state.isEmpty -> {
                    val label = stringResource(R.string.loading)
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                    }
                }
                // 空状态和错误也放在可滚动的列表里：下拉刷新要靠嵌套滚动触发。
                error != null && state.isEmpty -> LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        EmptyState(
                            title = stringResource(R.string.approvals_load_failed),
                            message = error.asString(),
                            actionLabel = stringResource(R.string.action_retry),
                            onAction = viewModel::retry,
                            modifier = Modifier.padding(top = 48.dp),
                        )
                    }
                }
                state.isEmpty -> LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        EmptyState(
                            title = stringResource(R.string.approvals_empty_title),
                            message = stringResource(R.string.approvals_empty_message),
                            modifier = Modifier.padding(top = 48.dp),
                        )
                    }
                }
                else -> LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(APPROVAL_LIST_TEST_TAG),
                    contentPadding = PaddingValues(ThinktinSpacing.Page),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    for (group in state.groups) {
                        item(key = "group-${group.instanceId}") {
                            val name = group.instanceName ?: stringResource(R.string.approvals_instance_unknown)
                            val count = group.cards.count { it.canDecide }
                            SectionHeader(
                                title = if (count > 0) {
                                    pluralStringResource(R.plurals.approvals_group_title, count, name, count)
                                } else {
                                    name
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag(APPROVAL_GROUP_TEST_TAG + group.instanceId),
                            )
                        }
                        items(group.cards, key = { it.approvalId ?: it.key.toString() }) { card ->
                            ApprovalCardItem(
                                card = card,
                                nowMs = now,
                                clock = container.clock,
                                actionState = actionState,
                                actions = viewModel.actions,
                                onOpen = card.approvalId?.let { id -> { onOpenApproval(id) } },
                            )
                        }
                    }
                }
            }
        }
    }
    ApprovalDialogs(actionState, viewModel.actions)
}
