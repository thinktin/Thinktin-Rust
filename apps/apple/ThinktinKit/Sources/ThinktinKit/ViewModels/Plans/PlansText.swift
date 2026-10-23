import Foundation

/// 计划管理（WBS 12.6）界面上的文案：中英文都在这里，界面按 `DisplayLanguage` 取。
public enum PlansText {
    // MARK: AI 生成标识（计划这几页的规则表）

    /// 计划页上会出现的、可能是 agent 写的文字（docs/ios-packages.md 12.5“AI 生成标识要有一张规则表”、
    /// docs/android-design.md 8.4）。
    public enum Field: CaseIterable, Hashable, Sendable {
        /// 计划的标题。
        case title
        /// 计划的目标。
        case goal
        /// 流水线一步的提示词。
        case stepPrompt
        /// 运行历史里的摘要（`Run.summary`，agent 最后的回答）。
        case runSummary
        /// 运行历史里的失败原因（`Run.error`，平台的英文诊断）。
        case runError
        /// 触发规则的描述（App 按规则生成的话）。
        case scheduleDescription
    }

    /// 规则表：这个字段要不要带“AI 生成”标识。
    ///
    /// | 字段 | 标 | 说明 |
    /// |---|---|---|
    /// | 标题、目标 | agent 建的（`createdBy == .agent`），或者正在等确认的 | 等确认说明 agent 刚改过它（agent 能改自己实例上用户建的计划，`created_by` 还是 user），按 agent 写的标 |
    /// | 流水线步骤的提示词 | 同上 | agent 的 schedule 工具改不了步骤，但 agent 建的计划一律按 agent 写的标 |
    /// | 运行摘要 | 是 | agent 的回答 |
    /// | 失败原因 | 否 | 平台的英文诊断，界面只显示“失败”，详情折叠 |
    /// | 触发规则的描述 | 否 | App 按规则生成的话，不是 agent 写的文字 |
    public static func isAIGenerated(_ field: Field, in plan: Plan) -> Bool {
        switch field {
        case .title, .goal, .stepPrompt: plan.createdBy == .agent || plan.awaitingConfirmation
        case .runSummary: true
        case .runError, .scheduleDescription: false
        }
    }

    // MARK: 规则、下一次

    /// 列表一行里的规则摘要：第一条规则的描述，多条时加“等 N 条规则”；没有规则时说没有。
    public static func scheduleSummary(
        _ plan: Plan, language: DisplayLanguage = .current, timeZone: TimeZone = .current
    ) -> String {
        let zh = language == .chinese
        guard let first = plan.triggers.first(where: \.isEnabled) ?? plan.triggers.first else {
            return zh ? "没有触发规则" : "No schedule"
        }
        let text = ScheduleDescription.describe(first.schedule, language: language, timeZone: timeZone)
        let others = plan.triggers.count - 1
        guard others > 0 else { return text }
        return zh ? "\(text) 等 \(plan.triggers.count) 条规则" : "\(text) + \(others) more"
    }

    /// “下次：明天 09:00” / “Next: tomorrow 09:00”。
    public static func nextFire(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        let when = Formatting.relativeTime(date, now: now, language: language, calendar: calendar)
        return language == .chinese ? "下次：\(when)" : "Next: \(when)"
    }

    /// “上次：3 小时前” / “Last: 3 hr ago”。
    public static func lastFire(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        let when = Formatting.relativeTime(date, now: now, language: language, calendar: calendar)
        return language == .chinese ? "上次：\(when)" : "Last: \(when)"
    }

    /// 接下来几次的时间（预览），用顿号 / 逗号连起来。
    public static func upcoming(
        _ dates: [Date], now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        dates.map { Formatting.dateTime($0, now: now, language: language, calendar: calendar) }
            .joined(separator: language == .chinese ? "、" : ", ")
    }

    /// 触发器状态那一行：规则失效、停用、下一次、已经不会再触发。
    public static func triggerState(
        _ trigger: Trigger, plan: Plan, now: Date = Date(), language: DisplayLanguage = .current,
        calendar: Calendar = .current
    ) -> String {
        let zh = language == .chinese
        if trigger.isInvalid { return zh ? "规则已失效，已停用" : "Rule no longer valid; turned off" }
        if !trigger.isEnabled { return zh ? "已停用" : "Turned off" }
        if plan.awaitingConfirmation { return zh ? "确认后生效" : "Starts once you confirm" }
        if plan.isPaused { return zh ? "计划暂停中" : "Plan is paused" }
        if let next = trigger.nextFireAt { return nextFire(next, now: now, language: language, calendar: calendar) }
        return zh ? "不会再触发" : "Won't fire again"
    }

