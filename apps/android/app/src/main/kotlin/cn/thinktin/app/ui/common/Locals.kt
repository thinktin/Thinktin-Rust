package cn.thinktin.app.ui.common

import androidx.compose.runtime.staticCompositionLocalOf
import cn.thinktin.app.AppContainer
import cn.thinktin.data.service.ThinktinService

/** 当前的 AppContainer（AppRoot 提供）。 */
val LocalAppContainer = staticCompositionLocalOf<AppContainer> { error("AppContainer 未提供") }

/** 当前使用的服务（演示或真实，AppRoot 按设置提供）。 */
val LocalThinktinService = staticCompositionLocalOf<ThinktinService> { error("ThinktinService 未提供") }
