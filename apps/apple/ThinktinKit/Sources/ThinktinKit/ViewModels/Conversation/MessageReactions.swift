import Foundation
import Observation

// 消息的表情回应（规范 4.3.4、6.11，参考 06 的两排表情、90 的完整表情选择器）：用户给一条消息（自己的任务、Botin 的回复、
// 运行的结果）点几个表情，画在气泡下面，再点一次去掉。服务端没有这个字段（6.11 B 要后端存），所以**只记在这台设备上**
// （`MessageReactionStore`，`UserDefaults` 一个键），不同步、不发给 Botin，换手机、安卓上看不到。

/// 表情回应的常量和长按面板上的那两排。
public enum MessageReactions {
    /// 长按面板上直接点的 11 个（参考 06：两排，第二排最后是“更多表情”）。
    public static let quick = ["👍", "👎", "❤️", "😂", "🎉", "😮", "🔥", "👀", "🙏", "😢", "💯"]
    /// 一条消息最多记几个（再加挤掉最早的）。
    public static let maxPerMessage = 12
    /// 最多记多少条消息的回应（再加删掉最久没动过的）。
    public static let maxMessages = 2_000
}

/// 这台设备上记的表情回应：按“Botin id / 消息 id”记一串表情（先点的在前）。消息 id 是时间线里那一项的 `ConversationItem.id`
/// （事件的序号，同一个 Botin 里不变；事件流重置后序号会变，旧的回应就对不上了，不处理），运行结果那一块是
/// `ConversationFindTarget.summaryID(turnID:)`。
///
/// 存成一张按最后改动排的表（JSON 数组，最久没动的在前），超过 `MessageReactions.maxMessages` 条时从前面删。`defaults` 为 nil 时
/// 只记在内存里（测试、预览）。删了 Botin、注销账号时由 `BotinLocalData` 调 `forget(instanceID:)`。
@Observable @MainActor
public final class MessageReactionStore {
    static let storageKey = "cn.thinktin.conversation.reactions"

    /// 整个 App 共用的一份（存在 `UserDefaults.standard`）。
    public static let shared = MessageReactionStore()

