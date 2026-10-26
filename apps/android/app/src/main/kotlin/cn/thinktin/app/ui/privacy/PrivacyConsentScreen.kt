package cn.thinktin.app.ui.privacy

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.settings.PRIVACY_POLICY_URL
import cn.thinktin.app.ui.settings.TERMS_URL
import cn.thinktin.app.ui.settings.openUrl
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles

/**
 * 首次启动的隐私政策页（13.11）：同意之前什么都不做（不建客户端、不联网、不初始化推送 SDK），只能看政策、协议和清单。
 * 隐私政策改版（[cn.thinktin.app.settings.PrivacyPolicy.VERSION] 加一）、在设置里撤回同意之后也显示它。
 *
 * “不同意”先说明为什么不能用（要手机号登录、要联网），可以再看看，也可以退出（不反复弹窗逼用户同意）。
 */
@Composable
fun PrivacyConsentScreen(onAccept: () -> Unit, onExit: () -> Unit) {
    var showingLists by rememberSaveable { mutableStateOf(false) }
    var declined by rememberSaveable { mutableStateOf(false) }
    if (showingLists) {
        BackHandler { showingLists = false }
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                ThinktinTopBar(
                    title = stringResource(R.string.privacy_consent_view_details),
                    navigationIcon = TopBarIcons.Back,
                    navigationContentDescription = stringResource(R.string.action_back),
                    onNavigationClick = { showingLists = false },
                )
            },
        ) { padding ->
            PrivacyListsContent(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 24.dp),
            )
        }
        return
    }
    val context = LocalContext.current
    Scaffold(containerColor = MaterialTheme.colorScheme.background) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = stringResource(R.string.privacy_consent_title),
                style = ThinktinTextStyles.Greeting,
                modifier = Modifier
                    .padding(top = 32.dp, bottom = 8.dp)
                    .semantics { heading() },
            )
            Text(
                text = stringResource(R.string.privacy_consent_intro),
                style = MaterialTheme.typography.bodyLarge,
            )
            listOf(
                R.string.privacy_consent_point_account,
                R.string.privacy_consent_point_content,
                R.string.privacy_consent_point_permissions,
                R.string.privacy_consent_point_choice,
            ).forEach { point ->
                Text(
                    text = stringResource(R.string.privacy_consent_bullet, stringResource(point)),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Column(modifier = Modifier.padding(top = 4.dp)) {
                TextButton(onClick = { openUrl(context, PRIVACY_POLICY_URL) }) {
                    Text(stringResource(R.string.privacy_consent_read_privacy))
                }
                TextButton(onClick = { openUrl(context, TERMS_URL) }) {
                    Text(stringResource(R.string.privacy_consent_read_terms))
                }
                TextButton(onClick = { showingLists = true }) {
                    Text(stringResource(R.string.privacy_consent_view_details))
                }
            }
            PrimaryButton(
                text = stringResource(R.string.privacy_consent_agree),
                onClick = onAccept,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
            )
            TextButton(onClick = { declined = true }, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Text(stringResource(R.string.privacy_consent_disagree))
            }
        }
    }
    if (declined) {
        ConfirmDialog(
            title = stringResource(R.string.privacy_consent_declined_title),
            text = stringResource(R.string.privacy_consent_declined_message),
            confirm = stringResource(R.string.privacy_consent_review),
            onConfirm = { declined = false },
            onDismiss = { declined = false },
            dismiss = stringResource(R.string.privacy_consent_exit),
            onDismissButton = onExit,
        )
    }
}
