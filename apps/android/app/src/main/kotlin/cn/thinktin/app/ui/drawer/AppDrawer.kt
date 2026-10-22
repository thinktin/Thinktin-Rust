package cn.thinktin.app.ui.drawer

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.AddComment
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.data.model.Instance
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing

/** 抽屉里能去的地方。 */
enum class DrawerDestination {
    NewChat,

    /** Agent 目录（领养）。 */
    Catalog,
    Inbox,
    Plans,
    Teams,
    Settings,
}

const val DRAWER_TEST_TAG = "app-drawer"

/** 抽屉（第 3 节）：搜索、新对话、收件箱（未读角标）、计划、团队与流水线、我的 agent、底部头像 → 设置。 */
@Composable
fun AppDrawer(
    state: DrawerUiState,
    currentRoute: String?,
    onQueryChange: (String) -> Unit,
    onNavigate: (DrawerDestination) -> Unit,
    onOpenInstance: (Instance) -> Unit,
    modifier: Modifier = Modifier,
    onOpenInstanceSettings: (Instance) -> Unit = {},
) {
    ModalDrawerSheet(
        modifier = modifier.testTag(DRAWER_TEST_TAG),
        drawerContainerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.weight(1f)) {
            OutlinedTextField(
                value = state.query,
                onValueChange = onQueryChange,
                singleLine = true,
                placeholder = { Text(stringResource(R.string.drawer_search)) },
                leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                shape = ThinktinShapes.Composer,
                colors = OutlinedTextFieldDefaults.colors(
                    unfocusedBorderColor = MaterialTheme.colorScheme.outline,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = ThinktinSpacing.Page, vertical = 12.dp),
            )
            DrawerItem(R.string.drawer_new_chat, Icons.Outlined.AddComment, selected = false) {
                onNavigate(DrawerDestination.NewChat)
            }
            DrawerItem(R.string.drawer_catalog, Icons.Outlined.Apps, selected = currentRoute == "catalog") {
                onNavigate(DrawerDestination.Catalog)
            }
            val unreadLabel = if (state.unread > 0) {
                unreadLabel(state.unread)
            } else {
                null
            }
            NavigationDrawerItem(
                label = { Text(stringResource(R.string.drawer_inbox)) },
                icon = { Icon(Icons.Outlined.Inbox, contentDescription = null) },
                badge = {
                    if (state.unread > 0) {
                        Badge(Modifier.semantics { contentDescription = unreadLabel.orEmpty() }) {
                            Text(if (state.unread > 99) "99+" else state.unread.toString())
                        }
                    }
                },
                selected = currentRoute?.startsWith("inbox") == true,
                onClick = { onNavigate(DrawerDestination.Inbox) },
                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
            )
            DrawerItem(R.string.drawer_plans, Icons.Outlined.Schedule, selected = currentRoute == "plans") {
                onNavigate(DrawerDestination.Plans)
            }
            DrawerItem(R.string.drawer_teams, Icons.Outlined.AccountTree, selected = currentRoute == "teams") {
                onNavigate(DrawerDestination.Teams)
            }
            HorizontalDivider(
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                color = MaterialTheme.colorScheme.outline,
            )
            SectionHeader(
                title = stringResource(R.string.drawer_my_agents),
                modifier = Modifier.padding(horizontal = 28.dp),
            )
            val instances = state.visibleInstances
            if (instances.isEmpty()) {
                Text(
                    text = stringResource(R.string.drawer_no_agents),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 28.dp, vertical = 8.dp),
                )
            }
            LazyColumn(Modifier.weight(1f)) {
                items(instances, key = { it.id }) { instance ->
                    InstanceRow(
                        instance = instance,
                        agentName = state.agentNames[instance.agentId] ?: instance.agentId,
                        onOpen = { onOpenInstance(instance) },
                        onOpenSettings = { onOpenInstanceSettings(instance) },
                    )
                }
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outline)
        AccountRow(
            name = state.user?.displayName?.takeIf { it.isNotBlank() }
                ?: state.user?.phone
                ?: if (state.isDemo) stringResource(R.string.drawer_demo_user) else "",
            onClick = { onNavigate(DrawerDestination.Settings) },
        )
    }
}

/**
 * 实例行：状态点、名字（用户起的，不标 AI 生成）、agent 名；点开对话，长按或右侧“更多”进实例设置。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun InstanceRow(instance: Instance, agentName: String, onOpen: () -> Unit, onOpenSettings: () -> Unit) {
    val stateLabel = stringResource(instance.state.labelRes())
    val settingsLabel = stringResource(R.string.drawer_instance_settings)
    Row(
        modifier = Modifier
            .padding(NavigationDrawerItemDefaults.ItemPadding)
            .fillMaxWidth()
            .heightIn(min = ThinktinSpacing.ListItemMinHeight)
            .clip(ThinktinShapes.Composer)
            .combinedClickable(
                role = Role.Button,
                onClick = onOpen,
                onLongClickLabel = settingsLabel,
                onLongClick = onOpenSettings,
            )
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StatusDot(instance.state, contentDescription = stateLabel)
        Column(Modifier.weight(1f)) {
            Text(instance.name, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                text = agentName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onOpenSettings) {
            Icon(
                Icons.Outlined.MoreVert,
                contentDescription = stringResource(R.string.drawer_instance_more, instance.name),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun unreadLabel(count: Long): String = stringResource(R.string.drawer_unread, count.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())

@Composable
private fun DrawerItem(
    labelRes: Int,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
) {
    NavigationDrawerItem(
        label = { Text(stringResource(labelRes)) },
        icon = { Icon(icon, contentDescription = null) },
        selected = selected,
        onClick = onClick,
        modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
    )
}

/** 底部：头像（名字首字）+ 名字，整行点进设置。 */
@Composable
private fun AccountRow(name: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .background(MaterialTheme.colorScheme.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = name.firstOrNull()?.toString().orEmpty(),
                color = MaterialTheme.colorScheme.onPrimary,
                style = MaterialTheme.typography.titleMedium,
            )
        }
        Text(
            text = name,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Icon(Icons.Outlined.Settings, contentDescription = stringResource(R.string.drawer_settings))
    }
}
