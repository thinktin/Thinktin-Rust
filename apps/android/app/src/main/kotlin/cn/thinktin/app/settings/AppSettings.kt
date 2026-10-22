package cn.thinktin.app.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import cn.thinktin.design.theme.Appearance
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.io.IOException

/** App 语言：跟随系统 / 中文 / English（[tag] 是 BCP 47，也是 set_locale 的取值）。 */
enum class AppLanguage(val tag: String?) {
    System(null),
    Chinese("zh-CN"),
    English("en"),
}

/**
 * 告诉服务端的语言（`set_locale` 只认 zh-CN / en；推送、收件箱用它）：选了语言就用选的，
 * 跟随系统时看系统首选语言（[systemLanguage] 是 ISO 639 语言码，比如 zh、en、ja），中文以外一律 en。
 */
fun AppLanguage.serverLocale(systemLanguage: String): String =
    tag ?: if (systemLanguage.equals("zh", ignoreCase = true)) "zh-CN" else "en"

/** 界面偏好（存在 DataStore，不进服务端）。 */
data class AppSettings(
    val language: AppLanguage = AppLanguage.System,
    val appearance: Appearance = Appearance.System,
    /** 演示模式：用 Mock 数据，不联网。 */
    val demoMode: Boolean,
)

class AppSettingsRepository(
    private val store: DataStore<Preferences>,
    /** 没设置过演示模式时的默认值（debug 为 true）。 */
    private val demoDefault: Boolean,
    /**
     * 允许演示模式（只有 debug 包，第 7 节）。为假时演示模式恒为关：即使存过 demo_mode=true（比如从 debug 包
     * 覆盖安装成 release）也忽略，release 用户不会困在演示数据里。
     */
    val demoAllowed: Boolean = true,
) {
    val settings: Flow<AppSettings> = store.data
        .catch { e -> if (e is IOException) emit(emptyPreferences()) else throw e }
        .map { prefs ->
            AppSettings(
                language = prefs[KEY_LANGUAGE].toEnum(AppLanguage.System),
                appearance = prefs[KEY_APPEARANCE].toEnum(Appearance.System),
                demoMode = demoAllowed && (prefs[KEY_DEMO] ?: demoDefault),
            )
        }

    suspend fun setLanguage(language: AppLanguage) {
        store.edit { it[KEY_LANGUAGE] = language.name }
    }

    suspend fun setAppearance(appearance: Appearance) {
        store.edit { it[KEY_APPEARANCE] = appearance.name }
    }

    suspend fun setDemoMode(enabled: Boolean) {
        if (enabled && !demoAllowed) return
        store.edit { it[KEY_DEMO] = enabled }
    }

    private companion object {
        val KEY_LANGUAGE = stringPreferencesKey("language")
        val KEY_APPEARANCE = stringPreferencesKey("appearance")
        val KEY_DEMO = booleanPreferencesKey("demo_mode")

        inline fun <reified E : Enum<E>> String?.toEnum(default: E): E =
            enumValues<E>().firstOrNull { it.name == this } ?: default
    }
}
