import Foundation
import Testing

@testable import ThinktinKit

@Suite("IM 渠道的规则（12.14，和 proto::im 一致）")
struct ImChannelRulesTests {
    @Test("官方地址认出平台和 token；首尾空白不算")
    func parsesOfficialAddresses() throws {
        let cases: [(String, ImVendor, String)] = [
            (
                "https://open.feishu.cn/open-apis/bot/v2/hook/2f8a6c1e-1111-4a2b-9c3d-0123456789ab", .feishu,
                "2f8a6c1e-1111-4a2b-9c3d-0123456789ab"
            ),
            ("https://open.larksuite.com/open-apis/bot/v2/hook/abcdef1234567890", .lark, "abcdef1234567890"),
            (
                " https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa\n", .wecom,
                "693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa"
            ),
            (
                "https://oapi.dingtalk.com/robot/send?access_token=0123456789abcdef0123456789abcdef", .dingtalk,
                "0123456789abcdef0123456789abcdef"
            ),
        ]
        for (url, vendor, token) in cases {
            let parsed = try ImChannelRules.parseWebhook(url).get()
            #expect(parsed.vendor == vendor)
            #expect(parsed.token == token)
            #expect(ImChannelRules.vendor(of: url) == vendor)
        }
        #expect(ImChannelRules.hint("0123456789abcdef") == "…cdef")
    }

    @Test("改过的地址不认：别的主机、大小写、端口、用户名、路径不对、参数在前")
    func rejectsLookalikes() {
        let token = "0123456789abcdef"
        for url in [
            "https://open.feishu.cn.evil.com/open-apis/bot/v2/hook/\(token)",
            "https://open.feishu.cn./open-apis/bot/v2/hook/\(token)",
            "https://OPEN.FEISHU.CN/open-apis/bot/v2/hook/\(token)",
            "https://open.feishu.cn:8443/open-apis/bot/v2/hook/\(token)",
            "https://user@open.feishu.cn/open-apis/bot/v2/hook/\(token)",
            "https://evil.com/?https://open.feishu.cn/open-apis/bot/v2/hook/\(token)",
            "https://open.feishu.cn/open-apis/bot/hook/\(token)",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?debug=1&key=\(token)",
            "http://open.feishu.cn/open-apis/bot/v2/hook/\(token)",
            "",
        ] {
            #expect(throws: ImChannelProblem.unknownAddress, "\(url)") { try ImChannelRules.parseWebhook(url).get() }
        }
        for url in [
            "https://open.feishu.cn/open-apis/bot/v2/hook/\(token)/x",
            "https://open.feishu.cn/open-apis/bot/v2/hook/\(token)?x=1",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=\(token)&debug=1",
            "https://oapi.dingtalk.com/robot/send?access_token=short",
            "https://oapi.dingtalk.com/robot/send?access_token=" + String(repeating: "a", count: 129),
            "https://open.feishu.cn/open-apis/bot/v2/hook/",
        ] {
            #expect(throws: ImChannelProblem.badToken, "\(url)") { try ImChannelRules.parseWebhook(url).get() }
        }
        // 没粘完整也认得出是哪家（表单上先显示平台）。
        #expect(ImChannelRules.vendor(of: "https://open.feishu.cn/open-apis/bot/v2/hook/") == .feishu)
        #expect(ImChannelRules.vendor(of: "https://example.com") == nil)
    }

    @Test("签名密钥：空的就是没有；企业微信没有；8 到 128 个可见字符；钉钉以 SEC 开头")
    func secrets() {
        #expect(ImChannelRules.checkSecret("  ", vendor: .wecom) == nil)
        #expect(ImChannelRules.checkSecret("SEC12345", vendor: .wecom) == .secretNotSupported)
        #expect(ImChannelRules.checkSecret("abcdefgh", vendor: .feishu) == nil)
        #expect(ImChannelRules.checkSecret("abc", vendor: .feishu) == .badSecret)
        #expect(ImChannelRules.checkSecret("abcd efgh", vendor: .feishu) == .badSecret)
        #expect(ImChannelRules.checkSecret("密钥密钥密钥密钥", vendor: .lark) == .badSecret)
        #expect(ImChannelRules.checkSecret(String(repeating: "a", count: 129), vendor: .feishu) == .badSecret)
        #expect(ImChannelRules.checkSecret("12345678", vendor: .dingtalk) == .badSecret)
        #expect(ImChannelRules.checkSecret("SEC12345", vendor: .dingtalk) == nil)
    }

    @Test("备注最多 64 个字（按标量数）、没有控制字符；事件至少一种")
    func labelsAndEvents() {
        #expect(ImChannelRules.checkLabel("") == nil)
        #expect(ImChannelRules.checkLabel(String(repeating: "群", count: 64)) == nil)
        #expect(ImChannelRules.checkLabel(String(repeating: "群", count: 65)) == .badLabel)
        #expect(ImChannelRules.checkLabel("研发\n群") == .badLabel)
        #expect(ImChannelRules.checkEvents([]) == .noEvents)
        #expect(ImChannelRules.checkEvents([.approval]) == nil)
    }

