package cn.thinktin.app.update

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** 应用内更新的状态（13.12）。 */
sealed interface UpdateState {
    data object Idle : UpdateState

    data object Checking : UpdateState

    data object UpToDate : UpdateState

    data class Available(val manifest: UpdateManifest) : UpdateState

    data class Downloading(val manifest: UpdateManifest, val read: Long) : UpdateState

    /** 下好了、校验过了，等交给系统安装。 */
    data class Ready(val manifest: UpdateManifest, val file: File) : UpdateState

    data class Failed(val error: UpdateError, val manifest: UpdateManifest?) : UpdateState
}

/** 一个 https 地址的内容（测试里换成假的）。 */
fun interface HttpFetcher {
    /** 打开 [url]；非 2xx 抛 IOException。 */
    fun open(url: String): InputStream
}

/** 系统的 HttpURLConnection（证书按系统的校验，跟随重定向但不会从 https 跳到 http）。 */
object SystemHttpFetcher : HttpFetcher {
    override fun open(url: String): InputStream {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("Accept-Encoding", "identity")
        val code = connection.responseCode
        if (code !in 200..299) {
            connection.disconnect()
            throw IOException("HTTP $code")
        }
        return connection.inputStream
    }
}

/** 一个安装包里看得到的：包名、版本号、签名证书的 SHA-256。 */
data class ApkInfo(val packageName: String, val versionCode: Long, val signers: Set<String>)

/** 读安装包和装着的 App 的信息（[PackageManagerApkInspector]；测试里换成假的）。 */
interface ApkInspector {
    /** 下载的安装包；读不出来（不是 APK）为 null。 */
    fun archive(file: File): ApkInfo?

    /** 现在装着的这个 App。 */
    fun installed(): ApkInfo
}

/** 下载后、安装前的检查。 */
object ApkCheck {
    /**
     * 包名一样、版本号就是清单里的、比装着的新；两边都读得到签名时签名要一样（读不到时交给系统：签名不同的更新系统装不上）。
     * 通过返回 null。
     */
    fun verify(archive: ApkInfo?, installed: ApkInfo, manifest: UpdateManifest): UpdateError? = when {
        archive == null -> UpdateError.BadApk
        archive.packageName != installed.packageName -> UpdateError.BadApk
        archive.versionCode != manifest.versionCode || archive.versionCode <= installed.versionCode -> UpdateError.BadApk
        archive.signers.isNotEmpty() && installed.signers.isNotEmpty() && archive.signers != installed.signers ->
            UpdateError.Signature
        else -> null
    }
}

/**
 * 官网安装包的应用内更新（13.12，只有 `direct` 渠道有，`BuildConfig.SELF_UPDATE`）：拉更新清单 → 有新版本 → 下载到缓存的
 * `updates/`（边下边算 SHA-256，超过清单里的大小就停）→ 对 SHA-256、包名、版本号、签名 → 交给系统安装（[ApkInstaller]）。
 *
 * 自动检查一天最多一次（[checkIfDue]）；用户点了“以后再说”的版本不再自动提示（[dismiss]），手动检查照样显示。
 */
