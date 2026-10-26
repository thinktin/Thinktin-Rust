package cn.thinktin.app.progress

import android.util.Log
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 运行进度的常驻通知（13.10）：在对话里发起的运行（设置里能关）、在运行页上点了“在通知栏显示进度”的运行，发一条常驻通知，
 * App 进程在时按实例的事件流更新（状态、步数、等待原因），运行结束就撤掉（结果另有推送和收件箱）。
 *
 * 后台按推送更新：安卓没有 iOS 实时活动那样的进度推送（服务端只给 iPhone / iPad 发，docs/live-activities.md），进程被回收后
 * 通知停在最后的状态，计时器照走、8 小时后系统撤掉；运行结束的推送（推送 SDK 接上后）到了时由 [onRunFinished] 撤掉。
 *
 * 同时最多跟 [MAX_TRACKED] 个运行；退出登录时全部撤掉（[stopAll]）。
 */
class RunProgressTracker(
    private val scope: CoroutineScope,
    private val notifier: ProgressNotifier,
) {
    private val jobs = mutableMapOf<String, Job>()
    private val lock = Any()
    private val trackedRuns = MutableStateFlow<Set<String>>(emptySet())

    /** 正在跟的运行（运行页上的开关看它）。 */
    val tracked: StateFlow<Set<String>> = trackedRuns.asStateFlow()

    /**
     * 开始跟一个运行：先发一条，再订阅它所在实例的事件流。已经在跟的、已经结束的不管；没有通知权限时什么都不做。
     * [title] 是实例名。
     */
    fun track(service: ThinktinService, run: Run, title: String) {
        if (!run.state.isActive) return
        synchronized(lock) {
            if (run.id in jobs || jobs.size >= MAX_TRACKED) return
            jobs[run.id] = scope.launch { follow(service, run, title) }
            trackedRuns.update { it + run.id }
        }
    }

    private suspend fun follow(service: ThinktinService, run: Run, title: String) {
        try {
            val cached = try {
                service.cachedEventsBefore(run.instanceId, null, CACHED_EVENTS).filter { it.runId == run.id }
            } catch (_: ServiceError) {
                emptyList()
            }
            var progress = RunProgress.of(run, title, cached)
            if (!notifier.show(progress)) return
            // 收到运行结束、或者事件流以终止状态结束时停下。
            service.events(run.instanceId).firstOrNull { item ->
                when (item) {
                    is EventStreamItem.Status -> item.state.isFinal()
                    is EventStreamItem.Event -> {
                        val next = progress.apply(item.event)
                        if (next != progress) {
                            progress = next
                            if (next.isFinished) notifier.cancel(run.id) else notifier.show(next)
                        }
                        next.isFinished
                    }
                    is EventStreamItem.Reset -> false
                }
            }
        } catch (e: ServiceError) {
            // 订阅失败（断网、登录失效）：通知停在最后的状态，计时器照走。
            Log.w(TAG, "运行进度停止更新", e)
        } finally {
            synchronized(lock) { jobs.remove(run.id) }
            trackedRuns.update { it - run.id }
        }
    }

    /** 不再跟（运行页上关掉）：撤掉通知。 */
    fun stop(runId: String) {
        val job = synchronized(lock) { jobs.remove(runId) }
        job?.cancel()
        trackedRuns.update { it - runId }
        notifier.cancel(runId)
    }

    /** 运行结束的推送到了（或者别处知道它结束了）：撤掉。 */
    fun onRunFinished(runId: String) = stop(runId)

    /** 退出登录、换演示模式：全部撤掉。 */
    fun stopAll() {
        val ids = synchronized(lock) { jobs.keys.toList() }
        ids.forEach(::stop)
    }

    private fun StreamState.isFinal(): Boolean =
        this == StreamState.NotFound || this == StreamState.SignedOut || this == StreamState.AccountFrozen ||
            this == StreamState.UpgradeRequired || this == StreamState.Stopped

    companion object {
        private const val TAG = "RunProgress"
        const val MAX_TRACKED = 5
        private const val CACHED_EVENTS = 500
    }
}
