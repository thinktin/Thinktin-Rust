import Foundation
import Testing

@testable import ThinktinKit

// Botin 的头像外观（规范 docs/ios-ui-redesign.md 4.4.4、6.9）：形状和颜色的清单、按名字取色、存在这台设备上的读写和退路，
// 以前的版本存的颜色换成新的。

@MainActor
@Suite("Botin 头像外观")
struct InstanceAppearanceStoreTests {
    /// 只给这次测试用的 `UserDefaults`。
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "cn.thinktin.tests.appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("形状 3 × 5、颜色 2 × 6（色板的顺序、存的原始值）；按名字取色的 8 种和顺序")
    func catalog() {
        #expect(AvatarShape.allCases.count == 15)
        #expect(AvatarShape.allCases.first == .circle)
        // 色板两行：红、橙、琥珀黄、绿、薄荷绿、天蓝 / 蓝、紫罗兰、紫、粉、棕、灰。
        #expect(
            AvatarColor.allCases == [
                .red, .orange, .amber, .green, .mint, .sky, .blue, .violet, .purple, .pink, .brown, .grey,
            ])
        #expect(
            AvatarColor.allCases.map(\.rawValue) == [
                "red", "orange", "amber", "green", "mint", "sky", "blue", "violet", "purple", "pink", "brown", "grey",
            ])
        // 顺序不能改（按下标取，换了已有的 Botin 会变色）。
        #expect(AvatarColor.nameHashed == [.blue, .violet, .purple, .pink, .mint, .sky, .orange, .green])
        #expect(Set(AvatarColor.nameHashed).count == AvatarColor.nameHashed.count)
        #expect(Set(AvatarColor.nameHashed).isSubset(of: Set(AvatarColor.allCases)))
        // 读屏的名字都有、不重复。
        for language in [DisplayLanguage.chinese, .english] {
            #expect(Set(AvatarShape.allCases.map { $0.localizedName(language) }).count == 15)
            #expect(Set(AvatarColor.allCases.map { $0.localizedName(language) }).count == 12)
        }
        #expect(AvatarShape.cloud.localizedName(.chinese) == "云朵")
        #expect(AvatarColor.grey.localizedName(.english) == "Grey")
        #expect(AvatarColor.amber.localizedName(.chinese) == "琥珀黄")
    }

    @Test("按名字取色：FNV-1a，跨进程稳定，不分大小写、不管首尾空白（和第 0 轮的头像一样）")
    func nameHash() {
        // 期望值是在别处（Python）按同样的算法独立算出来的，和 ThinktinUI 的 InstanceAvatarTests 同一组。
        #expect(AvatarColor.nameHashIndex(for: "周报助手") == 4)
        #expect(AvatarColor.nameHashIndex(for: "Hermes Agent") == 2)
        #expect(AvatarColor.nameHashIndex(for: "OpenClaw") == 6)
        #expect(AvatarColor.nameHashIndex(for: "日程") == 3)
        #expect(AvatarColor.nameHashIndex(for: "Anthropic (Claude)") == 0)
        #expect(AvatarColor.nameHashIndex(for: "") == 5)
        #expect(AvatarColor.forName("周报助手") == .mint)
        #expect(AvatarColor.forName("OpenClaw") == .orange)
        #expect(AvatarColor.forName("Codex") == AvatarColor.forName("  codex \n"))
        #expect(InstanceAppearance.default.resolvedColor(name: "周报助手") == .mint)
        #expect(InstanceAppearance(color: .blue).resolvedColor(name: "周报助手") == .blue)
    }

    @Test("没记过的 Botin 是默认的：圆形、按名字取色")
    func fallback() {
        let store = InstanceAppearanceStore(defaults: nil)
        #expect(store.appearance(for: DemoData.writerID) == nil)
        #expect(store.resolved(for: DemoData.writerID) == .default)
        #expect(InstanceAppearance.default == InstanceAppearance(shape: .circle, color: nil))
        #expect(InstanceAppearance.default.isDefault)
        #expect(!InstanceAppearance(shape: .circle, color: .blue).isDefault)
    }

    @Test("记下、读回来（重开 App 也在）；改成默认的删掉记录")
    func roundTrip() throws {
        try withDefaults { defaults in
            let store = InstanceAppearanceStore(defaults: defaults)
            let flower = InstanceAppearance(shape: .flower, color: .purple)
            store.set(flower, for: DemoData.writerID)
            store.set(InstanceAppearance(shape: .star), for: DemoData.reviewerID)
            #expect(store.appearance(for: DemoData.writerID) == flower)

            let reopened = InstanceAppearanceStore(defaults: defaults)
            #expect(reopened.appearance(for: DemoData.writerID) == flower)
            #expect(reopened.appearance(for: DemoData.reviewerID) == InstanceAppearance(shape: .star, color: nil))
            #expect(reopened.appearances.count == 2)

            reopened.set(.default, for: DemoData.writerID)
            reopened.set(nil, for: DemoData.reviewerID)
            #expect(reopened.appearances.isEmpty)
            #expect(defaults.data(forKey: InstanceAppearanceStore.storageKey) == nil)
            #expect(InstanceAppearanceStore(defaults: defaults).appearances.isEmpty)
        }
    }

    @Test("读的时候宽松：认不出的形状当圆形、颜色当没选；坏数据当没有")
    func lenientDecoding() throws {
        try withDefaults { defaults in
            let json = """
                {"a": {"shape": "dodecahedron", "color": "amber"},
                 "b": {"shape": "cloud", "color": "ultraviolet"},
                 "c": {"shape": "circle"},
                 "": {"shape": "star"}}
                """
            defaults.set(Data(json.utf8), forKey: InstanceAppearanceStore.storageKey)
            let store = InstanceAppearanceStore(defaults: defaults)
            #expect(store.appearance(for: "a") == InstanceAppearance(shape: .circle, color: .amber))
            #expect(store.appearance(for: "b") == InstanceAppearance(shape: .cloud, color: nil))
            // 等于默认的、没有 id 的不留。
            #expect(store.appearance(for: "c") == nil)
            #expect(store.appearances.count == 2)

            defaults.set(Data("not json".utf8), forKey: InstanceAppearanceStore.storageKey)
            #expect(InstanceAppearanceStore(defaults: defaults).appearances.isEmpty)
        }
        // 编码：形状和颜色存原始值，没选颜色不写。
        let data = try JSONEncoder().encode(InstanceAppearance(shape: .leaf))
        #expect(String(decoding: data, as: UTF8.self) == #"{"shape":"leaf"}"#)
    }

    /// 存着的表（原始的字符串，看认不出的值有没有留着）。
    private func storedTable(_ defaults: UserDefaults) throws -> [String: [String: String]] {
        let data = try #require(defaults.data(forKey: InstanceAppearanceStore.storageKey))
        return try JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    @Test("以后的版本加的形状、颜色：画的时候当默认，别的 Botin 存的时候原样留着；自己改了、删了才换掉")
    func keepsUnrecognizedValues() throws {
        try withDefaults { defaults in
            let json = """
                {"a": {"shape": "dodecahedron"},
                 "b": {"shape": "cloud", "color": "ultraviolet"},
                 "c": {"shape": "blob", "color": "navy"},
                 "d": {"shape": "star", "color": "mint"}}
                """
            defaults.set(Data(json.utf8), forKey: InstanceAppearanceStore.storageKey)
            let store = InstanceAppearanceStore(defaults: defaults)
            #expect(store.resolved(for: "a") == .default)
            #expect(store.appearance(for: "b") == InstanceAppearance(shape: .cloud, color: nil))

            // 新建了一个 Botin：别的记录原样存回去。
            store.set(InstanceAppearance(shape: .leaf), for: "e")
            var table = try storedTable(defaults)
            #expect(table["a"] == ["shape": "dodecahedron"])
            #expect(table["b"] == ["shape": "cloud", "color": "ultraviolet"])
            #expect(table["c"] == ["shape": "blob", "color": "navy"])
            #expect(table["d"] == ["shape": "star", "color": "mint"])
            #expect(table["e"] == ["shape": "leaf"])

            // 重开也还在（再装回新版本时认得出）。
            let reopened = InstanceAppearanceStore(defaults: defaults)
            reopened.set(InstanceAppearance(shape: .hexagon), for: "e")
            #expect(try storedTable(defaults)["a"] == ["shape": "dodecahedron"])

            // 这个 Botin 自己改了外观（和读出来的一样也算）、删掉了，才换掉认不出的值。
            reopened.set(InstanceAppearance(shape: .cloud, color: nil), for: "b")
            reopened.set(nil, for: "a")
            reopened.forget(["c"])
            table = try storedTable(defaults)
            #expect(table["a"] == nil)
            #expect(table["b"] == ["shape": "cloud"])
            #expect(table["c"] == nil)
            #expect(table.count == 3)
        }
    }

    @Test("以前的版本存的 12 种颜色：读的时候换成最接近的新颜色，下次存的时候写新的原始值；认不出的照旧留着")
    func migratesLegacyColors() throws {
        let legacy: [String: AvatarColor] = [
            "teal": .mint, "lake": .sky, "blue": .blue, "navy": .blue, "indigo": .violet, "purple": .purple,
            "orchid": .purple, "pink": .pink, "brown": .brown, "taupe": .brown, "slate": .grey, "graphite": .grey,
        ]
        for (raw, color) in legacy {
            #expect(AvatarColor(storedValue: raw) == color, "\(raw)")
            // 直接按 `Codable` 读也一样（JSON 里的一个字符串）。
            let decoded = try JSONDecoder().decode([AvatarColor].self, from: Data(#"["\#(raw)"]"#.utf8))
            #expect(decoded == [color], "\(raw)")
        }
        // 新的原始值照样认得；只认这个版本的 `init(rawValue:)` 不认旧的；以后的版本加的谁都不认。
        for color in AvatarColor.allCases {
            #expect(AvatarColor(storedValue: color.rawValue) == color)
        }
        #expect(AvatarColor(rawValue: "teal") == nil && AvatarColor(rawValue: "graphite") == nil)
        #expect(AvatarColor(storedValue: "ultraviolet") == nil && AvatarColor(storedValue: "") == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([AvatarColor].self, from: Data(#"["ultraviolet"]"#.utf8))
        }
        let appearance = try JSONDecoder().decode(
            InstanceAppearance.self, from: Data(#"{"shape": "leaf", "color": "orchid"}"#.utf8))
        #expect(appearance == InstanceAppearance(shape: .leaf, color: .purple))

        try withDefaults { defaults in
            let json = """
                {"a": {"shape": "star", "color": "teal"},
                 "b": {"shape": "circle", "color": "graphite"},
                 "c": {"shape": "blob", "color": "navy"},
                 "d": {"shape": "cloud", "color": "ultraviolet"}}
                """
            defaults.set(Data(json.utf8), forKey: InstanceAppearanceStore.storageKey)
            let store = InstanceAppearanceStore(defaults: defaults)
            #expect(store.appearance(for: "a") == InstanceAppearance(shape: .star, color: .mint))
            #expect(store.appearance(for: "b") == InstanceAppearance(shape: .circle, color: .grey))
            // 形状认不出的那条照旧留着原样（画的时候颜色照样换成新的）。
            #expect(store.appearance(for: "c") == InstanceAppearance(shape: .circle, color: .blue))
            #expect(store.appearance(for: "d") == InstanceAppearance(shape: .cloud, color: nil))
            // 读的时候不写回去；下次存（随便哪个 Botin 改了外观）时整张表写新的原始值。
            #expect(try storedTable(defaults)["a"] == ["shape": "star", "color": "teal"])
            store.set(InstanceAppearance(shape: .leaf), for: "e")
            let table = try storedTable(defaults)
            #expect(table["a"] == ["shape": "star", "color": "mint"])
            #expect(table["b"] == ["shape": "circle", "color": "grey"])
            #expect(table["c"] == ["shape": "blob", "color": "navy"])
            #expect(table["d"] == ["shape": "cloud", "color": "ultraviolet"])
            #expect(table["e"] == ["shape": "leaf"])
            // 重开以后读的是新的原始值，样子不变。
            let reopened = InstanceAppearanceStore(defaults: defaults)
            #expect(reopened.appearance(for: "a") == InstanceAppearance(shape: .star, color: .mint))
            #expect(reopened.appearance(for: "b") == InstanceAppearance(shape: .circle, color: .grey))
        }
    }

    @Test("删掉一批 Botin 的记录（删了 Botin、注销账号）；没记过的不动")
    func forget() throws {
        try withDefaults { defaults in
            let store = InstanceAppearanceStore(defaults: defaults)
            store.set(InstanceAppearance(shape: .star), for: DemoData.writerID)
            store.set(InstanceAppearance(shape: .leaf), for: DemoData.reviewerID)
            store.forget([DemoData.writerID, "never-stored"])
            #expect(store.appearance(for: DemoData.writerID) == nil)
            #expect(store.appearance(for: DemoData.reviewerID) == InstanceAppearance(shape: .leaf))
            #expect(InstanceAppearanceStore(defaults: defaults).appearances.count == 1)
            store.forget([DemoData.reviewerID])
            #expect(defaults.data(forKey: InstanceAppearanceStore.storageKey) == nil)
        }
    }

    @Test("App 的 AppModel 带一份（传 nil 的 defaults 时只在内存里）")
    func appModelOwnsStore() {
        let app = AppModel(client: MockClient(state: DemoData.state(), stepDelay: 0), defaults: nil)
        app.appearances.set(InstanceAppearance(shape: .hexagon), for: DemoData.writerID)
        #expect(app.appearances.resolved(for: DemoData.writerID).shape == .hexagon)
    }
}
