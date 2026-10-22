package cn.thinktin.app

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.util.UUID

/**
 * “真实”服务的替身：数据来自 [MockThinktinService]，但 isDemo 为假，登录状态由测试控制（[auth]）。
 * 用来走 AppRoot 里非演示的分支（登录流、冻结页、运行中被踢下线）。
 */
class FakeThinktinService(
    private val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
    initial: AuthState = AuthState.SignedIn,
) : ThinktinService by mock {
    val auth = MutableStateFlow(initial)
    var logoutCalls = 0
        private set

    override val isDemo: Boolean = false
    override val authState: StateFlow<AuthState> get() = auth

    override suspend fun logout() {
        logoutCalls++
        auth.value = AuthState.SignedOut
    }
}

/**
 * 测试用的 AppContainer：设置存在独立的 DataStore 文件里（和 Application 自己的那个不冲突），
 * 真实服务由 [createCore] 提供。[demoAllowed] 为假时模拟 release 包。
 */
fun testContainer(
    context: Context,
    createCore: () -> ThinktinService,
    demoAllowed: Boolean = true,
    demoDefault: Boolean = false,
): AppContainer {
    val store = PreferenceDataStoreFactory.create(
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
        produceFile = { File(context.filesDir, "test-settings-${UUID.randomUUID()}.preferences_pb") },
    )
    return AppContainer(
        settingsRepository = AppSettingsRepository(store, demoDefault = demoDefault, demoAllowed = demoAllowed),
        clock = DemoTestApp.FIXED_CLOCK,
        createCore = createCore,
        createMock = { MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }) },
    )
}
