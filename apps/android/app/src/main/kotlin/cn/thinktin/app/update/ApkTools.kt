package cn.thinktin.app.update

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import java.io.File
import java.security.MessageDigest

/** 用 PackageManager 读安装包和装着的 App：包名、版本号、签名证书的 SHA-256。 */
class PackageManagerApkInspector(private val context: Context) : ApkInspector {
    override fun archive(file: File): ApkInfo? {
        val info = context.packageManager.getPackageArchiveInfo(file.path, signatureFlags()) ?: return null
        return info.toApkInfo()
    }

    override fun installed(): ApkInfo =
        context.packageManager.getPackageInfo(context.packageName, signatureFlags()).toApkInfo()

    @Suppress("DEPRECATION")
    private fun signatureFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.toApkInfo(): ApkInfo {
        val certificates = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = signingInfo
            when {
                signing == null -> null
                signing.hasMultipleSigners() -> signing.apkContentsSigners
                else -> signing.signingCertificateHistory?.takeLast(1)?.toTypedArray()
            }
        } else {
            signatures
        }
        val digests = certificates.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
        return ApkInfo(packageName, PackageInfoCompat.getLongVersionCode(this), digests)
    }
}

/** 交给系统安装的结果。 */
enum class InstallLaunch {
    /** 系统的安装界面打开了。 */
    Started,

    /** 还没允许 ThinkTin 安装应用：打开了系统里的那个开关，回来再点一次。 */
    NeedsPermission,

    /** 打不开（系统里没有安装程序）。 */
    Unavailable,
}

/** 把下好的安装包交给系统安装（content:// 加读权限，见 file_paths.xml 的 updates/）。 */
object ApkInstaller {
    fun launch(context: Context, file: File): InstallLaunch {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            return try {
                context.startActivity(settings)
                InstallLaunch.NeedsPermission
            } catch (_: ActivityNotFoundException) {
                InstallLaunch.Unavailable
            }
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            InstallLaunch.Started
        } catch (_: ActivityNotFoundException) {
            InstallLaunch.Unavailable
        }
    }
}

/** 存在 SharedPreferences 里（不进 DataStore 的设置：只是更新检查的记录）。 */
class SharedUpdatePrefs(private val prefs: SharedPreferences) : UpdatePrefs {
    override var lastCheckMs: Long
        get() = prefs.getLong(KEY_LAST_CHECK, 0)
        set(value) = prefs.edit().putLong(KEY_LAST_CHECK, value).apply()

    override var dismissedVersion: Long
        get() = prefs.getLong(KEY_DISMISSED, 0)
        set(value) = prefs.edit().putLong(KEY_DISMISSED, value).apply()

    companion object {
        private const val KEY_LAST_CHECK = "last_check_ms"
        private const val KEY_DISMISSED = "dismissed_version"

        fun of(context: Context) = SharedUpdatePrefs(context.getSharedPreferences("updates", Context.MODE_PRIVATE))
    }
}

/** 应用商店的包没有应用内更新：去商店的详情页（国内各商店都认 market://），没有商店就去官网下载页。 */
object StoreLinks {
    const val DOWNLOAD_PAGE = "https://thinktin.cn/download"

    fun openStore(context: Context) {
        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(market)
        } catch (_: ActivityNotFoundException) {
            openDownloadPage(context)
        }
    }

    fun openDownloadPage(context: Context) {
        val web = Intent(Intent.ACTION_VIEW, Uri.parse(DOWNLOAD_PAGE)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(web) }
    }
}
