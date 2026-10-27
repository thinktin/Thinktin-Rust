package cn.thinktin.app.ui.login

import androidx.annotation.StringRes
import cn.thinktin.app.R

/**
 * 登录页的国家 / 地区码（第 4.1 节：默认 +86，常用几个）。
 *
 * 服务端把手机号规范成 E.164（`+` 加 8 到 15 位数字，crates/auth 的 normalize_phone），这里先按各地的位数粗查一遍，
 * 输错时当场提示，不必等一次网络往返；真正的校验以服务端为准（它报 invalid 时同样显示在输入框下面）。
 *
 * @param dialCode 国际区号（不带 +）。
 * @param lengths 本地号码允许的位数。
 * @param prefixes 本地号码允许的开头（空表示不限）。
 */
enum class PhoneRegion(
    val dialCode: String,
    @StringRes val labelRes: Int,
    val lengths: IntRange,
    val prefixes: List<String> = emptyList(),
) {
    /** 中国大陆：11 位，1 开头。 */
    ChinaMainland("86", R.string.region_cn, 11..11, listOf("1")),
    HongKong("852", R.string.region_hk, 8..8, listOf("4", "5", "6", "7", "8", "9")),
    Macau("853", R.string.region_mo, 8..8, listOf("6")),
    Taiwan("886", R.string.region_tw, 9..9, listOf("9")),
    Singapore("65", R.string.region_sg, 8..8, listOf("8", "9")),
    Japan("81", R.string.region_jp, 10..10),
    UnitedStates("1", R.string.region_us, 10..10),
    UnitedKingdom("44", R.string.region_gb, 10..10, listOf("7")),
    ;

    /** 用户输入里的本地号码：只留数字（去掉空格、横线等），再去掉一个国内长途前缀 0（`0912…` → `912…`）。 */
    fun digits(input: String): String = input.filter(Char::isDigit).removePrefix("0")

    /** 号码格式对不对（只看位数和开头）。 */
    fun isValid(input: String): Boolean {
        val digits = digits(input)
        if (digits.length !in lengths) return false
        return prefixes.isEmpty() || prefixes.any { digits.startsWith(it) }
    }

    /** 交给服务端的 E.164（`+8613800138000`）。 */
    fun e164(input: String): String = "+$dialCode${digits(input)}"

    /** 页面上显示的号码（`+86 13800138000`）。 */
    fun display(input: String): String = "+$dialCode ${digits(input)}"

    companion object {
        val Default: PhoneRegion = ChinaMainland

        /** 输入框最多收多少位数字：各地号码里最长的，加一位长途前缀 0（再多就是输错了）。 */
        val MAX_INPUT_DIGITS: Int = entries.maxOf { it.lengths.last } + 1
    }
}
