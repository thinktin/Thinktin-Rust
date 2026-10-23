import Foundation
import Testing

@testable import ThinktinKit

// 许可证清单（WBS 12.12、16.5）：解析 inventory.json（schema 2）、按许可证分组、搜索、读原文、找资源包；
// 最后用本机生成的 ThinktinCore 包（target/linux 或 target/apple）里真实的清单整个过一遍。

@Suite("许可证清单")
struct LicenseInventoryTests {
    private func fixture() throws -> LicenseInventory {
        try LicenseInventory(data: Data(SettingsFixture.inventoryJSON.utf8))
    }

    // MARK: 解析

    @Test("解析：认不出的字段跳过，没有名字的、不是对象的组件不要，重名的加序号")
    func parse() throws {
        let inventory = try fixture()
        #expect(inventory.schema == 2)
        #expect(inventory.subject == "client-core")
        #expect(inventory.components.count == 7)
        let ids = inventory.components.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("cargo:jni-like@0.21.1"))
        #expect(ids.contains("cargo:jni-like@0.21.1#2"))

        let zeta = try #require(inventory.components.first { $0.name == "zeta" })
        #expect(zeta.version == "1.0.0")
        #expect(zeta.license == "MIT OR Apache-2.0")
        #expect(zeta.authors == "Zeta Authors <zeta@example.com>")
        #expect(zeta.sourceURL?.absoluteString == "https://crates.io/crates/zeta/1.0.0")
        #expect(zeta.texts.map(\.name) == ["LICENSE-MIT", "LICENSE-APACHE"])
        #expect(zeta.texts.map(\.spdx) == ["MIT", "Apache-2.0"])
        #expect(zeta.texts.allSatisfy { $0.kind == .original })
        #expect(zeta.ecosystemName(.chinese) == "Rust crate")

        // git@ 这种不是网页的源码地址不给链接；没有作者就是 nil。
        let alpha = try #require(inventory.components.first { $0.name == "Alpha" })
        #expect(alpha.sourceURL == nil)
        #expect(alpha.authors == nil)
        #expect(alpha.texts.map(\.kind) == [.original, .bundled])
        #expect(alpha.texts.last?.name == "LICENSE")

        // 包内子目录的原文：名字用在包里的路径；同一个文件只列一次。
        let inner = try #require(inventory.components.first { $0.name == "alpha" })
        #expect(inner.texts.count == 2)
        #expect(inner.texts.last?.name == "vendor/inner/LICENSE")
        #expect(inner.texts.last?.spdx == "MIT")
        #expect(inner.texts.last?.title(.chinese) == "包内：vendor/inner/LICENSE")

        // 标准文本：名字是 SPDX 标识。
        let jni = try #require(inventory.components.first { $0.id == "cargo:jni-like@0.21.1" })
        #expect(jni.texts == [LicenseText(path: "texts/spdx/MIT.txt", name: "MIT", spdx: "MIT", kind: .standard)])
        #expect(jni.texts.first?.title(.english) == "SPDX text: MIT")
        // `files` 不是数组：当没有。
        let jni2 = try #require(inventory.components.first { $0.id == "cargo:jni-like@0.21.1#2" })
        #expect(jni2.texts.map(\.kind) == [.standard])

        // 路径不在清单目录里的（镜像里的绝对路径、..、空路径段）不列；没声明许可证。
        let bash = try #require(inventory.components.first { $0.name == "bash" })
        #expect(bash.texts.isEmpty)
        #expect(bash.license == nil)
        #expect(bash.licenseText(.chinese) == "未声明许可证")
        #expect(bash.ecosystemName(.english) == "Debian package")

