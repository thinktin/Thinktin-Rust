package cn.thinktin.app.ui.common

import cn.thinktin.app.R
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.WaitCode

/**
 * 运行在等什么 → 界面文案（[Run.waitCode]，11.8）。不认识的码和没有码时返回 null：按运行状态显示。
 */
object WaitText {
    fun of(code: WaitCode?): UiText? = when (code) {
        WaitCode.Invalid -> UiText(R.string.wait_invalid_key)
        WaitCode.NoBalance -> UiText(R.string.wait_no_balance)
        WaitCode.Unavailable -> UiText(R.string.wait_key_unavailable)
        WaitCode.RateLimited -> UiText(R.string.wait_rate_limited)
        WaitCode.Overloaded -> UiText(R.string.wait_overloaded)
        WaitCode.DeviceOffline -> UiText(R.string.wait_device_offline)
        WaitCode.Unknown, null -> null
    }

    fun of(run: Run): UiText? = of(run.waitCode)
}
