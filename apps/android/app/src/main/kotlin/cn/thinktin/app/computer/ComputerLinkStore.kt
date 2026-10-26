package cn.thinktin.app.computer

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import cn.thinktin.data.model.ComputerLinkState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** 存 [ComputerLinkState] 的地方：App 里是 SharedPreferences，测试里是内存。存的是 JSON 文本。 */
interface ComputerLinkStorage {
    fun read(key: String): String?

    fun write(key: String, value: String)
}

class InMemoryComputerLinkStorage : ComputerLinkStorage {
    private val values = HashMap<String, String>()

    @Synchronized
    override fun read(key: String): String? = values[key]

    @Synchronized
    override fun write(key: String, value: String) {
        values[key] = value
    }
}

/** 本机的 SharedPreferences（不随备份、迁移走：见 `res/xml/data_extraction_rules.xml`，换了手机要重新配对）。 */
class SharedPrefsComputerLinkStorage(private val prefs: SharedPreferences) : ComputerLinkStorage {
    override fun read(key: String): String? = prefs.getString(key, null)

    override fun write(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    companion object {
        const val FILE = "computer_link"

        fun of(context: Context) = SharedPrefsComputerLinkStorage(context.getSharedPreferences(FILE, Context.MODE_PRIVATE))
    }
}

/**
 * 手机和电脑之间的状态（13.9），App 里只有一份（[cn.thinktin.app.AppContainer.computerLinks]）：设备页、审批中心各自的
 * 视图模型都改这一份，不会拿着旧的互相覆盖。改了马上存，按账号分开：同一台手机换了账号，看不到上一个账号的电脑。
 */
class ComputerLinkStore(private val storage: ComputerLinkStorage) {
    private val flows = HashMap<String, MutableStateFlow<ComputerLinkState>>()
    private val lock = Any()

    fun state(userId: String): StateFlow<ComputerLinkState> = flow(userId).asStateFlow()

    /** 改一下并存起来；[transform] 在锁里跑，要快、不能挂起。返回改完的。 */
    fun update(userId: String, transform: (ComputerLinkState) -> ComputerLinkState): ComputerLinkState =
        synchronized(lock) {
            val flow = flow(userId)
            val next = transform(flow.value)
            if (next != flow.value) {
                flow.value = next
                storage.write(key(userId), json.encodeToString(ComputerLinkState.serializer(), next))
            }
            next
        }

    private fun flow(userId: String): MutableStateFlow<ComputerLinkState> = synchronized(lock) {
        flows.getOrPut(userId) { MutableStateFlow(load(userId)) }
    }

    private fun load(userId: String): ComputerLinkState {
        val text = storage.read(key(userId)) ?: return ComputerLinkState()
        return try {
            json.decodeFromString(ComputerLinkState.serializer(), text)
        } catch (e: SerializationException) {
            // 存坏了（或者是以后的版本存的）：当成没配过，重新配对。
            Log.w(TAG, "computer link state unreadable", e)
            ComputerLinkState()
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "computer link state unreadable", e)
            ComputerLinkState()
        }
    }

    companion object {
        private const val TAG = "ComputerLinkStore"
        private val json = Json { ignoreUnknownKeys = true }

        fun key(userId: String) = "computerLink.$userId"
    }
}
