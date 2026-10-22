package cn.thinktin.app

import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.service.AuthState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** 真实服务就绪后，App 语言切换、系统语言变了都把新的 Accept-Language 交给服务（11.8）。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class)
class AppContainerLanguageTest {
    private val asked = LinkedBlockingQueue<AppLanguage>()
    private val mock = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })

    private fun next(): AppLanguage =
        asked.poll(5, TimeUnit.SECONDS) ?: throw AssertionError("没有设置 Accept-Language")

    @Test
    fun followsAppLanguageAndSystemLocales() = runBlocking {
        val container = testContainer(
            ApplicationProvider.getApplicationContext(),
            createCore = { FakeThinktinService(mock) },
            languageTags = { language ->
                asked.add(language)
                listOfNotNull(language.tag, "fr-FR")
            },
        )
        withTimeout(5_000) { container.coreService().first { it is ServiceState.Ready } }

        assertEquals("就绪时按当前设置（跟随系统）设一次", AppLanguage.System, next())
        container.settingsRepository.setLanguage(AppLanguage.English)
        assertEquals(AppLanguage.English, next())
        container.onSystemLocalesChanged()
        assertEquals("系统语言变了：按当前 App 语言重算", AppLanguage.English, next())
        // 交给服务的是算出来的列表。
        val deadline = System.currentTimeMillis() + 5_000
        while (mock.acceptLanguageTags != listOf("en", "fr-FR") && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertEquals(listOf("en", "fr-FR"), mock.acceptLanguageTags)
    }

    @Test
    fun syncsServerLocaleAfterLoginOnlyWhenDifferent() = runBlocking {
        val fake = FakeThinktinService(mock)
        val container = testContainer(
            ApplicationProvider.getApplicationContext(),
            createCore = { fake },
            systemLanguage = "ja",
        )
        val user = mock.me()
        // 跟随系统、系统是日语：服务端只认 zh-CN / en，按 en 算
        assertEquals("en", container.syncServerLocaleNow(fake, user.copy(locale = "zh-CN")))
        assertEquals(listOf("en"), fake.locales)
        assertEquals("一致就不改", null, container.syncServerLocaleNow(fake, user.copy(locale = "en")))
        container.settingsRepository.setLanguage(AppLanguage.Chinese)
        assertEquals("zh-CN", container.syncServerLocaleNow(fake, user.copy(locale = "en")))
        assertEquals(null, container.syncServerLocaleNow(fake, user.copy(locale = "zh-cn")))
        assertEquals(listOf("en", "zh-CN"), fake.locales)
    }

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(10)
    }

    @Test
    fun syncsServerLocaleOnStartAndLanguageChangeWhenSignedIn() = runBlocking {
        // 服务端记的是 en，App 跟随系统（中文）：已登录冷启动时改成 zh-CN
        mock.setLocale("en")
        val fake = FakeThinktinService(mock)
        val container = testContainer(ApplicationProvider.getApplicationContext(), createCore = { fake })
        withTimeout(5_000) { container.coreService().first { it is ServiceState.Ready } }
        waitUntil { synchronized(fake.locales) { fake.locales.isNotEmpty() } }
        assertEquals(listOf("zh-CN"), synchronized(fake.locales) { fake.locales.toList() })
        // 切换 App 语言：服务端跟着改
        container.settingsRepository.setLanguage(AppLanguage.English)
        waitUntil { synchronized(fake.locales) { fake.locales.size >= 2 } }
        assertEquals(listOf("zh-CN", "en"), synchronized(fake.locales) { fake.locales.toList() })
    }

    @Test
    fun noServerLocaleSyncWhenSignedOut() = runBlocking {
        mock.setLocale("en")
        val fake = FakeThinktinService(mock, initial = AuthState.SignedOut)
        val container = testContainer(ApplicationProvider.getApplicationContext(), createCore = { fake })
        withTimeout(5_000) { container.coreService().first { it is ServiceState.Ready } }
        waitUntil { mock.acceptLanguageTags.isNotEmpty() }
        Thread.sleep(200)
        assertEquals(emptyList<String>(), synchronized(fake.locales) { fake.locales.toList() })
    }
}
