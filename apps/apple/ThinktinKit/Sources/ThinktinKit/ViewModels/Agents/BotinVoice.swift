import Foundation
import Observation

// 编辑 Botin 的“语音通话”组（规范 4.4.3，参考 12、13–17、85–88）：语音、速度、语言三个单选菜单。ThinkTin 还没有语音通话
// （规范 6.23：服务端语音、语音合成、实例上的字段都没有），用户要先照参考把页面排出来（2026-11-05），所以选项是本地的演示数据
// （`BotinVoiceDemoData`），选了只记在这台设备上（`BotinVoiceStore`，按 Botin 的 id）。有了接口以后选项从服务端拿、
// 选择存到 Botin 上，这里的存储删掉。

/// 一种音色（“语音”菜单的一项）。
public struct BotinVoice: Hashable, Sendable, Identifiable {
    /// 存进 `UserDefaults` 的值，不能改。
    public let id: String
    /// 菜单里显示的名字（专名，中英文一样）。
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 语速（“速度”菜单，参考 16：0.5x 到 2x 六档）。原始值存进 `UserDefaults`，不能改。
public enum BotinVoiceSpeed: String, CaseIterable, Codable, Hashable, Sendable {
    case half = "0.5"
    case threeQuarters = "0.75"
    case normal = "1"
    case oneAndQuarter = "1.25"
    case oneAndHalf = "1.5"
    case double = "2"

    /// 倍数。
    public var multiplier: Double { Double(rawValue) ?? 1 }

    /// 菜单里的字：“0.5x”“1x”。
    public var label: String { "\(rawValue)x" }

    /// 读屏念的：“1.5 倍速”。
    public func accessibilityLabel(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "\(rawValue) 倍速" : "\(rawValue) times speed"
    }
}

/// 通话时说的语言（“语言”菜单的一项）。`code` 是 BCP 47 的语言标签。
public struct BotinVoiceLanguage: Hashable, Sendable, Identifiable {
    public let code: String
    public let chineseName: String
    public let englishName: String

    public var id: String { code }

    public init(code: String, chineseName: String, englishName: String) {
        self.code = code
        self.chineseName = chineseName
        self.englishName = englishName
    }

    public func name(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? chineseName : englishName
    }
}

/// 菜单里的选项（演示数据：没有语音接口，先放一组自己起的音色名和常见的语言；音色名是植物、矿物、自然景物，不用别家的名字）。
public enum BotinVoiceDemoData {
    /// 音色，按名字排（参考 13–15、85 的长菜单）。
    public static let voices: [BotinVoice] = [
        "Amber", "Aspen", "Basil", "Birch", "Brook", "Cedar", "Clover", "Coral", "Dune", "Ember", "Fern", "Flint",
        "Harbor", "Hazel", "Juniper", "Lark", "Linden", "Maple", "Meadow", "Onyx", "Pearl", "Quill", "Reed", "Sage",
        "Slate", "Sorrel", "Tide", "Willow",
    ].map { BotinVoice(id: $0.lowercased(), name: $0) }

