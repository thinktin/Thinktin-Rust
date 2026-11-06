import Foundation
import Testing

@testable import ThinktinKit

// 连接目录（规范 4.8，参考 36–52、101–107）：分类、推荐和精选、搜索、已连接列表、详情；自带的接入用真数据，其余是演示数据。

@MainActor
@Suite("连接目录")
struct ConnectionsModelTests {
    private func make(onPhone: Bool = true, category: ConnectionCategory? = nil) -> (MockClient, ConnectionsModel) {
        let mock = makeShellMock()
        return (mock, ConnectionsModel(client: mock, category: category, onPhone: onPhone))
    }

    private func loaded(onPhone: Bool = true) async -> (MockClient, ConnectionsModel) {
        let (mock, model) = make(onPhone: onPhone)
        await model.load()
        return (mock, model)
    }

    @Test("演示目录：id 不重复、每一项至少一个分类、推荐和精选里的 id 都在目录里、自带的六项")
    func catalogIsConsistent() {
        let catalog = ConnectionsDemoData.catalog
        let ids = catalog.apps.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(catalog.apps.allSatisfy { !$0.categories.isEmpty })
        #expect(catalog.recommended.allSatisfy { catalog.app($0) != nil })
        #expect(catalog.featured.allSatisfy { catalog.app($0) != nil })
        #expect(catalog.builtIns.compactMap(\.builtIn) == ConnectionBuiltIn.allCases)
        // 每个分类都有东西（参考 41–51 每一类都有行）。
        for category in ConnectionCategory.allCases {
            #expect(!catalog.apps(in: category).isEmpty, "\(category)")
        }
        // 两种语言都有名字和说明，而且不一样（英文不是漏翻的中文）。
        for app in catalog.apps {
            #expect(!app.name.chinese.isEmpty && !app.name.english.isEmpty)
            #expect(app.summary.chinese != app.summary.english, "\(app.id)")
        }
        // 推荐、精选露出的数比完整列表少（“>”点开才有意义）。
        #expect(catalog.recommended.count > ConnectionList.recommended.previewLimit)
        #expect(catalog.featured.count > ConnectionList.featured.previewLimit)
    }

    @Test("分类胶囊：照参考的顺序，ThinkTin 多了电脑和模型；Mac 上没有“iPhone”")
    func categories() {
        let (_, phone) = make()
        #expect(phone.categories.first == .thisDevice)
        #expect(phone.categories.count == ConnectionCategory.allCases.count)
        #expect(phone.categories.map { $0.title(.chinese) }.prefix(4) == ["iPhone", "电脑", "模型", "密码管理器"])
        #expect(ConnectionCategory.thisDevice.heading(.chinese) == "此 iPhone")
        #expect(ConnectionCategory.thisDevice.explanation(.chinese) != nil)
        #expect(ConnectionCategory.code.explanation(.chinese) == nil)
        let (_, mac) = make(onPhone: false)
        #expect(!mac.categories.contains(.thisDevice))
        #expect(!mac.visibleApps.contains { $0.isPhoneOnly })
        // Mac 上预选“iPhone”时退回“全部”。
        let (_, macPreselected) = make(onPhone: false, category: .thisDevice)
        #expect(macPreselected.category == nil)
        let (_, preselected) = make(category: .code)
        #expect(preselected.category == .code)
    }

    @Test("拉到以后：自带的接入按真数据算连没连（演示数据里电脑、飞书、key、保险箱有，企业微信、钉钉没有）")
    func builtInStatus() async {
        let (_, model) = make()
        let catalog = model.catalog
        // 拉之前不知道：不放按钮。
        let computer = try! #require(catalog.app(.computer))
        #expect(model.status(of: computer) == .unknown)
        #expect(model.row(for: computer).button == nil)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.error == nil)
        #expect(model.status(of: computer) == .connected(count: 1))
        #expect(model.status(of: catalog.app(.feishu)!) == .connected(count: 1))
        #expect(model.status(of: catalog.app(.wecom)!) == .needsSetup)
        #expect(model.status(of: catalog.app(.dingtalk)!) == .needsSetup)
        #expect(model.status(of: catalog.app(.modelKeys)!) == .connected(count: 3))
        #expect(model.status(of: catalog.app(.vault)!) == .connected(count: 2))
        #expect(model.connectedCount == 4)
        #expect(ConnectionsText.connectedCount(model.connectedCount, language: .chinese) == "已连接 4 个")
        // 只算电脑，不算手机、平板。
        #expect(model.computers?.allSatisfy(\.isComputer) == true)
    }

