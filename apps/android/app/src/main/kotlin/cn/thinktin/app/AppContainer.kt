package cn.thinktin.app

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.preferencesDataStoreFile
import androidx.fragment.app.FragmentActivity
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.app.settings.serverLocale
import cn.thinktin.app.ui.approval.ApprovalGate
import cn.thinktin.app.ui.approval.BiometricApprovalGate
import cn.thinktin.app.ui.chat.ArtifactFiles
import cn.thinktin.app.ui.chat.CacheArtifactFiles
import cn.thinktin.app.ui.chat.DraftHandoff
import cn.thinktin.data.core.AcceptLanguage
import cn.thinktin.data.core.ClientFactory
import cn.thinktin.data.core.TlsState
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.User
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.lang.ref.WeakReference
import java.time.Clock
import java.util.Locale

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
    /** 系统首选语言（ISO 639，跟随系统时用来决定告诉服务端的语言）。 */
    private val systemLanguage: () -> String = { Locale.getDefault().language },
    /** 批准审批前的身份确认；null 用 BiometricPrompt（测试里换成假的）。 */
    approvalGate: ApprovalGate? = null,
    /** 产出物下载到哪；null 用系统临时目录（[create] 传 App 的缓存目录）。 */
    artifactFiles: ArtifactFiles? = null,
) {
    /** 对话页下载产出物的位置（13.5）。 */
    val artifactFiles: ArtifactFiles =
        artifactFiles ?: CacheArtifactFiles(File(System.getProperty("java.io.tmpdir") ?: ".", "thinktin"))

    /** 首页拦下密码后转交给对话页的消息（13.5）。 */
    val draftHandoff = DraftHandoff()

    /** 当前的 MainActivity（弱引用，[attachActivity]）：BiometricPrompt 要它。 */
    @Volatile
    private var activityRef: WeakReference<FragmentActivity>? = null

    /**
     * 批准审批前的身份确认（13.16）。ViewModel 从这里取：它不持有 Activity，每次弹提示框时才找当前的
     * MainActivity，所以旋转屏幕后（ViewModel 还在、Activity 换了）照样能用。
     */
    val approvalGate: ApprovalGate = approvalGate ?: BiometricApprovalGate({ activityRef?.get() })

    /** MainActivity.onCreate 时登记自己（BiometricPrompt 要在当前的 Activity 上弹出）。 */
    fun attachActivity(activity: FragmentActivity) {
        activityRef = WeakReference(activity)
    }

    /** MainActivity.onDestroy：还是它的话就清掉。 */
    fun detachActivity(activity: FragmentActivity) {
        if (activityRef?.get() === activity) activityRef = null
    }

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

    /** 切换演示模式（登录页、核心库不可用页的“使用演示模式”）：在容器的作用域里写设置，不受页面销毁影响。 */
    fun launchSetDemoMode(enabled: Boolean) {
        scope.launch { settingsRepository.setDemoMode(enabled) }
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

    /**
     * 登录成功后（13.2）：服务端记的语言（[User.locale]，推送、收件箱用）和 App 当前的语言不一致就改过来。
     * 在容器的作用域里跑：登录一成功界面就换成主界面，登录页的 ViewModel 随之销毁，不能放在它的作用域里。
     */
    fun syncServerLocale(service: ThinktinService, user: User) {
        scope.launch { syncServerLocaleNow(service, user) }
    }

    /** [syncServerLocale] 的本体；改了返回要改成的语言，不用改返回 null。失败只记日志（不影响登录）。 */
    internal suspend fun syncServerLocaleNow(service: ThinktinService, user: User): String? {
        val wanted = settings.first().language.serverLocale(systemLanguage())
        if (user.locale.equals(wanted, ignoreCase = true)) return null
        try {
            service.setLocale(wanted)
        } catch (e: ServiceError) {
            Log.w(TAG, "同步服务端语言失败", e)
        }
        return wanted
    }

    /**
     * 服务就绪时、App 语言切换、系统语言变了时：把新的语言列表交给 [service]（之后的请求带新的 Accept-Language）；
     * 已登录时再同步服务端记的语言（推送、收件箱用）。登录成功那一刻由 [syncServerLocale] 管。
     */
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
                if (service.authState.value == AuthState.SignedIn) {
                    try {
                        syncServerLocaleNow(service, service.me())
                    } catch (e: ServiceError) {
                        // 取资料失败（断网等）：下次语言变化或下次启动再同步。
                        Log.w(TAG, "同步服务端语言失败", e)
                    }
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
            /** 默认跟着系统时区走（进程活着时换时区也跟着变）。 */
            clock: Clock = SystemZoneClock,
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
                artifactFiles = CacheArtifactFiles(app.cacheDir),
            )
        }
    }
}