    /// 键是 `key(instanceID:messageID:)`，值是表情（先点的在前）。
    public private(set) var table: [String: [String]]
    /// 键按最后改动排，最久没动的在前。
    @ObservationIgnored private var order: [String]
    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let entries = Self.load(from: defaults)
        self.table = Dictionary(entries.map { ($0.key, $0.emoji) }, uniquingKeysWith: { _, last in last })
        self.order = entries.map(\.key)
    }

    static func key(instanceID: InstanceID, messageID: String) -> String {
        "\(instanceID.rawValue)/\(messageID)"
    }

    /// 这条消息的回应（先点的在前）。
    public func reactions(instanceID: InstanceID, messageID: String) -> [String] {
        table[Self.key(instanceID: instanceID, messageID: messageID)] ?? []
    }

    /// 点一个表情：没点过加上（放最后），点过去掉。返回点完以后有没有这个表情。
    @discardableResult
    public func toggle(_ emoji: String, instanceID: InstanceID, messageID: String) -> Bool {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty else { return false }
        let key = Self.key(instanceID: instanceID, messageID: messageID)
        var list = table[key] ?? []
        let added: Bool
        if let index = list.firstIndex(of: emoji) {
            list.remove(at: index)
            added = false
        } else {
            list.append(emoji)
            if list.count > MessageReactions.maxPerMessage {
                list.removeFirst(list.count - MessageReactions.maxPerMessage)
            }
            added = true
        }
        order.removeAll { $0 == key }
        if list.isEmpty {
            table[key] = nil
        } else {
            table[key] = list
            order.append(key)
        }
        while order.count > MessageReactions.maxMessages {
            table[order.removeFirst()] = nil
        }
        save()
        return added
    }

    /// 删掉一个 Botin 的全部回应（删了 Botin、注销账号）。
    public func forget(instanceID: InstanceID) {
        let prefix = "\(instanceID.rawValue)/"
        let keys = table.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys { table[key] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
        save()
    }

    private struct Entry: Codable {
        var key: String
        var emoji: [String]

        enum CodingKeys: String, CodingKey {
            case key = "k"
            case emoji = "e"
        }
    }

    private func save() {
        guard let defaults else { return }
        let entries = order.compactMap { key in table[key].map { Entry(key: key, emoji: $0) } }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// 坏了（不是 JSON）就当没有；空的、重复的键丢掉（后面的为准）。
    private static func load(from defaults: UserDefaults?) -> [Entry] {
        guard let data = defaults?.data(forKey: storageKey),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        var seen = Set<String>()
        var result: [Entry] = []
        for entry in entries.reversed()
        where !entry.emoji.isEmpty && !entry.key.isEmpty && seen.insert(entry.key).inserted {
            result.append(entry)
        }
        return Array(result.reversed().suffix(MessageReactions.maxMessages))
    }
}

extension ConversationModel {
    /// 能不能点表情回应（Botin 还在）。
    public var canReact: Bool { !isMissing }

    /// 一条消息的回应（只在这台设备上）。
    public func reactions(for messageID: String) -> [String] {
        reactionStore.reactions(instanceID: instanceID, messageID: messageID)
    }

    /// 点一个表情：没点过加上、点过去掉。
    public func toggleReaction(_ emoji: String, on messageID: String) {
        guard canReact else { return }
        reactionStore.toggle(emoji, instanceID: instanceID, messageID: messageID)
    }
}

// MARK: - 完整的表情选择器（参考 90）

/// 表情选择器里的一类（Unicode CLDR 的分组，和系统键盘一样的顺序）。
public enum EmojiCategory: String, CaseIterable, Hashable, Sendable {
    case smileys, animals, food, activity, travel, objects, symbols, flags

    public func title(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .smileys: return zh ? "笑脸与人物" : "Smileys & People"
        case .animals: return zh ? "动物与自然" : "Animals & Nature"
        case .food: return zh ? "食物与饮料" : "Food & Drink"
        case .activity: return zh ? "活动" : "Activity"
        case .travel: return zh ? "旅行与地点" : "Travel & Places"
        case .objects: return zh ? "物品" : "Objects"
        case .symbols: return zh ? "符号" : "Symbols"
        case .flags: return zh ? "旗帜" : "Flags"
        }
    }

    /// 这一类的表情（按系统键盘的顺序，挑了常用的；国家和地区的旗帜不放）。
    public var emoji: [String] {
        Self.table[self] ?? []
    }

    private static let table: [EmojiCategory: [String]] = Dictionary(
        uniqueKeysWithValues: EmojiCategory.allCases.map { ($0, $0.source.map(String.init)) })

    private var source: String {
        switch self {
        case .smileys:
            "😀😃😄😁😆😅🤣😂🙂🙃🫠😉😊😇🥰😍🤩😘😗☺️😚😙🥲😋😛😜🤪😝🤑🤗🤭🫢🫣🤫🤔🫡🤐🤨😐😑😶🫥😶‍🌫️😏😒🙄😬😮‍💨🤥"
                + "😌😔😪🤤😴😷🤒🤕🤢🤮🤧🥵🥶🥴😵😵‍💫🤯🤠🥳🥸😎🤓🧐😕🫤😟🙁☹️😮😯😲😳🥺🥹😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱"
                + "😤😡😠🤬😈👿💀☠️💩🤡👹👺👻👽👾🤖😺😸😹😻😼😽🙀😿😾🙈🙉🙊"
                + "👋🤚🖐️✋🖖🫱🫲🫳🫴👌🤌🤏✌️🤞🫰🤟🤘🤙👈👉👆👇☝️🫵👍👎✊👊🤛🤜👏🙌🫶👐🤲🤝🙏✍️💅🤳💪🦾🦿🦵🦶👂🦻👃"
                + "🧠🫀🫁🦷🦴👀👁️👅👄🫦👶🧒👦👧🧑👱👨🧔👩🧓👴👵🙍🙎🙅🙆💁🙋🧏🙇🤦🤷🧑‍💻🧑‍🎨🧑‍🚀🧑‍🍳🧑‍🏫🧑‍🔬👮🕵️💂🥷👷"
                + "🫅🤴👸👳👲🧕🤵👰🤰🫄🤱👼🎅🤶🦸🦹🧙🧚🧛🧜🧝🧞🧟🧌💆💇🚶🧍🧎🏃💃🕺👯🧖🧗🤺🏇⛷️🏂🏌️🏄🚣🏊⛹️🏋️🚴🚵🤸🤼"
                + "🤽🤾🤹🧘🛀🛌👭👫👬💏💑👪🗣️👤👥🫂👣"
        case .animals:
            "🐶🐱🐭🐹🐰🦊🐻🐼🐻‍❄️🐨🐯🦁🐮🐷🐽🐸🐵🐔🐧🐦🐤🐣🐥🦆🦅🦉🦇🐺🐗🐴🦄🐝🪱🐛🦋🐌🐞🐜🪰🪲🪳🦟🦗🕷️🕸️🦂🐢🐍🦎"
                + "🦖🦕🐙🦑🦐🦞🦀🪼🐡🐠🐟🐬🐳🐋🦈🦭🐊🐅🐆🦓🦍🦧🦣🐘🦛🦏🐪🐫🦒🦘🦬🐃🐂🐄🐎🐖🐏🐑🦙🐐🦌🐕🐩🦮🐕‍🦺🐈🐈‍⬛"
                + "🪶🐓🦃🦤🦚🦜🦢🦩🕊️🐇🦝🦨🦡🦫🦦🦥🐁🐀🐿️🦔🐾🐉🐲🌵🎄🌲🌳🌴🪵🌱🌿☘️🍀🎍🪴🎋🍃🍂🍁🪺🪹🍄🐚🪸🪨🌾💐🌷"
                + "🌹🥀🪷🌺🌸🌼🌻🌞🌝🌛🌜🌚🌕🌖🌗🌘🌑🌒🌓🌔🌙🌎🌍🌏🪐💫⭐🌟✨⚡☄️💥🔥🌪️🌈☀️🌤️⛅🌥️☁️🌦️🌧️⛈️🌩️🌨️❄️"
                + "☃️⛄🌬️💨💧💦🫧☔☂️🌊🌫️"
        case .food:
            "🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥬🥒🌶️🫑🌽🥕🫒🧄🧅🥔🍠🫘🥐🥯🍞🥖🥨🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖"
                + "🌭🍔🍟🍕🫓🥪🥙🧆🌮🌯🫔🥗🥘🫕🥫🍝🍜🍲🍛🍣🍱🥟🦪🍤🍙🍚🍘🍥🥠🥮🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰"
                + "🥜🍯🥛🍼🫖☕🍵🧃🥤🧋🍶🍺🍻🥂🍷🥃🍸🍹🧉🍾🧊🥄🍴🍽️🥣🥡🥢🧂"
        case .activity:
            "⚽🏀🏈⚾🥎🎾🏐🏉🥏🎱🪀🏓🏸🏒🏑🥍🏏🪃🥅⛳🪁🏹🎣🤿🥊🥋🎽🛹🛼🛷⛸️🥌🎿🎯🪂🏆🥇🥈🥉🏅🎖️🏵️🎗️🎫🎟️🎪🎭🩰"
                + "🎨🎬🎤🎧🎼🎹🥁🪘🎷🎺🪗🎸🪕🎻🎲♟️🎳🎮🎰🧩"
        case .travel:
            "🚗🚕🚙🚌🚎🏎️🚓🚑🚒🚐🛻🚚🚛🚜🦯🦽🦼🛴🚲🛵🏍️🛺🚨🚔🚍🚘🚖🚡🚠🚟🚃🚋🚞🚝🚄🚅🚈🚂🚆🚇🚊🚉✈️🛫🛬🛩️💺"
                + "🛰️🚀🛸🚁🛶⛵🚤🛥️🛳️⛴️🚢⚓🪝⛽🚧🚦🚥🚏🗺️🗿🗽🗼🏰🏯🏟️🎡🎢🎠⛲⛱️🏖️🏝️🏜️🌋⛰️🏔️🗻🏕️⛺🛖🏠🏡🏘️🏚️"
                + "🏗️🏭🏢🏬🏣🏤🏥🏦🏨🏪🏫🏩💒🏛️⛪🕌🕍🛕🕋⛩️🛤️🛣️🗾🎑🏞️🌅🌄🌠🎇🎆🌇🌆🏙️🌃🌌🌉🌁"
        case .objects:
            "⌚📱📲💻⌨️🖥️🖨️🖱️🖲️🕹️🗜️💽💾💿📀📼📷📸📹🎥📽️🎞️📞☎️📟📠📺📻🎙️🎚️🎛️🧭⏱️⏲️⏰🕰️⌛⏳📡🔋🪫🔌"
                + "💡🔦🕯️🪔🧯🛢️💸💵💴💶💷🪙💰💳💎⚖️🪜🧰🪛🔧🔨⚒️🛠️⛏️🪚🔩⚙️🪤🧱⛓️🧲🧨🪓🔪🗡️⚔️🛡️⚰️🪦⚱️🏺🔮📿🧿"
                + "🪬💈⚗️🔭🔬🕳️🩹🩺🩻🩼💊💉🩸🧬🦠🧫🧪🌡️🧹🪠🧺🧻🚽🚰🚿🛁🧼🪥🪒🧽🪣🧴🛎️🔑🗝️🚪🪑🛋️🛏️🧸🪆🖼️🪞🪟"
                + "🛍️🛒🎁🎈🎏🎀🪄🪅🎊🎉🎎🏮🎐🧧✉️📩📨📧💌📥📤📦🏷️🪧📪📫📬📭📮📯📜📃📄📑🧾📊📈📉🗒️🗓️📆📅🗑️📇🗃️"
                + "🗳️🗄️📋📁📂🗂️🗞️📰📓📔📒📕📗📘📙📚📖🔖🧷🔗📎🖇️📐📏🧮📌📍✂️🖊️🖋️✒️🖌️🖍️📝✏️🔍🔎🔏🔐🔒🔓"
        case .symbols:
            "❤️🧡💛💚💙💜🖤🤍🤎💔❤️‍🔥❤️‍🩹❣️💕💞💓💗💖💘💝💟☮️✝️☪️🕉️☸️✡️🔯🕎☯️☦️🛐⛎♈♉♊♋♌♍♎♏♐♑♒♓"
                + "🆔⚛️🉑☢️☣️📴📳🈶🈚🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘❌⭕🛑⛔📛🚫💯💢♨️🚷🚯🚳🚱🔞📵🚭"
                + "❗❕❓❔‼️⁉️🔅🔆〽️⚠️🚸🔱⚜️🔰♻️✅🈯💹❇️✳️❎🌐💠Ⓜ️🌀💤🏧🚾♿🅿️🛗🈳🈂️🛂🛃🛄🛅🚹🚺🚼⚧️🚻🚮🎦"
                + "📶🈁🔣ℹ️🔤🔡🔠🆖🆗🆙🆒🆕🆓0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟🔢#️⃣*️⃣⏏️▶️⏸️⏯️⏹️⏺️⏭️⏮️⏩⏪⏫⏬◀️"
                + "🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔀🔁🔂🔄🔃🎵🎶➕➖➗✖️🟰♾️💲💱™️©️®️〰️➰➿🔚🔙🔛🔝🔜✔️☑️🔘"
                + "🔴🟠🟡🟢🔵🟣⚫⚪🟤🔺🔻🔸🔹🔶🔷🔳🔲▪️▫️◾◽◼️◻️🟥🟧🟨🟩🟦🟪⬛⬜🟫🔈🔇🔉🔊🔔🔕📣📢💬💭🗯️♠️♣️♥️♦️🃏🎴"
                + "🀄🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛"
        case .flags:
            "🏁🚩🎌🏴🏳️"
        }
    }
}