    @Test("行上的按钮：演示的“连接”、手机能力的“允许”弹即将推出；没设置的去现有页面；已连接的灰掉")
    func rowButtons() async throws {
        let (_, model) = await loaded()
        let catalog = model.catalog
        let docs = try #require(catalog.app("docs"))
        let docsButton = try #require(model.row(for: docs, language: .chinese).button)
        #expect(docsButton.title == "连接")
        #expect(docsButton.style == .regular)
        #expect(docsButton.action == .comingSoon("docs"))
        let calendar = try #require(catalog.app(ConnectionsDemoData.calendarID))
        let allow = try #require(model.row(for: calendar, language: .chinese).button)
        #expect(allow.title == "允许")
        #expect(allow.style == .prominent)
        #expect(allow.action == .comingSoon(ConnectionsDemoData.calendarID))
        let wecom = try #require(catalog.app(.wecom))
        let add = try #require(model.row(for: wecom, language: .chinese).button)
        #expect(add.title == "添加")
        #expect(add.style == .prominent)
        #expect(add.action == .open(.imChannels))
        let keys = try #require(catalog.app(.modelKeys))
        let connected = try #require(model.row(for: keys, language: .chinese).button)
        #expect(connected.title == "已连接")
        #expect(!connected.isEnabled)
        // 读屏念成一句：名字、说明、按钮。
        #expect(model.row(for: docs, language: .chinese).accessibilityLabel.hasPrefix("在线文档，"))
        #expect(docsButton.accessibilityLabel == "连接 在线文档")
    }

    @Test("没设置时按钮去的地方：配对电脑看登录设备、加群在 IM 渠道、加 key 弹添加 key、保险箱进列表")
    func setupRoutes() {
        #expect(ConnectionBuiltIn.computer.setupRoute == .devices)
        #expect(ConnectionBuiltIn.feishu.setupRoute == .imChannels)
        #expect(ConnectionBuiltIn.modelKeys.setupRoute == .addCredential)
        #expect(ConnectionBuiltIn.vault.setupRoute == .vault)
        #expect(ConnectionBuiltIn.modelKeys.manageRoute == .credentials)
        #expect(ConnectionBuiltIn.dingtalk.manageRoute == .imChannels)
        #expect(ConnectionBuiltIn.feishu.imVendors == [.feishu, .lark])
        #expect(ConnectionsText.setup(.computer, language: .chinese) == "配对")
    }

    @Test("文案是 ThinkTin 自己的：搜索框、已连接列表的小标题不照抄参考的句子")
    func ownCopy() {
        #expect(ConnectionsText.searchPrompt(.chinese) == "按名字或用途搜索")
        #expect(ConnectionsText.searchPrompt(.english) == "Search by name or use")
        #expect(ConnectionsText.installedHeader(.chinese) == "ThinkTin 自带")
        #expect(ConnectionList.recommended.title(.chinese) == "推荐")
        // 小标题已经说了是自带的，脚注不再重复。
        #expect(!ConnectionsText.installedFootnote(.chinese).contains("自带"))
    }

    @Test("“全部”：推荐露出 4 个、精选 6 个，标题点开完整列表")
    func allSections() async {
        let (_, model) = await loaded()
        let sections = model.sections(.chinese)
        #expect(sections.map(\.id) == [.list(.recommended), .list(.featured)])
        #expect(sections.map(\.title) == ["推荐", "精选"])
        #expect(sections[0].rows.count == 4)
        #expect(sections[1].rows.count == 6)
        #expect(sections[0].moreRoute == .connectionList(.recommended))
        #expect(sections[1].moreRoute == .connectionList(.featured))
        // 精选打头的是 ThinkTin 自带的。
        #expect(sections[1].rows.first?.id == ConnectionsDemoData.computerID)
        // 完整列表比露出的多。
        #expect(model.listRows(.recommended, language: .chinese).count == model.catalog.recommended.count)
        #expect(model.listRows(.featured, language: .chinese).count == model.catalog.featured.count)
    }

    @Test("推荐理由：连了相关的那一项才写“因为你连了 …”，没连写说明")
    func recommendationReason() async throws {
        let (mock, model) = await loaded()
        let docs = try #require(model.catalog.app("docs"))
        #expect(model.recommendationReason(for: docs, language: .chinese) == "因为你连了飞书")
        let rows = model.listRows(.recommended, language: .chinese)
        #expect(rows.first { $0.id == "docs" }?.subtitle == "因为你连了飞书")
        // 团队聊天的理由是企业微信，演示数据里没连：写说明。
        let chat = try #require(model.catalog.app("team-chat"))
        #expect(model.recommendationReason(for: chat, language: .chinese) == nil)
        #expect(rows.first { $0.id == "team-chat" }?.subtitle == chat.summary.chinese)
        // 精选、分类里的行不写理由。
        model.category = .productivity
        #expect(model.sections(.chinese)[0].rows.first { $0.id == "docs" }?.subtitle == docs.summary.chinese)
        // 群都删了：不再写理由。
        mock.update { $0.imChannels = [] }
        await model.load()
        #expect(model.recommendationReason(for: docs, language: .english) == nil)
    }

