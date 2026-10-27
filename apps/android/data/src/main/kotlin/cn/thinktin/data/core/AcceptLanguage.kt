package cn.thinktin.data.core

import android.os.LocaleList
import cn.thinktin.core.acceptLanguageHeader

/**
 * 请求头 `Accept-Language`（11.8）：服务端按它给 agent 介绍、许可说明的语言，新用户注册时按它定推送和收件箱的语言。
 *
 * 语言列表在这里拼（Android 的 [LocaleList]，App 里选的语言放最前），拼成请求头交给 client-core 的
 * `accept_language_header`（q 值、个数上限、过滤非法标签都在 Rust 里，iOS 共用一套）。
 */
object AcceptLanguage {
    /**
     * 按偏好排好的语言标签：[appLanguage]（App 设置里选的，BCP 47；跟随系统时为 null）在前，再接系统的语言列表；
     * 去重（不分大小写），去掉空的和 `und`。
     */
    fun tags(appLanguage: String?, system: LocaleList = LocaleList.getDefault()): List<String> =
        merge(appLanguage, system.toLanguageTags().split(','))

    /** [tags] 的纯逻辑部分（JVM 测试用）。 */
    internal fun merge(appLanguage: String?, systemTags: List<String>): List<String> {
        val seen = HashSet<String>()
        return (listOfNotNull(appLanguage) + systemTags)
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.equals("und", ignoreCase = true) }
            .filter { seen.add(it.lowercase()) }
    }

    /** 拼成请求头（`zh-CN, en-US;q=0.9`）；没有可用的标签时为 null（不带这个头）。会调 client-core（加载 .so）。 */
    fun header(tags: List<String>): String? =
        if (tags.isEmpty()) null else acceptLanguageHeader(tags).takeIf { it.isNotBlank() }
}
