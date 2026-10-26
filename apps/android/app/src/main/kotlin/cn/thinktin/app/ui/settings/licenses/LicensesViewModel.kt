package cn.thinktin.app.ui.settings.licenses

import android.content.res.AssetManager
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

/** 清单目录（`thinktin-licenses/`）里的文件从哪读：App 里是 assets，测试里给假的。 */
fun interface LicenseSource {
    /** 读一个文件（相对清单目录）；没有返回 null，超过 [limit] 字节抛 [LicenseInventoryException]（TooLarge）。 */
    fun read(path: String, limit: Int): ByteArray?
}

/** `:core` 的 assets 里的 `thinktin-licenses/`（`sync-core.sh` 放进去的；CI 的 debug 包里没有）。 */
class AssetLicenseSource(private val assets: AssetManager, private val directory: String = DIRECTORY) : LicenseSource {
    override fun read(path: String, limit: Int): ByteArray? = try {
        assets.open("$directory/$path").use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > limit) throw LicenseInventoryException(LicenseInventoryProblem.TooLarge)
            }
            out.toByteArray()
        }
    } catch (_: IOException) {
        null
    }

    companion object {
        const val DIRECTORY = "thinktin-licenses"
    }
}

/** App 自己打进包里的库（README“第三方依赖与许可证”那张表；Gradle 依赖不在客户端核心的清单里）。 */
data class AppDependency(val name: String, val license: String)

val APP_DEPENDENCIES = listOf(
    AppDependency("AndroidX（core、activity、lifecycle、navigation、datastore、security-crypto、appcompat、biometric）", "Apache-2.0"),
    AppDependency("Jetpack Compose（UI、Material 3、Material Icons）", "Apache-2.0"),
    AppDependency("kotlinx-coroutines、kotlinx-serialization", "Apache-2.0"),
    AppDependency("commonmark（含 GFM 表格、删除线扩展）", "BSD-2-Clause"),
    AppDependency("JNA", "Apache-2.0 OR LGPL-2.1"),
    AppDependency("rustls-platform-verifier（Android 组件）", "Apache-2.0 OR MIT"),
)

sealed interface InventoryState {
    data object Loading : InventoryState

    data class Loaded(val inventory: LicenseInventory) : InventoryState

    data class Failed(val problem: LicenseInventoryProblem) : InventoryState
}

data class LicensesUiState(
    val inventory: InventoryState = InventoryState.Loading,
    val query: String = "",
    /** 展开着的组件（看许可证、作者、来源、原文）。 */
    val expanded: Set<String> = emptySet(),
) {
    val groups: List<LicenseGroup>
        get() = (inventory as? InventoryState.Loaded)?.inventory?.groups(query).orEmpty()

    /** 搜索后 App 自己的库还剩哪些。 */
    val appDependencies: List<AppDependency>
        get() {
            val tokens = searchTokens(query)
            return APP_DEPENDENCIES.filter { dep ->
                tokens.all { dep.name.contains(it, ignoreCase = true) || dep.license.contains(it, ignoreCase = true) }
            }
        }
}

/**
 * 开源许可（13.13，路由 `licenses`）：App 自己用的库，加客户端核心的清单（按许可证分组、可以搜，点开看版本、作者、来源和原文）。
 * 包里没带清单（CI 的 debug 包）时说一声，App 自己的库照常列。
 */
class LicensesViewModel(
    private val source: LicenseSource,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val state = MutableStateFlow(LicensesUiState())
    val uiState: StateFlow<LicensesUiState> = state.asStateFlow()

    init {
        viewModelScope.launch {
            val result = withContext(io) { load() }
            state.update { it.copy(inventory = result) }
        }
    }

    fun onQueryChange(query: String) = state.update { it.copy(query = query) }

    fun toggle(componentId: String) = state.update {
        it.copy(expanded = if (componentId in it.expanded) it.expanded - componentId else it.expanded + componentId)
    }

    private fun load(): InventoryState = try {
        val bytes = source.read(LicenseInventory.FILE_NAME, MAX_INVENTORY_BYTES)
            ?: return InventoryState.Failed(LicenseInventoryProblem.NotBundled)
        InventoryState.Loaded(LicenseInventory.parse(bytes.decodeToString()))
    } catch (e: LicenseInventoryException) {
        InventoryState.Failed(e.problem)
    }

    private companion object {
        const val MAX_INVENTORY_BYTES = 16 * 1024 * 1024
    }
}

sealed interface LicenseTextState {
    data object Loading : LicenseTextState

    data class Loaded(val paragraphs: List<String>) : LicenseTextState

    data class Failed(val problem: LicenseInventoryProblem) : LicenseTextState
}

/** 一份原文（路由 `licenses/text?path=`）：分段显示，长文滚动时只画看得见的。 */
class LicenseTextViewModel(
    private val source: LicenseSource,
    private val path: String,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val state = MutableStateFlow<LicenseTextState>(LicenseTextState.Loading)
    val uiState: StateFlow<LicenseTextState> = state.asStateFlow()

    init {
        viewModelScope.launch { state.value = withContext(io) { load() } }
    }

    private fun load(): LicenseTextState {
        if (!LicenseFiles.isSafePath(path)) return LicenseTextState.Failed(LicenseInventoryProblem.InvalidPath)
        return try {
            val bytes = source.read(path, LicenseFiles.MAX_TEXT_BYTES)
                ?: return LicenseTextState.Failed(LicenseInventoryProblem.Unreadable)
            // UTF-8，不是的按 Latin-1。
            val text = runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString() }
                .getOrElse { String(bytes, Charsets.ISO_8859_1) }
            LicenseTextState.Loaded(LicenseFiles.paragraphs(text))
        } catch (e: LicenseInventoryException) {
            LicenseTextState.Failed(e.problem)
        }
    }
}