    @Test("选了分类：一组，标题是分类名（“此 iPhone”带说明），列出这一类的全部")
    func categorySection() async {
        let (_, model) = await loaded()
        model.category = .thisDevice
        var sections = model.sections(.chinese)
        #expect(sections.count == 1)
        #expect(sections[0].id == .category(.thisDevice))
        #expect(sections[0].title == "此 iPhone")
        #expect(sections[0].explanation != nil)
        #expect(sections[0].moreRoute == nil)
        #expect(sections[0].rows.map(\.title) == ["日历", "家庭", "提醒事项", "通讯录", "位置", "闹钟"])
        #expect(sections[0].rows.allSatisfy { $0.button?.title == "允许" })
        model.category = .communication
        sections = model.sections(.chinese)
        #expect(sections[0].title == "通信")
        // 自带的 IM 渠道排在前面，后面是演示的应用。
        #expect(sections[0].rows.prefix(3).map(\.id) == ["feishu", "wecom", "dingtalk"])
        model.category = .passwords
        #expect(model.sections(.english)[0].rows.map(\.id) == ["vault", ConnectionsDemoData.passwordManagerID])
    }

    @Test("搜索：名字、说明、技能，两种语言都搜，不分大小写；Mac 上搜不到手机能力")
    func search() async {
        let (_, model) = await loaded()
        #expect(model.searchResults("key", language: .chinese).map(\.id) == ["model-keys"])
        #expect(model.searchResults("FEISHU", language: .chinese).first?.id == "feishu")
        #expect(model.searchResults("发布说明", language: .chinese).map(\.id) == [ConnectionsDemoData.codeHostingID])
        #expect(model.searchResults("日历", language: .chinese).map(\.id).contains(ConnectionsDemoData.calendarID))
        #expect(model.searchResults("   ", language: .chinese).isEmpty)
        model.query = "邮件"
        let sections = model.sections(.chinese)
        #expect(sections.map(\.id) == [.search])
        #expect(sections[0].rows.map(\.id).contains("email"))
        model.query = "完全没有这个"
        #expect(model.sections(.chinese)[0].rows.isEmpty)
        let (_, mac) = await loaded(onPhone: false)
        #expect(!mac.searchResults("日历", language: .chinese).map(\.id).contains(ConnectionsDemoData.calendarID))
    }

    @Test("已连接列表（参考 37）：自带的六项，连上的写账户数，没设置的写说明，按名字过滤")
    func installed() async {
        let (_, model) = await loaded()
        let rows = model.installedRows(.chinese)
        #expect(rows.map(\.id) == model.catalog.builtIns.map(\.id))
        #expect(rows.first { $0.id == "computer" }?.subtitle == "1 台电脑")
        #expect(rows.first { $0.id == "feishu" }?.subtitle == "1 个群")
        #expect(rows.first { $0.id == "model-keys" }?.subtitle == "3 个 key")
        #expect(rows.first { $0.id == "vault" }?.subtitle == "2 个条目")
        #expect(rows.first { $0.id == "wecom" }?.subtitle == model.catalog.app(.wecom)?.summary.chinese)
        #expect(model.installedRows(.english).first { $0.id == "model-keys" }?.subtitle == "3 keys")
        #expect(ConnectionsText.accountCount(1, of: .vault, language: .english) == "1 item")
        model.query = "钉钉"
        #expect(model.installedRows(.chinese).map(\.id) == ["dingtalk"])
    }

    @Test("详情：已连接的有账户、添加账户、“…”菜单、灰掉的“已连接”；账户点了进各自的页面")
    func connectedDetail() async throws {
        let (_, model) = await loaded()
        let keys = try #require(model.detail(ConnectionsDemoData.modelKeysID, language: .chinese))
        #expect(keys.status == .connected(count: 3))
        #expect(keys.showsMenu)
        #expect(keys.manageRoute == .credentials)
        #expect(keys.addAccount == .open(.addCredential))
        #expect(keys.accounts.map(\.title) == ["Claude 主力", "DeepSeek", "百炼（停用）"])
        #expect(keys.accounts.map(\.isDimmed) == [false, false, true])
        #expect(keys.accounts[0].route == .credential(DemoData.claudeCredentialID))
        #expect(keys.accounts[2].subtitle == "••••3hTz · 已停用")
        #expect(keys.primary?.title == "已连接")
        #expect(keys.primary?.isEnabled == false)
        #expect(keys.disconnectNote != nil)
        #expect(keys.footnote == nil)
        let computer = try #require(model.detail(ConnectionsDemoData.computerID, language: .chinese))
        #expect(computer.accounts.map(\.title) == ["张三的 MacBook Pro"])
        #expect(computer.accounts.first?.subtitle == "在线")
        #expect(computer.accounts.first?.route == .devices)
        let feishu = try #require(model.detail(ConnectionsDemoData.feishuID, language: .chinese))
        #expect(feishu.accounts.map(\.title) == ["研发群"])
        #expect(feishu.accounts.first?.route == .imChannels)
        let vault = try #require(model.detail(ConnectionsDemoData.vaultID, language: .chinese))
        #expect(vault.accounts.map(\.title) == ["github", "aliyun-oss"])
        #expect(vault.accounts.first?.route == .vaultItem(DemoData.githubVaultID))
    }

