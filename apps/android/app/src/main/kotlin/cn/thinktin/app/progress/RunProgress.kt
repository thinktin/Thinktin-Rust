package cn.thinktin.app.progress

import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.WaitCode
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * 常驻通知里显示的（13.10）：只有实例名、状态、步数、开始时间、等待原因的码。锁屏上谁都看得见，不放运行的任务、摘要这些
 * agent 或用户写的文字（和 iOS 的实时活动一样，docs/live-activities.md）。
 */
data class RunProgress(
    val runId: String,
    val instanceId: String,
    /** 实例名。 */
    val title: String,
    val state: RunState,
    /** 已经走了几步（这个运行的工具调用）。 */
    val steps: Int,
    val startedAtMs: Long?,
    val waitCode: WaitCode?,
) {
    val isFinished: Boolean get() = state.isTerminal

    /**
     * 按事件更新：`run.state` 换状态和等待原因（开始跑时记下开始时间），这个运行的工具调用（`agent.tool_call`）步数加一。别的运行、别的事件不动。
     */
    fun apply(event: InstanceEvent): RunProgress {
        if (event.runId != runId) return this
        return when (event.kind) {
            EventKinds.RUN_STATE -> {
                val state = (event.payload["state"] as? JsonPrimitive)?.contentOrNull?.let(RunState::fromWire) ?: return this
                val wait = (event.payload["wait_code"] as? JsonPrimitive)?.contentOrNull?.let(WaitCode::fromWire)
                copy(
                    state = state,
                    waitCode = wait,
                    startedAtMs = startedAtMs ?: event.createdAtMs.takeIf { state == RunState.Running || state == RunState.WaitingChildren },
                )
            }
            EventKinds.AGENT_TOOL_CALL -> copy(steps = steps + 1)
            else -> this
        }
    }

    companion object {
        /** 从运行和缓存里这个运行的事件算起。 */
        fun of(run: Run, title: String, cached: List<InstanceEvent> = emptyList()): RunProgress = cached.sortedBy { it.seq }.fold(
            RunProgress(
                runId = run.id, instanceId = run.instanceId, title = title, state = run.state, steps = 0,
                startedAtMs = run.startedAtMs, waitCode = run.waitCode,
            ),
        ) { progress, event ->
            if (run.state.isTerminal && event.kind == EventKinds.RUN_STATE) progress else progress.apply(event)
        }
    }
}