    // MARK: 策略

    /// ACP 的工具种类（预授权用；顺序是界面上的顺序）。
    public static let toolKinds = ["read", "search", "fetch", "think", "edit", "move", "delete", "execute", "other"]

    /// 有风险的工具种类（预授权前提醒）：会改文件、删文件、跑命令的。
    public static func isRiskyTool(_ kind: String) -> Bool {
        ["edit", "move", "delete", "execute"].contains(kind)
    }

    /// 工具种类的名字；认不出的原样显示。
    public static func toolName(_ kind: String, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch kind {
        case "read": return zh ? "读取文件" : "Read files"
        case "search": return zh ? "搜索" : "Search"
        case "fetch": return zh ? "联网获取" : "Fetch from the web"
        case "think": return zh ? "思考" : "Think"
        case "edit": return zh ? "修改文件" : "Edit files"
        case "move": return zh ? "移动、重命名文件" : "Move or rename files"
        case "delete": return zh ? "删除文件" : "Delete files"
        case "execute": return zh ? "运行命令" : "Run commands"
        case "switch_mode": return zh ? "切换模式" : "Switch modes"
        case "other": return zh ? "其他工具" : "Other tools"
        default: return kind
        }
    }

    /// 预授权的工具（“读取文件、搜索”），没有时说“都要审批”。
    public static func toolsSummary(_ kinds: [String], language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        guard !kinds.isEmpty else { return zh ? "没有，每次用工具都要审批" : "None; every tool use needs approval" }
        let ordered = toolKinds.filter(kinds.contains) + kinds.filter { !toolKinds.contains($0) }
        return ordered.map { toolName($0, language: language) }.joined(separator: zh ? "、" : ", ")
    }

    /// 超时后的动作。
    public static func timeoutActionName(_ action: ApprovalTimeoutAction, language: DisplayLanguage = .current)
        -> String
    {
        let zh = language == .chinese
        switch action {
        case .skip: return zh ? "跳过这一步" : "Skip that step"
        case .pausePlan: return zh ? "暂停计划" : "Pause the plan"
        case .fail: return zh ? "这次运行失败" : "Fail the run"
        case .unknown(let raw): return raw
        }
    }

    /// 超时后的动作的一句说明。
    public static func timeoutActionDetail(_ action: ApprovalTimeoutAction, language: DisplayLanguage = .current)
        -> String?
    {
        let zh = language == .chinese
        switch action {
        case .skip: return zh ? "当作拒绝，agent 接着做别的。" : "Treated as a rejection; the agent carries on."
        case .pausePlan: return zh ? "这次运行停下，计划暂停，等你回来处理。" : "The run stops and the plan pauses until you're back."
        case .fail: return zh ? "这次运行算失败，下次照常触发。" : "This run fails; the next one runs as usual."
        case .unknown: return nil
        }
    }

    /// 补跑方式。
    public static func catchUpName(_ catchUp: CatchUp, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch catchUp {
        case .once: return zh ? "只补一次" : "Catch up once"
        case .all: return zh ? "全部补跑" : "Catch up every run"
        case .skip: return zh ? "不补" : "Don't catch up"
        case .unknown(let raw): return raw
        }
    }

    /// 补跑方式的一句说明。
    public static func catchUpDetail(_ catchUp: CatchUp, language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch catchUp {
        case .once: return zh ? "错过了几次都只补跑最近的一次。" : "However many runs were missed, only the latest runs."
        case .all: return zh ? "错过几次补几次。" : "Every missed run runs."
        case .skip: return zh ? "错过的不补，等下一次。" : "Missed runs are skipped; wait for the next one."
        case .unknown: return nil
        }
    }

    /// 时长（超时、单次时长上限）：“1 小时”“24 小时”“7 天”。
    public static func duration(_ seconds: Int, language: DisplayLanguage = .current) -> String {
        Formatting.duration(TimeInterval(seconds), language: language)
    }

