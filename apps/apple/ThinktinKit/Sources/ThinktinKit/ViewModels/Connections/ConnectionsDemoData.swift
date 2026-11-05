import Foundation

/// 连接目录的本地数据（规范 4.8、6.12）。
///
/// - 前六项是 ThinkTin 已经有的接入（`builtIn` 不为 nil）：电脑、飞书、企业微信、钉钉、模型 key、保险箱，状态和账户用真数据。
/// - 其余都是**演示数据**：版式照参考 36–52、101–107 排出来给用户看，ThinkTin 还不能连（第三方连接器、“此 iPhone”、外部密码管理器
///   都要后端和产品决定，规范 6.12 的 B），界面上点了弹“即将推出”。名字都用通用的叫法（“在线文档”“代码仓库”），不写别家的产品名、
///   不用别家的 Logo。用户会按真实功能删改这里。
public enum ConnectionsDemoData {
    public static let computerID: ConnectionID = "computer"
    public static let feishuID: ConnectionID = "feishu"
    public static let wecomID: ConnectionID = "wecom"
    public static let dingtalkID: ConnectionID = "dingtalk"
    public static let modelKeysID: ConnectionID = "model-keys"
    public static let vaultID: ConnectionID = "vault"
    /// 演示：带技能的应用（参考 105、106 的长说明）。
    public static let codeHostingID: ConnectionID = "code-hosting"
    /// 演示：手机上的能力（参考 40）。
    public static let calendarID: ConnectionID = "phone-calendar"
    /// 演示：外部密码管理器（参考 41）。
    public static let passwordManagerID: ConnectionID = "password-manager"

    /// 整个目录。
    public static let catalog = ConnectionCatalog(
        apps: builtIns + phone + apps,
        recommended: [
            "email", "docs", "project-boards", "shared-calendar", "team-chat", "spreadsheets", "crm", "web-search",
            "notes", "meeting-notes",
        ],
        featured: [computerID, feishuID, modelKeysID, vaultID, "email", "cloud-drive", codeHostingID])

    // MARK: ThinkTin 自带的接入

    static let builtIns: [ConnectionApp] = [
        ConnectionApp(
            id: computerID, name: ConnectionText("电脑", "Computer"),
            summary: ConnectionText(
                "让 Botin 借你的电脑执行命令、打开应用", "Let Botins run commands and open apps on your computer"),
            details: ConnectionText(
                "配对以后，Botin 能借你的电脑执行命令、打开应用、读写你允许的目录。删除文件、执行命令这类高危操作，每次都会先发到"
                    + "手机上等你批准。",
                "Once paired, Botins can run commands, open apps and use the folders you allow on your computer. Risky "
                    + "actions such as deleting files or running commands are sent to your phone for approval every time."
            ),
            systemImage: "laptopcomputer", tint: .neutral, categories: [.computer], builtIn: .computer),
        ConnectionApp(
            id: feishuID, name: ConnectionText("飞书", "Feishu / Lark"),
            summary: ConnectionText("把任务结果发到飞书群", "Post task results to Feishu or Lark groups"),
            details: ConnectionText(
                "把 Botin 的任务结果、失败提醒和审批请求发到飞书（Lark）群里。在群设置里加一个自定义机器人，把它的地址贴进来就行。",
                "Post a Botin's results, failures and approval requests to a Feishu or Lark group. Add a custom bot in "
                    + "the group's settings and paste its address here."),
            systemImage: "paperplane.fill", tint: .blue, categories: [.communication], builtIn: .feishu),
        ConnectionApp(
            id: wecomID, name: ConnectionText("企业微信", "WeCom"),
            summary: ConnectionText("把任务结果发到企业微信群", "Post task results to WeCom groups"),
            details: ConnectionText(
                "把 Botin 的任务结果、失败提醒和审批请求发到企业微信群里。在群里添加群机器人，把它的地址贴进来就行。",
                "Post a Botin's results, failures and approval requests to a WeCom group. Add a group bot and paste its "
                    + "address here."),
            systemImage: "bubble.left.and.bubble.right.fill", tint: .green, categories: [.communication],
            builtIn: .wecom),
        ConnectionApp(
            id: dingtalkID, name: ConnectionText("钉钉", "DingTalk"),
            summary: ConnectionText("把任务结果发到钉钉群", "Post task results to DingTalk groups"),
            details: ConnectionText(
                "把 Botin 的任务结果、失败提醒和审批请求发到钉钉群里。在群设置里加一个自定义机器人，把它的地址贴进来就行。",
                "Post a Botin's results, failures and approval requests to a DingTalk group. Add a custom bot in the "
                    + "group's settings and paste its address here."),
            systemImage: "bell.badge.fill", tint: .indigo, categories: [.communication], builtIn: .dingtalk),
        ConnectionApp(
            id: modelKeysID, name: ConnectionText("模型 key", "Model keys"),
            summary: ConnectionText(
                "Botin 调模型用你自己的 key，费用由厂商直接收", "Botins use your own keys; providers bill you directly"),
            details: ConnectionText(
                "Botin 调模型用你自己的 key，费用由厂商直接收。每把 key 可以设每日上限，在 Botin 的模型路由里选用哪把。",
                "Botins call models with your own keys, and providers bill you directly. Each key can have a daily "
                    + "limit, and you pick which key a Botin uses in its model routes."),
            systemImage: "key.fill", tint: .orange, categories: [.models], builtIn: .modelKeys),
        ConnectionApp(
            id: vaultID, name: ConnectionText("密码保险箱", "Vault"),
            summary: ConnectionText(
                "Botin 能用的账号密码，密码不会发给模型", "Accounts Botins can sign in with; never sent to the model"),
            details: ConnectionText(
                "Botin 登录网站时能用的账号密码。密码只在 Botin 的沙箱里用，不会发给模型；可以限定哪些 Botin 能用。",
                "Accounts Botins can sign in with. Passwords stay in the Botin's sandbox and are never sent to the "
                    + "model, and you can limit which Botins may use each one."),
            systemImage: "lock.rectangle.stack.fill", tint: .teal, categories: [.passwords], builtIn: .vault),
    ]

