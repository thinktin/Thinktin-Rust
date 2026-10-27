package cn.thinktin.app.ui.settings.licenses

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

const val LICENSES_LIST_TEST_TAG = "licenses-list"
const val LICENSE_COMPONENT_TEST_TAG = "license-component-"

/**
 * 开源许可（13.13，设置 → 关于 → 开源许可）：App 自己用的库、客户端核心的组件（按许可证分组，可以搜，点开看版本、作者、
 * 来源和原文）。原文进 [LicenseTextScreen]。
 */
@Composable
fun LicensesScreen(onBack: () -> Unit, onOpenText: (path: String, title: String) -> Unit) {
    val context = LocalContext.current
    val viewModel: LicensesViewModel = viewModel(
        factory = viewModelFactory { initializer { LicensesViewModel(AssetLicenseSource(context.applicationContext.assets)) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_licenses),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .testTag(LICENSES_LIST_TEST_TAG),
            contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
        ) {
            item(key = "intro") {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        stringResource(R.string.licenses_intro),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = state.query,
                        onValueChange = viewModel::onQueryChange,
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                        placeholder = { Text(stringResource(R.string.licenses_search)) },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    )
                }
            }
            val deps = state.appDependencies
            if (deps.isNotEmpty()) {
                item(key = "app-header") { SectionHeader(title = stringResource(R.string.licenses_app_section), modifier = Modifier.padding(top = 16.dp)) }
                items(deps, key = { "app-" + it.name }) { dep ->
                    Column(Modifier.padding(vertical = 8.dp)) {
                        Text(dep.name, style = MaterialTheme.typography.bodyLarge)
                        Text(dep.license, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            item(key = "core-header") {
                SectionHeader(title = stringResource(R.string.licenses_core_section), modifier = Modifier.padding(top = 16.dp))
            }
            when (val inventory = state.inventory) {
                InventoryState.Loading -> item(key = "loading") {
                    val label = stringResource(R.string.loading)
                    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                    }
                }
                is InventoryState.Failed -> item(key = "failed") {
                    Text(
                        stringResource(inventory.problem.messageRes()),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
                is InventoryState.Loaded -> {
                    val all = inventory.inventory
                    item(key = "summary") {
                        Text(
                            pluralStringResource(R.plurals.licenses_core_summary, all.components.size, all.components.size, all.licenseCount),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(vertical = 4.dp),
                        )
                    }
                    val groups = state.groups
                    if (groups.isEmpty() && deps.isEmpty()) {
                        item(key = "no-results") {
                            Text(stringResource(R.string.licenses_no_results), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    for (group in groups) {
                        item(key = "group-" + group.license) {
                            val title = group.license.ifEmpty { stringResource(R.string.licenses_undeclared) }
                            SectionHeader(
                                title = pluralStringResource(R.plurals.licenses_group_title, group.components.size, title, group.components.size),
                                modifier = Modifier.padding(top = 12.dp),
                            )
                        }
                        items(group.components, key = { it.id }) { component ->
                            ComponentRow(
                                component = component,
                                expanded = component.id in state.expanded,
                                onToggle = { viewModel.toggle(component.id) },
                                onOpenText = onOpenText,
                            )
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ComponentRow(
    component: LicenseComponent,
    expanded: Boolean,
    onToggle: () -> Unit,
    onOpenText: (String, String) -> Unit,
) {
    val context = LocalContext.current
    val stateText = stringResource(if (expanded) R.string.licenses_collapse else R.string.licenses_expand)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onToggle)
            .heightIn(min = 48.dp)
            .padding(vertical = 8.dp)
            .semantics { stateDescription = stateText }
            .testTag(LICENSE_COMPONENT_TEST_TAG + component.id),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text("${component.name} ${component.version}".trim(), style = MaterialTheme.typography.bodyLarge)
        if (!expanded) return@Column
        Text(
            component.license ?: stringResource(R.string.licenses_undeclared),
            style = MaterialTheme.typography.bodySmall,
        )
        component.authors?.let {
            Text(stringResource(R.string.licenses_authors, it), style = MaterialTheme.typography.bodySmall)
        }
        component.sourceUrl?.let { url ->
            TextButton(onClick = {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            }) { Text(stringResource(R.string.licenses_source)) }
        }
        for (text in component.texts) {
            val title = when (text.kind) {
                LicenseTextKind.Original -> text.name
                LicenseTextKind.Bundled -> stringResource(R.string.licenses_text_bundled, text.name)
                LicenseTextKind.Standard -> stringResource(R.string.licenses_text_standard, text.name)
            }
            TextButton(onClick = { onOpenText(text.path, "${component.name} · $title") }) { Text(title) }
        }
    }
}

/** 一份原文（`licenses/text?path=`）。 */
@Composable
fun LicenseTextScreen(path: String, title: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val viewModel: LicenseTextViewModel = viewModel(
        key = "license-text-$path",
        factory = viewModelFactory {
            initializer { LicenseTextViewModel(AssetLicenseSource(context.applicationContext.assets), path) }
        },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = title,
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        when (val current = state) {
            LicenseTextState.Loading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                val label = stringResource(R.string.loading)
                CircularProgressIndicator(Modifier.semantics { contentDescription = label })
            }
            is LicenseTextState.Failed -> Text(
                stringResource(current.problem.messageRes()),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(padding).padding(ThinktinSpacing.Page),
            )
            is LicenseTextState.Loaded -> LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(ThinktinSpacing.Page),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(current.paragraphs) { paragraph ->
                    Text(paragraph, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

fun LicenseInventoryProblem.messageRes(): Int = when (this) {
    LicenseInventoryProblem.NotBundled -> R.string.licenses_not_bundled
    LicenseInventoryProblem.Unreadable, LicenseInventoryProblem.InvalidPath -> R.string.licenses_text_missing
    LicenseInventoryProblem.Malformed -> R.string.licenses_malformed
    LicenseInventoryProblem.TooLarge -> R.string.licenses_too_large
}