    /// 审批超时那一行：“等 1 小时，超时后跳过这一步”。
    public static func approvalSummary(_ policy: PlanPolicy, language: DisplayLanguage = .current) -> String {
        let wait = duration(policy.approvalTimeoutSecs, language: language)
        let action = timeoutActionName(policy.onApprovalTimeout, language: language)
        return language == .chinese ? "等 \(wait)，超时后\(action)" : "Wait \(wait), then \(lowercasedFirst(action))"
    }

    /// 单次预算那一行：“最多 5 万 token · 最长 30 分 · 步数不限”。
    public static func budgetSummary(_ budget: RunBudget, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let tokens =
            budget.maxTokens.map {
                zh
                    ? "最多 \(Formatting.tokens($0, language: language)) token"
                    : "Up to \(Formatting.tokens($0, language: language)) tokens"
            } ?? (zh ? "token 不限" : "No token limit")
        let time =
            zh
            ? "最长 \(duration(budget.maxDurationSecs, language: language))"
            : "up to \(duration(budget.maxDurationSecs, language: language))"
        let steps =
            budget.maxSteps.map { zh ? "最多 \($0) 步" : "up to \($0) steps" } ?? (zh ? "步数不限" : "no step limit")
        return [tokens, time, steps].joined(separator: " · ")
    }

    /// 每日 token 上限那一行。
    public static func dailyLimitSummary(_ limit: Int?, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        guard let limit else { return zh ? "不限" : "No limit" }
        return zh
            ? "每天最多 \(Formatting.tokens(limit, language: language)) token"
            : "Up to \(Formatting.tokens(limit, language: language)) tokens a day"
    }

    /// 等待超时那一行（等电脑上线、等补 key）。
    public static func waitSummary(_ policy: PlanPolicy, language: DisplayLanguage = .current) -> String {
        let wait = duration(policy.waitTimeoutSecs, language: language)
        return language == .chinese ? "等电脑上线、等补 key 最多 \(wait)" : "Wait up to \(wait) for a computer or a key"
    }

    /// 超时类的预设（秒）：5 分钟到 7 天。
    public static let timeoutPresets = [300, 900, 1800, 3600, 4 * 3600, 12 * 3600, 86400, 3 * 86400, 7 * 86400]
    /// 单次运行时长的预设（秒）：5 分钟到 24 小时。
    public static let durationPresets = [300, 900, 1800, 3600, 2 * 3600, 6 * 3600, 12 * 3600, 86400]

