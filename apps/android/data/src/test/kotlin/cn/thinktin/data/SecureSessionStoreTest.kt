package cn.thinktin.data

import android.content.ContextWrapper
import android.content.SharedPreferences
import cn.thinktin.core.Session
import cn.thinktin.data.core.ClientFactory
import cn.thinktin.data.session.SecureSessionStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.GeneralSecurityException

class SecureSessionStoreTest {
    private val session = Session(userId = "u1", deviceId = "d1", accessToken = "at", refreshToken = "rt")

    @Test
    fun saveThenLoadRoundTrips() {
        val prefs = FakeSharedPreferences()
        val store = SecureSessionStore(prefs)
        assertTrue(store.persistent)
        assertNull(store.load())
        store.save(session)
        assertEquals(session, store.load())
        // 新实例（下次启动）读到同样的内容。
        assertEquals(session, SecureSessionStore(prefs).load())
    }

    @Test
    fun saveNullClears() {
        val prefs = FakeSharedPreferences()
        val store = SecureSessionStore(prefs)
        store.save(session)
        store.save(null)
        assertNull(store.load())
        assertTrue(prefs.values.isEmpty())
    }

    @Test
    fun partialSessionIsSignedOut() {
        val prefs = FakeSharedPreferences()
        prefs.values += mapOf("user_id" to "u1", "device_id" to "d1", "access_token" to "at")
        assertNull(SecureSessionStore(prefs).load())
    }

    @Test
    fun unreadablePrefsAreClearedInsteadOfThrowing() {
        val prefs = FakeSharedPreferences()
        SecureSessionStore(prefs).save(session)
        prefs.failReads = true
        val store = SecureSessionStore(prefs)
        // 解密失败不能抛给 client-core：按未登录处理，并清掉坏数据。
        assertNull(store.load())
        assertTrue(prefs.values.isEmpty())
    }

    @Test
    fun failedCommitDoesNotThrow() {
        val prefs = FakeSharedPreferences(commitResult = false)
        SecureSessionStore(prefs).save(session)
        val throwing = FakeSharedPreferences(failWrites = true)
        SecureSessionStore(throwing).save(session)
    }

    @Test
    fun memoryFallbackWhenPrefsUnavailable() {
        val store = SecureSessionStore(prefs = null)
        assertFalse(store.persistent)
        assertNull(store.load())
        store.save(session)
        assertEquals(session, store.load())
        store.save(null)
        assertNull(store.load())
    }

    @Test
    fun openRetriesOnceAfterReset() {
        val context = ContextWrapper(null)
        val good = FakeSharedPreferences()
        var opens = 0
        var resets = 0
        val opened = SecureSessionStore.openPrefsOrNull(
            context,
            open = { if (opens++ == 0) throw GeneralSecurityException("keystore gone") else good },
            reset = { resets++ },
        )
        assertSame(good, opened)
        assertEquals(2, opens)
        assertEquals(1, resets)

        val failed = SecureSessionStore.openPrefsOrNull(
            context,
            open = { throw SecurityException("still broken") },
            reset = { resets++ },
        )
        assertNull(failed)
        assertEquals(2, resets)
    }

    @Test
    fun clientConfigFollowsSpec() {
        val dir = File("/data/user/0/cn.thinktin.app/files")
        val config = ClientFactory.config(dir, "https://api.example.com", deviceName = "Pixel 8")
        assertEquals("https://api.example.com", config.baseUrl)
        assertEquals("android", config.platform)
        assertEquals(File(dir, "thinktin.db").absolutePath, config.cachePath)
        assertEquals("Pixel 8", config.deviceName)
        assertEquals(30u, config.timeoutSecs)
        assertTrue(ClientFactory.defaultDeviceName().isNotBlank())
    }
}

/** 内存里的 SharedPreferences；[failReads] 模拟解密失败，[failWrites] / [commitResult] 模拟写盘失败。 */
private class FakeSharedPreferences(
    private val commitResult: Boolean = true,
    private val failWrites: Boolean = false,
) : SharedPreferences {
    val values = mutableMapOf<String, Any?>()
    var failReads = false

    private fun checkRead() {
        if (failReads) throw SecurityException("Could not decrypt value")
    }

    override fun getAll(): Map<String, *> = values.toMap().also { checkRead() }
    override fun getString(key: String, defValue: String?): String? {
        checkRead()
        return values[key] as String? ?: defValue
    }
    override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? = defValues
    override fun getInt(key: String, defValue: Int): Int = defValue
    override fun getLong(key: String, defValue: Long): Long = defValue
    override fun getFloat(key: String, defValue: Float): Float = defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = defValue
    override fun contains(key: String): Boolean = key in values
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) = Unit

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private var clear = false

        override fun putString(key: String, value: String?) = apply { pending[key] = value }
        override fun putStringSet(key: String, values: Set<String>?) = apply { pending[key] = values }
        override fun putInt(key: String, value: Int) = apply { pending[key] = value }
        override fun putLong(key: String, value: Long) = apply { pending[key] = value }
        override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        override fun remove(key: String) = apply { pending[key] = null }
        override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            if (failWrites) throw IllegalStateException("disk full")
            if (!commitResult) return false
            if (clear) values.clear()
            pending.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
            return true
        }

        override fun apply() {
            commit()
        }
    }
}
