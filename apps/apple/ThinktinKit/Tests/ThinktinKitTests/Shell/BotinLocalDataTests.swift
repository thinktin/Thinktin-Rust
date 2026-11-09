import Foundation
import Testing

@testable import ThinktinKit

/// 这台设备上按 Botin 记的五样东西放在一起删（删 Botin、它在服务端没了、注销账号）。
@MainActor
@Suite("这台设备上按 Botin 记的东西")
struct BotinLocalDataTests {
    /// 五样都给 `id` 记一点东西。
    private func fill(_ local: BotinLocalData, _ ids: [InstanceID]) {
        for id in ids {
            local.appearances.set(InstanceAppearance(shape: .flower, color: .purple), for: id)
            local.preferences.setPinned(true, for: id)
            local.voices.set(BotinVoiceSettings(voiceID: "onyx", speed: .half), for: id)
            local.reactions.toggle("👍", instanceID: id, messageID: "7")
        }
    }

    /// 这个 Botin 在五样里还有没有记录（主 Botin 另外看）。
    private func remembers(_ local: BotinLocalData, _ id: InstanceID) -> [Bool] {
        [
            local.appearances.appearance(for: id) != nil,
            local.preferences.isPinned(id),
            local.voices.settings[id] != nil,
            !local.reactions.reactions(instanceID: id, messageID: "7").isEmpty,
        ]
    }

    @Test("删 Botin：五样都删掉它的记录，是主 Botin 的话清掉；别的 Botin 的不动")
    func forget() {
        let local = BotinLocalData.inMemory()
        fill(local, ["a", "b"])
        local.primary.set("a")

        local.forget(["a"])
        #expect(remembers(local, "a") == [false, false, false, false])
        #expect(remembers(local, "b") == [true, true, true, true])
        #expect(local.primary.primaryID == nil)

        local.primary.set("b")
        local.forget(["c"])
        local.forget([])
        #expect(local.primary.primaryID == "b", "删的不是主 Botin，不动")
        #expect(remembers(local, "b") == [true, true, true, true])
    }

    @Test("注销账号：这个账号的 Botin 都删掉，主 Botin 不在列表里也清掉")
    func forgetAccount() {
        let local = BotinLocalData.inMemory()
        fill(local, ["a", "b", "old"])
        local.primary.set("unlisted")

        local.forgetAccount(["a", "b"])
        #expect(remembers(local, "a") == [false, false, false, false])
        #expect(remembers(local, "b") == [false, false, false, false])
        #expect(local.primary.primaryID == nil)
        #expect(remembers(local, "old") == [true, true, true, true], "不在列表里的（别的账号的）不动")
    }

    @Test("按 defaults 建：nil 只在内存里；测试的 suite 五样都新建在它上面；standard 用 App 共用的那几份")
    func storage() {
        let memory = BotinLocalData(defaults: nil)
        #expect(memory.voices !== BotinVoiceStore.shared)
        #expect(memory.reactions !== MessageReactionStore.shared)
        #expect(memory.primary !== PrimaryBotinStore.shared)

        let name = "BotinLocalDataTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let suite = BotinLocalData(defaults: defaults)
        #expect(suite.voices !== BotinVoiceStore.shared)
        #expect(suite.reactions !== MessageReactionStore.shared)
        #expect(suite.primary !== PrimaryBotinStore.shared)
        fill(suite, ["a"])
        suite.primary.set("a")
        let reopened = BotinLocalData(defaults: defaults)
        #expect(remembers(reopened, "a") == [true, true, true, true])
        #expect(reopened.primary.primaryID == "a")
        reopened.forgetAccount(["a"])
        let cleared = BotinLocalData(defaults: defaults)
        #expect(remembers(cleared, "a") == [false, false, false, false])
        #expect(cleared.primary.primaryID == nil)

        let standard = BotinLocalData(defaults: .standard)
        #expect(standard.voices === BotinVoiceStore.shared)
        #expect(standard.reactions === MessageReactionStore.shared)
        #expect(standard.primary === PrimaryBotinStore.shared)
    }

    @Test("应用框架：AppModel 的头像外观、置顶隐藏就是 local 里的；Botin 在服务端没了时五样都删")
    func appModel() async {
        let model = AppModel(client: makeShellMock(), defaults: nil)
        #expect(model.appearances === model.local.appearances)
        #expect(model.instancePreferences === model.local.preferences)
        await model.start()
        let writer = DemoData.writerID
        let reviewer = DemoData.reviewerID
        fill(model.local, [writer, reviewer])
        model.local.primary.set(reviewer)

        model.receive(.stream(.notFound, instanceID: reviewer, subscription: UUID()), number: 1)
        #expect(remembers(model.local, reviewer) == [false, false, false, false])
        #expect(model.local.primary.primaryID == nil)
        #expect(remembers(model.local, writer) == [true, true, true, true])
    }
}
