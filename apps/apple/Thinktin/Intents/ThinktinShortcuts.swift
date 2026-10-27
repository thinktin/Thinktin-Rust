import AppIntents

/// 装好就有的快捷指令和 Siri 短语（WBS 12.20）。短语里要有 App 名；英文短语在 AppShortcuts.xcstrings。
/// 要选实例、计划的两个（下任务、暂停计划）不放短语里的参数：实例名是用户起的，Siri 认不准，在快捷指令里选。
struct ThinktinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StopAllIntent(),
            phrases: ["用\(.applicationName)全部停止", "\(.applicationName)全部停止"],
            shortTitle: "全部停止",
            systemImageName: "stop.circle")
        AppShortcut(
            intent: PendingApprovalsIntent(),
            phrases: ["\(.applicationName)有几个待审批", "查看\(.applicationName)的待审批"],
            shortTitle: "待审批",
            systemImageName: "checkmark.shield")
        AppShortcut(
            intent: SendTaskIntent(),
            phrases: ["用\(.applicationName)下任务", "给\(.applicationName)的实例下任务"],
            shortTitle: "下任务",
            systemImageName: "paperplane")
        AppShortcut(
            intent: SetPlanPausedIntent(),
            phrases: ["暂停\(.applicationName)的计划", "用\(.applicationName)暂停计划"],
            shortTitle: "暂停计划",
            systemImageName: "pause.circle")
    }
}
