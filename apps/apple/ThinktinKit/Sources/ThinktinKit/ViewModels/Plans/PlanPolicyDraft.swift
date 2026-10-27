import Foundation

/// 编辑中的计划策略（WBS 12.6）：预授权的工具种类、审批超时和超时后的动作、单次预算（token、时长、步数）、
/// 每日 token 上限、等待超时。数字输入框里的是文字（空的是“不限”），`policy` 换算成 `PlanPolicy`；
/// 取值范围按服务端的 `check_policy`（`PlanPolicy.isValid`）在本地先查。
public struct PlanPolicyDraft: Hashable, Sendable {
    /// 预授权的工具种类（保持原来的顺序；认不出的种类原样保留）。
    public var preauthorizedTools: [String]
    public var approvalTimeoutSecs: Int
    public var onApprovalTimeout: ApprovalTimeoutAction
    /// 单次最多多少 token；空的是不限。
    public var maxTokens: String
    public var maxDurationSecs: Int
    /// 单次最多几步；空的是不限。
    public var maxSteps: String
    /// 每天最多多少 token；空的是不限。
    public var dailyTokenLimit: String
    public var waitTimeoutSecs: Int

    public init(_ policy: PlanPolicy = PlanPolicy()) {
        preauthorizedTools = policy.preauthorizedTools
        approvalTimeoutSecs = policy.approvalTimeoutSecs
        onApprovalTimeout = policy.onApprovalTimeout
        maxTokens = policy.budget.maxTokens.map(String.init) ?? ""
        maxDurationSecs = policy.budget.maxDurationSecs
        maxSteps = policy.budget.maxSteps.map(String.init) ?? ""
        dailyTokenLimit = policy.dailyTokenLimit.map(String.init) ?? ""
        waitTimeoutSecs = policy.waitTimeoutSecs
    }

    // MARK: 工具

    public func allows(_ kind: String) -> Bool {
        preauthorizedTools.contains(kind)
    }

    /// 打开或关掉一种工具的预授权。
    public mutating func setTool(_ kind: String, allowed: Bool) {
        if allowed {
            if !preauthorizedTools.contains(kind) { preauthorizedTools.append(kind) }
        } else {
            preauthorizedTools.removeAll { $0 == kind }
        }
    }

    // MARK: 检查与换算

    /// 填的内容有什么问题（按页面上的顺序）。
    public var problems: [PlanPolicyProblem] {
        var out: [PlanPolicyProblem] = []
        if preauthorizedTools.count > PlanPolicy.maxPreauthorizedTools {
            out.append(.tooManyTools(max: PlanPolicy.maxPreauthorizedTools))
        }
        if !PlanPolicy.timeoutRange.contains(approvalTimeoutSecs) { out.append(.approvalTimeoutOutOfRange) }
        if Self.parse(maxTokens) == nil { out.append(.notAPositiveNumber(.maxTokens)) }
        if !PlanPolicy.maxDurationRange.contains(maxDurationSecs) { out.append(.maxDurationOutOfRange) }
        if Self.parse(maxSteps) == nil { out.append(.notAPositiveNumber(.maxSteps)) }
        if Self.parse(dailyTokenLimit) == nil { out.append(.notAPositiveNumber(.dailyTokenLimit)) }
        if !PlanPolicy.timeoutRange.contains(waitTimeoutSecs) { out.append(.waitTimeoutOutOfRange) }
        return out
    }

    /// 这个数字框的问题（界面在框下面显示）。
    public func problem(for field: PlanPolicyNumberField) -> PlanPolicyProblem? {
        let text: String
        switch field {
        case .maxTokens: text = maxTokens
        case .maxSteps: text = maxSteps
        case .dailyTokenLimit: text = dailyTokenLimit
        }
        return Self.parse(text) == nil ? .notAPositiveNumber(field) : nil
    }

    /// 换算成 `PlanPolicy`；有问题时为 nil。
    public var policy: PlanPolicy? {
        guard problems.isEmpty, let tokens = Self.parse(maxTokens), let steps = Self.parse(maxSteps),
            let daily = Self.parse(dailyTokenLimit)
        else { return nil }
        return PlanPolicy(
            preauthorizedTools: preauthorizedTools, approvalTimeoutSecs: approvalTimeoutSecs,
            onApprovalTimeout: onApprovalTimeout,
            budget: RunBudget(maxTokens: tokens, maxDurationSecs: maxDurationSecs, maxSteps: steps),
            dailyTokenLimit: daily, waitTimeoutSecs: waitTimeoutSecs)
    }

    /// 数字框的内容：空的（不限）是 `.some(nil)`，正整数是 `.some(n)`，别的是 nil。可以带千分位的逗号、空格。
    static func parse(_ text: String) -> Int?? {
        let cleaned = text.filter { !$0.isWhitespace && $0 != "," && $0 != "，" }
        if cleaned.isEmpty { return .some(nil) }
        guard cleaned.allSatisfy(\.isASCII), let n = Int(cleaned), n > 0 else { return nil }
        return .some(n)
    }
}

/// 策略里的数字框。
public enum PlanPolicyNumberField: Hashable, Sendable {
    case maxTokens, maxSteps, dailyTokenLimit
}

/// 策略填得不对的地方。
public enum PlanPolicyProblem: Hashable, Sendable {
    case notAPositiveNumber(PlanPolicyNumberField)
    case approvalTimeoutOutOfRange
    case waitTimeoutOutOfRange
    case maxDurationOutOfRange
    case tooManyTools(max: Int)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .notAPositiveNumber:
            return zh ? "填一个大于 0 的整数，空着是不限。" : "Enter a whole number above 0, or leave it empty for no limit."
        case .approvalTimeoutOutOfRange:
            return zh ? "审批最少等 1 分钟，最多等 7 天。" : "Approvals can wait from 1 minute to 7 days."
        case .waitTimeoutOutOfRange:
            return zh ? "最少等 1 分钟，最多等 7 天。" : "The wait can be from 1 minute to 7 days."
        case .maxDurationOutOfRange:
            return zh ? "每次最长 24 小时。" : "A run can last up to 24 hours."
        case .tooManyTools(let max):
            return zh ? "最多预授权 \(max) 种工具。" : "Up to \(max) tool kinds can be pre-approved."
        }
    }
}
