package cn.thinktin.app.ui.catalog

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.errorText
import cn.thinktin.data.service.ServiceError
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing

/** Agent 目录（第 4.4 节，路由 catalog）：搜索框 + 卡片列表；点卡片进详情。 */
@Composable
fun CatalogScreen(onBack: () -> Unit, onOpenAgent: (String) -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: CatalogViewModel = viewModel(factory = viewModelFactory { initializer { CatalogViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_catalog),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            SearchField(query = state.query, onQueryChange = viewModel::onQueryChange)
            when {
                state.loading && state.agents.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(modifier = Modifier.semantics { contentDescription = loading })
                }
                state.loadError != null && state.agents.isEmpty() ->
                    LoadError(error = state.loadError!!, onRetry = viewModel::load)
                state.emptyCatalog -> EmptyState(
                    title = stringResource(R.string.catalog_empty_title),
                    message = stringResource(R.string.catalog_empty_message),
                    modifier = Modifier.padding(top = 48.dp),
                )
                else -> AgentList(state = state, onOpenAgent = onOpenAgent, onRetry = viewModel::load)
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onQueryChange: (String) -> Unit) {
    val label = stringResource(R.string.catalog_search)
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        placeholder = { Text(label) },
        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(Icons.Outlined.Close, contentDescription = stringResource(R.string.catalog_search_clear))
                }
            }
        },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        shape = ThinktinShapes.Composer,
        colors = OutlinedTextFieldDefaults.colors(unfocusedBorderColor = MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp)
            .semantics { contentDescription = label },
    )
}

@Composable
private fun LoadError(error: ServiceError, onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(ThinktinSpacing.Page)
            .padding(top = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
    ) {
        Text(
            text = stringResource(R.string.catalog_load_failed),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            text = errorText(error),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        SecondaryButton(text = stringResource(R.string.action_retry), onClick = onRetry)
    }
}

@Composable
private fun AgentList(state: CatalogUiState, onOpenAgent: (String) -> Unit, onRetry: () -> Unit) {
    val visible = state.visibleAgents
    LazyColumn(
        contentPadding = PaddingValues(start = ThinktinSpacing.Page, end = ThinktinSpacing.Page, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        modifier = Modifier.fillMaxSize(),
    ) {
        // 刷新失败但有旧列表：顶部一行错误 + 重试。
        val error = state.loadError
        if (error != null) {
            item(key = "error") {
                Column(horizontalAlignment = Alignment.Start) {
                    Text(
                        text = errorText(error),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    SecondaryButton(text = stringResource(R.string.action_retry), onClick = onRetry)
                }
            }
        }
        if (visible.isEmpty()) {
            item(key = "no-match") {
                Text(
                    text = stringResource(R.string.catalog_no_match, state.query.trim()),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .padding(vertical = 24.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
        items(visible, key = { it.id }) { agent ->
            AgentCard(agent = agent, onClick = { onOpenAgent(agent.id) })
        }
    }
}
