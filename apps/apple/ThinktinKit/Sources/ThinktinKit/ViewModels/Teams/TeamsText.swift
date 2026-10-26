import Foundation

/// 团队与流水线的文案（WBS 12.7）：表单的问题、几句说明。页面上的按钮文字在各页面里。
public enum TeamsText {
    public static func intro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "几个实例编成一组：负责人分工，成员各做一块。存成模板以后能一键领养一整套。"
            : "Group instances into a team: the lead splits the work and members each take a part. Save one as a "
                + "template to adopt the whole set in one tap."
    }

    public static func memberCount(_ count: Int, language: DisplayLanguage) -> String {
        language == .chinese ? "\(count) 个成员" : (count == 1 ? "1 member" : "\(count) members")
    }

    public static func role(_ role: TeamRole, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch role {
        case .lead: return zh ? "负责人" : "Lead"
        case .member, .unknown: return zh ? "成员" : "Member"
        }
    }

    public static func teamProblem(_ problem: TeamFormProblem, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch problem {
        case .nameEmpty: return zh ? "给团队起个名字" : "Give the team a name"
        case .nameTooLong:
            return zh ? "名字最多 \(TeamEditorModel.maxName) 个字" : "At most \(TeamEditorModel.maxName) characters"
        case .noMembers: return zh ? "至少选一个成员" : "Pick at least one member"
        case .tooManyMembers:
            return zh ? "最多 \(TeamEditorModel.maxMembers) 个成员" : "At most \(TeamEditorModel.maxMembers) members"
        case .noLead: return zh ? "选一个负责人" : "Pick a lead"
        }
    }

    public static func stepProblem(_ problem: StepProblem, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch problem {
        case .badKey:
            return zh
                ? "键名只能用小写字母、数字、_、-，以字母或数字开头，最多 32 个"
                : "Use lowercase letters, digits, _ and -, starting with a letter or digit, up to 32"
        case .duplicateKey: return zh ? "键名重复了" : "Another step uses this key"
        case .noInstance: return zh ? "选一个实例" : "Pick an instance"
        case .deletedInstance: return zh ? "这个实例已经删掉了，换一个" : "This instance was deleted. Pick another."
        case .emptyPrompt: return zh ? "写一下这一步做什么" : "Describe what this step does"
        case .promptTooLong:
            return zh ? "最多 \(PipelineRules.maxPrompt) 个字" : "At most \(PipelineRules.maxPrompt) characters"
        case .unknownDependency(_, let key): return zh ? "依赖的步骤“\(key)”不在了" : "Step “\(key)” no longer exists"
        case .selfDependency: return zh ? "不能依赖自己" : "A step can't wait for itself"
        case .cycle:
            return zh
                ? "步骤之间的依赖绕成了一个圈，去掉一个依赖" : "The steps wait for each other in a loop. Remove one dependency."
        case .tooMany: return zh ? "最多 \(PipelineRules.maxSteps) 步" : "At most \(PipelineRules.maxSteps) steps"
        }
    }

    public static func pipelineIntro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "按依赖顺序跑：没有依赖的一起开始，依赖的步骤做完才轮到它，前面的产出物会交给它。"
            : "Steps run in dependency order: those without dependencies start together, the rest wait for theirs "
                + "and get their files."
    }

    /// 新建流水线时的说明（没有触发规则）。
    public static func newPipelineNote(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "建好后在计划详情里加触发规则，它就会按时跑。"
            : "After it's created, add a schedule on the plan's page so it runs on time."
    }

    /// 运行树顶上：子步骤在等你。
    public static func attention(_ run: Run, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let name = run.stepKey.flatMap { $0.isEmpty ? nil : $0 } ?? (zh ? "一个子任务" : "A sub-task")
        switch run.state {
        case .waitingApproval: return zh ? "\(name) 在等你审批" : "\(name) is waiting for your approval"
        case .waitingQuota: return zh ? "\(name) 在等可用的模型 key" : "\(name) is waiting for a usable model key"
        case .waitingDevice: return zh ? "\(name) 在等你的电脑上线" : "\(name) is waiting for your computer"
        default: return zh ? "\(name) 在等你处理" : "\(name) needs you"
        }
    }
}
