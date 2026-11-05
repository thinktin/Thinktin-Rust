import Foundation

/// App 里的每一个页面（WBS 12.16，信息架构见 docs/ios-packages.md “信息架构映射总表”、docs/android-design.md 第 3 节）。
///
/// 导航栈（`Router.path`）、sheet（`Router.sheet`、`sheetPath`、`nestedSheet`）、深链（`DeepLink`）、推送（`PushPayload`）都用它
/// 表示目的地；界面层（ThinktinUI 的 `AppShell`）按 `feature` 把它分派给各功能目录里的 `XxxDestination`。导航结构见
/// docs/ios-ui-redesign.md 第 3 节：首页（实例列表）永远是根，对话压栈，设置和领养是 sheet。
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
    /// 和电脑配对（12.9）：用系统相机扫电脑上的二维码时，`thinktin-pair:` 深链带着配对码打开（`code` 是整条深链）。
    case pairComputer(code: String)

    // MARK: 对话与运行（12.5）

    /// 首页：实例列表，导航栈永远的根（应用框架的页面，`Shell/`）。所有返回的终点。
    case home
    /// 一个实例的对话（时间线 + 输入框）。压进主导航栈（在 sheet 里打开也是先关 sheet），同时记成当前实例
    /// （`Router.currentInstanceID`：新任务、小组件、快捷指令默认用它）。
    case conversation(InstanceID)
    /// 运行详情。
    case run(RunID)
    /// 运行树（流水线、委派的子运行）。`RunID` 是树里任意一个运行，页面定位到它所在的节点。
    case runTree(RunID)
    /// 进行中：跨实例的运行和等待态（对应 Claude 的后台会话列表）。
    case activeRuns

    // MARK: agent 与实例（12.3）

    /// Agent 目录（界面上是“引擎”）。入口：新建 Botin 表单的“了解引擎”（规范 3.3、4.7.1）；引导、没有实例时的“新任务”、
    /// 对话页“实例已删”的空状态都改成弹新建表单了。
    case agentCatalog
    case agent(AgentID)
    /// 领养新实例（首页右上的“+”，sheet）：`agentID` 是预选的 agent，nil 时在表单里选（规范 4.7.1、6.4 A）。
    case adopt(agentID: AgentID?)
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

    /// 计划列表：`instanceID` 为 nil 时是全部实例的（工作台菜单），否则是这个实例的（实例资料的“计划”）。
    case plans(instanceID: InstanceID?)
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

    /// 设置（首页左上的头像，sheet）：里面的子页压进 sheet 自己的导航栈（`Router.sheetPath`）。
    case settings
    case licenses
    case about

    // MARK: IM 渠道（12.14）

    case imChannels

    // MARK: 首次启动与引导（12.17）

    /// 新用户引导（领养 → 加 key → 配 main → 发第一个任务）。
    case onboarding

    // MARK: 搜索（12.21）

    /// 搜索：不压栈，回到首页并激活首页的搜索栏（`Router.searchRequest`）。
    case search

    // MARK: 应用框架（12.16）

    /// “新任务”：选在哪个实例上下任务（引导、快捷指令、没有当前实例时）。
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
    /// 导航栈的根（首页；搜索是首页原地展开的）：打开时关掉 sheet、回到根，不压栈。
    case root
    /// 压栈：sheet 开着时压进 sheet 自己的导航栈，否则压进主导航栈（对话例外，总是先关 sheet 再压进主栈）。
    case push
    /// 用 sheet 弹出（表单、选择器、设置），里面自带一个导航栈；sheet 里再开 sheet 页叠一层（最多两层）。
    case sheet
    /// 整页的全局状态（登录、冻结、升级）：由 `AppModel.phase` 决定显示，`Router` 不处理。
    case global
}

extension AppRoute {
    /// 由哪个功能（工作包）负责这个页面。
    public var feature: AppFeature {
        switch self {
        case .signIn, .account, .devices, .pairComputer: .account
        case .conversation, .run, .runTree, .activeRuns: .conversation
        case .agentCatalog, .agent, .adopt, .instance: .agents
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
        case .home, .newTask, .frozen, .upgrade: .shell
        }
    }

    /// 页面怎么出现。首页和搜索是根；表单、选择器、设置、领养用 sheet；整页状态由 `AppModel` 管；其余压栈。
    public var presentation: RoutePresentation {
        switch self {
        case .home, .search: .root
        case .signIn, .frozen, .upgrade: .global
        case .newTask, .addCredential, .newPlan, .editPlan, .onboarding, .pairComputer, .settings, .adopt: .sheet
        default: .push
        }
    }

    /// 首页“工作台”菜单直达的顶级页面（`Router.openTopLevel`）：先关掉 sheet、回到首页再压它，返回就回到首页
    /// （和安卓的 `popUpTo(home)` 一致）。
    public var isTopLevel: Bool {
        switch self {
        case .inbox, .approvals, .activeRuns, .teams: true
        case .plans(let instanceID), .artifacts(let instanceID): instanceID == nil
        default: false
        }
    }

    /// 页面所属的实例（有的话）：打开对话、从推送和深链打开时记成当前实例；实例被删时它的页面一起拿掉
    /// （`Router.removeRoutes(of:)`）。
    public var instanceID: InstanceID? {
        switch self {
        case .conversation(let id), .instance(let id), .modelRoutes(let id): id
        case .newPlan(let id), .artifacts(let id), .plans(let id): id
        default: nil
        }
    }

    /// 从外面（深链、推送）打开时，返回栈要不要经过所属实例的对话（规范 3.4）：实例资料、模型路由、实例的计划和产出物、
    /// 运行详情和运行树、产出物详情是“首页 → 实例的对话 → 目标页”（运行的实例要推送里带着）；其余（收件箱、审批、
    /// 计划详情、保险箱请求……）是“首页 → 目标页”。返回栈由 `DeepLink.backStack(to:instanceID:)` 算。
    public var returnsToConversation: Bool {
        switch self {
        case .instance, .modelRoutes, .run, .runTree, .artifact: true
        case .plans(let instanceID), .artifacts(let instanceID): instanceID != nil
        default: false
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
