import Foundation

/// App 里的每一个页面（WBS 12.16，信息架构见 docs/ios-packages.md “信息架构映射总表”、docs/android-design.md 第 3 节）。
///
/// 导航栈（`Router.path`）、sheet（`Router.sheet`）、深链（`DeepLink`）、推送（`PushPayload`）都用它表示目的地；
/// 界面层（ThinktinUI 的 `AppShell`）按 `feature` 把它分派给各功能目录里的 `XxxDestination`。
///
/// 加 case 的规矩：要跨功能跳转、要深链的页面才加在这里；只在一个功能里用的子页面，在功能自己的目录里用
/// `NavigationLink { … } label: { … }` 或 sheet 打开（docs/ios.md 第 9 节）。新加的 case 要同时补上 `feature`、
/// `presentation`、`offlinePolicy`、`title(_:)`，测试会逐个检查。
public enum AppRoute: Hashable, Sendable, Codable {
    // MARK: 账号与设备（12.2）

    /// 登录（手机号、验证码）。没登录时由 `AppShell` 整页显示，不进导航栈。
    case signIn
    /// 账号：昵称、手机号、注销。
    case account
    /// 登录设备：列表、下线、下线其他设备。
    case devices

    // MARK: 对话与运行（12.5）

    /// 首页：还没有实例（或还没选中）时导航栈的根。
    case home
    /// 一个实例的对话（时间线 + 输入框）。总是导航栈的根：打开它等于切换当前实例并回到根。
    case conversation(InstanceID)
    /// 运行详情。
    case run(RunID)
    /// 运行树（流水线、委派的子运行）。`RunID` 是树里任意一个运行，页面定位到它所在的节点。
    case runTree(RunID)
    /// 进行中：跨实例的运行和等待态（对应 Claude 的后台会话列表）。
    case activeRuns

    // MARK: agent 与实例（12.3）

    case agentCatalog
    case agent(AgentID)
    /// 实例详情：状态说明、改名、升级 / 回滚、删除。深链 `thinktin://instance/{id}` 打开它（和安卓一致）。
    case instance(InstanceID)

    // MARK: 模型 key（12.4）

    case credentials
    case addCredential
    case credential(CredentialID)
    /// 实例的模型路由（别名、降级链）。
    case modelRoutes(InstanceID)
    case usage

    // MARK: 计划（12.6）

    case plans
    case plan(PlanID)
    /// 新建计划；`instanceID` 是预选的实例（从实例详情、对话里进来时）。
    case newPlan(instanceID: InstanceID?)
    case editPlan(PlanID)
    /// agent 新建或修改了计划、等用户确认（10.7 的 `plan_confirm` 推送、收件箱、对话里的待确认卡片、计划列表的
    /// “待确认”分区）：标题、目标、触发规则、策略、流水线步骤，确认（`confirmPlan` 带 `revision`）或删掉。
    case confirmPlan(PlanID)

    // MARK: 团队与流水线（12.7）

    case teams
    case team(TeamID)
    case teamTemplates
    /// 流水线编辑器：`planID` 为 nil 时新建（`teamID` 是从哪个团队进来的，预选成员）。
    case pipelineEditor(planID: PlanID?, teamID: TeamID?)

    // MARK: 收件箱（12.8）

    case inbox
    /// 收件箱里的一条（推送、深链 `thinktin://inbox/{id}` 点进来）。
    case inboxItem(InboxItemID)

    // MARK: 审批（12.15）

    /// 审批中心（跨实例的待审批队列）。
    case approvals
    case approval(ApprovalID)

    // MARK: 产出物（12.18）

    /// 产出物库；`instanceID` 为 nil 时是全部实例的。
    case artifacts(instanceID: InstanceID?)
    /// 一个产出物（对话、运行详情、产出物库点进来）：预览、分享、存到“文件”、删除。带上所属的运行（按运行取产出物）。
    case artifact(ArtifactID, runID: RunID)

    // MARK: 保险箱（12.13）

