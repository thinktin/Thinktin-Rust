package cn.thinktin.app.ui.common

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 每秒减一的倒计时（重发验证码的 60 秒、限频的剩余秒数）。在 [scope]（ViewModel 的 viewModelScope）里跑，
 * 测试里用 kotlinx-coroutines-test 的 TestCoroutineScheduler 推进虚拟时间。[onTick] 收到剩余秒数，最后一次是 0。
 */
class Countdown(private val scope: CoroutineScope, private val onTick: (Int) -> Unit) {
    private var job: Job? = null

    fun start(seconds: Int) {
        job?.cancel()
        onTick(seconds.coerceAtLeast(0))
        if (seconds <= 0) return
        job = scope.launch {
            var left = seconds
            while (left > 0) {
                delay(TICK_MS)
                left--
                onTick(left)
            }
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
        onTick(0)
    }

    companion object {
        const val TICK_MS: Long = 1_000
    }
}
