package cn.thinktin.app.update

import org.json.JSONException
import org.json.JSONObject
import java.net.URI

/**
 * 官网安装包的更新清单（13.12）：放在官网的一个静态 JSON 文件（`BuildConfig.UPDATE_MANIFEST_URL`），发版时由
 * `apps/android/scripts/update-manifest.py` 生成（docs/android-release.md 第 3 节）：
 *
 * ```json
 * {"version_code": 12, "version_name": "0.2.0", "apk_url": "https://thinktin.cn/download/android/thinktin-0.2.0.apk",
 *  "sha256": "<64 位十六进制>", "size": 31457280, "min_sdk": 26, "notes": {"zh": "……", "en": "……"}}
 * ```
 *
 * 安装包只能从 thinktin.cn（含子域名）的 https 地址下载；下载后还要对 [sha256]、包名、版本号、签名（见 [ApkCheck]）。
 */
data class UpdateManifest(
    val versionCode: Long,
    val versionName: String,
    val apkUrl: String,
    val sha256: String,
    val size: Long,
    val minSdk: Int,
    val notesZh: String,
    val notesEn: String,
) {
    /** 更新说明（界面是中文就给中文，否则英文；缺了哪种就用另一种）。 */
    fun notes(chinese: Boolean): String = if (chinese) notesZh.ifBlank { notesEn } else notesEn.ifBlank { notesZh }

    companion object {
        /** 清单最大多少字节（防止下到一个大文件）。 */
        const val MAX_BYTES = 64 * 1024

        /** 安装包最大多少字节。 */
        const val MAX_APK_BYTES = 500L * 1024 * 1024

        private val HEX64 = Regex("^[0-9a-f]{64}$")

        /** 解析并检查；不合格抛 [UpdateException]（[UpdateError.BadManifest]）。 */
        fun parse(text: String): UpdateManifest {
            val json = try {
                JSONObject(text)
            } catch (e: JSONException) {
                throw UpdateException(UpdateError.BadManifest, e)
            }
            fun bad(): Nothing = throw UpdateException(UpdateError.BadManifest)
            val versionCode = json.optLong("version_code", -1)
            val versionName = json.optString("version_name").trim()
            val apkUrl = json.optString("apk_url").trim()
            val sha256 = json.optString("sha256").trim().lowercase()
            val size = json.optLong("size", -1)
            val minSdk = json.optInt("min_sdk", 26)
            val notes = json.optJSONObject("notes")
            if (versionCode <= 0 || versionName.isEmpty() || !HEX64.matches(sha256)) bad()
            if (size <= 0 || size > MAX_APK_BYTES || !isAllowedUrl(apkUrl)) bad()
            return UpdateManifest(
                versionCode = versionCode,
                versionName = versionName,
                apkUrl = apkUrl,
                sha256 = sha256,
                size = size,
                minSdk = minSdk,
                notesZh = notes?.optString("zh").orEmpty().trim(),
                notesEn = notes?.optString("en").orEmpty().trim(),
            )
        }

        /** 只认 https 的 thinktin.cn 和它的子域名（下载服务换 CDN 时用子域名）。 */
        fun isAllowedUrl(url: String): Boolean {
            val uri = try {
                URI(url)
            } catch (_: Exception) {
                return false
            }
            val host = uri.host?.lowercase() ?: return false
            return uri.scheme.equals("https", ignoreCase = true) && uri.userInfo == null &&
                (host == "thinktin.cn" || host.endsWith(".thinktin.cn"))
        }
    }
}

/** 更新失败的原因（界面按它出文案）。 */
enum class UpdateError {
    /** 连不上、超时、服务器出错。 */
    Network,

    /** 清单的格式、地址不对。 */
    BadManifest,

    /** 新版本要更高的 Android 版本。 */
    DeviceTooOld,

    /** 下载的文件和清单里的大小、SHA-256 对不上。 */
    Checksum,

    /** 不是 ThinkTin 的安装包，或者版本号不对。 */
    BadApk,

    /** 签名和装着的 App 不一样（不是我们发的，系统也装不上）。 */
    Signature,

    /** 存不下（空间不够）。 */
    Storage,
}

class UpdateException(val error: UpdateError, cause: Throwable? = null) : Exception(error.name, cause)
