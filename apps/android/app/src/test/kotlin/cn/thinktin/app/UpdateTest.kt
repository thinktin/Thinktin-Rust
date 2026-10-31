package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.update.ApkCheck
import cn.thinktin.app.update.ApkInfo
import cn.thinktin.app.update.ApkInspector
import cn.thinktin.app.update.HttpFetcher
import cn.thinktin.app.update.UpdateError
import cn.thinktin.app.update.UpdateException
import cn.thinktin.app.update.UpdateManifest
import cn.thinktin.app.update.UpdatePrefs
import cn.thinktin.app.update.UpdateState
import cn.thinktin.app.update.Updater
import cn.thinktin.data.service.AuthState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** 测试用的“网络”：地址 → 内容；没有的地址抛 IOException（像 404）。 */
class FakeHttp(private val bodies: MutableMap<String, ByteArray> = mutableMapOf()) : HttpFetcher {
    val requests = mutableListOf<String>()

    operator fun set(url: String, body: ByteArray) {
        bodies[url] = body
    }

    override fun open(url: String): java.io.InputStream {
        requests += url
        return ByteArrayInputStream(bodies[url] ?: throw IOException("HTTP 404"))
    }
}

class MemoryUpdatePrefs : UpdatePrefs {
    override var lastCheckMs: Long = 0
    override var dismissedVersion: Long = 0
}

class FakeInspector(
    var archive: ApkInfo? = ApkInfo("cn.thinktin.app", 2, setOf("aa")),
    var installed: ApkInfo = ApkInfo("cn.thinktin.app", 1, setOf("aa")),
) : ApkInspector {
    override fun archive(file: File): ApkInfo? = archive

    override fun installed(): ApkInfo = installed
}

/** 官网的更新清单和安装包（版本 2，装着的是 1）。 */
object UpdateFixture {
    const val MANIFEST_URL = "https://thinktin.cn/download/android/latest.json"
    const val APK_URL = "https://thinktin.cn/download/android/thinktin-0.2.0.apk"
    val apk: ByteArray = ByteArray(200_000) { (it % 251).toByte() }

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    fun manifestJson(
        versionCode: Long = 2,
        sha256: String = sha256(apk),
        size: Long = apk.size.toLong(),
        minSdk: Int = 26,
        apkUrl: String = APK_URL,
    ) = """
        {"version_code": $versionCode, "version_name": "0.2.0", "apk_url": "$apkUrl", "sha256": "$sha256",
         "size": $size, "min_sdk": $minSdk, "notes": {"zh": "修了几个问题", "en": "Bug fixes"}}
    """.trimIndent()

