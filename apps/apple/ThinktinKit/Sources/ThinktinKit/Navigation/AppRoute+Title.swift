import Foundation

extension AppRoute {
    /// 页面的标题（导航栏、抽屉入口、占位页、读屏）。实例对话的导航栏标题是实例名，这里给的是通用的“对话”。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let (zh, en) = titles
        return language == .chinese ? zh : en
    }

    private var titles: (String, String) {
        switch self {
        case .signIn: ("登录", "Sign in")
        case .account: ("账号", "Account")
        case .devices: ("登录设备", "Devices")
        case .home: ("首页", "Home")
        case .conversation: ("对话", "Conversation")
        case .run: ("运行详情", "Run details")
        case .runTree: ("运行树", "Run tree")
        case .activeRuns: ("进行中", "In progress")
        case .agentCatalog: ("Agent 目录", "Agent catalog")
        case .agent: ("Agent 详情", "Agent details")
        case .instance: ("实例详情", "Instance details")
        case .credentials: ("模型 key", "Model keys")
        case .addCredential: ("添加 key", "Add key")
        case .credential: ("Key 详情", "Key details")
        case .modelRoutes: ("模型路由", "Model routes")
        case .usage: ("用量", "Usage")
        case .plans: ("计划", "Plans")
        case .plan: ("计划详情", "Plan details")
        case .newPlan: ("新建计划", "New plan")
        case .editPlan: ("编辑计划", "Edit plan")
        case .confirmPlan: ("确认计划", "Review plan")
        case .teams: ("团队", "Teams")
        case .team: ("团队详情", "Team details")
        case .teamTemplates: ("团队模板", "Team templates")
        case .pipelineEditor(let planID, _): planID == nil ? ("新建流水线", "New pipeline") : ("编辑流水线", "Edit pipeline")
        case .inbox: ("收件箱", "Inbox")
        case .inboxItem: ("通知", "Notification")
        case .approvals: ("审批", "Approvals")
        case .approval: ("审批详情", "Approval")
        case .artifacts: ("产出物", "Artifacts")
        case .vault: ("密码保险箱", "Vault")
        case .vaultItem: ("保险箱条目", "Vault item")
        case .vaultRequest: ("填写请求", "Vault request")
        case .settings: ("设置", "Settings")
        case .licenses: ("开源许可", "Open-source licenses")
        case .about: ("关于", "About")
        case .imChannels: ("IM 渠道", "IM channels")
        case .onboarding: ("开始使用", "Get started")
        case .search: ("搜索", "Search")
        case .newTask: ("新任务", "New task")
        case .frozen: ("账号已冻结", "Account frozen")
        case .upgrade: ("需要更新", "Update required")
        }
    }
}