    case vault
    case vaultItem(VaultItemID)
    /// agent 请用户填的账号密码（深链 `thinktin://vault/request/{id}`）。
    case vaultRequest(VaultRequestID)

    // MARK: 设置（12.12）

    case settings
    case licenses
    case about

    // MARK: IM 渠道（12.14）

    case imChannels

    // MARK: 首次启动与引导（12.17）

    /// 新用户引导（领养 → 加 key → 配 main → 发第一个任务）。
    case onboarding

    // MARK: 搜索（12.21）

    case search

    // MARK: 应用框架（12.16）

    /// 抽屉里的“新任务”：选在哪个实例上下任务。
    case newTask
    /// 账号被冻结（整页，由 `AppModel.phase` 决定，不进导航栈）。
    case frozen
    /// 版本太老，请升级（整页，由 `AppModel.phase` 决定，不进导航栈）。
    case upgrade
}

extension AppRoute: Identifiable {
    /// `sheet(item:)` 用。
    public var id: Self { self }
}

/// 页面怎么出现。
public enum RoutePresentation: Hashable, Sendable {
    /// 导航栈的根（首页、实例对话）：打开时回到根，不压栈。
    case root
    /// 压进导航栈。
    case push
    /// 用 sheet 弹出（表单、选择器），里面自带一个导航栈。
    case sheet
    /// 整页的全局状态（登录、冻结、升级）：由 `AppModel.phase` 决定显示，`Router` 不处理。
    case global
}

extension AppRoute {
    /// 由哪个功能（工作包）负责这个页面。
    public var feature: AppFeature {
        switch self {
        case .signIn, .account, .devices: .account
        case .home, .conversation, .run, .runTree, .activeRuns: .conversation
        case .agentCatalog, .agent, .instance: .agents
        case .credentials, .addCredential, .credential, .modelRoutes, .usage: .models
        case .plans, .plan, .newPlan, .editPlan, .confirmPlan: .plans
        case .teams, .team, .teamTemplates, .pipelineEditor: .teams
        case .inbox, .inboxItem: .inbox
        case .approvals, .approval: .approvals
        case .artifacts, .artifact: .artifacts
        case .vault, .vaultItem, .vaultRequest: .vault
        case .settings, .licenses, .about: .settings
        case .imChannels: .imChannels
        case .onboarding: .onboarding
        case .search: .search
        case .newTask, .frozen, .upgrade: .shell
        }
    }

    /// 页面怎么出现。表单和选择器用 sheet，整页状态由 `AppModel` 管，其余压栈。
    public var presentation: RoutePresentation {
        switch self {
        case .home, .conversation: .root
        case .signIn, .frozen, .upgrade: .global
        case .newTask, .addCredential, .newPlan, .editPlan, .onboarding: .sheet
        default: .push
        }
    }

    /// 抽屉直达的顶级页面：从抽屉打开时导航栈先回到根再压它（返回就回到对话，和安卓的 `popUpTo(home)` 一致）。
    public var isTopLevel: Bool {
        switch self {
        case .inbox, .approvals, .activeRuns, .plans, .teams, .settings, .search, .agentCatalog: true
        case .artifacts(let instanceID): instanceID == nil
        default: false
        }
    }

    /// 页面所属的实例（有的话）：从推送、深链打开时顺带切换当前实例，返回时回到这个实例的对话。
    public var instanceID: InstanceID? {
        switch self {
        case .conversation(let id), .instance(let id), .modelRoutes(let id): id
        case .newPlan(let id), .artifacts(let id): id
        default: nil
        }
    }

    /// 离线时这个页面怎么显示（docs/ios.md 第 6.2 节的表）。
    public var offlinePolicy: OfflinePolicy {
        switch self {
        // client-core 缓存的只有实例、运行、事件、收件箱（cache.rs 的几张表）。
        case .home, .conversation, .run, .runTree, .activeRuns, .instance, .inbox, .inboxItem: .cached
        // 不用联网的页面。搜索只搜本机缓存（12.21）。
        case .licenses, .about, .settings, .search, .newTask, .frozen, .upgrade, .signIn: .local
        default: .unavailable
        }
    }
}