    @Test("发送失败的原因换成怎么处理；认不出的给原文")
    func lastErrors() {
        #expect(
            ImChannelText.lastError(
                "feishu 19024: the message has none of the bot's custom keywords", language: .chinese
            )
            .contains("ThinkTin"))
        #expect(
            ImChannelText.lastError(
                "wecom 93000: the webhook is invalid or the bot was removed from the group", language: .chinese
            )
            .contains("换上新地址"))
        #expect(
            ImChannelText.lastError(
                "dingtalk 310000: security check failed (signing secret, custom keywords or IP list)",
                language: .english
            )
            .contains("security settings"))
        #expect(ImChannelText.lastError("feishu http 418: odd", language: .chinese).hasSuffix("feishu http 418: odd"))
        let channel = ImChannel(id: "c1", vendor: .wecom, label: " ", hint: "…abcd", createdAt: Date())
        #expect(ImChannelText.title(channel, language: .chinese) == "企业微信群机器人 …abcd")
    }
}

@MainActor
@Suite("IM 渠道的页面（12.14）")
struct ImChannelModelTests {
    private let wecom = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abcd1234efgh"

    @Test("列表：加载、开关、测试消息（关着的先提示，每小时 10 条）、删除")
    func list() async throws {
        let mock = makeShellMock()
        let model = ImChannelsModel(client: mock)
        await model.load()
        #expect(model.channels.map(\.id) == [DemoData.feishuChannelID])
        #expect(model.canAdd)

        await model.setEnabled(DemoData.feishuChannelID, false)
        #expect(model.channels.first?.isEnabled == false)
        await model.sendTest(DemoData.feishuChannelID)
        #expect(model.notice == .turnOnFirst)
        #expect(mock.callCount("testImChannel(_:)") == 0)

        await model.setEnabled(DemoData.feishuChannelID, true)
        await model.sendTest(DemoData.feishuChannelID)
        #expect(model.notice == .testQueued(DemoData.feishuChannelID))
        for _ in 1..<ImChannelRules.testsPerHour { await model.sendTest(DemoData.feishuChannelID) }
        #expect(model.notice == .testQueued(DemoData.feishuChannelID))
        await model.sendTest(DemoData.feishuChannelID)
        #expect(model.notice == .testRateLimited)
        #expect(model.error == nil)

        // 别处已经删了：照样拿掉。
        mock.update { $0.imChannels = [] }
        await model.delete(DemoData.feishuChannelID)
        #expect(model.channels.isEmpty)
        #expect(model.error == nil)
    }

    @Test("新建：边粘边认出平台；问题点了保存才标；默认全部事件")
    func create() async throws {
        let mock = makeShellMock()
        let editor = ImChannelEditorModel(client: mock)
        #expect(editor.isNew && editor.editsWebhook)
        #expect(editor.events == ImEvent.knownCases)

        editor.webhookURL = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key="
        #expect(editor.vendor == .wecom)
        #expect(!editor.supportsSecret)
        #expect(await editor.save() == nil)
        #expect(editor.attemptedSave)
        #expect(editor.webhookProblem == .badToken)

        editor.webhookURL = wecom
        editor.secret = "SEC12345"
        #expect(editor.secretProblem == .secretNotSupported)
        editor.secret = ""
        editor.toggle(.approval)
        editor.toggle(.runFinished)
        editor.toggle(.runFailed)
        #expect(editor.eventsProblem == .noEvents)
        editor.toggle(.approval)
        editor.toggle(.runFinished)
        // 选的顺序不影响：按固定顺序发。
        #expect(editor.events == [.runFinished, .approval])
        editor.label = "  运维群 "
        let created = try #require(await editor.save())
        #expect(created.vendor == .wecom)
        #expect(created.label == "运维群")
        #expect(created.events == [.runFinished, .approval])
        #expect(created.hint == "…efgh")
        #expect(!created.hasSecret)
    }

    @Test("修改：只发改了的；换地址时先改备注再换，换失败了再点只换地址")
    func edit() async throws {
        let mock = makeShellMock()
        let channel = try #require(try await mock.imChannels().first)
        let editor = ImChannelEditorModel(client: mock, channel: channel)
        #expect(!editor.editsWebhook)
        #expect(editor.vendor == .feishu)
        #expect(!editor.hasChanges)

        editor.label = "研发二群"
        editor.isReplacingWebhook = true
        editor.webhookURL = "https://oapi.dingtalk.com/robot/send?access_token=0123456789abcdef"
        editor.secret = "SEC12345"
        mock.failNext("replaceImWebhook(_:webhookURL:secret:)", with: .network(message: "offline"))
        #expect(await editor.save() == nil)
        #expect(editor.error?.isOffline == true)
        #expect(try await mock.imChannels().first?.label == "研发二群")

        let saved = try #require(await editor.save())
        #expect(mock.callCount("updateImChannel(_:label:events:enabled:)") == 1)
        #expect(saved.vendor == .dingtalk)
        #expect(saved.hasSecret)
        #expect(saved.label == "研发二群")
    }

    @Test("换地址：机器人失效被停用的重新打开，错误清掉")
    func replaceReopens() async throws {
        let mock = makeShellMock()
        mock.update { s in
            s.imChannels[0].isEnabled = false
            s.imChannels[0].lastError = "feishu 19001: the bot's webhook token is invalid (bot removed?)"
        }
        let channel = try #require(try await mock.imChannels().first)
        let editor = ImChannelEditorModel(client: mock, channel: channel)
        editor.isReplacingWebhook = true
        editor.webhookURL = "https://open.feishu.cn/open-apis/bot/v2/hook/2f8a6c1e-1111-4a2b-9c3d-0123456789ab"
        let saved = try #require(await editor.save())
        #expect(saved.isEnabled)
        #expect(saved.lastError == nil)
        #expect(!saved.hasSecret)
    }
}
