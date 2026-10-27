import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("Mac 的手机控制（14.5、14.6、14.8）")
struct ComputerHostModelTests {
    private let phone = DemoData.iPadDeviceID

    private func grant(_ id: String, expiresIn: TimeInterval) -> CapabilityGrant {
        CapabilityGrant(
            desktopID: DemoData.macDeviceID, tokenID: id, dirs: ["/Users/me/Documents"], apps: [],
            expiresAt: Date().addingTimeInterval(expiresIn))
    }

    @Test("开始、连上、停止：状态跟着服务的事件变")
    func startAndStop() async {
        let host = FakeComputerHost()
        let model = ComputerHostModel(host: host)
        #expect(model.connection == .offline)
        #expect(ComputerHostText.status(model, language: .chinese).hasPrefix("已停止"))

        model.start()
        #expect(model.isEnabled)
        #expect(host.connection() == .connecting)
        await model.apply(.connection(.connecting))
        #expect(ComputerHostText.status(model, language: .chinese) == "正在连接……")
        await model.apply(.connection(.connected))
        #expect(!model.isControllable, "还没配对手机")
        #expect(ComputerHostText.status(model, language: .chinese).contains("还没配对"))

        model.stop()
        await model.apply(.stopped(.requested))
        #expect(!model.isEnabled)
        #expect(model.stopReason == nil, "自己停的不算出错")
        #expect(model.connection == .offline)
    }

    @Test("agent 正在执行工具：状态行说在做什么；结束、断线、停下时清掉")
    func activity() async {
        let host = FakeComputerHost(phone: HostPhone(deviceID: phone, publicKey: "k"))
        let model = ComputerHostModel(host: host)
        model.start()
        await model.apply(.connection(.connected))
        await model.apply(.activity("computer_screenshot"))
        #expect(model.activeTool == "computer_screenshot")
        #expect(ComputerHostText.status(model, language: .chinese).contains("正在使用这台电脑：截图"))
        #expect(ComputerHostText.status(model, language: .english).contains("taking a screenshot"))
        await model.apply(.activity(nil))
        #expect(model.activeTool == nil)
        #expect(ComputerHostText.status(model, language: .chinese).hasPrefix("已连接："))

        await model.apply(.activity("computer_run"))
        await model.apply(.connection(.connecting))
        #expect(model.activeTool == nil, "断线时调用都断了")
        await model.apply(.connection(.connected))
        await model.apply(.activity("computer_click"))
        await model.apply(.stopped(.replaced))
        #expect(model.activeTool == nil)
        #expect(ComputerHostText.toolName("computer_something", language: .chinese) == "computer_something")
    }

    @Test("被中继拒绝、被顶掉：停下并说清楚，不自动重启；再开始时清掉")
    func stopReasons() async {
        let host = FakeComputerHost()
        let model = ComputerHostModel(host: host)
        model.start()
        await model.apply(.stopped(.refused("account frozen")))
        #expect(!model.isEnabled)
        #expect(model.stopReason == .refused("account frozen"))
        #expect(ComputerHostText.status(model, language: .chinese).contains("拒绝"))
        model.start()
        #expect(model.stopReason == nil)
        await model.apply(.stopped(.replaced))
        #expect(ComputerHostText.status(model, language: .english).contains("is ThinkTin open twice?"))
    }

    @Test("配对：出二维码、过期了提示再出一个；出不了时说原因；手机扫码配好后记下手机和它的名字")
    func pairing() async {
        var clock = Date()
        let host = FakeComputerHost()
        let model = ComputerHostModel(host: host, client: makeShellMock(), now: { clock })
        model.startPairing()
        let code = model.pairingCode
        #expect(code?.hasPrefix("thinktin-pair:v1?") == true)
        #expect(!model.pairingExpired)
        clock = clock.addingTimeInterval(ComputerHostModel.pairingTTL + 1)
        #expect(model.pairingCode == nil)
        #expect(model.pairingExpired)

        host.failNextPairing(.pairing("not a P-256 public key"))
        model.startPairing()
        #expect(model.error == .pairing("not a P-256 public key"))
        #expect(ComputerHostText.error(model.error!, language: .chinese).contains("出不了二维码"))

        model.startPairing()
        #expect(model.error == nil)
        host.send(.pairing(.paired(phoneID: phone)))
        await model.apply(.pairing(.paired(phoneID: phone)))
        #expect(model.phone?.deviceID == phone)
        #expect(model.phoneName == "张三的 iPad")
        #expect(ComputerHostText.paired(name: model.phoneName, language: .chinese) == "已和“张三的 iPad”配对")
        await model.apply(.connection(.connected))
        #expect(model.isControllable)

        model.cancelPairing()
        #expect(model.pairing == .idle)
    }

    @Test("授权：只列还有效的，快到期的在前；解除配对后手机和授权都没了")
    func grantsAndUnpair() async {
        let host = FakeComputerHost(
            phone: HostPhone(deviceID: phone, publicKey: "k"),
            grants: [grant("later", expiresIn: 7200), grant("soon", expiresIn: 600), grant("gone", expiresIn: -60)])
        let model = ComputerHostModel(host: host)
        #expect(model.phone?.deviceID == phone)
        #expect(model.activeGrants.map(\.tokenID) == ["soon", "later"])

        host.setGrants([])
        model.refresh()
        #expect(model.activeGrants.isEmpty)

        model.unpair()
        #expect(model.phone == nil)
        #expect(model.phoneName == nil)
    }
}
