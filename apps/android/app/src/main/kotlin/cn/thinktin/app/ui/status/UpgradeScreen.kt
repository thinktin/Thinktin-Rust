package cn.thinktin.app.ui.status

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.update.StoreLinks
import cn.thinktin.app.update.UpdatePanel
import cn.thinktin.app.update.UpdateState
import cn.thinktin.app.update.Updater
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles

/**
 * 服务端说这个版本太老（任何请求返回 UpgradeRequired，或事件流握手 426，见
 * [cn.thinktin.data.service.ThinktinService.upgradeState]）：整个界面换成这一页，不能再用，直到装上新版本。
 *
 * 官网安装包（[updater] 不为空，13.12）：进来就检查，直接在这页下载、校验、安装；应用商店的包：去商店的详情页，
 * 也可以去官网下载。
 */
@Composable
fun UpgradeRequiredScreen(updater: Updater?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    if (updater != null) {
        LaunchedEffect(updater) {
            if (updater.updateState.value.let { it == UpdateState.Idle || it == UpdateState.UpToDate }) updater.check()
        }
    }
    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                imageVector = Icons.Outlined.SystemUpdate,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 48.dp, bottom = 8.dp),
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
            if (updater != null) {
                UpdatePanel(updater, modifier = Modifier.padding(top = ThinktinSpacing.Paragraph))
            } else {
                PrimaryButton(
                    text = stringResource(R.string.upgrade_store),
                    onClick = { StoreLinks.openStore(context) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = ThinktinSpacing.Paragraph),
                )
                TextButton(onClick = { StoreLinks.openDownloadPage(context) }) {
                    Text(stringResource(R.string.update_open_website))
                }
            }
        }
    }
}