    // MARK: 演示：这台手机上的能力（参考 40）

    static let phone: [ConnectionApp] = [
        ConnectionApp(
            id: calendarID, name: ConnectionText("日历", "Calendar"),
            summary: ConnectionText("查看日程、添加活动", "See your schedule and add events"),
            systemImage: "calendar", tint: .red, categories: [.thisDevice], kind: .deviceCapability),
        ConnectionApp(
            id: "phone-home", name: ConnectionText("家庭", "Home"),
            summary: ConnectionText("控制灯光、门锁等配件", "Control lights, locks and other accessories"),
            systemImage: "house.fill", tint: .orange, categories: [.thisDevice], kind: .deviceCapability),
        ConnectionApp(
            id: "phone-reminders", name: ConnectionText("提醒事项", "Reminders"),
            summary: ConnectionText("设置和查看提醒", "Set and check reminders"),
            systemImage: "checklist", tint: .blue, categories: [.thisDevice], kind: .deviceCapability),
        ConnectionApp(
            id: "phone-contacts", name: ConnectionText("通讯录", "Contacts"),
            summary: ConnectionText("查找你认识的人", "Look up people you know"),
            systemImage: "person.crop.circle.fill", tint: .neutral, categories: [.thisDevice],
            kind: .deviceCapability),
        ConnectionApp(
            id: "phone-location", name: ConnectionText("位置", "Location"),
            summary: ConnectionText("查找附近的地方", "Find places nearby"),
            systemImage: "location.fill", tint: .blue, categories: [.thisDevice], kind: .deviceCapability),
        ConnectionApp(
            id: "phone-alarms", name: ConnectionText("闹钟", "Alarms"),
            summary: ConnectionText("设置闹钟和计时器", "Set alarms and timers"),
            systemImage: "alarm.fill", tint: .neutral, categories: [.thisDevice], kind: .deviceCapability),
    ]

    // MARK: 演示：第三方应用（参考 36、41–51、101–107）

