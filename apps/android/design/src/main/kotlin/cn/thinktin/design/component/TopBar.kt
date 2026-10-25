package cn.thinktin.design.component

import androidx.compose.foundation.layout.RowScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import cn.thinktin.design.theme.ThinktinTheme

/**
 * 顶栏：标题居中，背景和页面底色一致（不用阴影分层）。
 * [navigationIcon] 为 null 时不显示左侧按钮；有就必须给 [navigationContentDescription]（读屏）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThinktinTopBar(
    title: String,
    modifier: Modifier = Modifier,
    navigationIcon: ImageVector? = null,
    navigationContentDescription: String? = null,
    onNavigationClick: () -> Unit = {},
    actions: @Composable RowScope.() -> Unit = {},
) {
    CenterAlignedTopAppBar(
        modifier = modifier,
        title = {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        navigationIcon = {
            if (navigationIcon != null) {
                IconButton(onClick = onNavigationClick) {
                    Icon(navigationIcon, contentDescription = navigationContentDescription)
                }
            }
        },
        actions = actions,
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
            containerColor = MaterialTheme.colorScheme.background,
            scrolledContainerColor = MaterialTheme.colorScheme.background,
        ),
    )
}

/** 常用的导航图标（第 2.4 节：Material Symbols Outlined）。 */
object TopBarIcons {
    val Back: ImageVector get() = Icons.AutoMirrored.Outlined.ArrowBack
    val Menu: ImageVector get() = Icons.Outlined.Menu
    val Close: ImageVector get() = Icons.Outlined.Close
}

@Preview(showBackground = true)
@Composable
internal fun ThinktinTopBarPreview() {
    ThinktinTheme {
        ThinktinTopBar(title = "小码", navigationIcon = TopBarIcons.Menu, navigationContentDescription = "菜单")
    }
}
