package cn.thinktin.app

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.preferencesDataStoreFile
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.data.core.AcceptLanguage
import cn.thinktin.data.core.ClientFactory
import cn.thinktin.data.core.TlsState
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Clock

/** 服务的创建状态：真实服务要加载 .so、打开 SQLite、读 Keystore，在后台线程上创建。 */
sealed interface ServiceState {
    data object Loading : ServiceState

    data class Ready(val service: ThinktinService) : ServiceState

    /** 核心库不可用（安装包里没有 .so、绑定与库的契约版本不一致、缓存打不开……）。 */
    data class Failed(val error: Throwable) : ServiceState
}

/**
 * 手写的依赖容器（不用 Hilt）：设置、时钟、两套 ThinktinService（演示 / 真实）。
 *
 * 真实服务第一次用到时才在 [io] 上创建（不占主线程），任何异常（UnsatisfiedLinkError、
 * ExceptionInInitializerError、Keystore 的 GeneralSecurityException……）都变成 [ServiceState.Failed]，
 * 界面显示“核心库不可用”页，不崩溃。
 */
class AppContainer(
    val settingsRepository: AppSettingsRepository,
    val clock: Clock,
    private val createCore: () -> ThinktinService,
    private val createMock: () -> ThinktinService,
    /** 测试用：强制演示模式。 */
    private val forceDemo: Boolean = false,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** App 语言 → 请求头 Accept-Language 的语言列表（默认：选的语言在前，再接系统的语言列表）。 */
    private val languageTags: (AppLanguage) -> List<String> = { AcceptLanguage.tags(it.tag) },
) {
    private val scope = CoroutineScope(SupervisorJob() + io)
    private val mock: ThinktinService by lazy(createMock)
    private val coreState = MutableStateFlow<ServiceState>(ServiceState.Loading)
    private var coreStarted = false
    private val lock = Any()

    /** 系统语言列表变了（[onSystemLocalesChanged]）时加一，让 Accept-Language 重新算一次。 */
    private val localeChanges = MutableStateFlow(0)

    /** 允许演示模式（只有 debug 包）。 */
    val demoAllowed: Boolean get() = settingsRepository.demoAllowed || forceDemo

    /** 当前设置（演示模式已按 forceDemo 修正）。 */
    val settings: Flow<AppSettings> =
        settingsRepository.settings.map { if (forceDemo) it.copy(demoMode = true) else it }

    /** 演示服务（同步创建，很轻）。 */
    fun demoService(): ThinktinService = mock

    /** 真实服务的状态；第一次调用时开始在后台创建。 */
    fun coreService(): StateFlow<ServiceState> {
        synchronized(lock) {
            if (!coreStarted) {
                coreStarted = true
                startCore()
            }
        }
        return coreState.asStateFlow()
    }

    /** 创建失败后重试（比如更新了安装包之外的条件）；正在创建或已就绪时什么也不做。 */
    fun retryCore() {
        synchronized(lock) {
            if (coreState.value !is ServiceState.Failed) return
            coreState.value = ServiceState.Loading
            startCore()
        }
    }

    /** 系统语言变了（Application.onConfigurationChanged）：重新告诉真实服务 Accept-Language。 */
    fun onSystemLocalesChanged() {
        localeChanges.update { it + 1 }
    }

    private fun startCore() {
        scope.launch {
            val state = try {
                ServiceState.Ready(createCore())
            } catch (e: Throwable) {
                // 有意兜住 Error：UnsatisfiedLinkError、NoClassDefFoundError、ExceptionInInitializerError 都是 Error。
                Log.e(TAG, "client-core 不可用", e)
                ServiceState.Failed(e)
            }
            coreState.value = state
            if (state is ServiceState.Ready) followLanguage(state.service)
        }
    }

    /** App 语言切换、系统语言变了时，把新的语言列表交给 [service]（之后的请求带新的 Accept-Language）。 */
    private suspend fun followLanguage(service: ThinktinService) {
        settings.map { it.language }
            .distinctUntilChanged()
            .combine(localeChanges) { language, _ -> language }
            .collect { language ->
                try {
                    service.setAcceptLanguage(languageTags(language))
                } catch (e: Exception) {
                    // 只是请求头：失败不影响使用（日志里记一下）。
                    Log.w(TAG, "设置 Accept-Language 失败", e)
                }
            }
    }

    companion object {
        private const val TAG = "AppContainer"

        fun create(
            context: Context,
            /** HTTPS 系统证书校验的状态（Application.onCreate 里已经初始化）；https 地址没初始化时真实服务创建失败。 */
            tls: TlsState,
            forceDemo: Boolean = false,
            clock: Clock = Clock.systemDefaultZone(),
            /** DataStore 的文件名（测试里每个 Application 用自己的，同一进程里不能有两个 DataStore 开同一个文件）。 */
            settingsName: String = "settings",
        ): AppContainer {
            val app = context.applicationContext
            val store = PreferenceDataStoreFactory.create(
                scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
                produceFile = { app.preferencesDataStoreFile(settingsName) },
            )
            return AppContainer(
                settingsRepository = AppSettingsRepository(
                    store,
                    demoDefault = BuildConfig.DEMO_DEFAULT,
                    demoAllowed = BuildConfig.DEBUG,
                ),
                clock = clock,
                createCore = { ClientFactory.createService(app, BuildConfig.BASE_URL, tls) },
                createMock = { MockThinktinService(clock = { clock.millis() }) },
                forceDemo = forceDemo,
            )
        }
    }
}