    static let apps: [ConnectionApp] = [
        // 密码管理器
        ConnectionApp(
            id: passwordManagerID, name: ConnectionText("外部密码管理器", "Password manager"),
            summary: ConnectionText(
                "让 Botin 在你的电脑上用密码管理器里的登录信息登录网站，每次都会先问你",
                "Let Botins sign in to websites on your computer with your password manager, asking you every time"),
            systemImage: "key.viewfinder", tint: .neutral, categories: [.passwords]),
        // 效率
        ConnectionApp(
            id: "docs", name: ConnectionText("在线文档", "Online docs"),
            summary: ConnectionText("搜索、阅读、新建和修改你的在线文档", "Search, read, create and edit your online documents"),
            systemImage: "doc.text.fill", tint: .blue, categories: [.productivity], recommendedBecause: .feishu),
        ConnectionApp(
            id: "cloud-drive", name: ConnectionText("网盘", "Cloud drive"),
            summary: ConnectionText("浏览、搜索和分享网盘里的文件", "Browse, search and share files in your cloud drive"),
            systemImage: "externaldrive.fill", tint: .blue, categories: [.productivity]),
        ConnectionApp(
            id: "project-boards", name: ConnectionText("项目看板", "Project boards"),
            summary: ConnectionText(
                "新建、更新和跟进任务，按看板整理进度", "Create, update and track tasks, and organise progress on boards"),
            systemImage: "rectangle.split.3x1.fill", tint: .purple, categories: [.productivity],
            recommendedBecause: .feishu),
        ConnectionApp(
            id: "notes", name: ConnectionText("笔记", "Notes"),
            summary: ConnectionText("整理、搜索你的笔记", "Organise and search your notes"),
            systemImage: "note.text", tint: .yellow, categories: [.productivity]),
        ConnectionApp(
            id: "meeting-notes", name: ConnectionText("会议纪要", "Meeting notes"),
            summary: ConnectionText("把会议录音整理成纪要和待办", "Turn meeting recordings into notes and to-dos"),
            systemImage: "waveform", tint: .green, categories: [.productivity]),
        // 通信
        ConnectionApp(
            id: "email", name: ConnectionText("邮件", "Email"),
            summary: ConnectionText("搜索、阅读、起草和整理邮件", "Search, read, draft and organise email"),
            systemImage: "envelope.fill", tint: .blue, categories: [.communication]),
        ConnectionApp(
            id: "shared-calendar", name: ConnectionText("共享日历", "Shared calendars"),
            summary: ConnectionText("查看日程、约会议", "Check schedules and book meetings"),
            systemImage: "calendar.badge.clock", tint: .red, categories: [.communication, .productivity],
            recommendedBecause: .feishu),
        ConnectionApp(
            id: "team-chat", name: ConnectionText("团队聊天", "Team chat"),
            summary: ConnectionText("在频道里收发消息、找聊天记录", "Send and read channel messages, and search history"),
            systemImage: "number", tint: .purple, categories: [.communication], recommendedBecause: .wecom),
        ConnectionApp(
            id: "social", name: ConnectionText("社交媒体", "Social media"),
            summary: ConnectionText("搜索帖子、看热门话题", "Search posts and follow trending topics"),
            systemImage: "at", tint: .neutral, categories: [.communication, .marketing]),
        // 设计
        ConnectionApp(
            id: "design-files", name: ConnectionText("设计稿", "Design files"),
            summary: ConnectionText("查看设计稿、导出切图、留评论", "View design files, export assets and leave comments"),
            systemImage: "paintpalette.fill", tint: .pink, categories: [.design]),
        ConnectionApp(
            id: "image-editor", name: ConnectionText("图片编辑", "Image editor"),
            summary: ConnectionText("生成、裁剪和调整图片", "Generate, crop and adjust images"),
            systemImage: "photo.on.rectangle.angled", tint: .orange, categories: [.design]),
        // 代码
        ConnectionApp(
            id: codeHostingID, name: ConnectionText("代码仓库", "Code hosting"),
            summary: ConnectionText("查看仓库、议题和合并请求", "Browse repositories, issues and pull requests"),
            details: ConnectionText(
                "让 Botin 查看和管理你的代码仓库：搜索代码、看提交记录、开议题、审合并请求、在评论里回复。带的技能能帮你写发布说明、"
                    + "整理议题、查构建失败的原因。Botin 只能碰你授权的仓库；推送代码、合并这类改动，每次都会先问你。",
                "Let Botins browse and manage your repositories: search code, read history, open issues, review pull "
                    + "requests and reply in comments. Its skills help write release notes, triage issues and find why "
                    + "a build failed. Botins only see the repositories you allow, and pushing or merging always asks "
                    + "you first."),
            systemImage: "chevron.left.forwardslash.chevron.right", tint: .neutral, categories: [.code],
            skills: [
                ConnectionText("写发布说明", "Write release notes"), ConnectionText("整理议题", "Triage issues"),
                ConnectionText("审合并请求", "Review pull requests"), ConnectionText("查构建失败", "Debug failed builds"),
            ]),
        ConnectionApp(
            id: "ci", name: ConnectionText("持续集成", "CI"),
            summary: ConnectionText("查看构建、重跑失败的任务", "Check builds and re-run failed jobs"),
            systemImage: "hammer.fill", tint: .green, categories: [.code]),
        ConnectionApp(
            id: "error-tracking", name: ConnectionText("错误监控", "Error tracking"),
            summary: ConnectionText("查看线上错误和告警", "See production errors and alerts"),
            systemImage: "ant.fill", tint: .red, categories: [.code]),
        // 数据
        ConnectionApp(
            id: "databases", name: ConnectionText("数据库", "Databases"),
            summary: ConnectionText("查询数据、生成报表", "Query data and build reports"),
            systemImage: "cylinder.split.1x2.fill", tint: .indigo, categories: [.data]),
        ConnectionApp(
            id: "spreadsheets", name: ConnectionText("在线表格", "Spreadsheets"),
            summary: ConnectionText("读取和更新在线表格", "Read and update online spreadsheets"),
            systemImage: "tablecells.fill", tint: .green, categories: [.data, .productivity],
            recommendedBecause: .feishu),
        ConnectionApp(
            id: "analytics", name: ConnectionText("访问统计", "Analytics"),
            summary: ConnectionText("查看网站和 App 的访问数据", "See traffic for your websites and apps"),
            systemImage: "chart.bar.xaxis", tint: .orange, categories: [.data, .marketing]),
        // 销售
        ConnectionApp(
            id: "crm", name: ConnectionText("客户管理", "CRM"),
            summary: ConnectionText("查找客户、更新商机和跟进记录", "Look up customers and update deals and follow-ups"),
            systemImage: "person.2.fill", tint: .blue, categories: [.sales]),
        ConnectionApp(
            id: "scheduling", name: ConnectionText("预约", "Scheduling"),
            summary: ConnectionText("让客户自己挑时间预约", "Let customers pick a time to meet"),
            systemImage: "calendar.badge.plus", tint: .teal, categories: [.sales]),
        // 营销
        ConnectionApp(
            id: "email-marketing", name: ConnectionText("邮件营销", "Email marketing"),
            summary: ConnectionText("管理订阅者、发营销邮件", "Manage subscribers and send campaigns"),
            systemImage: "megaphone.fill", tint: .orange, categories: [.marketing]),
        ConnectionApp(
            id: "sms", name: ConnectionText("短信通知", "Text messages"),
            summary: ConnectionText("给客户发短信和通知", "Send texts and notices to customers"),
            systemImage: "message.fill", tint: .green, categories: [.marketing]),
        // 财务
        ConnectionApp(
            id: "bookkeeping", name: ConnectionText("记账", "Bookkeeping"),
            summary: ConnectionText("记录收支、对账", "Record income and spending, and reconcile"),
            systemImage: "yensign.circle.fill", tint: .green, categories: [.finance]),
        ConnectionApp(
            id: "invoices", name: ConnectionText("发票", "Invoices"),
            summary: ConnectionText("开发票、查发票状态", "Issue invoices and check their status"),
            systemImage: "doc.richtext.fill", tint: .indigo, categories: [.finance]),
        ConnectionApp(
            id: "bank-accounts", name: ConnectionText("银行账户", "Bank accounts"),
            summary: ConnectionText(
                "连接银行卡和投资账户，查看余额和流水", "Link bank and investment accounts to see balances and activity"),
            systemImage: "building.columns.fill", tint: .teal, categories: [.finance]),
        // 研究
        ConnectionApp(
            id: "papers", name: ConnectionText("文献检索", "Papers"),
            summary: ConnectionText("搜索论文、整理参考文献", "Search papers and organise references"),
            systemImage: "books.vertical.fill", tint: .orange, categories: [.research]),
        ConnectionApp(
            id: "web-search", name: ConnectionText("网页搜索", "Web search"),
            summary: ConnectionText("实时搜索网页和新闻", "Search the web and news in real time"),
            systemImage: "globe", tint: .blue, categories: [.research]),
        // 支持
        ConnectionApp(
            id: "help-desk", name: ConnectionText("客服工单", "Help desk"),
            summary: ConnectionText("搜索对话、联系人和帮助文章", "Search conversations, contacts and help articles"),
            systemImage: "questionmark.bubble.fill", tint: .blue, categories: [.support]),
        ConnectionApp(
            id: "knowledge-base", name: ConnectionText("知识库", "Knowledge base"),
            summary: ConnectionText("管理帮助中心的文章", "Manage help-center articles"),
            systemImage: "book.fill", tint: .green, categories: [.support]),
    ]
}