/// 表情选择器的数据：分类、搜索。
public enum EmojiCatalog {
    /// 找表情：中文关键词（常用的几十个）、Unicode 的英文名字（“GRINNING FACE”）、分类名（“动物”）都能找；按分类的顺序排、
    /// 不重复。空的返回空。
    public static func search(_ query: String, language: DisplayLanguage) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for category in EmojiCategory.allCases {
            let categoryMatches =
                category.title(.chinese).contains(q) || category.title(.english).lowercased().contains(q)
            for emoji in category.emoji where seen.insert(emoji).inserted {
                if categoryMatches || emoji == q || keywords(for: emoji).contains(where: { $0.contains(q) }) {
                    result.append(emoji)
                }
            }
        }
        return result
    }

    /// 一个表情能被哪些词找到：中文关键词 + Unicode 名字（小写，去掉连接符、变体选择符、肤色）。
    public static func keywords(for emoji: String) -> [String] {
        let names = emoji.unicodeScalars.compactMap { scalar -> String? in
            guard let name = scalar.properties.name,
                !name.hasPrefix("ZERO WIDTH"), !name.hasPrefix("VARIATION SELECTOR"),
                !name.hasPrefix("EMOJI MODIFIER"), !name.hasPrefix("COMBINING")
            else { return nil }
            return name.lowercased()
        }
        return (chinese[emoji] ?? []) + names
    }

    /// 常用表情的中文关键词。
    static let chinese: [String: [String]] = {
        let source = """
            😀 笑 开心 高兴|😃 笑 开心|😄 笑 开心|😁 笑 嘻嘻|😆 大笑 哈哈|😅 尴尬 汗|🤣 笑 打滚|😂 笑哭 哈哈 笑死|🙂 微笑|🙃 倒脸|\
            🫠 融化|😉 眨眼|😊 微笑 害羞|😇 天使|🥰 爱 喜欢|😍 喜欢 爱心眼|🤩 崇拜 星星眼|😘 飞吻 亲|😋 好吃 馋|😜 调皮|🤪 疯狂|\
            🤗 拥抱|🤭 偷笑|🤫 嘘 安静|🤔 思考 想 疑问|🫡 敬礼 收到|🤐 闭嘴|🤨 怀疑|😐 无语 面无表情|😑 无语|😶 沉默|😏 得意|\
            😒 不爽|🙄 翻白眼|😬 尴尬|😌 放松|😔 失落|😪 困|🤤 流口水|😴 睡觉 困|😷 口罩 生病|🤒 发烧 生病|🤕 受伤|🤢 恶心|\
            🤮 呕吐|🤧 感冒 喷嚏|🥵 热|🥶 冷|😵 晕|🤯 震惊 爆炸|🥳 庆祝 派对 生日|😎 酷 墨镜|🤓 书呆子|🧐 研究 审视|😕 困惑|\
            😟 担心|🙁 难过|😮 惊讶 哇|😲 震惊|😳 脸红 害羞|🥺 可怜 求求|🥹 感动|😨 害怕|😰 焦虑 冷汗|😢 哭 难过 伤心|\
            😭 大哭 哭|😱 惊恐 害怕|😩 累|😫 累 疲惫|🥱 打哈欠 困|😤 哼 不服|😡 生气 愤怒|😠 生气|🤬 骂人 愤怒|😈 坏笑|\
            💀 骷髅 死了|💩 便便|🤡 小丑|👻 鬼|👽 外星人|🤖 机器人|🙈 捂眼 不看|🙊 捂嘴|👋 挥手 你好 再见|✋ 举手 停|👌 好的 好|\
            ✌️ 胜利 耶|🤞 祈祷 好运|🤟 爱你|🤙 打电话|👈 左|👉 右|👆 上|👇 下|☝️ 第一|👍 赞 好 同意 点赞|👎 踩 不好 反对|\
            ✊ 拳头 加油|👊 拳头|👏 鼓掌 棒|🙌 欢呼 举手|🫶 比心|🤝 握手 合作|🙏 谢谢 拜托 祈祷|✍️ 写字|💪 加油 强壮 肌肉|\
            🧠 大脑 聪明|👀 看 眼睛 关注|👶 宝宝|🧑‍💻 程序员 写代码|🫂 拥抱|❤️ 心 爱 喜欢 红心|🧡 心 橙色|💛 心 黄色|💚 心 绿色|\
            💙 心 蓝色|💜 心 紫色|🖤 心 黑色|🤍 心 白色|💔 心碎|❤️‍🔥 热爱|💕 心|💯 满分 一百 完美|✅ 完成 对 勾|❌ 错 不 叉|\
            ⭕ 对 圆|⚠️ 警告 注意|❓ 问号 疑问|❗ 感叹号 重要|‼️ 重要|💤 睡觉|💬 对话 消息 聊天|💭 想法|🔥 火 厉害 热门|⭐ 星星|\
            🌟 星星 闪亮|✨ 闪亮 星光|⚡ 闪电 快|💥 爆炸|🌈 彩虹|☀️ 太阳 晴|🌙 月亮 晚安|☁️ 云|🌧️ 下雨 雨|❄️ 雪 冷|🌊 海浪|\
            🍀 幸运 四叶草|🌹 玫瑰 花|🌸 樱花 花|🌻 向日葵 花|🐶 狗|🐱 猫|🐼 熊猫|🐯 老虎|🐷 猪|🐮 牛|🐔 鸡|🐟 鱼|🐉 龙|\
            ☕ 咖啡|🍵 茶|🍺 啤酒|🍻 干杯|🥂 干杯|🍷 红酒|🍰 蛋糕|🎂 蛋糕 生日|🍜 面条 拉面|🍚 米饭|🥟 饺子|🍉 西瓜|🍎 苹果|\
            🎉 庆祝 撒花 恭喜|🎊 庆祝 彩球|🎈 气球|🎁 礼物|🏆 奖杯 冠军|🥇 金牌 第一|🎯 目标 靶心|🎮 游戏|🎵 音乐|🚀 火箭 发布 上线|\
            ✈️ 飞机 出差|🚗 汽车|🏠 家 房子|🏢 公司 办公楼|💡 灯泡 想法 主意|📌 图钉 置顶|📎 回形针 附件|📝 笔记 记录|📅 日历 日期|\
            ⏰ 闹钟 提醒|⏳ 等待 沙漏|💻 电脑 笔记本|📱 手机|🔒 锁 安全|🔑 钥匙 密码|💰 钱 钱袋|📈 增长 上涨|📉 下跌|📊 图表 数据|\
            🔍 搜索 查找|📦 包裹 快递|✉️ 邮件 信|🔗 链接|🛠️ 工具 修理|⚙️ 设置 齿轮|🧪 实验 测试|🐛 虫子 bug|🔔 通知 铃铛|🔕 静音
            """
        var table: [String: [String]] = [:]
        for entry in source.split(separator: "|") {
            let parts = entry.split(separator: " ").map(String.init)
            guard let emoji = parts.first, parts.count > 1 else { continue }
            table[emoji] = Array(parts.dropFirst())
        }
        return table
    }()
}

