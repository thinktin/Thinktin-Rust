package cn.thinktin.app

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.data.core.AcceptLanguage
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.LoginResult
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.User
import cn.thinktin.data.service.ServiceError
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
 * 用来走 AppRoot 里非演示的分支（登录流、冻结页、运行中被踢下线），以及登录、设备与账号页的错误路径：
 * [failNext] 让某个方法下一次调用抛指定的错误（只抛一次）。验证码只认 [validCode]，其余报 invalid（和服务端一样）。
 */
class FakeThinktinService(
    private val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
    initial: AuthState = AuthState.SignedIn,
    /** 登录返回的用户的语言（服务端记的语言，测试登录后的 setLocale）。 */
    private val userLocale: String = "zh-CN",
) : ThinktinService by mock {
    val auth = MutableStateFlow(initial)
    var logoutCalls = 0
        private set
    val sentCodes = mutableListOf<String>()
    val logins = mutableListOf<Pair<String, String>>()
    val locales = mutableListOf<String>()
    var selfCodes = 0
        private set
    var deletedWith: String? = null
        private set
    var validCode = "123456"

    private val failures = mutableMapOf<String, ServiceError>()

    /** [method] 下一次调用抛 [error]。 */
    fun failNext(method: String, error: ServiceError) {
        synchronized(failures) { failures[method] = error }
    }

    private fun maybeFail(method: String) {
        synchronized(failures) { failures.remove(method) }?.let { throw it }
    }

    private fun invalidCode(): Nothing = throw ServiceError.Api(422, "invalid", "invalid or expired code", null)

    override val isDemo: Boolean = false
    override val authState: StateFlow<AuthState> get() = auth

    override suspend fun sendCode(phone: String) {
        sentCodes += phone
        maybeFail("sendCode")
    }

    override suspend fun login(phone: String, code: String, pushChannel: String?, pushToken: String?): LoginResult {
        logins += phone to code
        maybeFail("login")
        if (code != validCode) invalidCode()
        auth.value = AuthState.SignedIn
        return LoginResult(user = mock.me().copy(phone = phone, locale = userLocale), newUser = false)
    }

    override suspend fun logout() {
        logoutCalls++
        auth.value = AuthState.SignedOut
    }

    override suspend fun me(): User {
        maybeFail("me")
        return mock.me()
    }

    override suspend fun setLocale(locale: String): User {
        locales += locale
        return mock.setLocale(locale)
    }

    override suspend fun devices(): List<DeviceInfo> {
        maybeFail("devices")
        return mock.devices()
    }

    override suspend fun revokeDevice(deviceId: String) {
        maybeFail("revokeDevice")
        val current = mock.devices().firstOrNull { it.id == deviceId }?.current == true
        mock.revokeDevice(deviceId)
        if (current) auth.value = AuthState.SignedOut
    }

    override suspend fun signOutOtherDevices(stopAgents: Boolean): SignOutOthersResult {
        maybeFail("signOutOtherDevices")
        return mock.signOutOtherDevices(stopAgents)
    }

    override suspend fun stopAll(): StopAllResult {
        maybeFail("stopAll")
        return mock.stopAll()
    }

    override suspend fun sendSelfCode(purpose: SelfCodePurpose) {
        selfCodes++
        maybeFail("sendSelfCode")
    }

    override suspend fun deleteAccount(code: String) {
        maybeFail("deleteAccount")
        if (code != validCode) invalidCode()
        deletedWith = code
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
    languageTags: ((AppLanguage) -> List<String>)? = null,
    systemLanguage: String = "zh",
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
        languageTags = languageTags ?: { AcceptLanguage.tags(it.tag) },
        systemLanguage = { systemLanguage },
    )
}
