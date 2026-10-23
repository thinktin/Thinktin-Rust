import Foundation
import Testing

@testable import ThinktinKit

// 外观与语言的偏好（WBS 12.12）：存 UserDefaults、默认跟随系统、认不出的值当没设、界面语言怎么定。

@MainActor
@Suite("外观与语言的偏好")
struct SettingsPreferencesTests {
    /// 一个独立的 UserDefaults（用完删掉）。
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "cn.thinktin.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("默认跟随系统；改了存下来，下次启动读得回来；改回跟随系统删掉键")
    func persistence() {
        withDefaults { defaults in
            let prefs = SettingsPreferences(defaults: defaults, systemLanguage: { .chinese })
            #expect(prefs.appearance == .system)
            #expect(prefs.language == .system)
            #expect(prefs.displayLanguage == .chinese)

            prefs.setAppearance(.dark)
            prefs.setLanguage(.english)
            #expect(defaults.string(forKey: SettingsPreferences.appearanceKey) == "dark")
            #expect(defaults.string(forKey: SettingsPreferences.languageKey) == "english")
            #expect(prefs.displayLanguage == .english)

            let reopened = SettingsPreferences(defaults: defaults, systemLanguage: { .chinese })
            #expect(reopened.appearance == .dark)
            #expect(reopened.language == .english)

            reopened.setAppearance(.system)
            reopened.setLanguage(.system)
            #expect(defaults.object(forKey: SettingsPreferences.appearanceKey) == nil)
            #expect(defaults.object(forKey: SettingsPreferences.languageKey) == nil)
        }
    }

    @Test("认不出的值（降级回来的老版本）当没设")
    func unknownValues() {
        withDefaults { defaults in
            defaults.set("sepia", forKey: SettingsPreferences.appearanceKey)
            defaults.set("klingon", forKey: SettingsPreferences.languageKey)
            let prefs = SettingsPreferences(defaults: defaults, systemLanguage: { .english })
            #expect(prefs.appearance == .system)
            #expect(prefs.language == .system)
            #expect(prefs.displayLanguage == .english)
        }
    }

    @Test("不存的那份（预览、测试）只在内存里")
    func inMemory() {
        let prefs = SettingsFixture.preferences(system: .english)
        prefs.setLanguage(.chinese)
        #expect(prefs.displayLanguage == .chinese)
        #expect(prefs.systemDisplayLanguage == .english)
        #expect(SettingsFixture.preferences().language == .system)
    }

    @Test("跟随系统用系统给 App 定的语言，选了就固定")
    func resolution() {
        #expect(LanguagePreference.system.resolved(system: .english) == .english)
        #expect(LanguagePreference.system.resolved(system: .chinese) == .chinese)
        #expect(LanguagePreference.chinese.resolved(system: .english) == .chinese)
        #expect(LanguagePreference.english.resolved(system: .chinese) == .english)
        #expect(LanguagePreference(.english) == .english)
        #expect(LanguagePreference(.chinese) == .chinese)
    }

    @Test("选项的名字：语言用它自己的写法，跟随系统带上实际的语言")
    func titles() {
        #expect(LanguagePreference.chinese.title(.english) == "中文")
        #expect(LanguagePreference.english.title(.chinese) == "English")
        #expect(LanguagePreference.system.title(.chinese) == "跟随系统")
        #expect(LanguagePreference.system.title(.english) == "System")
        #expect(LanguagePreference.system.summary(system: .chinese, language: .chinese) == "跟随系统（中文）")
        #expect(LanguagePreference.system.summary(system: .english, language: .english) == "System (English)")
        #expect(LanguagePreference.english.summary(system: .chinese, language: .chinese) == "English")

        for language in DisplayLanguage.allCases {
            let titles = AppearancePreference.allCases.map { $0.title(language) }
            #expect(Set(titles).count == AppearancePreference.allCases.count)
        }
        #expect(AppearancePreference.dark.title(.chinese) == "深色")
        #expect(AppearancePreference.light.title(.english) == "Light")
        #expect(AppearancePreference.system.detail(.chinese) != nil)
        #expect(AppearancePreference.dark.detail(.chinese) == nil)
    }
}
