import AppIntents
import ThinktinKit

// 快捷指令和 Siri（WBS 12.20）：全部停止、给实例下任务、查待审批数、暂停 / 恢复计划。逻辑在 ThinktinKit 的
// `QuickActions`（有测试），这里只是 App Intents 的外壳。都在 App 的进程里跑（快捷指令在后台拉起 App，不打开界面），
// 用 App 的同一个客户端（`AppEnvironment.shared`）；做完刷新角标，主屏小组件跟着变。
//
// 标题、参数名、短语是中文的，英文在 Localizable.xcstrings 和 AppShortcuts.xcstrings；做完说给用户听的话跟着
// App 里选的界面语言（`QuickActionText`）。
//
// “全部停止”不再问一遍：它是急停按钮，用户在快捷指令里点了、或者对 Siri 说了完整的短语才会跑；停下来的计划在 App 里能恢复。

/// 快捷指令里显示的错误。
struct QuickActionFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// 快捷指令共用的：客户端、界面语言、出错时换成用户看得懂的话。
@MainActor
enum IntentContext {
    static var language: DisplayLanguage { SettingsPreferences.shared.displayLanguage }

    /// 跑一个操作；出错时换成快捷指令能显示的错误。做完刷新角标（小组件跟着变）。
    static func run<T: Sendable>(
        _ body: @Sendable (QuickActions) async throws(QuickActionError) -> T
    ) async throws -> T {
        let environment = AppEnvironment.shared
        // 电脑发来的审批存在本机（12.9），按登录的账号取；快捷指令冷启动 App、还没读到账号时只数云端的。
        let computerLinks = environment.appModel.user.map { ComputerLinkStore(defaults: .standard).load(userID: $0.id) }
        let value: T
        do {
            value = try await body(QuickActions(client: environment.client, computerLinks: computerLinks))
        } catch {
            throw QuickActionFailure(message: QuickActionText.error(error, language: language))
        }
        await environment.appModel.refreshBadges()
        return value
    }
}

struct StopAllIntent: AppIntent {
    static let title: LocalizedStringResource = "全部停止"
    static let description = IntentDescription("取消所有正在进行的运行、暂停所有计划、收回预授权。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.stopAll()
        }
        return .result(dialog: "\(QuickActionText.stopped(result, language: IntentContext.language))")
    }
}

struct PendingApprovalsIntent: AppIntent {
    static let title: LocalizedStringResource = "查看待审批数"
    static let description = IntentDescription("有几个 agent 的操作在等你批准（过期的不算）。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = try await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.pendingApprovals()
        }
        return .result(
            value: count, dialog: "\(QuickActionText.pendingApprovals(count, language: IntentContext.language))")
    }
}

struct SendTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "给实例下任务"
    static let description = IntentDescription("把一个任务交给选中的 agent 实例。任务里像有密码或 key 时不发，要在 App 里先存进保险箱。")

    @Parameter(title: "实例")
    var instance: InstanceEntity

    @Parameter(title: "任务")
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = InstanceID(instance.id)
        let text = task
        _ = try await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.sendTask(to: id, text: text)
        }
        return .result(dialog: "\(QuickActionText.sent(to: instance.name, language: IntentContext.language))")
    }
}

struct SetPlanPausedIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停或恢复计划"
    static let description = IntentDescription("暂停一个计划（到点不再运行），或者恢复它。")

    @Parameter(title: "计划")
    var plan: PlanEntity

    @Parameter(title: "暂停", default: true)
    var paused: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = PlanID(plan.id)
        let paused = self.paused
        let updated = try await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.setPlanPaused(id, paused: paused)
        }
        return .result(
            dialog:
                "\(QuickActionText.planPaused(updated.title, paused: updated.isPaused, language: IntentContext.language))"
        )
    }
}