    @Test("详情：没设置的、演示的、手机能力；演示数据有“即将推出”的脚注，带技能的列出技能")
    func otherDetails() async throws {
        let (_, model) = await loaded()
        let wecom = try #require(model.detail(ConnectionsDemoData.wecomID, language: .chinese))
        #expect(wecom.status == .needsSetup)
        #expect(!wecom.showsMenu)
        #expect(wecom.accounts.isEmpty)
        #expect(wecom.addAccount == nil)
        #expect(wecom.primary?.title == "添加群机器人")
        #expect(wecom.primary?.action == .open(.imChannels))
        let code = try #require(model.detail(ConnectionsDemoData.codeHostingID, language: .chinese))
        #expect(code.status == .available)
        #expect(code.primary?.action == .comingSoon(ConnectionsDemoData.codeHostingID))
        #expect(code.skills.count == 4)
        #expect(
            code.description.count > (model.catalog.app(ConnectionsDemoData.codeHostingID)?.summary.chinese.count ?? 0))
        #expect(code.footnote == ConnectionsText.comingSoonFootnote(.chinese))
        #expect(code.disconnectNote == nil)
        #expect(code.manageRoute == nil)
        let calendar = try #require(model.detail(ConnectionsDemoData.calendarID, language: .english))
        #expect(calendar.primary?.title == "Allow")
        #expect(model.detail("nope") == nil)
        // Mac 上没有手机能力的详情。
        let (_, mac) = await loaded(onPhone: false)
        #expect(mac.detail(ConnectionsDemoData.calendarID) == nil)
        #expect(
            model.comingSoonMessage(ConnectionsDemoData.codeHostingID, language: .chinese)
                == "ThinkTin 还不能连代码仓库，做好了会在这里打开。")
    }

    @Test("拉不到：四样都失败时报错、不放按钮；只失败一样不报错，那一项不放按钮")
    func loadFailures() async throws {
        let (mock, model) = make()
        mock.failNext("devices()", with: .network(message: "offline"))
        mock.failNext("imChannels()", with: .network(message: "offline"))
        mock.failNext("credentials()", with: .network(message: "offline"))
        mock.failNext("vaultItems()", with: .network(message: "offline"))
        await model.load()
        #expect(model.error == .network(message: "offline"))
        #expect(model.connectedCount == 0)
        let vault = try #require(model.catalog.app(.vault))
        #expect(model.row(for: vault).button == nil)
        // 演示数据照样能看。
        #expect(model.sections(.chinese)[0].rows.count == 4)
        await model.load()
        #expect(model.error == nil)
        #expect(model.connectedCount == 4)
        // 再失败一样：留着上次拉到的。
        mock.failNext("credentials()", with: .network(message: "offline"))
        await model.load()
        #expect(model.error == nil)
        #expect(model.status(of: try #require(model.catalog.app(.modelKeys))) == .connected(count: 3))
        // 刚打开就只失败一样：那一项不知道。
        let (mock2, fresh) = make()
        mock2.failNext("imChannels()", with: .network(message: "offline"))
        await fresh.load()
        #expect(fresh.error == nil)
        #expect(fresh.status(of: try #require(fresh.catalog.app(.feishu))) == .unknown)
        #expect(fresh.connectedCount == 3)
    }

    @Test("文案：这几页不带 AI 生成标识；设置里那一行指过来")
    func text() {
        #expect(ConnectionsText.showsAIGeneratedLabel == false)
        #expect(ConnectionsText.disconnect(.chinese) == "断开连接")
        #expect(ConnectionsText.goManage(.modelKeys, language: .chinese) == "去模型 key")
        #expect(ConnectionsText.because("飞书", language: .english) == "Because you use 飞书")
        #expect(ConnectionsText.comingSoonMessage(nil, language: .english).hasPrefix("This isn't ready"))
    }
}