class Updater(
    private val manifestUrl: String,
    /** 装着的版本号（BuildConfig.VERSION_CODE）。 */
    private val currentVersionCode: Long,
    private val sdkInt: Int,
    private val dir: File,
    private val inspector: ApkInspector,
    private val prefs: UpdatePrefs,
    private val clock: () -> Long = System::currentTimeMillis,
    private val http: HttpFetcher = SystemHttpFetcher,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Main.immediate),
) {
    private val state = MutableStateFlow<UpdateState>(UpdateState.Idle)
    val updateState: StateFlow<UpdateState> = state.asStateFlow()
    private var job: Job? = null

    /** 自动检查发现的、用户还没点过“以后再说”的新版本（根界面弹提示）。 */
    val shouldPrompt: Boolean
        get() = (state.value as? UpdateState.Available)?.manifest?.versionCode?.let { it != prefs.dismissedVersion } == true

    /** 手动检查（设置 → 检查更新、升级页）。正在检查、下载时什么都不做。 */
    fun check() {
        if (job?.isActive == true) return
        job = scope.launch { checkNow() }
    }

    /** 自动检查：离上次检查超过一天才查。 */
    fun checkIfDue() {
        if (clock() - prefs.lastCheckMs < DAY_MS) return
        check()
    }

    internal suspend fun checkNow() {
        state.value = UpdateState.Checking
        state.value = try {
            val manifest = withContext(io) { UpdateManifest.parse(readText(manifestUrl)) }
            prefs.lastCheckMs = clock()
            when {
                manifest.versionCode <= currentVersionCode -> UpdateState.UpToDate
                manifest.minSdk > sdkInt -> UpdateState.Failed(UpdateError.DeviceTooOld, manifest)
                else -> UpdateState.Available(manifest)
            }
        } catch (e: UpdateException) {
            UpdateState.Failed(e.error, null)
        } catch (_: IOException) {
            UpdateState.Failed(UpdateError.Network, null)
        }
    }

    /** “以后再说”：这个版本不再自动提示。 */
    fun dismiss() {
        (state.value as? UpdateState.Available)?.let { prefs.dismissedVersion = it.manifest.versionCode }
    }

    /** 下载、校验（有新版本或上次下载失败时）。 */
    fun download() {
        val manifest = when (val current = state.value) {
            is UpdateState.Available -> current.manifest
            is UpdateState.Failed -> current.manifest ?: return
            else -> return
        }
        if (job?.isActive == true) return
        job = scope.launch { downloadNow(manifest) }
    }

    internal suspend fun downloadNow(manifest: UpdateManifest) {
        state.value = UpdateState.Downloading(manifest, 0)
        state.value = try {
            val file = withContext(io) { fetchApk(manifest) }
            val problem = withContext(io) { ApkCheck.verify(inspector.archive(file), inspector.installed(), manifest) }
            if (problem != null) {
                file.delete()
                UpdateState.Failed(problem, manifest)
            } else {
                UpdateState.Ready(manifest, file)
            }
        } catch (e: UpdateException) {
            UpdateState.Failed(e.error, manifest)
        } catch (_: IOException) {
            UpdateState.Failed(UpdateError.Network, manifest)
        }
    }

    private fun readText(url: String): String = http.open(url).use { input ->
        val bytes = input.readNBytesCompat(UpdateManifest.MAX_BYTES + 1)
        if (bytes.size > UpdateManifest.MAX_BYTES) throw UpdateException(UpdateError.BadManifest)
        bytes.toString(Charsets.UTF_8)
    }

    /** 下到 `updates/thinktin-<版本号>.apk`（先写 .part，对上 SHA-256 再改名）；别的旧文件先删掉。 */
    private fun fetchApk(manifest: UpdateManifest): File {
        if (!dir.exists() && !dir.mkdirs()) throw UpdateException(UpdateError.Storage)
        dir.listFiles()?.forEach { it.delete() }
        val part = File(dir, "thinktin-${manifest.versionCode}.apk.part")
        val digest = MessageDigest.getInstance("SHA-256")
        var read = 0L
        try {
            http.open(manifest.apkUrl).use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        read += n
                        if (read > manifest.size) throw UpdateException(UpdateError.Checksum)
                        digest.update(buffer, 0, n)
                        output.write(buffer, 0, n)
                        state.value = UpdateState.Downloading(manifest, read)
                    }
                }
            }
        } catch (e: IOException) {
            part.delete()
            // 写文件失败（空间不够）和网络断了都是 IOException：看文件还能不能写来分。
            throw if (dir.usableSpace < manifest.size - read) UpdateException(UpdateError.Storage, e) else e
        } catch (e: UpdateException) {
            part.delete()
            throw e
        }
        val hex = digest.digest().joinToString("") { "%02x".format(it) }
        if (read != manifest.size || hex != manifest.sha256) {
            part.delete()
            throw UpdateException(UpdateError.Checksum)
        }
        val apk = File(dir, "thinktin-${manifest.versionCode}.apk")
        if (!part.renameTo(apk)) throw UpdateException(UpdateError.Storage)
        return apk
    }

    companion object {
        const val DAY_MS = 24L * 60 * 60 * 1000
    }
}

/** 最多读 [limit] 个字节（API 26 没有 readNBytes）。 */
private fun InputStream.readNBytesCompat(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1024)
    while (out.size() < limit) {
        val n = read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (n < 0) break
        out.write(buffer, 0, n)
    }
    return out.toByteArray()
}

/** 上次检查的时间、点过“以后再说”的版本。 */
interface UpdatePrefs {
    var lastCheckMs: Long
    var dismissedVersion: Long
}
