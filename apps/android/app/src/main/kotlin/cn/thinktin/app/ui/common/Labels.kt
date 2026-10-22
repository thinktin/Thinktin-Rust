package cn.thinktin.app.ui.common

import androidx.annotation.StringRes
import cn.thinktin.app.R
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.RunState

/** 状态的显示文字（第 8.1 节）。 */
@StringRes
fun InstanceState.labelRes(): Int = when (this) {
    InstanceState.Provisioning -> R.string.instance_state_provisioning
    InstanceState.Running -> R.string.instance_state_running
    InstanceState.Paused -> R.string.instance_state_paused
    InstanceState.Archived -> R.string.instance_state_archived
    InstanceState.Deleted -> R.string.instance_state_deleted
    InstanceState.Unknown -> R.string.instance_state_unknown
}

@StringRes
fun RunState.labelRes(): Int = when (this) {
    RunState.Queued -> R.string.run_state_queued
    RunState.Starting -> R.string.run_state_starting
    RunState.Running -> R.string.run_state_running
    RunState.WaitingApproval -> R.string.run_state_waiting_approval
    RunState.WaitingDevice -> R.string.run_state_waiting_device
    RunState.WaitingQuota -> R.string.run_state_waiting_quota
    RunState.WaitingChildren -> R.string.run_state_waiting_children
    RunState.Backoff -> R.string.run_state_backoff
    RunState.Succeeded -> R.string.run_state_succeeded
    RunState.Failed -> R.string.run_state_failed
    RunState.Cancelled -> R.string.run_state_cancelled
    RunState.Unknown -> R.string.run_state_unknown
}
