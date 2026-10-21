package cn.thinktin.data.session

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import cn.thinktin.core.Session
import cn.thinktin.core.SessionStore

/**
 * client-core 的 [SessionStore]：登录令牌存在 EncryptedSharedPreferences 里（Keystore 里的 AES256-GCM 主密钥）。
 * `save(null)`（退出登录、会话失效、被远程下线）时清空。client-core 会在后台线程调用，这里的读写都是同步的。
 */
class SecureSessionStore internal constructor(private val prefs: SharedPreferences) : SessionStore {

    constructor(context: Context) : this(openPrefs(context.applicationContext))

    override fun load(): Session? {
        val userId = prefs.getString(KEY_USER_ID, null) ?: return null
        val deviceId = prefs.getString(KEY_DEVICE_ID, null) ?: return null
        val access = prefs.getString(KEY_ACCESS_TOKEN, null) ?: return null
        val refresh = prefs.getString(KEY_REFRESH_TOKEN, null) ?: return null
        return Session(userId = userId, deviceId = deviceId, accessToken = access, refreshToken = refresh)
    }

    override fun save(session: Session?) {
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
    }

    companion object {
        private const val FILE_NAME = "thinktin_session"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"

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
    }
}
