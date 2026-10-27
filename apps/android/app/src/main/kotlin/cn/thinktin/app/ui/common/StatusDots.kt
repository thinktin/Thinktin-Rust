package cn.thinktin.app.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.RunState
import cn.thinktin.design.component.StatusDot
import cn.thinktin.design.component.StatusTone

/** 实例状态 → 状态点色调（第 8.1 节）：创建中灰闪、运行中绿、已暂停灰、已归档空心；已删除不显示（null）。 */
fun InstanceState.tone(): StatusTone? = when (this) {
    InstanceState.Provisioning -> StatusTone.Starting
    InstanceState.Running -> StatusTone.Online
    InstanceState.Paused -> StatusTone.Idle
    InstanceState.Archived -> StatusTone.Archived
    InstanceState.Deleted -> null
    InstanceState.Unknown -> StatusTone.Unknown
}

/** 运行状态 → 色调：运行中主色闪烁、等待用户处理警告色、成功绿、失败红、其余灰。 */
fun RunState.tone(): StatusTone = when (this) {
    RunState.Queued, RunState.Starting -> StatusTone.Starting
    RunState.Running -> StatusTone.Working
    RunState.WaitingApproval, RunState.WaitingDevice, RunState.WaitingQuota, RunState.Backoff -> StatusTone.Attention
    RunState.WaitingChildren -> StatusTone.Waiting
    RunState.Succeeded -> StatusTone.Success
    RunState.Failed -> StatusTone.Failure
    RunState.Cancelled -> StatusTone.Idle
    RunState.Unknown -> StatusTone.Unknown
}

/** 实例状态点；已删除的实例不画。 */
@Composable
fun StatusDot(state: InstanceState, modifier: Modifier = Modifier, contentDescription: String? = null) {
    val tone = state.tone() ?: return
    StatusDot(tone, modifier, contentDescription)
}

/** 运行状态点。 */
@Composable
fun StatusDot(state: RunState, modifier: Modifier = Modifier, contentDescription: String? = null) {
    StatusDot(state.tone(), modifier, contentDescription)
}
