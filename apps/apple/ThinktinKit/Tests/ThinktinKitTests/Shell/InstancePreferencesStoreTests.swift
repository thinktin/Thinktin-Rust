import Foundation
import Testing

@testable import ThinktinKit

// 首页的置顶、隐藏（规范 docs/ios-ui-redesign.md 4.2.1–4.2.3、6.10 A）：只存这台设备，置顶和隐藏互斥，删掉 Botin 时删记录。

@MainActor
@Suite("首页的置顶和隐藏")
struct InstancePreferencesStoreTests {
    private let a: InstanceID = "a"
    private let b: InstanceID = "b"
    private let c: InstanceID = "c"

    /// 只给这次测试用的 `UserDefaults`。
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "cn.thinktin.tests.instancePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("置顶按先后排；重复置顶不变；取消置顶从中间拿掉")
    func pinOrder() {
        let store = InstancePreferencesStore(defaults: nil)
        #expect(store.pinned.isEmpty && store.hidden.isEmpty)
        store.setPinned(true, for: b)
        store.setPinned(true, for: a)
        store.setPinned(true, for: c)
        store.setPinned(true, for: b)
        #expect(store.pinned == [b, a, c])
        #expect(store.isPinned(a) && !store.isHidden(a))
        store.setPinned(false, for: a)
        #expect(store.pinned == [b, c])
        // 本来就没置顶的取消置顶：不变。
        store.setPinned(false, for: a)
        #expect(store.pinned == [b, c])
    }

    @Test("置顶和隐藏互斥：隐藏时取消置顶，置顶时取消隐藏；取消隐藏回到普通行")
    func exclusive() {
        let store = InstancePreferencesStore(defaults: nil)
        store.setPinned(true, for: a)
        store.setHidden(true, for: a)
        #expect(store.isHidden(a) && !store.isPinned(a))
        store.setPinned(true, for: a)
        #expect(store.isPinned(a) && !store.isHidden(a))
        store.setHidden(true, for: b)
        store.setHidden(false, for: b)
        #expect(!store.isHidden(b) && !store.isPinned(b))
    }

    @Test("记下、读回来（重开 App 也在）；都清掉时删掉那个键")
    func roundTrip() throws {
        try withDefaults { defaults in
            let store = InstancePreferencesStore(defaults: defaults)
            store.setPinned(true, for: c)
            store.setPinned(true, for: a)
            store.setHidden(true, for: b)

            let reopened = InstancePreferencesStore(defaults: defaults)
            #expect(reopened.pinned == [c, a])
            #expect(reopened.hidden == [b])

            reopened.setPinned(false, for: c)
            reopened.setPinned(false, for: a)
            reopened.setHidden(false, for: b)
            #expect(defaults.data(forKey: InstancePreferencesStore.storageKey) == nil)
            let empty = InstancePreferencesStore(defaults: defaults)
            #expect(empty.pinned.isEmpty && empty.hidden.isEmpty)
        }
    }

    @Test("删掉 Botin：置顶、隐藏的记录一起删")
    func forget() throws {
        try withDefaults { defaults in
            let store = InstancePreferencesStore(defaults: defaults)
            store.setPinned(true, for: a)
            store.setPinned(true, for: b)
            store.setHidden(true, for: c)
            store.forget([a, c, "unknown"])
            #expect(store.pinned == [b])
            #expect(store.hidden.isEmpty)
            #expect(InstancePreferencesStore(defaults: defaults).pinned == [b])
        }
    }

    @Test("存坏了当没有；空 id、重复的去掉；又置顶又隐藏的按隐藏算；缺了一项当空的")
    func lenientLoad() throws {
        try withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: InstancePreferencesStore.storageKey)
            let broken = InstancePreferencesStore(defaults: defaults)
            #expect(broken.pinned.isEmpty && broken.hidden.isEmpty)

            let json = #"{"pinned": ["a", "", "b", "a", "c"], "hidden": ["c", ""]}"#
            defaults.set(Data(json.utf8), forKey: InstancePreferencesStore.storageKey)
            let store = InstancePreferencesStore(defaults: defaults)
            #expect(store.pinned == [a, b])
            #expect(store.hidden == [c])

            defaults.set(Data(#"{"hidden": ["a"]}"#.utf8), forKey: InstancePreferencesStore.storageKey)
            let partial = InstancePreferencesStore(defaults: defaults)
            #expect(partial.pinned.isEmpty && partial.hidden == [a])
        }
    }

    @Test("AppModel：首页按它分成置顶、普通、隐藏；都隐藏了是“所有 Botin 都已隐藏”；Botin 没了时删记录")
    func appModel() async {
        let model = AppModel(client: makeShellMock(), defaults: nil)
        await model.start()
        let writer = DemoData.writerID
        let reviewer = DemoData.reviewerID
        #expect(model.homeContent.pinned.isEmpty)
        #expect(Set(model.homeContent.rows.map(\.id)) == [writer, reviewer])

        model.instancePreferences.setPinned(true, for: reviewer)
        #expect(model.homeContent.pinned.map(\.id) == [reviewer])
        #expect(model.homeContent.rows.map(\.id) == [writer])
        // “首页第一行”是置顶的那个。
        #expect(model.homeRows.map(\.id) == [reviewer, writer])

        model.instancePreferences.setHidden(true, for: writer)
        #expect(model.homeContent.hidden.map(\.id) == [writer])
        #expect(model.homeRows.map(\.id) == [reviewer])
        #expect(model.homePlaceholder == nil)
        model.instancePreferences.setHidden(true, for: reviewer)
        #expect(model.homeContent.isAllHidden)
        #expect(model.homePlaceholder == .allHidden)

        // 事件流说 Botin 没了：从列表里拿掉，它的记录也删掉。
        model.receive(.stream(.notFound, instanceID: reviewer, subscription: UUID()), number: 1)
        #expect(!model.instancePreferences.isHidden(reviewer))
        #expect(model.instancePreferences.isHidden(writer))
    }
}
