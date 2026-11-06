import Foundation
import Testing

@testable import ThinktinKit

// 编辑 Botin 的“语音通话”组（规范 4.4.3，参考 12、13–17、85–88）：菜单里的选项、行上的值、本机的存储和草稿。

@MainActor
@Suite("Botin 的语音通话设置")
struct BotinVoiceTests {
    /// 一个只给这次测试用的 `UserDefaults`。
    private func defaults(_ name: String = #function) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cn.thinktin.tests.agents.voice.\(name).\(UUID().uuidString)"))
    }

    @Test("选项：音色按名字排、不重复；语速六档 0.5x–2x；语言中文在前、代码不重复")
    func options() {
        let voices = BotinVoiceDemoData.voices
        #expect(voices.count >= 20)
        #expect(voices.map(\.name) == voices.map(\.name).sorted())
        #expect(Set(voices.map(\.id)).count == voices.count)
        #expect(voices.allSatisfy { $0.id == $0.name.lowercased() })

        #expect(BotinVoiceSpeed.allCases.map(\.label) == ["0.5x", "0.75x", "1x", "1.25x", "1.5x", "2x"])
        #expect(BotinVoiceSpeed.allCases.map(\.multiplier) == [0.5, 0.75, 1, 1.25, 1.5, 2])
        #expect(BotinVoiceSpeed.oneAndHalf.accessibilityLabel(.chinese) == "1.5 倍速")

        let languages = BotinVoiceDemoData.languages
        #expect(languages.first?.code == "zh-Hans")
        #expect(Set(languages.map(\.code)).count == languages.count)
        #expect(languages.allSatisfy { !$0.chineseName.isEmpty && !$0.englishName.isEmpty })
        #expect(BotinVoiceDemoData.language(code: "ja")?.name(.chinese) == "日语")
        #expect(BotinVoiceDemoData.language(code: "ja")?.name(.english) == "Japanese")
    }

    @Test("行上的值：没选音色“未设置”、没选语言“自动”，选了写名字")
    func values() {
        #expect(BotinVoiceText.voiceValue(nil, language: .chinese) == "未设置")
        #expect(BotinVoiceText.voiceValue("cedar", language: .english) == "Cedar")
        #expect(BotinVoiceText.voiceValue("gone", language: .english) == "Not set")
        #expect(BotinVoiceText.languageValue(nil, language: .chinese) == "自动")
        #expect(BotinVoiceText.languageValue("fr", language: .chinese) == "法语")
        #expect(BotinVoiceText.languageValue("fr", language: .english) == "French")
        #expect(BotinVoiceText.section(.chinese) == "语音通话")
        #expect(BotinVoiceText.footer(.chinese).contains("即将推出"))
        #expect(BotinVoiceSettings.default.speed == .normal)
        #expect(BotinVoiceSettings.default.isDefault)
    }

    @Test("存储：按 Botin 记，默认的不存，重开还在，删了的忘掉")
    func store() throws {
        let defaults = try defaults()
        let store = BotinVoiceStore(defaults: defaults)
        #expect(store.settings(for: DemoData.writerID) == .default)

        let chosen = BotinVoiceSettings(voiceID: "cedar", speed: .oneAndQuarter, languageCode: "zh-Hans")
        store.set(chosen, for: DemoData.writerID)
        store.set(.default, for: DemoData.reviewerID)
        #expect(store.settings(for: DemoData.writerID) == chosen)
        #expect(store.settings.count == 1)

        let reopened = BotinVoiceStore(defaults: defaults)
        #expect(reopened.settings(for: DemoData.writerID) == chosen)
        #expect(reopened.settings(for: DemoData.reviewerID) == .default)

        // 改回默认就删掉记录。
        reopened.set(.default, for: DemoData.writerID)
        #expect(reopened.settings.isEmpty)
        #expect(defaults.data(forKey: BotinVoiceStore.storageKey) == nil)

        reopened.set(chosen, for: "a")
        reopened.set(chosen, for: "b")
        reopened.forget(["a", "missing"])
        #expect(BotinVoiceStore(defaults: defaults).settings.keys.sorted() == ["b"])
    }

    @Test("存储读得宽：认不出的音色和语言当没选、认不出的语速当 1x；坏数据当没有")
    func lenientDecoding() throws {
        let defaults = try defaults()
        let json = #"""
            {"x": {"voice": "nobody", "speed": "3", "language": "xx"},
             "y": {"voice": "fern", "speed": "0.75"},
             "": {"voice": "fern"}}
            """#
        defaults.set(Data(json.utf8), forKey: BotinVoiceStore.storageKey)
        let store = BotinVoiceStore(defaults: defaults)
        // x 读出来是默认的，不留。
        #expect(store.settings.keys.sorted() == ["y"])
        #expect(store.settings(for: "y") == BotinVoiceSettings(voiceID: "fern", speed: .threeQuarters))

        defaults.set(Data("not json".utf8), forKey: BotinVoiceStore.storageKey)
        #expect(BotinVoiceStore(defaults: defaults).settings.isEmpty)
        #expect(BotinVoiceStore(defaults: nil).settings.isEmpty)
    }

    @Test("草稿：从记下的开始，改了才算有改动，“完成”才记下")
    func editor() {
        let store = BotinVoiceStore(defaults: nil)
        store.set(BotinVoiceSettings(voiceID: "sage"), for: DemoData.writerID)
        let editor = BotinVoiceEditor(instanceID: DemoData.writerID, store: store)
        #expect(editor.voiceID == "sage")
        #expect(editor.speed == .normal)
        #expect(editor.languageCode == nil)
        #expect(!editor.hasChanges)

        editor.speed = .double
        editor.languageCode = "en"
        #expect(editor.hasChanges)
        // 没点“完成”不记。
        #expect(store.settings(for: DemoData.writerID).speed == .normal)
        editor.save()
        #expect(
            store.settings(for: DemoData.writerID)
                == BotinVoiceSettings(voiceID: "sage", speed: .double, languageCode: "en"))

        let other = BotinVoiceEditor(instanceID: DemoData.reviewerID, store: store)
        other.voiceID = nil
        other.save()
        #expect(store.settings[DemoData.reviewerID] == nil)
    }

    @Test("删了 Botin 顺带删这台设备上记的语音通话设置；删失败的留着")
    func deleteForgetsVoice() async {
        let mock = AgentsFixture.mock()
        let local = BotinLocalData.inMemory()
        let voices = local.voices
        let chosen = BotinVoiceSettings(voiceID: "onyx", speed: .half)
        voices.set(chosen, for: DemoData.writerID)
        voices.set(chosen, for: DemoData.reviewerID)

        let failing = InstanceDetailModel(client: mock, instanceID: DemoData.writerID, local: local)
        mock.failNext(with: .api(status: 503, code: .unavailable, message: "busy", retryAfterSecs: 5))
        #expect(!(await failing.delete()))
        #expect(voices.settings(for: DemoData.writerID) == chosen)

        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID, local: local)
        #expect(model.voices === voices)
        #expect(InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID).voices == nil)
        #expect(await model.delete())
        #expect(voices.settings[DemoData.reviewerID] == nil)
        #expect(voices.settings(for: DemoData.writerID) == chosen)
    }
}