    fun http(manifest: String = manifestJson()) = FakeHttp().also {
        it[MANIFEST_URL] = manifest.toByteArray()
        it[APK_URL] = apk
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class UpdateTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val inDialog = hasAnyAncestor(isDialog())

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun updater(
        http: FakeHttp = UpdateFixture.http(),
        inspector: FakeInspector = FakeInspector(),
        prefs: UpdatePrefs = MemoryUpdatePrefs(),
        sdkInt: Int = 35,
        now: Long = 1_000_000_000L,
        scope: CoroutineScope? = null,
    ): Updater {
        val dispatcher = UnconfinedTestDispatcher()
        return Updater(
            manifestUrl = UpdateFixture.MANIFEST_URL,
            currentVersionCode = 1,
            sdkInt = sdkInt,
            dir = File(app.cacheDir, "updates"),
            inspector = inspector,
            prefs = prefs,
            clock = { now },
            http = http,
            io = dispatcher,
            scope = scope ?: CoroutineScope(dispatcher),
        )
    }

    @Test
    fun manifestIsParsedAndChecked() {
        val manifest = UpdateManifest.parse(UpdateFixture.manifestJson())
        assertEquals(2L, manifest.versionCode)
        assertEquals("0.2.0", manifest.versionName)
        assertEquals("修了几个问题", manifest.notes(chinese = true))
        assertEquals("Bug fixes", manifest.notes(chinese = false))
        val noZh = UpdateManifest.parse(UpdateFixture.manifestJson().replace("\"zh\": \"修了几个问题\", ", ""))
        assertEquals("Bug fixes", noZh.notes(chinese = true))

        fun rejects(json: String) {
            try {
                UpdateManifest.parse(json)
                fail("should reject: $json")
            } catch (e: UpdateException) {
                assertEquals(UpdateError.BadManifest, e.error)
            }
        }
        rejects("not json")
        rejects(UpdateFixture.manifestJson(versionCode = 0))
        rejects(UpdateFixture.manifestJson(sha256 = "abc"))
        rejects(UpdateFixture.manifestJson(size = 0))
        rejects(UpdateFixture.manifestJson(apkUrl = "http://thinktin.cn/a.apk"))
        rejects(UpdateFixture.manifestJson(apkUrl = "https://evil.example/a.apk"))
        rejects(UpdateFixture.manifestJson(apkUrl = "https://thinktin.cn.evil.example/a.apk"))
        rejects(UpdateFixture.manifestJson(apkUrl = "https://user@thinktin.cn/a.apk"))
        assertTrue(UpdateManifest.isAllowedUrl("https://dl.thinktin.cn/a.apk"))
    }

    @Test
    fun apkCheckComparesPackageVersionAndSigner() {
        val manifest = UpdateManifest.parse(UpdateFixture.manifestJson())
        val installed = ApkInfo("cn.thinktin.app", 1, setOf("aa"))
        assertNull(ApkCheck.verify(ApkInfo("cn.thinktin.app", 2, setOf("aa")), installed, manifest))
        assertEquals(UpdateError.BadApk, ApkCheck.verify(null, installed, manifest))
        assertEquals(UpdateError.BadApk, ApkCheck.verify(ApkInfo("com.other", 2, setOf("aa")), installed, manifest))
        assertEquals(UpdateError.BadApk, ApkCheck.verify(ApkInfo("cn.thinktin.app", 3, setOf("aa")), installed, manifest))
        assertEquals(
            UpdateError.BadApk,
            ApkCheck.verify(ApkInfo("cn.thinktin.app", 2, setOf("aa")), installed.copy(versionCode = 2), manifest),
        )
        assertEquals(UpdateError.Signature, ApkCheck.verify(ApkInfo("cn.thinktin.app", 2, setOf("bb")), installed, manifest))
        assertEquals(UpdateError.Signature, ApkCheck.verify(ApkInfo("cn.thinktin.app", 2, emptySet()), installed, manifest))
    }

    @Test
    fun checkFindsNewerVersionsAndRemembersWhen() = runTest {
        val prefs = MemoryUpdatePrefs()
        val available = updater(prefs = prefs)
        // 手动检查的结果不弹提示。
        available.check()
        assertTrue(available.updateState.value is UpdateState.Available)
        assertEquals(1_000_000_000L, prefs.lastCheckMs)
        assertFalse(available.shouldPrompt)
        prefs.lastCheckMs = 0
        available.checkIfDue()
        assertTrue(available.shouldPrompt)
        available.dismiss()
        assertEquals(2L, prefs.dismissedVersion)
        assertFalse(available.shouldPrompt)

        val same = updater(http = UpdateFixture.http(UpdateFixture.manifestJson(versionCode = 1)))
        same.checkNow()
        assertEquals(UpdateState.UpToDate, same.updateState.value)

        val tooOld = updater(http = UpdateFixture.http(UpdateFixture.manifestJson(minSdk = 36)), sdkInt = 35)
        tooOld.checkNow()
        assertEquals(UpdateError.DeviceTooOld, (tooOld.updateState.value as UpdateState.Failed).error)

        val offline = updater(http = FakeHttp())
        offline.checkNow()
        assertEquals(UpdateError.Network, (offline.updateState.value as UpdateState.Failed).error)

        val broken = updater(http = UpdateFixture.http("{}"))
        broken.checkNow()
        assertEquals(UpdateError.BadManifest, (broken.updateState.value as UpdateState.Failed).error)
    }

    @Test
    fun automaticCheckRunsAtMostOncePerDay() = runTest {
        val http = UpdateFixture.http()
        val prefs = MemoryUpdatePrefs().apply { lastCheckMs = 1_000_000_000L - Updater.DAY_MS + 1 }
        updater(http = http, prefs = prefs).checkIfDue()
        assertEquals(0, http.requests.size)
        prefs.lastCheckMs = 1_000_000_000L - Updater.DAY_MS
        updater(http = http, prefs = prefs).checkIfDue()
        assertEquals(listOf(UpdateFixture.MANIFEST_URL), http.requests)
    }

    @Test
    fun downloadIsVerifiedBeforeInstall() = runTest {
        val goodPrefs = MemoryUpdatePrefs()
        val good = updater(prefs = goodPrefs)
        good.checkNow()
        good.downloadNow(UpdateManifest.parse(UpdateFixture.manifestJson()))
        val ready = good.updateState.value as UpdateState.Ready
        assertTrue(ready.file.exists())
        assertEquals(UpdateFixture.apk.size.toLong(), ready.file.length())
        good.dismiss()
        assertEquals(ready.manifest.versionCode, goodPrefs.dismissedVersion)
        assertTrue(ready.file.delete())
        assertNull(good.readyFile())
        assertEquals(UpdateError.Storage, (good.updateState.value as UpdateState.Failed).error)

        // SHA-256 不对：删掉，报校验失败。
        val badHash = updater(http = UpdateFixture.http(UpdateFixture.manifestJson(sha256 = "0".repeat(64))))
        badHash.checkNow()
        badHash.download()
        assertEquals(UpdateError.Checksum, (badHash.updateState.value as UpdateState.Failed).error)
        assertTrue(File(app.cacheDir, "updates").listFiles().orEmpty().isEmpty())

        // 比清单说的大：下到一半就停。
        val tooBig = updater(http = UpdateFixture.http(UpdateFixture.manifestJson(size = 1_000)))
        tooBig.checkNow()
        tooBig.download()
        assertEquals(UpdateError.Checksum, (tooBig.updateState.value as UpdateState.Failed).error)

        // 签名不一样、包名不一样。
        val signature = updater(inspector = FakeInspector(archive = ApkInfo("cn.thinktin.app", 2, setOf("bb"))))
        signature.checkNow()
        signature.download()
        assertEquals(UpdateError.Signature, (signature.updateState.value as UpdateState.Failed).error)
        val other = updater(inspector = FakeInspector(archive = ApkInfo("com.other", 2, setOf("aa"))))
        other.checkNow()
        other.download()
        assertEquals(UpdateError.BadApk, (other.updateState.value as UpdateState.Failed).error)
        assertTrue(File(app.cacheDir, "updates").listFiles().orEmpty().isEmpty())

        // 下载时断网：可以重试。
        val http = UpdateFixture.http()
        val flaky = updater(http = http)
        flaky.checkNow()
        http[UpdateFixture.APK_URL] = ByteArray(0)
        flaky.download()
        assertEquals(UpdateError.Checksum, (flaky.updateState.value as UpdateState.Failed).error)
        http[UpdateFixture.APK_URL] = UpdateFixture.apk
        flaky.download()
        assertTrue(flaky.updateState.value is UpdateState.Ready)
    }

    @Test
    fun settingsCheckDownloadAndInstall() {
        val fake = FakeThinktinService(initial = AuthState.SignedIn)
        // 已经自动检查过（不弹提示），从设置里手动查。
        val prefs = MemoryUpdatePrefs().apply { lastCheckMs = System.currentTimeMillis() }
        val updater = Updater(
            manifestUrl = UpdateFixture.MANIFEST_URL,
            currentVersionCode = 1,
            sdkInt = 35,
            dir = File(app.cacheDir, "updates"),
            inspector = FakeInspector(),
            prefs = prefs,
            http = UpdateFixture.http(),
        )
        app.container = testContainer(app, { fake }, updater = updater)
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("外观"))
        compose.onNode(hasText("检查更新")).performScrollTo().performClick()
        waitFor(hasText("有新版本 0.2.0"))
        compose.onNode(hasText("修了几个问题")).assertExists()
        compose.onNode(hasText("下载并安装")).performClick()
        waitFor(hasText("安装"))
        // 还没允许安装应用：去系统设置。
        compose.onNode(hasText("安装")).performClick()
        waitFor(hasText("先在系统设置里允许 ThinkTin 安装应用，回来再点“安装”。"))
        val settings = shadowOf(app).nextStartedActivity
        assertEquals(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, settings.action)
        // 允许之后：交给系统的安装程序。
        shadowOf(app.packageManager).setCanRequestPackageInstalls(true)
        compose.onNode(hasText("安装")).performClick()
        val install = shadowOf(app).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, install.action)
        assertEquals("application/vnd.android.package-archive", install.type)
        assertTrue(install.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
    }

    @Test
    fun dailyPromptOffersTheNewVersionOnce() {
        val fake = FakeThinktinService(initial = AuthState.SignedIn)
        val prefs = MemoryUpdatePrefs()
        val updater = Updater(
            manifestUrl = UpdateFixture.MANIFEST_URL,
            currentVersionCode = 1,
            sdkInt = 35,
            dir = File(app.cacheDir, "updates"),
            inspector = FakeInspector(),
            prefs = prefs,
            http = UpdateFixture.http(),
        )
        app.container = testContainer(app, { fake }, updater = updater)
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasText("发现新版本 0.2.0"))
        compose.onNode(hasText("下载并安装") and inDialog).assertExists()
        compose.onNode(hasText("以后再说")).performClick()
        compose.waitUntil(timeoutMillis = 10_000) {
            compose.onAllNodes(hasText("发现新版本 0.2.0")).fetchSemanticsNodes().isEmpty()
        }
        assertEquals(2L, prefs.dismissedVersion)
    }
}
