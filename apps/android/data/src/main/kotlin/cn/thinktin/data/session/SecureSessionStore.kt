package cn.thinktin.data.session

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import cn.thinktin.core.Session
import cn.thinktin.core.SessionStore
import java.security.KeyStore

/**
 * client-core 的 [SessionStore]：登录令牌存在 EncryptedSharedPreferences 里（Keystore 里的 AES256-GCM 主密钥）。
 * `save(null)`（退出登录、会话失效、被远程下线）时清空。client-core 会在后台线程调用，这里的读写都是同步的。
 *
 * 不向 client-core 抛异常（回调里抛出的异常会被 UniFFI 当成内部错误，而不是“未登录”）：
 * - 打开时 Keystore 失效或文件损坏（换了锁屏、系统升级、备份恢复……）：删掉偏好文件和主密钥重建一次，
 *   还不行就退回只在内存里的存储（这次进程内能登录，重启后要重新登录）；
 * - 读的时候解密失败：清空，按未登录处理；
 * - 写失败：记日志（下次启动按未登录处理）。
 *
 * @param prefs 为 null 时只存在内存里（[persistent] 为假）。
 */
class SecureSessionStore internal constructor(private val prefs: SharedPreferences?) : SessionStore {

    constructor(context: Context) : this(openPrefsOrNull(context.applicationContext))

    @Volatile
    private var memory: Session? = null

    /** 令牌能落盘（加密偏好可用）。 */
    val persistent: Boolean get() = prefs != null

    @SuppressLint("ApplySharedPref") // 清掉读不出的令牌要立即落盘，同 save。
    override fun load(): Session? {
        val prefs = prefs ?: return memory
        return try {
            read(prefs)
        } catch (e: Exception) {
            // 解密失败（SecurityException 等）：这些令牌已经读不出来了，清掉按未登录处理。
            Log.w(TAG, "读取登录令牌失败，清空后按未登录处理", e)
            try {
                prefs.edit().clear().commit()
            } catch (cleanup: Exception) {
                Log.w(TAG, "清空登录令牌失败", cleanup)
            }
            null
        }
    }

    @SuppressLint("ApplySharedPref") // 必须同步落盘，见下面的注释。
    override fun save(session: Session?) {
        val prefs = prefs ?: run {
            memory = session
            return
        }
        val saved = try {
            val editor = prefs.edit()
            if (session == null) {
                editor.clear()
            } else {
                editor.putString(KEY_USER_ID, session.userId)
                    .putString(KEY_DEVICE_ID, session.deviceId)
                    .putString(KEY_ACCESS_TOKEN, session.accessToken)
                    .putString(KEY_REFRESH_TOKEN, session.refreshToken)
            }
            // commit：client-core 返回前令牌必须已经落盘（刷新令牌只能用一次）。
            editor.commit()
        } catch (e: Exception) {
            Log.w(TAG, "保存登录令牌失败", e)
            false
        }
        if (!saved) Log.w(TAG, "登录令牌没有写进磁盘（commit 返回 false），下次启动需要重新登录")
    }

    private fun read(prefs: SharedPreferences): Session? {
        val userId = prefs.getString(KEY_USER_ID, null) ?: return null
        val deviceId = prefs.getString(KEY_DEVICE_ID, null) ?: return null
        val access = prefs.getString(KEY_ACCESS_TOKEN, null) ?: return null
        val refresh = prefs.getString(KEY_REFRESH_TOKEN, null) ?: return null
        return Session(userId = userId, deviceId = deviceId, accessToken = access, refreshToken = refresh)
    }

    companion object {
        private const val TAG = "SecureSessionStore"
        internal const val FILE_NAME = "thinktin_session"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"

        /** 打开加密偏好；失败时删掉文件和主密钥重建一次，还失败返回 null（退回内存存储）。 */
        internal fun openPrefsOrNull(
            context: Context,
            open: (Context) -> SharedPreferences = ::openPrefs,
            reset: (Context) -> Unit = ::resetPrefs,
        ): SharedPreferences? {
            try {
                return open(context)
            } catch (e: Exception) {
                // GeneralSecurityException（Keystore 失效）、IOException（文件损坏）、
                // 以及 Tink 包成 RuntimeException / SecurityException 的同类错误。
                Log.w(TAG, "打开加密偏好失败，删掉重建", e)
            }
            return try {
                reset(context)
                open(context)
            } catch (e: Exception) {
                Log.e(TAG, "重建加密偏好仍然失败，登录令牌只保存在内存里", e)
                null
            }
        }

        private fun openPrefs(context: Context): SharedPreferences {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                context,
                FILE_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }

        /** 删掉偏好文件（里面也存着加密用的 keyset）和 Keystore 里的主密钥。 */
        private fun resetPrefs(context: Context) {
            context.deleteSharedPreferences(FILE_NAME)
            try {
                KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    .deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
            } catch (e: Exception) {
                Log.w(TAG, "删除主密钥失败", e)
            }
        }
    }
}