// MARK: - 文案

extension ConversationText {
    /// 读屏的自定义操作、Mac 右键菜单里的一项。
    public static func react(_ language: DisplayLanguage) -> String {
        language == .chinese ? "回应" : "React"
    }

    /// 长按面板第二排最后那个（参考 06 的“笑脸 +”）。
    public static func moreEmoji(_ language: DisplayLanguage) -> String {
        language == .chinese ? "更多表情" : "More Emoji"
    }

    /// 表情选择器左上的返回（回到长按面板）。
    public static func emojiBack(_ language: DisplayLanguage) -> String {
        language == .chinese ? "返回" : "Back"
    }

    /// 表情选择器的搜索框（参考 90）。
    public static func searchEmoji(_ language: DisplayLanguage) -> String {
        language == .chinese ? "搜索表情" : "Search Emoji"
    }

    /// 气泡下面的一个回应的读屏标签（点了去掉）。
    public static func removeReaction(_ emoji: String, language: DisplayLanguage) -> String {
        language == .chinese ? "你的回应 \(emoji)，点按移除" : "Your reaction \(emoji). Tap to remove"
    }

    /// 气泡下面那一排的说明：只在这台设备上。
    public static func reactionsNote(_ language: DisplayLanguage) -> String {
        language == .chinese ? "表情回应只保存在这台设备上" : "Reactions are saved on this device only"
    }

    /// 长按面板第一组里的“标为未读”（参考 06；ThinkTin 没有未读，6.10）。
    public static func markUnread(_ language: DisplayLanguage) -> String {
        language == .chinese ? "标为未读" : "Mark as Unread"
    }

    /// “标为未读”点了以后“即将推出”的说明。
    public static func markUnreadComingSoon(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "未读要记在服务端才能在各台设备上对得上，还在做。"
            : "Unread state has to live on the server to stay in sync across devices. It's on the way."
    }
}