    /// 语言（参考 17、86–88 的长菜单）：中文的三种在前，然后英语，其余按英文名排。“自动”不在这里（菜单的第一项是 nil）。
    public static let languages: [BotinVoiceLanguage] = [
        BotinVoiceLanguage(code: "zh-Hans", chineseName: "中文（简体）", englishName: "Chinese (Simplified)"),
        BotinVoiceLanguage(code: "zh-Hant", chineseName: "中文（繁体）", englishName: "Chinese (Traditional)"),
        BotinVoiceLanguage(code: "yue", chineseName: "粤语", englishName: "Cantonese"),
        BotinVoiceLanguage(code: "en", chineseName: "英语", englishName: "English"),
        BotinVoiceLanguage(code: "ar-EG", chineseName: "阿拉伯语（埃及）", englishName: "Arabic (Egypt)"),
        BotinVoiceLanguage(code: "ar-SA", chineseName: "阿拉伯语（沙特阿拉伯）", englishName: "Arabic (Saudi Arabia)"),
        BotinVoiceLanguage(code: "ar-AE", chineseName: "阿拉伯语（阿拉伯联合酋长国）", englishName: "Arabic (UAE)"),
        BotinVoiceLanguage(code: "bn", chineseName: "孟加拉语", englishName: "Bengali"),
        BotinVoiceLanguage(code: "ca", chineseName: "加泰罗尼亚语", englishName: "Catalan"),
        BotinVoiceLanguage(code: "da", chineseName: "丹麦语", englishName: "Danish"),
        BotinVoiceLanguage(code: "nl", chineseName: "荷兰语", englishName: "Dutch"),
        BotinVoiceLanguage(code: "fi", chineseName: "芬兰语", englishName: "Finnish"),
        BotinVoiceLanguage(code: "fr", chineseName: "法语", englishName: "French"),
        BotinVoiceLanguage(code: "de", chineseName: "德语", englishName: "German"),
        BotinVoiceLanguage(code: "hi", chineseName: "印地语", englishName: "Hindi"),
        BotinVoiceLanguage(code: "hu", chineseName: "匈牙利语", englishName: "Hungarian"),
        BotinVoiceLanguage(code: "id", chineseName: "印度尼西亚语", englishName: "Indonesian"),
        BotinVoiceLanguage(code: "it", chineseName: "意大利语", englishName: "Italian"),
        BotinVoiceLanguage(code: "ja", chineseName: "日语", englishName: "Japanese"),
        BotinVoiceLanguage(code: "ko", chineseName: "韩语", englishName: "Korean"),
        BotinVoiceLanguage(code: "pl", chineseName: "波兰语", englishName: "Polish"),
        BotinVoiceLanguage(code: "pt-BR", chineseName: "葡萄牙语（巴西）", englishName: "Portuguese (Brazil)"),
        BotinVoiceLanguage(code: "pt-PT", chineseName: "葡萄牙语（葡萄牙）", englishName: "Portuguese (Portugal)"),
        BotinVoiceLanguage(code: "ru", chineseName: "俄语", englishName: "Russian"),
        BotinVoiceLanguage(code: "es-MX", chineseName: "西班牙语（墨西哥）", englishName: "Spanish (Mexico)"),
        BotinVoiceLanguage(code: "es-ES", chineseName: "西班牙语（西班牙）", englishName: "Spanish (Spain)"),
        BotinVoiceLanguage(code: "sv", chineseName: "瑞典语", englishName: "Swedish"),
        BotinVoiceLanguage(code: "th", chineseName: "泰语", englishName: "Thai"),
        BotinVoiceLanguage(code: "tr", chineseName: "土耳其语", englishName: "Turkish"),
        BotinVoiceLanguage(code: "vi", chineseName: "越南语", englishName: "Vietnamese"),
    ]

    public static func voice(id: String) -> BotinVoice? {
        voices.first { $0.id == id }
    }

    public static func language(code: String) -> BotinVoiceLanguage? {
        languages.first { $0.code == code }
    }
}

/// 一个 Botin 的语音通话设置。
public struct BotinVoiceSettings: Codable, Hashable, Sendable {
    /// 音色；nil 是“未设置”（参考 13 菜单的第一项）。
    public var voiceID: String?
    public var speed: BotinVoiceSpeed
    /// 语言；nil 是“自动”（参考 17 菜单的第一项）。
    public var languageCode: String?

    /// 没设置过：未设置的音色、1x、自动。
    public static let `default` = BotinVoiceSettings()

    public init(voiceID: String? = nil, speed: BotinVoiceSpeed = .normal, languageCode: String? = nil) {
        self.voiceID = voiceID
        self.speed = speed
        self.languageCode = languageCode
    }

    public var isDefault: Bool { self == .default }

    private enum CodingKeys: String, CodingKey {
        case voice, speed, language
    }

    /// 宽松地读：认不出的音色、语言（以后的版本加的、或者演示数据换了）当没选，认不出的语速当 1x，不让一条坏记录拖垮整张表。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let voice = try container.decodeIfPresent(String.self, forKey: .voice)
        let speed = try container.decodeIfPresent(String.self, forKey: .speed)
        let language = try container.decodeIfPresent(String.self, forKey: .language)
        voiceID = voice.flatMap { BotinVoiceDemoData.voice(id: $0)?.id }
        self.speed = speed.flatMap(BotinVoiceSpeed.init(rawValue:)) ?? .normal
        languageCode = language.flatMap { BotinVoiceDemoData.language(code: $0)?.code }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(voiceID, forKey: .voice)
        try container.encode(speed.rawValue, forKey: .speed)
        try container.encodeIfPresent(languageCode, forKey: .language)
    }
}

