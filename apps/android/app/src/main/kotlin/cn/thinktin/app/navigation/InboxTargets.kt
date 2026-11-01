package cn.thinktin.app.navigation

import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxKind

/**
 * 收件箱条目点进去去哪（第 4.8 节“点击跳转”；收件箱页面在 13.8，先把跳转规则定下来）：
 * - 审批：审批详情 `approval/{id}`（13.16；已处理、过期的在详情里显示结果）；没有审批 id 的去审批中心；
 * - 保险箱填写请求：`vault?requestId=…`；
 * - 计划待确认：计划详情；
 * - 运行完成 / 失败、其他提醒：有运行去运行详情，有计划去计划，有实例去对话；IM 渠道被停用的提醒（子类型
 *   `im_channel_disabled`）去 IM 渠道设置（13.15，和 iOS 一样）；
 * - 电脑审批去审批中心处理。
 * 返回 null 表示没有可去的页面（只标已读）。
 */
fun InboxItem.targetRoute(): String? = when (kind) {
    InboxKind.Approval -> approvalId?.let(Routes::approval) ?: Routes.APPROVALS
    InboxKind.VaultRequest -> Routes.vault(vaultRequestId)
    InboxKind.PlanConfirm -> planId?.let(Routes::plan) ?: Routes.PLANS
    InboxKind.ComputerApproval -> Routes.APPROVALS
    InboxKind.RunFinished, InboxKind.RunFailed, InboxKind.Info ->
        if (subtype == SUBTYPE_IM_CHANNEL_DISABLED) {
            Routes.IM_CHANNELS
        } else {
            runId?.let(Routes::run) ?: planId?.let(Routes::plan) ?: instanceId?.let(Routes::chat)
        }
}

/** IM 渠道的机器人失效、被后台停用了（10.5）。 */
const val SUBTYPE_IM_CHANNEL_DISABLED = "im_channel_disabled"
