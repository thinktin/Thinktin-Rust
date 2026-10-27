package cn.thinktin.app.settings

import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat

/**
 * App 的界面语言（13.13）：交给系统的“应用语言”（Android 13 起系统设置里也能改；更早的由 AppCompat 记下，清单里的
 * `AppLocalesMetadataHolderService`）。设置里选了之后 Activity 重建，界面换语言；同时存进 [AppSettings.language]，
 * 请求的 Accept-Language 和服务端记的语言（推送、收件箱用）跟着变（[cn.thinktin.app.AppContainer]）。
 */
object AppLocales {
    fun apply(language: AppLanguage) {
        val tag = language.tag
        AppCompatDelegate.setApplicationLocales(
            if (tag == null) LocaleListCompat.getEmptyLocaleList() else LocaleListCompat.forLanguageTags(tag),
        )
    }

    /** 系统里现在的应用语言（用户可能在系统设置里改过）；没设过是跟随系统。 */
    fun current(): AppLanguage = fromTag(AppCompatDelegate.getApplicationLocales().toLanguageTags())

    /** `zh-CN`、`zh-Hans-CN` → 中文，`en-US` → English，空的、别的语言 → 跟随系统。 */
    fun fromTag(tags: String): AppLanguage {
        val first = tags.split(',').firstOrNull()?.trim().orEmpty()
        val language = first.substringBefore('-').substringBefore('_')
        return when {
            language.equals("zh", ignoreCase = true) -> AppLanguage.Chinese
            language.equals("en", ignoreCase = true) -> AppLanguage.English
            else -> AppLanguage.System
        }
    }
}