    /// 预设加上现在的值（不在预设里时插进去），升序。
    public static func presets(_ presets: [Int], including current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    // MARK: 改了什么

    /// 一处改动在页面上怎么写：哪一项、之前、现在（之前或现在没有的为 nil）。
    public struct ChangeLine: Hashable, Sendable {
        public var label: String
        public var before: String?
        public var after: String?
    }

    /// 改动的文字。`instanceName` 把实例 id 换成名字（流水线步骤用）。
    public static func describe(
        _ change: PlanChangeItem, language: DisplayLanguage = .current, timeZone: TimeZone = .current,
        instanceName: (InstanceID) -> String = { $0.rawValue }
    ) -> ChangeLine {
        let zh = language == .chinese
        func schedules(_ list: [Schedule]) -> String {
            list.map { ScheduleDescription.describe($0, language: language, timeZone: timeZone) }
                .joined(separator: zh ? "；" : "; ")
        }
        func steps(_ list: [PlanStep]) -> String {
            guard !list.isEmpty else { return zh ? "没有（单个 agent）" : "None (single agent)" }
            return list.map { "\($0.key) → \(instanceName($0.instanceID))" }.joined(separator: zh ? "、" : ", ")
        }
        switch change {
        case .title(let from, let to):
            return ChangeLine(label: zh ? "标题" : "Title", before: from, after: to)
        case .goal(let from, let to):
            return ChangeLine(label: zh ? "目标" : "Goal", before: from, after: to)
        case .triggersAdded(let list):
            return ChangeLine(label: zh ? "新加的触发规则" : "Schedule added", before: nil, after: schedules(list))
        case .triggersRemoved(let list):
            return ChangeLine(label: zh ? "去掉的触发规则" : "Schedule removed", before: schedules(list), after: nil)
        case .preauthorizedTools(let from, let to):
            return ChangeLine(
                label: zh ? "预授权的工具" : "Pre-approved tools", before: toolsSummary(from, language: language),
                after: toolsSummary(to, language: language))
        case .approvalTimeout(let from, let to):
            return ChangeLine(
                label: zh ? "审批等多久" : "Approval wait", before: duration(from, language: language),
                after: duration(to, language: language))
        case .timeoutAction(let from, let to):
            return ChangeLine(
                label: zh ? "超时后" : "After a timeout", before: timeoutActionName(from, language: language),
                after: timeoutActionName(to, language: language))
        case .budget(let from, let to):
            return ChangeLine(
                label: zh ? "每次运行的上限" : "Per-run limits", before: budgetSummary(from, language: language),
                after: budgetSummary(to, language: language))
        case .dailyTokenLimit(let from, let to):
            return ChangeLine(
                label: zh ? "每日 token 上限" : "Daily token limit", before: dailyLimitSummary(from, language: language),
                after: dailyLimitSummary(to, language: language))
        case .waitTimeout(let from, let to):
            return ChangeLine(
                label: zh ? "等电脑、等 key 多久" : "Wait for a computer or key", before: duration(from, language: language),
                after: duration(to, language: language))
        case .catchUp(let from, let to):
            return ChangeLine(
                label: zh ? "错过的怎么补" : "Missed runs", before: catchUpName(from, language: language),
                after: catchUpName(to, language: language))
        case .steps(let from, let to):
            return ChangeLine(label: zh ? "流水线步骤" : "Pipeline steps", before: steps(from), after: steps(to))
        }
    }

    // MARK: 确认页

    /// 确认页顶上的一句话：agent 做了什么。
    public static func reviewHeadline(_ kind: PlanReviewKind, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch kind {
        case .created: return zh ? "agent 新建了一个计划" : "An agent created a plan"
        case .updated, .updatedWithoutBaseline: return zh ? "agent 改了这个计划" : "An agent changed this plan"
        }
    }

    /// 确认页顶上的说明。
    public static func reviewMessage(_ kind: PlanReviewKind, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch kind {
        case .created:
            return zh
                ? "确认之前它不会运行。看清它要做什么、什么时候做、能用哪些工具，再决定。"
                : "It won't run until you confirm. Check what it does, when it runs and which tools it can use."
        case .updated:
            return zh
                ? "改动已经标出来了。确认之前计划暂停，不会按新的内容运行。"
                : "The changes are marked below. The plan stays paused until you confirm."
        case .updatedWithoutBaseline:
            return zh
                ? "App 里没有改之前的版本可以对比（只记得这次打开 App 后看过的计划），请完整核对下面的内容。确认之前计划暂停。"
                : "The app doesn't have the earlier version to compare with (it only remembers plans you viewed "
                    + "since opening it), so review everything below. The plan stays paused until you confirm."
        }
    }

    /// 确认时发现计划又被改过。
    public static func conflictMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "你看的时候计划又被改过了，下面已经换成最新的内容，改动标出来了。请重新核对后再确认。"
            : "The plan changed while you were reviewing it. Below is the latest version with the changes marked. "
                + "Review it again before confirming."
    }

    // MARK: 运行历史

    /// 运行的来源（运行历史里一般都是计划触发的；手动补跑之类以后可能有别的）。
    public static func runSourceName(_ source: RunSource, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch source {
        case .user: return zh ? "你发起的" : "Started by you"
        case .plan: return zh ? "按时触发" : "Scheduled"
        case .pipeline: return zh ? "流水线" : "Pipeline"
        case .delegate: return zh ? "委派" : "Delegated"
        case .unknown(let raw): return raw
        }
    }

    // MARK: 空状态、离线

    /// 没有计划时的说明（可以直接对 agent 说）。
    public static func emptyMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "新建一个，或者直接对 agent 说“每天 8 点帮我…”，它会安排好，等你确认。"
            : "Create one, or just tell an agent “every day at 8, …”. It sets the plan up and asks you to confirm."
    }

    /// 第一个字母小写（英文句中拼接用：“then skip that step”）。
    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
