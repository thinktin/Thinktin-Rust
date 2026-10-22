package cn.thinktin.app.ui.common

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import cn.thinktin.app.R
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale

/**
 * token 数的显示（设计规范第 5 节）：一万以下用千分位（9,999）；一万起中文写“1.2 万”“3.4 亿”，英文写“12k”“1.2M”。
 * 写法（万 / k）由资源 `number_style` 决定（values 是 cjk，values-en 是 western），跟着 App 的语言走；
 * 单位的文字也在资源里（[Unit.pattern]）。
 */
object TokenFormat {
    enum class Style {
        /** 万、亿。 */
        Cjk,

        /** k、M、B。 */
        Western,
    }

    enum class Unit(val divisor: Long, @StringRes val pattern: Int) {
        TenThousand(10_000, R.string.number_ten_thousand),
        HundredMillion(100_000_000, R.string.number_hundred_million),
        Thousand(1_000, R.string.number_thousand),
        Million(1_000_000, R.string.number_million),
        Billion(1_000_000_000, R.string.number_billion),
    }

    /** 千分位（12,345）。 */
    fun grouped(value: Long): String = String.format(Locale.US, "%,d", value)

    /** 选单位：一万以下不用单位。 */
    fun unitOf(value: Long, style: Style): Unit? {
        val v = if (value < 0) -value else value
        if (v < 10_000) return null
        return when (style) {
            Style.Cjk -> if (v < 100_000_000) Unit.TenThousand else Unit.HundredMillion
            Style.Western -> when {
                v < 1_000_000 -> Unit.Thousand
                v < 1_000_000_000 -> Unit.Million
                else -> Unit.Billion
            }
        }
    }

    /**
     * 格式化：[unitText] 把“数字 + 单位”拼成文字（界面上用资源里的格式，测试里直接拼）。
     */
    fun format(value: Long, style: Style, unitText: (Unit, String) -> String): String {
        val unit = unitOf(value, style) ?: return grouped(value)
        val sign = if (value < 0) "-" else ""
        return sign + unitText(unit, scaled(if (value < 0) -value else value, unit.divisor))
    }

    /** value / unit：小于 100 时留一位小数（去掉末尾的 .0），否则取整；四舍五入。 */
    fun scaled(value: Long, unit: Long): String {
        val exact = BigDecimal.valueOf(value).divide(BigDecimal.valueOf(unit))
        val digits = if (exact < BigDecimal.valueOf(100)) 1 else 0
        val rounded = exact.setScale(digits, RoundingMode.HALF_UP).stripTrailingZeros()
        return if (rounded.scale() <= 0) grouped(rounded.toBigInteger().toLong()) else rounded.toPlainString()
    }

    fun styleOf(wire: String): Style = if (wire == "western") Style.Western else Style.Cjk
}

/** 按当前语言格式化 token 数。 */
@Composable
fun formatTokens(value: Long): String {
    val style = TokenFormat.styleOf(stringResource(R.string.number_style))
    val unit = TokenFormat.unitOf(value, style) ?: return TokenFormat.grouped(value)
    val pattern = stringResource(unit.pattern)
    return TokenFormat.format(value, style) { _, number -> String.format(Locale.ROOT, pattern, number) }
}
