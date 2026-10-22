package cn.thinktin.app

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.preferencesDataStoreFile
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.data.core.ClientFactory
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.time.Clock

/**
 * 手写的依赖容器（不用 Hilt）：设置、时钟、两套 ThinktinService（演示 / 真实）。
 * 真实服务第一次用到时才创建（会加载 libclient_core.so）。
 */
class AppContainer(
    val settingsRepository: AppSettingsRepository,
    val clock: Clock,
    private val createCore: () -> ThinktinService,
    private val createMock: () -> ThinktinService,
    /** 测试用：强制演示模式。 */
    private val forceDemo: Boolean = false,
) {
    private val mock: ThinktinService by lazy(createMock)
    private val core: Result<ThinktinService> by lazy {
        // 安装包里没有 .so（CI 打的包）时 JNA 抛 UnsatisfiedLinkError：界面提示改用演示模式。
        try {
            Result.success(createCore())
        } catch (e: UnsatisfiedLinkError) {
            Result.failure(e)
        } catch (e: NoClassDefFoundError) {
            Result.failure(e)
        }
    }

    /** 当前设置（演示模式已按 forceDemo 修正）。 */
    val settings: Flow<AppSettings> =
        settingsRepository.settings.map { if (forceDemo) it.copy(demoMode = true) else it }

    /** 按演示模式取服务；真实服务不可用时返回 null。 */
    fun service(demo: Boolean): ThinktinService? = if (demo) mock else core.getOrNull()

    companion object {
        fun create(
            context: Context,
            forceDemo: Boolean = false,
            clock: Clock = Clock.systemDefaultZone(),
        ): AppContainer {
            val app = context.applicationContext
            val store = PreferenceDataStoreFactory.create(
                scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
                produceFile = { app.preferencesDataStoreFile("settings") },
            )
            return AppContainer(
                settingsRepository = AppSettingsRepository(store, demoDefault = BuildConfig.DEMO_DEFAULT),
                clock = clock,
                createCore = { ClientFactory.createService(app, BuildConfig.BASE_URL) },
                createMock = { MockThinktinService(clock = { clock.millis() }) },
                forceDemo = forceDemo,
            )
        }
    }
}
