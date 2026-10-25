package cn.thinktin.app.navigation

import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxKind

/**
 * 收件箱条目点进去去哪（第 4.8 节“点击跳转”；收件箱页面在 13.8，先把跳转规则定下来）：
 * - 审批：审批详情 `approval/{id}`（13.16；已处理、过期的在详情里显示结果）；没有审批 id 的去审批中心；
 * - 保险箱填写请求：`vault?requestId=…`；
 * - 计划待确认：计划详情；
 * - 运行完成 / 失败、其他提醒：有运行去运行详情，有计划去计划，有实例去对话；
 * - 电脑审批（13.9，P3）还没有页面：有运行去运行详情，否则不跳。
 * 返回 null 表示没有可去的页面（只标已读）。
 */
fun InboxItem.targetRoute(): String? = when (kind) {
    InboxKind.Approval -> approvalId?.let(Routes::approval) ?: Routes.APPROVALS
    InboxKind.VaultRequest -> Routes.vault(vaultRequestId)
    InboxKind.PlanConfirm -> planId?.let(Routes::plan) ?: Routes.PLANS
    InboxKind.ComputerApproval -> runId?.let(Routes::run)
    InboxKind.RunFinished, InboxKind.RunFailed, InboxKind.Info ->
        runId?.let(Routes::run) ?: planId?.let(Routes::plan) ?: instanceId?.let(Routes::chat)
}
