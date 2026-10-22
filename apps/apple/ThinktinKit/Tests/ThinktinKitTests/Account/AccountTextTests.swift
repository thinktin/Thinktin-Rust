import Foundation
import Testing

@testable import ThinktinKit

// 账号与设备页面上拼出来的文字（中英文），以及重装后清旧会话（WBS 12.2）。

@Suite("账号与设备的文案")
struct AccountTextTests {
    @Test("全部停止的结果：数字、英文单复数、什么都没停")
    func stopAllSummary() {
        let result = StopAllResult(runsCancelled: 3, grantsRevoked: 1, plansPaused: 2)
        #expect(result.summary(.chinese) == "已取消 3 个运行，吊销 1 个运行授权，暂停 2 个计划。")
        #expect(result.summary(.english) == "Cancelled 3 runs, revoked 1 run grant, and paused 2 plans.")
        let none = StopAllResult(runsCancelled: 0, grantsRevoked: 0, plansPaused: 0)
        #expect(none.isEmpty)
        #expect(!result.isEmpty)
        #expect(none.summary(.english) == "Nothing was running, and every plan was already paused.")
    }

    @Test("下线其他设备的结果：台数，顺带停了的接在后面")
    func signOutOthersSummary() {
        #expect(SignOutOthersResult(devicesSignedOut: 0).summary(.chinese) == "没有其他登录着的设备。")
        #expect(
            SignOutOthersResult(devicesSignedOut: 1).summary(.english)
                == "Signed out 1 device. They'll need to sign in again.")
        let both = SignOutOthersResult(
            devicesSignedOut: 2, stopped: StopAllResult(runsCancelled: 1, grantsRevoked: 1, plansPaused: 0))
        #expect(
            both.summary(.chinese) == "已下线 2 台设备，它们要重新登录才能再用。已取消 1 个运行，吊销 1 个运行授权，暂停 0 个计划。")
        #expect(
            both.summary(.english)
                == "Signed out 2 devices. They'll need to sign in again. Cancelled 1 run, revoked 1 run grant, "
                + "and paused 0 plans.")
    }

    @Test("设备的状态一行：本机、电脑在线 / 离线、手机的最近活跃；登录时间")
    func deviceText() {
        let now = Fixture.now
        let calendar = Fixture.calendar
        let current = DeviceInfo(
            id: "d1", platform: .ios, name: "iPhone", isCurrent: true, createdAt: Fixture.date(2026, 10, 2))
        #expect(current.activityText(now: now, language: .chinese, calendar: calendar) == "正在使用")
        #expect(current.signedInText(now: now, language: .chinese, calendar: calendar) == "10月2日登录")
        #expect(current.signedInText(now: now, language: .english, calendar: calendar) == "Signed in Oct 2")

        let mac = DeviceInfo(
            id: "d2", platform: .macos, name: "张三的 MacBook Pro", isOnline: true, createdAt: Fixture.date(2026, 9, 1),
            lastSeenAt: now.addingTimeInterval(-3 * 3600))
        #expect(mac.activityText(now: now, language: .chinese, calendar: calendar) == "在线")
        var offline = mac
        offline.isOnline = false
        #expect(offline.activityText(now: now, language: .chinese, calendar: calendar) == "离线 · 最近活跃 3 小时前")
        #expect(
            offline.activityText(now: now, language: .english, calendar: calendar) == "Offline · last active 3 hr ago")
        #expect(
            offline.accessibilityText(now: now, language: .chinese, calendar: calendar)
                == "张三的 MacBook Pro，Mac，离线 · 最近活跃 3 小时前，9月1日登录")

        let phone = DeviceInfo(
            id: "d3", platform: .android, name: "  ", createdAt: Fixture.date(2025, 3, 4),
            lastSeenAt: now.addingTimeInterval(-5 * 60))
        #expect(phone.displayName(.chinese) == "Android")
        #expect(phone.activityText(now: now, language: .chinese, calendar: calendar) == "最近活跃 5 分钟前")
        #expect(phone.activityText(now: now, language: .english, calendar: calendar) == "Last active 5 min ago")
        #expect(phone.signedInText(now: now, language: .chinese, calendar: calendar) == "2025年3月4日登录")
    }

    @Test("平台名：认不出的显示原文，空的显示“未知设备”")
    func platformNames() {
        #expect(DevicePlatform.ios.localizedName(.chinese) == "iOS")
        #expect(DevicePlatform.macos.localizedName(.english) == "Mac")
        #expect(DevicePlatform.unknown("harmony").localizedName(.chinese) == "harmony")
        #expect(DevicePlatform.unknown("").localizedName(.chinese) == "未知设备")
        #expect(DevicePlatform.unknown("").localizedName(.english) == "Unknown device")
    }

    @Test("注销说明：中英文条数一样，写了无法恢复和保留的内容")
    func deletionNotice() {
        let zh = AccountDeletionNotice.deletedItems(.chinese)
        let en = AccountDeletionNotice.deletedItems(.english)
        #expect(zh.count == en.count)
        #expect(zh.contains { $0.contains("无法恢复") })
        #expect(AccountDeletionNotice.footnote(.chinese).contains("审计日志"))
        #expect(AccountDeletionNotice.footnote(.english).contains("new account"))
        #expect(StopAllModel.confirmationMessage(.chinese).contains("暂停所有计划"))
    }

    @Test("重装后第一次启动清掉 Keychain 里的旧会话，之后不再清")
    func freshInstall() throws {
        let suite = "AccountTextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = InMemorySessionStore(DemoData.demoSession)

        #expect(FreshInstallGuard.clearStaleSession(in: sessions, defaults: defaults))
        #expect(sessions.load() == nil)
        // 之后登录了，再启动不清。
        sessions.save(DemoData.demoSession)
        #expect(!FreshInstallGuard.clearStaleSession(in: sessions, defaults: defaults))
        #expect(sessions.load() == DemoData.demoSession)
    }

    @Test("第一次启动本来就没有会话：只记下标记")
    func freshInstallWithoutSession() throws {
        let suite = "AccountTextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = InMemorySessionStore()
        #expect(!FreshInstallGuard.clearStaleSession(in: sessions, defaults: defaults))
        #expect(defaults.bool(forKey: FreshInstallGuard.markerKey))
        sessions.save(DemoData.demoSession)
        #expect(!FreshInstallGuard.clearStaleSession(in: sessions, defaults: defaults))
        #expect(sessions.load() != nil)
    }
}
