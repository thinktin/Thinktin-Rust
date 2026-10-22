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
) {
    val settings: Flow<AppSettings> = store.data
        .catch { e -> if (e is IOException) emit(emptyPreferences()) else throw e }
        .map { prefs ->
            AppSettings(
                language = prefs[KEY_LANGUAGE].toEnum(AppLanguage.System),
                appearance = prefs[KEY_APPEARANCE].toEnum(Appearance.System),
                demoMode = prefs[KEY_DEMO] ?: demoDefault,
            )
        }

    suspend fun setLanguage(language: AppLanguage) {
        store.edit { it[KEY_LANGUAGE] = language.name }
    }

    suspend fun setAppearance(appearance: Appearance) {
        store.edit { it[KEY_APPEARANCE] = appearance.name }
    }

    suspend fun setDemoMode(enabled: Boolean) {
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
