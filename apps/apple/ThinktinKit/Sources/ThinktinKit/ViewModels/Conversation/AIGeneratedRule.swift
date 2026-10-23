import Foundation

/// AI 生成标识的规则表（WBS 16.3，docs/ios-packages.md 12.5 “AI 生成标识要有一张规则表”，和安卓 docs/android-design.md
/// 8.4 一致）：界面上显示的每一种 agent 可能写的文字要不要带“AI 生成”标识。
///
/// `InstanceEvent.isAIGenerated` 只对 `agent.message`、`agent.thought`、`agent.plan` 为真（服务端
/// `proto::labels::is_ai_generated_event`），别的字段没有标识位，按这张表补标。12.5、12.6、12.15、12.18 统一用它。
/// 复制、分享 agent 的输出时末尾追加的文字见 `ConversationText.copyFooter(_:)`（和 `proto::labels::text_footer_in` 一致）。
public enum AIGeneratedField: String, CaseIterable, Hashable, Sendable {
    /// agent 的回复（`agent.message`）。
    case agentMessage
    /// 思考过程（`agent.thought`）。
    case agentThought
    /// agent 的待办清单（`agent.plan`）。
    case agentPlan
    /// 工具调用的标题（`agent.tool_call` 的 `title`）。
    case toolCallTitle
    /// 平台工具调用的参数（`agent.platform_tool_call` 的 `arguments`：计划标题、委派任务、产出物名都是 agent 写的）。
    case platformToolCall
    /// 审批的标题（`Approval.title`、`agent.permission_requested` 的 `title`、`waiting_approval` 的状态说明）。
    case approvalTitle
    /// 保险箱填写请求的用途（`VaultRequest.purpose`、`vault.requested` 的 `purpose`）。
    case vaultRequestPurpose
    /// agent 建的计划的标题和目标（`created_by = agent`）、`plan.needs_confirmation` / `plan.cancelled` 的 `title`。
    case agentPlanTitle
    /// 委派的标题（`delegate.started` 的 `title`）。
    case delegateTitle
    /// 委派子运行的任务（负责人 agent 写的，不能显示成“你说”）。
    case delegatedRunPrompt
    /// 流水线步骤的任务（后面附了上游步骤的摘要，`orchestrator::pipeline::handoff_prompt`）。
    case pipelineStepPrompt
    /// 运行的摘要（`Run.summary`，agent 最后的回答）。
    case runSummary
    /// 产出物的名字（agent 起的）。
    case artifactName
    /// 电脑高危操作的说明（12.9）。
    case computerApprovalDescription
    /// 用户自己写的任务（`source = user` 的 `Run.prompt`）。
    case userPrompt
    /// 用户建的计划的标题和目标。
    case userPlanTitle
    /// 运行的失败原因（`Run.error`：平台的英文诊断信息，不是 agent 写的）。
    case runError
    /// 等 key 时的状态说明（服务端按用户语言写的，`KeyProblem::describe`）。
    case quotaReason
    /// 平台的系统提示、收件箱里平台发的通知、界面自己的文案。
    case platformText

    /// 要不要带“AI 生成”标识。
    public var isAIGenerated: Bool {
        switch self {
        case .agentMessage, .agentThought, .agentPlan, .toolCallTitle, .platformToolCall, .approvalTitle,
            .vaultRequestPurpose, .agentPlanTitle, .delegateTitle, .delegatedRunPrompt, .pipelineStepPrompt,
            .runSummary, .artifactName, .computerApprovalDescription:
            true
        case .userPrompt, .userPlanTitle, .runError, .quotaReason, .platformText:
            false
        }
    }

    /// 运行的任务（对话里的“用户消息”）属于哪一种：用户自己发的不标；委派（负责人 agent 写的）、流水线步骤（附了上游摘要）
    /// 要标；计划触发的是计划的目标，agent 建的计划要标（`planAuthor` 不知道时按用户的算，计划页上另有标识）。
    public static func prompt(of run: Run, planAuthor: PlanAuthor? = nil) -> AIGeneratedField {
        switch run.source {
        case .delegate: .delegatedRunPrompt
        case .pipeline: .pipelineStepPrompt
        case .plan: planAuthor == .agent ? .agentPlanTitle : .userPlanTitle
        case .user, .unknown: .userPrompt
        }
    }

    /// 计划的标题、目标属于哪一种。
    public static func planTitle(createdBy author: PlanAuthor) -> AIGeneratedField {
        author == .agent ? .agentPlanTitle : .userPlanTitle
    }

    /// 运行状态说明（`Run.stateReason`、`run.state` 的 `reason`）属于哪一种：等审批时是 agent 写的审批标题，等 key 时是
    /// 服务端按用户语言写的，其余是平台的英文诊断（docs/ios-packages.md 12.5 第一条）。
    public static func stateReason(for state: RunState) -> AIGeneratedField {
        switch state {
        case .waitingApproval: .approvalTitle
        case .waitingQuota: .quotaReason
        default: .runError
        }
    }
}