        let ring = try #require(inventory.components.first { $0.name == "ring" })
        #expect(ring.restrictedTerms == ["patent"])
    }

    @Test("不是清单的格式：抛 malformed")
    func malformed() {
        #expect(throws: LicenseInventoryError.self) { try LicenseInventory(data: Data("[]".utf8)) }
        #expect(throws: LicenseInventoryError.self) { try LicenseInventory(data: Data("{\"schema\": 2}".utf8)) }
        #expect(throws: LicenseInventoryError.self) { try LicenseInventory(data: Data("not json".utf8)) }
        // 只有 components 也行（schema、subject 缺了用默认值）。
        let minimal = try? LicenseInventory(data: Data("{\"components\": []}".utf8))
        #expect(minimal?.components.isEmpty == true)
        #expect(minimal?.schema == 0)
    }

    // MARK: 分组与搜索

    @Test("OR 的顺序不影响分组；别的表达式原样")
    func normalization() {
        #expect(LicenseInventory.normalizedLicense("MIT OR Apache-2.0") == "Apache-2.0 OR MIT")
        #expect(LicenseInventory.normalizedLicense("Apache-2.0 OR MIT") == "Apache-2.0 OR MIT")
        #expect(LicenseInventory.normalizedLicense("  MIT   OR  Apache-2.0 ") == "Apache-2.0 OR MIT")
        #expect(LicenseInventory.normalizedLicense("Zlib OR Apache-2.0 OR MIT") == "Apache-2.0 OR MIT OR Zlib")
        #expect(LicenseInventory.normalizedLicense("MIT OR MIT") == "MIT")
        #expect(LicenseInventory.normalizedLicense("MIT") == "MIT")
        #expect(LicenseInventory.normalizedLicense("Apache-2.0 AND ISC") == "Apache-2.0 AND ISC")
        #expect(
            LicenseInventory.normalizedLicense("(MIT OR Apache-2.0) AND Unicode-3.0")
                == "(MIT OR Apache-2.0) AND Unicode-3.0")
        #expect(
            LicenseInventory.normalizedLicense("Apache-2.0 WITH LLVM-exception OR MIT")
                == "Apache-2.0 WITH LLVM-exception OR MIT")
        #expect(LicenseInventory.normalizedLicense(nil) == "")
        #expect(LicenseInventory.normalizedLicense("  ") == "")
    }

    @Test("分组：多的在前，没声明的最后；组里按名字、版本（数字顺序）排")
    func grouping() throws {
        let inventory = try fixture()
        let groups = inventory.groups()
        #expect(groups.map(\.license) == ["Apache-2.0 OR MIT", "MIT", "Apache-2.0 AND ISC", ""])
        #expect(groups.map(\.components.count) == [3, 2, 1, 1])
        #expect(groups[0].components.map(\.name) == ["Alpha", "alpha", "zeta"])
        #expect(groups[0].components.map(\.version) == ["0.2.0", "0.10.0", "1.0.0"])
        #expect(groups.last?.title(.chinese) == "未声明许可证")
        #expect(groups.last?.title(.english) == "No license declared")
        #expect(groups.first?.title(.chinese) == "Apache-2.0 OR MIT")
        #expect(inventory.licenseCount == 4)
        #expect(groups.reduce(0) { $0 + $1.components.count } == inventory.components.count)
    }

    @Test("搜索：每个词都要匹配名字、版本、许可证、作者之一，不分大小写")
    func search() throws {
        let inventory = try fixture()
        #expect(inventory.groups(matching: "ZETA").flatMap(\.components).map(\.name) == ["zeta"])
        #expect(inventory.groups(matching: "isc").flatMap(\.components).map(\.name) == ["ring"])
        // 许可证的两种写法都搜得到。
        #expect(inventory.groups(matching: "MIT OR Apache").flatMap(\.components).count >= 3)
        #expect(inventory.groups(matching: "jni team").flatMap(\.components).map(\.id) == ["cargo:jni-like@0.21.1"])
        #expect(inventory.groups(matching: "alpha 0.10").flatMap(\.components).map(\.version) == ["0.10.0"])
        #expect(inventory.groups(matching: "nothing-like-this").isEmpty)
        #expect(inventory.groups(matching: "   ").count == inventory.groups().count)
        let zeta = try #require(inventory.components.first { $0.name == "zeta" })
        #expect(zeta.matches("example.com"))
        #expect(!zeta.matches("zeta gpl"))
    }

    // MARK: 原文

    @Test("路径要在清单目录里面")
    func resolve() {
        let base = URL(fileURLWithPath: "/tmp/licenses")
        #expect(
            LicenseFiles.resolve("texts/by-hash/aaaa/LICENSE", in: base)?.path
                == "/tmp/licenses/texts/by-hash/aaaa/LICENSE")
        #expect(LicenseFiles.resolve("NOTICES.md", in: base) != nil)
        for bad in ["", "/etc/passwd", "~/x", "texts/../../etc/passwd", "./texts/a", "texts//a", "texts/a/", "a\\b"] {
            #expect(LicenseFiles.resolve(bad, in: base) == nil, "\(bad)")
        }
    }

    @Test("读原文：换行统一、不是 UTF-8 的按 Latin-1、不在的报 unreadable、太大的不读")
    func readText() throws {
        let directory = try SettingsFixture.inventoryDirectory()
        defer { SettingsFixture.remove(directory) }
        let mit = try LicenseFiles.readText("texts/by-hash/aaaa/LICENSE-MIT", in: directory)
        #expect(!mit.contains("\r"))
        #expect(mit.hasPrefix("MIT License\n\nCopyright"))

        try Data([0x43, 0x61, 0x66, 0xE9]).write(to: directory.appendingPathComponent("latin1.txt"))
        #expect(try LicenseFiles.readText("latin1.txt", in: directory) == "Café")

        #expect(throws: LicenseInventoryError.unreadable("texts/missing")) {
            try LicenseFiles.readText("texts/missing", in: directory)
        }
        #expect(throws: LicenseInventoryError.invalidPath("../x")) {
            try LicenseFiles.readText("../x", in: directory)
        }
        try Data(count: LicenseFiles.maxTextBytes + 1).write(to: directory.appendingPathComponent("big.txt"))
        #expect(throws: LicenseInventoryError.tooLarge("big.txt")) {
            try LicenseFiles.readText("big.txt", in: directory)
        }
    }

    @Test("分段：空行和只有空白的行隔开，段里的换行、行首缩进保留，行尾空白去掉")
    func paragraphs() {
        let text = "Apache License\nVersion 2.0   \n\n   1. Definitions.\n      \"License\" shall mean\n \t \n\n\nEND\n"
        #expect(
            LicenseFiles.paragraphs(text) == [
                "Apache License\nVersion 2.0", "   1. Definitions.\n      \"License\" shall mean", "END",
            ])
        #expect(LicenseFiles.paragraphs("").isEmpty)
        #expect(LicenseFiles.paragraphs("\n\n  \n").isEmpty)
        #expect(LicenseFiles.paragraphs("one") == ["one"])
    }

    @Test("错误的提示中英文都有、不带英文原文")
    func errorMessages() {
        let errors: [LicenseInventoryError] = [
            .notBundled, .unreadable("x"), .malformed("detail"), .invalidPath("x"), .tooLarge("x"),
        ]
        for error in errors {
            #expect(!error.message(.chinese).isEmpty)
            #expect(!error.message(.english).isEmpty)
            #expect(!error.message(.chinese).contains("detail"))
        }
    }

    // MARK: 找资源包

    @Test("资源包：iOS 的扁平包、macOS 的 Contents/Resources、Linux 的 .resources 都找得到")
    func locate() throws {
        let root = try SettingsFixture.temporaryDirectory()
        defer { SettingsFixture.remove(root) }
        let name = CoreLicenses.resourceBundleName
        let layouts = [
            "ios/\(name).bundle/Licenses", "mac/\(name).bundle/Contents/Resources/Licenses",
            "linux/\(name).resources/Licenses",
        ]
        for layout in layouts {
            try SettingsFixture.write("{\"components\": []}", to: "\(layout)/inventory.json", in: root)
            let base = root.appendingPathComponent(String(layout.split(separator: "/")[0]))
            let found = CoreLicenses.locate(searching: [root.appendingPathComponent("nowhere"), base])
            #expect(found?.standardizedFileURL.path == root.appendingPathComponent(layout).standardizedFileURL.path)
        }
        // 有资源包但没有清单：不算。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty/\(name).bundle/Licenses"), withIntermediateDirectories: true)
        #expect(CoreLicenses.locate(searching: [root.appendingPathComponent("empty")]) == nil)
        #expect(CoreLicenses.locate(searching: []) == nil)
        // 默认找的地方不重复。
        let paths = CoreLicenses.searchLocations.map(\.standardizedFileURL.path)
        #expect(Set(paths).count == paths.count)
        #expect(!paths.isEmpty)
    }

    @Test(
        "测试进程里也按资源包的名字找得到 ThinktinCore 的 Licenses（构建目录里，和测试包放在一起）",
        .enabled(if: SettingsFixture.realLicensesDirectory != nil, "先跑 tools/client-core/build-linux-swift.sh"))
    func locateBuiltBundle() throws {
        let located = try #require(CoreLicenses.locate())
        let real = try #require(SettingsFixture.realLicensesDirectory)
        #expect(located.lastPathComponent == CoreLicenses.directoryName)
        #expect(try LicenseInventory.load(from: located) == LicenseInventory.load(from: real))
    }

    @Test("Swift 依赖：现在没有第三方包")
    func swiftPackages() {
        #expect(SwiftPackageLicenses.components.isEmpty)
    }

    // MARK: 真实的清单

    @Test(
        "本机生成的 ThinktinCore 包里真实的清单：每个组件都有原文、原文都读得出来、分组覆盖全部组件",
        .enabled(if: SettingsFixture.realLicensesDirectory != nil, "先跑 tools/client-core/build-linux-swift.sh"))
    func realInventory() throws {
        let directory = try #require(SettingsFixture.realLicensesDirectory)
        let inventory = try LicenseInventory.load(from: directory)
        #expect(inventory.schema == LicenseInventory.supportedSchema)
        #expect(inventory.subject == "client-core")
        #expect(inventory.components.count > 100)
        #expect(inventory.components.allSatisfy { !$0.name.isEmpty && !$0.version.isEmpty })
        #expect(Set(inventory.components.map(\.id)).count == inventory.components.count)

        let groups = inventory.groups()
        #expect(groups.reduce(0) { $0 + $1.components.count } == inventory.components.count)
        #expect(groups.count == inventory.licenseCount)
        for (a, b) in zip(groups, groups.dropFirst()) where !b.license.isEmpty {
            #expect(a.components.count >= b.components.count)
        }
        // “MIT OR Apache-2.0”和“Apache-2.0 OR MIT”并成一组。
        let raw = Set(inventory.components.compactMap(\.license))
        if raw.contains("MIT OR Apache-2.0") && raw.contains("Apache-2.0 OR MIT") {
            let merged = try #require(groups.first { $0.license == "Apache-2.0 OR MIT" })
            #expect(
                Set(merged.components.compactMap(\.license)).isSuperset(of: ["MIT OR Apache-2.0", "Apache-2.0 OR MIT"]))
        }

        // 每个组件至少有一份能打开的原文，每份都读得出来。
        var paths = Set<String>()
        for component in inventory.components {
            #expect(!component.texts.isEmpty, "\(component.id)")
            #expect(component.sourceURL?.scheme == "https", "\(component.id)")
            for text in component.texts { paths.insert(text.path) }
        }
        for path in paths {
            let text = try LicenseFiles.readText(path, in: directory)
            #expect(!LicenseFiles.paragraphs(text).isEmpty, "\(path)")
        }
        #expect(inventory.components.flatMap(\.texts).contains { $0.kind == .original })

        // 有包内原文的组件（aws-lc-sys 带着 aws-lc 的），名字是在包里的路径。
        if let aws = inventory.components.first(where: { $0.name == "aws-lc-sys" }) {
            #expect(aws.texts.contains { $0.kind == .bundled && $0.name.contains("/") })
        }

        // 搜索。
        let rustls = inventory.groups(matching: "rustls").flatMap(\.components)
        #expect(!rustls.isEmpty)
        #expect(rustls.allSatisfy { $0.matches("rustls") })

        // NOTICES.md 也读得出来。
        let notices = try LicenseFiles.readText(LicenseInventory.noticesFileName, in: directory)
        #expect(LicenseFiles.paragraphs(notices).first?.hasPrefix("# ") == true)
    }
}