/// 这台设备上记的语音通话设置（按 Botin 的 id）：编辑页点“完成”时写（`BotinVoiceEditor.save()`）。
///
/// 存在 `UserDefaults` 里（一个键，JSON：`{实例 id: {voice, speed, language}}`），只是本机的偏好，不上传；默认的不存。
/// 删了 Botin（`InstanceDetailModel.delete()`）时删掉对应的记录。`defaults` 为 nil 时只记在内存里（测试、预览）。
@Observable @MainActor
public final class BotinVoiceStore {
    static let storageKey = "cn.thinktin.agents.botinVoice"

    /// App 用的那一份（`UserDefaults.standard`）。
    public static let shared = BotinVoiceStore()

    /// 记下的设置（不含默认的）。
    public private(set) var settings: [InstanceID: BotinVoiceSettings]

    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    /// 这个 Botin 的设置；没记过是默认的。
    public func settings(for id: InstanceID) -> BotinVoiceSettings {
        settings[id] ?? .default
    }

    /// 记下设置；默认的删掉记录。
    public func set(_ value: BotinVoiceSettings, for id: InstanceID) {
        guard !value.isDefault else {
            forget([id])
            return
        }
        guard settings[id] != value else { return }
        settings[id] = value
        save()
    }

    /// 删掉这些 Botin 的记录（删了 Botin）。
    public func forget(_ ids: [InstanceID]) {
        var changed = false
        for id in ids where settings.removeValue(forKey: id) != nil {
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        guard let defaults else { return }
        let table = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
        if table.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// 读出来的表：坏了（不是 JSON）就当没有；默认的不留。
    private static func load(from defaults: UserDefaults?) -> [InstanceID: BotinVoiceSettings] {
        guard let data = defaults?.data(forKey: storageKey),
            let table = try? JSONDecoder().decode([String: BotinVoiceSettings].self, from: data)
        else { return [:] }
        var settings: [InstanceID: BotinVoiceSettings] = [:]
        for (key, value) in table where !key.isEmpty && !value.isDefault {
            settings[InstanceID(key)] = value
        }
        return settings
    }
}

/// 编辑页“语音通话”组的草稿：打开时从记下的开始，点“完成”时记下（`save()`），点返回放弃。
@Observable @MainActor
public final class BotinVoiceEditor {
    public let instanceID: InstanceID
    public var voiceID: String?
    public var speed: BotinVoiceSpeed
    public var languageCode: String?
    /// 打开时的设置（判断有没有改过）。
    public let original: BotinVoiceSettings

    @ObservationIgnored private let store: BotinVoiceStore

    public init(instanceID: InstanceID, store: BotinVoiceStore) {
        self.instanceID = instanceID
        self.store = store
        let current = store.settings(for: instanceID)
        original = current
        voiceID = current.voiceID
        speed = current.speed
        languageCode = current.languageCode
    }

    /// 现在选的。
    public var settings: BotinVoiceSettings {
        BotinVoiceSettings(voiceID: voiceID, speed: speed, languageCode: languageCode)
    }

    public var hasChanges: Bool { settings != original }

    /// 记下（“完成”）。
    public func save() {
        store.set(settings, for: instanceID)
    }
}

/// “语音通话”组的字。
public enum BotinVoiceText {
    public static func section(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "语音通话" : "Voice calls"
    }

    public static func voice(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "语音" : "Voice"
    }

    public static func speed(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "速度" : "Speed"
    }

    public static func language(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "语言" : "Language"
    }

    /// 音色菜单的第一项（没选）。
    public static func notSet(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "未设置" : "Not set"
    }

    /// 语言菜单的第一项（跟着对话的语言）。
    public static func automatic(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "自动" : "Automatic"
    }

    /// 这一组的脚注：还没有语音通话，选择先只存在这台设备上。
    public static func footer(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "语音通话即将推出。这里的选择先只保存在这台设备上。"
            : "Voice calls are coming soon. For now these choices are saved on this device only."
    }

    /// 行上显示的音色名：没选是“未设置”。
    public static func voiceValue(_ id: String?, language: DisplayLanguage = .current) -> String {
        id.flatMap { BotinVoiceDemoData.voice(id: $0)?.name } ?? notSet(language)
    }

    /// 行上显示的语言：没选是“自动”。
    public static func languageValue(_ code: String?, language: DisplayLanguage = .current) -> String {
        code.flatMap { BotinVoiceDemoData.language(code: $0)?.name(language) } ?? automatic(language)
    }
}
