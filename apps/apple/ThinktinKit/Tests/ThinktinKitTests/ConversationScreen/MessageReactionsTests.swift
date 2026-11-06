import Foundation
import Testing

@testable import ThinktinKit

private let writer = ConversationFixture.writer
private let reviewer = ConversationFixture.reviewer

/// 每个测试一个独立的 `UserDefaults`（用完删掉）。
private func makeDefaults() -> (UserDefaults, String) {
    let name = "MessageReactionsTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@MainActor
@Suite("表情回应：本机存储")
struct MessageReactionStoreTests {
    @Test("点一下加上、再点去掉；先点的在前；空白不算；存下来换一个实例读得回来")
    func toggleAndPersist() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MessageReactionStore(defaults: defaults)
        #expect(store.toggle("👍", instanceID: writer, messageID: "seq-1"))
        #expect(store.toggle("🎉", instanceID: writer, messageID: "seq-1"))
        #expect(store.toggle(" ❤️ ", instanceID: writer, messageID: "seq-2"))
        #expect(!store.toggle("  ", instanceID: writer, messageID: "seq-2"))
        #expect(store.reactions(instanceID: writer, messageID: "seq-1") == ["👍", "🎉"])
        #expect(store.reactions(instanceID: writer, messageID: "seq-2") == ["❤️"])
        #expect(store.reactions(instanceID: reviewer, messageID: "seq-1").isEmpty, "按 Botin 分开")
        #expect(!store.toggle("👍", instanceID: writer, messageID: "seq-1"))
        #expect(store.reactions(instanceID: writer, messageID: "seq-1") == ["🎉"])
        let reloaded = MessageReactionStore(defaults: defaults)
        #expect(reloaded.reactions(instanceID: writer, messageID: "seq-1") == ["🎉"])
        #expect(reloaded.reactions(instanceID: writer, messageID: "seq-2") == ["❤️"])
        // 全去掉以后不留空记录。
        reloaded.toggle("🎉", instanceID: writer, messageID: "seq-1")
        reloaded.toggle("❤️", instanceID: writer, messageID: "seq-2")
        #expect(reloaded.table.isEmpty)
        #expect(defaults.data(forKey: MessageReactionStore.storageKey) == nil)
    }

    @Test("一条最多 12 个（挤掉最早的）；最多记 2000 条消息（删最久没动的）；删 Botin 时一起删")
    func limitsAndForget() {
        let store = MessageReactionStore(defaults: nil)
        for emoji in MessageReactions.quick + ["🙂", "🙃"] {
            store.toggle(emoji, instanceID: writer, messageID: "seq-1")
        }
        let list = store.reactions(instanceID: writer, messageID: "seq-1")
        #expect(list.count == MessageReactions.maxPerMessage)
        #expect(list.first == MessageReactions.quick[1] && list.last == "🙃")
        for i in 0...MessageReactions.maxMessages {
            store.toggle("👍", instanceID: reviewer, messageID: "m-\(i)")
        }
        #expect(store.table.count == MessageReactions.maxMessages)
        #expect(store.reactions(instanceID: writer, messageID: "seq-1").isEmpty, "最久没动的先删")
        // 一共记了 2002 条：最早的 seq-1 和 m-0 被删掉。
        #expect(store.reactions(instanceID: reviewer, messageID: "m-0").isEmpty)
        #expect(store.reactions(instanceID: reviewer, messageID: "m-1") == ["👍"])
        store.forget(instanceID: reviewer)
        #expect(store.table.isEmpty)
    }

    @Test("存的东西坏了当没有；重复的键后面的为准")
    func corruptData() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("不是 JSON".utf8), forKey: MessageReactionStore.storageKey)
        #expect(MessageReactionStore(defaults: defaults).table.isEmpty)
        let json = #"[{"k":"a/1","e":["👍"]},{"k":"a/1","e":["🎉"]},{"k":"","e":["x"]},{"k":"a/2","e":[]}]"#
        defaults.set(Data(json.utf8), forKey: MessageReactionStore.storageKey)
        let store = MessageReactionStore(defaults: defaults)
        #expect(store.table == ["a/1": ["🎉"]])
    }

    @Test("对话页：回应记在这个 Botin 下；找不到 Botin 时不能点")
    func conversationModel() async {
        let store = MessageReactionStore(defaults: nil)
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer, reactionStore: store)
        await model.start()
        #expect(model.canReact)
        model.toggleReaction("🔥", on: "seq-9")
        #expect(model.reactions(for: "seq-9") == ["🔥"])
        #expect(store.reactions(instanceID: writer, messageID: "seq-9") == ["🔥"])
        let gone = ConversationModel(client: mock, instanceID: "gone", reactionStore: store)
        await gone.start()
        #expect(!gone.canReact)
        gone.toggleReaction("🔥", on: "seq-9")
        #expect(gone.reactions(for: "seq-9").isEmpty)
    }
}

@Suite("表情选择器的数据")
struct EmojiCatalogTests {
    @Test("八类，每类都有、类里不重复、每个是一个字符；长按面板的 11 个都在里面")
    func categories() {
        #expect(EmojiCategory.allCases.count == 8)
        var all: [String] = []
        for category in EmojiCategory.allCases {
            let emoji = category.emoji
            #expect(!emoji.isEmpty, "\(category)")
            #expect(Set(emoji).count == emoji.count, "\(category) 里有重复")
            #expect(emoji.allSatisfy { $0.count == 1 })
            all += emoji
        }
        #expect(Set(all).count == all.count, "跨类也不重复")
        #expect(MessageReactions.quick.allSatisfy { all.contains($0) })
        #expect(MessageReactions.quick.count == 11)
        #expect(EmojiCategory.smileys.title(.chinese) == "笑脸与人物")
        #expect(EmojiCategory.flags.title(.english) == "Flags")
    }

    @Test("搜索：中文关键词、Unicode 英文名、分类名都能找；空的、找不到的是空")
    func search() {
        #expect(EmojiCatalog.search("笑", language: .chinese).contains("😂"))
        #expect(EmojiCatalog.search("赞", language: .chinese).first == "👍")
        #expect(EmojiCatalog.search("Grinning", language: .english).contains("😀"))
        #expect(EmojiCatalog.search("melting", language: .english) == ["🫠"])
        let animals = EmojiCatalog.search("动物", language: .chinese)
        #expect(animals == EmojiCategory.animals.emoji)
        #expect(EmojiCatalog.search("  ", language: .chinese).isEmpty)
        #expect(EmojiCatalog.search("zzqqxx", language: .english).isEmpty)
        #expect(EmojiCatalog.search("🐶", language: .chinese) == ["🐶"])
        // 连接符、变体选择符、肤色不算名字。
        #expect(!EmojiCatalog.keywords(for: "❤️").contains { $0.contains("variation") })
        #expect(EmojiCatalog.keywords(for: "❤️").contains("心"))
    }
}
