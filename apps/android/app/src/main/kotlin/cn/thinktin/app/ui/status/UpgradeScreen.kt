package cn.thinktin.app.ui.status

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles
import kotlinx.coroutines.launch

/**
 * 服务端说这个版本太老（任何请求返回 UpgradeRequired，或事件流握手 426，见
 * [cn.thinktin.data.service.ThinktinService.upgradeState]）：整个界面换成这一页，不能再用，直到装上新版本。
 *
 * “更新 App”按钮先占位（提示到应用商店更新），13.12 接应用内更新后换成真的下载 / 跳转。
 */
@Composable
fun UpgradeRequiredScreen(modifier: Modifier = Modifier) {
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val pending = stringResource(R.string.upgrade_action_pending)
    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                imageVector = Icons.Outlined.SystemUpdate,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            Text(
                text = stringResource(R.string.upgrade_title),
                style = ThinktinTextStyles.Greeting,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = stringResource(R.string.upgrade_message),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            PrimaryButton(
                text = stringResource(R.string.upgrade_action),
                // TODO(13.12)：接应用内更新（各渠道的更新 / 应用商店跳转）。
                onClick = { scope.launch { snackbar.showSnackbar(pending) } },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = ThinktinSpacing.Paragraph),
            )
        }
    }
}
