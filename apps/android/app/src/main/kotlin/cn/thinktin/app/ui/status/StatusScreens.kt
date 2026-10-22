package cn.thinktin.app.ui.status

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import cn.thinktin.app.R
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.theme.ThinktinSpacing

/** 账号被冻结（AccountFrozen）：说明 + 退出登录。 */
@Composable
fun FrozenScreen(onSignOut: () -> Unit) {
    CenteredState {
        EmptyState(
            title = stringResource(R.string.frozen_title),
            message = stringResource(R.string.frozen_message),
            actionLabel = stringResource(R.string.action_sign_out),
            onAction = onSignOut,
        )
    }
}

/** 安装包里没有 libclient_core.so（如 CI 打的包）且关了演示模式。 */
@Composable
fun CoreUnavailableScreen(onUseDemo: () -> Unit) {
    CenteredState {
        EmptyState(
            title = stringResource(R.string.core_unavailable_title),
            message = stringResource(R.string.core_unavailable_message),
            actionLabel = stringResource(R.string.login_use_demo),
            onAction = onUseDemo,
        )
    }
}

@Composable
private fun CenteredState(content: @Composable () -> Unit) {
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
