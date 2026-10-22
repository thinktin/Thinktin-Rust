import Foundation
import Testing

@testable import ThinktinKit

// 登录设备、下线其他设备、全部停止（WBS 12.2）。

@MainActor
@Suite("登录设备与全部停止")
struct DevicesModelTests {
    private func make() -> (MockClient, AppModel, DevicesModel) {
        let mock = makeShellMock()
        let app = AppModel(client: mock, defaults: nil)
        return (mock, app, DevicesModel(client: app.client))
    }

    @Test("列表：本机在最前，其余按最近活跃；电脑在线")
    func load() async {
        let (_, _, model) = make()
        #expect(!model.hasLoaded)
        await model.loadIfNeeded()
        #expect(model.hasLoaded)
        #expect(model.devices.map(\.id) == [DemoData.deviceID, DemoData.macDeviceID, DemoData.iPadDeviceID])
        #expect(model.currentDevice?.id == DemoData.deviceID)
        #expect(model.otherDevices.count == 2)
        #expect(model.devices[1].isComputer && model.devices[1].isOnline)
        #expect(!model.devices[2].isOnline)
        // 拉过了不重复拉。
        await model.loadIfNeeded()
        #expect(model.loadError == nil)
    }

    @Test("拉不到：记下错误，之前的列表留着")
    func loadError() async {
        let (mock, _, model) = make()
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.loadError?.isOffline == true)
        #expect(model.devices.count == 3)
        await model.load()
        #expect(model.loadError == nil)
    }

    @Test("下线别的设备：从列表里去掉，服务端也没了")
    func revokeOther() async {
        let (mock, app, model) = make()
        await model.load()
        let iPad = try! #require(model.devices.first { $0.id == DemoData.iPadDeviceID })
        #expect(await model.revoke(iPad))
        #expect(model.devices.map(\.id) == [DemoData.deviceID, DemoData.macDeviceID])
        #expect(model.lastRevoked?.id == DemoData.iPadDeviceID)
        #expect(!mock.state.devices.contains { $0.id == DemoData.iPadDeviceID })
        #expect(app.phase == .signedIn)
        model.dismissLastRevoked()
        #expect(model.lastRevoked == nil)
    }

    @Test("下线本机等于退出登录：应用框架回到登录页")
    func revokeCurrent() async {
        let (mock, app, model) = make()
        await app.start()
        await model.load()
        let current = try! #require(model.currentDevice)
        #expect(await model.revoke(current))
        #expect(!mock.signedIn())
        #expect(await eventually { app.phase == .signedOut })
        #expect(app.instances.isEmpty)
    }

    @Test("下线时设备已经不在了（别处下线过）：当作成功；其他错误留着提示")
    func revokeErrors() async {
        let (mock, _, model) = make()
        await model.load()
        let mac = try! #require(model.devices.first { $0.id == DemoData.macDeviceID })
        mock.failNext(with: .api(status: 404, code: .notFound, message: "device not found", retryAfterSecs: nil))
        #expect(await model.revoke(mac))
        #expect(!model.devices.contains { $0.id == DemoData.macDeviceID })
        #expect(model.actionError == nil)

        let iPad = try! #require(model.devices.first { $0.id == DemoData.iPadDeviceID })
        mock.failNext(with: .network(message: "offline"))
        #expect(await !model.revoke(iPad))
        #expect(model.actionError?.isOffline == true)
        #expect(model.devices.contains { $0.id == DemoData.iPadDeviceID })
        #expect(model.revoking.isEmpty)
        model.dismissActionError()
        #expect(model.actionError == nil)
    }

    @Test("下线其他设备：只剩本机，结果有台数；不勾选全部停止时运行照常")
    func signOutOthers() async {
        let (mock, app, model) = make()
        await model.load()
        let activeBefore = mock.state.runs.filter(\.state.isActive).count
        let result = await model.signOutOthers(stopAgents: false)
        #expect(result == SignOutOthersResult(devicesSignedOut: 2))
        #expect(model.signOutOthersResult == result)
        #expect(model.devices.map(\.id) == [DemoData.deviceID])
        #expect(mock.state.runs.filter(\.state.isActive).count == activeBefore)
        #expect(app.phase == .signedIn)
        #expect(result?.summary(.chinese) == "已下线 2 台设备，它们要重新登录才能再用。")
    }

    @Test("下线其他设备并全部停止：运行取消、计划暂停，结果里有数字")
    func signOutOthersAndStop() async {
        let (mock, _, model) = make()
        await model.load()
        let active = mock.state.runs.filter(\.state.isActive).count
        let unpaused = mock.state.plans.filter { !$0.isPaused }.count
        #expect(active > 0)
        let result = await model.signOutOthers(stopAgents: true)
        #expect(result?.devicesSignedOut == 2)
        #expect(result?.stopped == StopAllResult(runsCancelled: active, grantsRevoked: active, plansPaused: unpaused))
        #expect(mock.state.runs.filter(\.state.isActive).isEmpty)
        #expect(mock.state.plans.filter { !$0.isPaused }.isEmpty)
    }

    @Test("下线其他设备失败：提示，列表不动")
    func signOutOthersError() async {
        let (mock, _, model) = make()
        await model.load()
        mock.failNext(with: .api(status: 503, code: .unavailable, message: "down", retryAfterSecs: nil))
        #expect(await model.signOutOthers(stopAgents: false) == nil)
        #expect(model.actionError?.apiCode == .unavailable)
        #expect(model.devices.count == 3)
        #expect(!model.isSigningOutOthers)
    }

    @Test("全部停止：结果有取消、吊销、暂停的数字；再停一次什么都没有")
    func stopAll() async {
        let (mock, app, _) = make()
        let model = StopAllModel(client: app.client)
        let active = mock.state.runs.filter(\.state.isActive).count
        let unpaused = mock.state.plans.filter { !$0.isPaused }.count
        let result = await model.stopAll()
        #expect(result == StopAllResult(runsCancelled: active, grantsRevoked: active, plansPaused: unpaused))
        #expect(model.result == result)
        #expect(!model.isStopping)
        #expect(mock.state.runs.filter(\.state.isActive).isEmpty)
        let again = await model.stopAll()
        #expect(again?.isEmpty == true)
        #expect(again?.summary(.chinese) == "没有在跑的任务，计划也都已经暂停。")
    }

    @Test("全部停止失败：记下错误；冻结时应用框架切到冻结页")
    func stopAllErrors() async {
        let (mock, app, _) = make()
        await app.start()
        let model = StopAllModel(client: app.client)
        mock.failNext(with: .network(message: "offline"))
        #expect(await model.stopAll() == nil)
        #expect(model.error?.isOffline == true)
        model.dismissError()
        #expect(model.error == nil)
        mock.failNext(with: .accountFrozen)
        #expect(await model.stopAll() == nil)
        #expect(await eventually { app.phase == .frozen })
    }
}
