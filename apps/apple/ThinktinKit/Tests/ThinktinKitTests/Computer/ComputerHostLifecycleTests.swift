import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("Mac 的工具服务跟着登录状态走（14.5、14.6）")
struct ComputerHostLifecycleTests {
    private let mac = DemoData.macDeviceID

    private func defaults() -> UserDefaults {
        let name = "lifecycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("登录了才建服务；开关按设备记下，下次照着开；退出登录停下但不改记下的开关")
    func followsSignIn() async {
        let defaults = defaults()
        var hosts: [DeviceID: FakeComputerHost] = [:]
        let lifecycle = ComputerHostLifecycle(client: nil, defaults: defaults) { id in
            let host = FakeComputerHost()
            hosts[id] = host
            return host
        }
        lifecycle.update(signedIn: false, deviceID: nil)
        #expect(lifecycle.model == nil)
        lifecycle.update(signedIn: true, deviceID: nil)
        #expect(lifecycle.model == nil, "没有设备 id 建不了")

        lifecycle.update(signedIn: true, deviceID: mac)
        let first = lifecycle.model
        #expect(first != nil)
        #expect(first?.isEnabled == false, "第一次登录：默认关着")
        #expect(hosts[mac]?.connection() == .offline)
        lifecycle.update(signedIn: true, deviceID: mac)
        #expect(lifecycle.model === first, "同一台设备不重建")

        first?.start()
        #expect(lifecycle.wantsEnabled(mac))
        lifecycle.update(signedIn: false, deviceID: nil)
        #expect(lifecycle.model == nil)
        #expect(hosts[mac]?.connection() == .offline, "退出登录：停下")
        #expect(lifecycle.wantsEnabled(mac), "不算用户点了停止")

        lifecycle.update(signedIn: true, deviceID: mac)
        #expect(lifecycle.model !== first)
        #expect(lifecycle.model?.isEnabled == true, "上次开着：照着开")
        #expect(hosts[mac]?.connection() == .connecting)
        lifecycle.model?.stop()
        #expect(!lifecycle.wantsEnabled(mac))

        let other = DeviceID("0192f3a0-0000-7000-8000-0000000000bb")
        lifecycle.update(signedIn: true, deviceID: other)
        #expect(lifecycle.model?.isEnabled == false, "换了设备（重新登录）：从关着开始")
    }

    @Test("建不起服务：记下错误；下次建起来了清掉")
    func reportsErrors() {
        let fail = Locked(true)
        let lifecycle = ComputerHostLifecycle(client: nil, defaults: defaults()) {
            (_: DeviceID) throws(ComputerHostError) -> any ComputerHost in
            if fail.withLock({ $0 }) { throw .state("no data dir") }
            return FakeComputerHost()
        }
        lifecycle.update(signedIn: true, deviceID: mac)
        #expect(lifecycle.model == nil)
        #expect(lifecycle.error == .state("no data dir"))
        fail.withLock { $0 = false }
        lifecycle.update(signedIn: true, deviceID: mac)
        #expect(lifecycle.model != nil)
        #expect(lifecycle.error == nil)
    }

    @Test("跟着 AppModel：退出登录时丢掉服务")
    func followsTheAppModel() async throws {
        let app = AppModel(client: makeShellMock(signedIn: true), defaults: nil)
        let lifecycle = ComputerHostLifecycle(client: nil, defaults: defaults()) { _ in FakeComputerHost() }
        let following = Task { await lifecycle.follow(app) { [mac] in mac } }
        #expect(await eventually { lifecycle.model != nil })
        try await app.signOut()
        #expect(await eventually { lifecycle.model == nil })
        following.cancel()
    }
}

@Suite("computer_key 的按键（14.4）")
struct KeyCombinationTests {
    @Test("单个键、组合键、别名、大小写和空格")
    func parses() throws {
        #expect(try KeyCombination.parse("return").get() == KeyCombination(keyCode: 0x24))
        #expect(try KeyCombination.parse("cmd+s").get() == KeyCombination(keyCode: 0x01, modifiers: .command))
        #expect(
            try KeyCombination.parse("Cmd + Shift + T").get()
                == KeyCombination(keyCode: 0x11, modifiers: [.command, .shift]))
        #expect(
            try KeyCombination.parse("ctrl+alt+delete").get()
                == KeyCombination(keyCode: 0x33, modifiers: [.control, .option]))
        #expect(try KeyCombination.parse("option+ArrowLeft").get() == KeyCombination(keyCode: 0x7B, modifiers: .option))
        #expect(try KeyCombination.parse("f12").get().keyCode == 0x6F)
        #expect(try KeyCombination.parse("cmd+,").get() == KeyCombination(keyCode: 0x2B, modifiers: .command))
    }

    @Test("写错了：说清楚怎么写")
    func rejects() {
        #expect(KeyCombination.parse("") == .failure(.malformed("")))
        #expect(KeyCombination.parse("cmd+") == .failure(.malformed("cmd+")))
        #expect(KeyCombination.parse("hyper+a") == .failure(.unknownModifier("hyper")))
        #expect(KeyCombination.parse("cmd+launch") == .failure(.unknownKey("launch")))
        #expect(KeyCombinationError.unknownKey("launch").description.contains("f1–f12"))
    }
}

@Suite("截图和点击的坐标（14.3、14.4）")
struct ScreenshotGeometryTests {
    @Test("Retina 屏缩到长边上限，点击按比例换回点")
    func scalesDown() throws {
        let geometry = ScreenshotGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(geometry.imageWidth == 1568)
        #expect(geometry.imageHeight == 1018)
        let center = try #require(geometry.point(x: 784, y: 509))
        #expect(abs(center.x - 756.5) < 1)
        #expect(abs(center.y - 491.5) < 1)
        #expect(geometry.point(x: 1568, y: 0) == nil)
        #expect(geometry.point(x: -1, y: 0) == nil)
    }

    @Test("小屏不放大；显示器不在原点时加上偏移")
    func keepsSmallScreens() throws {
        let geometry = ScreenshotGeometry(displayFrame: CGRect(x: 100, y: 50, width: 1024, height: 768), scale: 1)
        #expect(geometry.imageWidth == 1024)
        #expect(geometry.imageHeight == 768)
        #expect(try #require(geometry.point(x: 0, y: 0)) == CGPoint(x: 100.5, y: 50.5))
    }
}
