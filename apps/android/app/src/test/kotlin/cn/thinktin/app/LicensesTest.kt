package cn.thinktin.app

import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.app.settings.AppLocales
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.app.ui.settings.SettingsViewModel
import cn.thinktin.app.ui.settings.licenses.InventoryState
import cn.thinktin.app.ui.settings.licenses.LicenseFiles
import cn.thinktin.app.ui.settings.licenses.LicenseInventory
import cn.thinktin.app.ui.settings.licenses.LicenseInventoryException
import cn.thinktin.app.ui.settings.licenses.LicenseInventoryProblem
import cn.thinktin.app.ui.settings.licenses.LicenseTextKind
import cn.thinktin.app.ui.settings.licenses.LicenseTextState
import cn.thinktin.app.ui.settings.licenses.LicenseTextViewModel
import cn.thinktin.app.ui.settings.licenses.LicensesViewModel
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** 13.13：客户端核心的许可证清单、原文、开源许可页的视图模型，界面语言的取值，设置里换语言。 */
@OptIn(ExperimentalCoroutinesApi::class)
class LicensesTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private val sample = """
        {"schema": 2, "subject": "client-core", "components": [
          {"ecosystem": "cargo", "name": "serde", "version": "1.0.200", "license": "MIT OR Apache-2.0",
           "authors": "Erick Tryzelaar", "source_url": "https://github.com/serde-rs/serde",
           "files": ["texts/by-hash/aa/LICENSE-MIT", "texts/by-hash/aa/LICENSE-APACHE"],
           "file_licenses": [{"file": "texts/by-hash/aa/LICENSE-MIT", "path": "LICENSE-MIT", "proposed": "MIT"}]},
          {"ecosystem": "cargo", "name": "anyhow", "version": "1.0.9", "license": "Apache-2.0 OR MIT",
           "generic_files": ["texts/spdx/MIT.txt", "../escape"]},
          {"ecosystem": "cargo", "name": "anyhow", "version": "1.0.10", "license": "Apache-2.0 OR MIT"},
          {"ecosystem": "cargo", "name": "ring", "version": "0.17.8", "license": "ISC AND MIT",
           "bundled_files": ["texts/by-hash/bb/LICENSE"], "source_url": "javascript:alert(1)"},
          {"ecosystem": "cargo", "name": "mystery", "version": "0.1.0"},
          {"ecosystem": "cargo", "version": "9"},
          "not an object",
          {"ecosystem": "cargo", "name": "serde", "version": "1.0.200", "license": "MIT"}
        ]}
    """.trimIndent()

    @Test
    fun parsesAndGroupsTheInventory() {
        val inventory = LicenseInventory.parse(sample)
        assertEquals(2, inventory.schema)
        assertEquals("client-core", inventory.subject)
        assertEquals(6, inventory.components.size)
        // 重复的组件 id 加序号。
        assertEquals("cargo:serde@1.0.200#2", inventory.components.last().id)
        val groups = inventory.groups()
        assertEquals(listOf("Apache-2.0 OR MIT", "ISC AND MIT", "MIT", ""), groups.map { it.license })
        // 组里按名字、版本（数字按大小）排。
        assertEquals(listOf("anyhow 1.0.9", "anyhow 1.0.10", "serde 1.0.200"), groups[0].components.map { "${it.name} ${it.version}" })
        assertEquals(4, inventory.licenseCount)

        val serde = inventory.components.first()
        assertEquals("https://github.com/serde-rs/serde", serde.sourceUrl)
        assertEquals(listOf("LICENSE-MIT", "LICENSE-APACHE"), serde.texts.map { it.name })
        assertEquals("MIT", serde.texts.first().spdx)
        val anyhow = inventory.components[1]
        // 路径不在清单目录里的不列；标准文本按 SPDX 标识命名。
        assertEquals(listOf("MIT"), anyhow.texts.map { it.name })
        assertEquals(LicenseTextKind.Standard, anyhow.texts.single().kind)
        val ring = inventory.components[3]
        assertNull(ring.sourceUrl)
        assertEquals(LicenseTextKind.Bundled, ring.texts.single().kind)
    }

    @Test
    fun searchAndNormalization() {
        val inventory = LicenseInventory.parse(sample)
        assertEquals(listOf("ring"), inventory.groups("isc").flatMap { it.components }.map { it.name })
        assertEquals(listOf("serde", "serde"), inventory.groups("serde mit").flatMap { it.components }.map { it.name })
        assertTrue(inventory.groups("nothing-like-this").isEmpty())
        assertEquals("Apache-2.0 OR MIT", LicenseInventory.normalizedLicense("MIT  OR Apache-2.0 OR MIT"))
        assertEquals("(MIT OR Apache-2.0) AND ISC", LicenseInventory.normalizedLicense(" (MIT OR Apache-2.0)  AND ISC "))
        assertEquals("", LicenseInventory.normalizedLicense(null))
    }

    @Test
    fun rejectsMalformedInventories() {
        for (bad in listOf("[]", "{}", "{\"components\": 3}", "not json")) {
            try {
                LicenseInventory.parse(bad)
                fail("parsed $bad")
            } catch (e: LicenseInventoryException) {
                assertEquals(LicenseInventoryProblem.Malformed, e.problem)
            }
        }
    }

    @Test
    fun pathsAndParagraphs() {
        assertTrue(LicenseFiles.isSafePath("texts/by-hash/aa/LICENSE"))
        for (bad in listOf("", "/etc/passwd", "../x", "a/./b", "a//b", "a\\b", "~/x")) assertFalse(bad, LicenseFiles.isSafePath(bad))
        assertEquals(
            listOf("MIT License", "Permission is hereby granted\n  1. keep this", "THE SOFTWARE"),
            LicenseFiles.paragraphs("MIT License\r\n\r\nPermission is hereby granted  \n  1. keep this\n \n\nTHE SOFTWARE\n"),
        )
    }

    @Test
    fun viewModelLoadsSearchesAndExpands() = runTest(dispatcher) {
        val files = mapOf("inventory.json" to sample.toByteArray(), "texts/spdx/MIT.txt" to "MIT License\n\nfree".toByteArray())
        val source = { path: String, limit: Int -> files[path]?.also { if (it.size > limit) throw LicenseInventoryException(LicenseInventoryProblem.TooLarge) } }
        val vm = LicensesViewModel(source, io = dispatcher)
        advanceUntilIdle()
        val loaded = vm.uiState.value.inventory as InventoryState.Loaded
        assertEquals(6, loaded.inventory.components.size)
        vm.onQueryChange("ring")
        assertEquals(listOf("ring"), vm.uiState.value.groups.flatMap { it.components }.map { it.name })
        // App 自己的库也按搜索词过滤。
        assertTrue(vm.uiState.value.appDependencies.isEmpty())
        vm.onQueryChange("jna")
        assertEquals(1, vm.uiState.value.appDependencies.size)
        vm.toggle("cargo:ring@0.17.8")
        assertTrue("cargo:ring@0.17.8" in vm.uiState.value.expanded)
        vm.toggle("cargo:ring@0.17.8")
        assertTrue(vm.uiState.value.expanded.isEmpty())

        val text = LicenseTextViewModel(source, "texts/spdx/MIT.txt", io = dispatcher)
        advanceUntilIdle()
        assertEquals(LicenseTextState.Loaded(listOf("MIT License", "free")), text.uiState.value)
        val escape = LicenseTextViewModel(source, "../secret", io = dispatcher)
        advanceUntilIdle()
        assertEquals(LicenseTextState.Failed(LicenseInventoryProblem.InvalidPath), escape.uiState.value)
        val missing = LicenseTextViewModel(source, "texts/nope", io = dispatcher)
        advanceUntilIdle()
        assertEquals(LicenseTextState.Failed(LicenseInventoryProblem.Unreadable), missing.uiState.value)

        val none = LicensesViewModel({ _, _ -> null }, io = dispatcher)
        advanceUntilIdle()
        assertEquals(InventoryState.Failed(LicenseInventoryProblem.NotBundled), none.uiState.value.inventory)
    }

    @Test
    fun appLanguageFromSystemTags() {
        assertEquals(AppLanguage.Chinese, AppLocales.fromTag("zh-CN"))
        assertEquals(AppLanguage.Chinese, AppLocales.fromTag("zh-Hans-CN,en"))
        assertEquals(AppLanguage.English, AppLocales.fromTag("en-US"))
        assertEquals(AppLanguage.System, AppLocales.fromTag(""))
        assertEquals(AppLanguage.System, AppLocales.fromTag("ja-JP"))
    }

    @Test
    fun settingsStoresAndAppliesTheLanguage() = runTest(dispatcher) {
        val dir = Files.createTempDirectory("settings").toFile()
        val store = PreferenceDataStoreFactory.create(
            scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
            produceFile = { File(dir, "settings.preferences_pb") },
        )
        val repository = AppSettingsRepository(store, demoDefault = false)
        val applied = mutableListOf<AppLanguage>()
        val vm = SettingsViewModel(repository, FakeThinktinService(), applyLocales = { applied += it })
        vm.setLanguage(AppLanguage.English)
        advanceUntilIdle()
        // DataStore 在 IO 线程上写：等它落盘。
        repeat(100) {
            if (applied.isNotEmpty()) return@repeat
            Thread.sleep(20)
            advanceUntilIdle()
        }
        assertEquals(listOf(AppLanguage.English), applied)
        assertEquals(AppLanguage.English, repository.settings.first().language)
        dir.deleteRecursively()
    }
}
