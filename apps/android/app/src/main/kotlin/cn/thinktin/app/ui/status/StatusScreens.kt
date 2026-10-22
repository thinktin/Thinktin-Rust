package cn.thinktin.app.ui.status

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import cn.thinktin.app.R
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.theme.ThinktinSpacing

/**
 * 真实服务创建失败（安装包里没有 libclient_core.so、契约版本不一致、缓存或 Keystore 打不开……）：
 * 说明 + 原因 + 重试；[onUseDemo] 只在 debug 包里给（release 不提供演示模式入口）。
 */
@Composable
fun CoreUnavailableScreen(error: Throwable?, onRetry: () -> Unit, onUseDemo: (() -> Unit)?) {
    CenteredState {
        EmptyState(
            title = stringResource(R.string.core_unavailable_title),
            message = stringResource(R.string.core_unavailable_message),
            actionLabel = stringResource(R.string.action_retry),
            onAction = onRetry,
        )
        if (error != null) {
            Text(
                text = stringResource(R.string.core_unavailable_detail, error.describe()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                maxLines = 4,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = ThinktinSpacing.Paragraph),
            )
        }
        if (onUseDemo != null) {
            TextButton(onClick = onUseDemo, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Text(stringResource(R.string.login_use_demo))
            }
        }
    }
}

/** 真实服务正在后台创建（通常很快）。 */
@Composable
fun LoadingScreen() {
    val label = stringResource(R.string.loading)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(Modifier.semantics { contentDescription = label })
    }
}

/** 失败原因（类型 + 消息，只给人看，不含令牌）。 */
private fun Throwable.describe(): String {
    val root = generateSequence(this) { it.cause }.last()
    val name = root::class.java.simpleName.ifEmpty { root::class.java.name }
    return root.message?.takeIf { it.isNotBlank() }?.let { "$name: $it" } ?: name
}

@Composable
private fun CenteredState(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.Center,
    ) {
        content()
    }
}
