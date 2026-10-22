package cn.thinktin.app

import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.data.mock.MockThinktinService
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
}
