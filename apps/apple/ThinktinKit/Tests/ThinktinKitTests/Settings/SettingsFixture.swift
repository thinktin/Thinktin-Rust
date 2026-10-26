import Foundation

@testable import ThinktinKit

// 设置、开源许可（WBS 12.12）测试共用的东西：临时目录、小份的清单、真实清单的位置。

enum SettingsFixture {
    /// 一个新的临时目录（测试结束后调 `remove`）。
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thinktin-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 写一个文件（中间的目录自动建）。
    static func write(_ text: String, to relativePath: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// 内存里的设置偏好；系统语言固定。
    @MainActor
    static func preferences(system: DisplayLanguage = .chinese) -> SettingsPreferences {
        SettingsPreferences(defaults: nil, systemLanguage: { system })
    }

    /// 一份小清单：覆盖分组（OR 的顺序不同算一组）、没声明许可证、包内原文、标准文本、不安全的路径、重名、
    /// 字段类型不对、没有名字的组件。
    static let inventoryJSON = """
        {
          "schema": 2,
          "subject": "client-core",
          "components": [
            {
              "ecosystem": "cargo", "name": "zeta", "version": "1.0.0", "license": "MIT OR Apache-2.0",
              "files": ["texts/by-hash/aaaa/LICENSE-MIT", "texts/by-hash/bbbb/LICENSE-APACHE"],
              "file_licenses": [
                {"file": "texts/by-hash/aaaa/LICENSE-MIT", "path": "LICENSE-MIT", "proposed": "MIT"},
                {"file": "texts/by-hash/bbbb/LICENSE-APACHE", "path": "LICENSE-APACHE", "proposed": "Apache-2.0"}
              ],
              "generic_files": [], "bundled_files": [], "assets": [],
              "authors": "Zeta Authors <zeta@example.com>",
              "source_url": "https://crates.io/crates/zeta/1.0.0"
            },
            {
              "ecosystem": "cargo", "name": "Alpha", "version": "0.2.0", "license": "Apache-2.0 OR MIT",
              "files": ["texts/by-hash/bbbb/LICENSE-APACHE"],
              "file_licenses": [{"file": "texts/by-hash/bbbb/LICENSE-APACHE", "path": "LICENSE-APACHE"}],
              "bundled_files": ["texts/by-hash/cccc/LICENSE"],
              "authors": null, "source_url": "git@github.com:alpha/alpha.git"
            },
            {
              "ecosystem": "cargo", "name": "alpha", "version": "0.10.0", "license": "Apache-2.0 OR MIT",
              "files": ["texts/by-hash/bbbb/LICENSE-APACHE", "texts/by-hash/bbbb/LICENSE-APACHE"],
              "bundled_files": ["texts/by-hash/cccc/LICENSE"],
              "file_licenses": [
                {"file": "texts/by-hash/cccc/LICENSE", "path": "vendor/inner/LICENSE", "proposed": "MIT", "bundled": true}
              ]
            },
            {
              "ecosystem": "cargo", "name": "jni-like", "version": "0.21.1", "license": "MIT",
              "files": [], "generic_files": ["texts/spdx/MIT.txt"], "authors": "jni team"
            },
            {
              "ecosystem": "deb", "name": "bash", "version": "5.2", "license": null,
              "files": ["/usr/share/doc/bash/copyright", "texts/../secret", "texts//double"]
            },
            {
              "ecosystem": "cargo", "name": "jni-like", "version": "0.21.1", "license": "MIT",
              "files": "not-a-list", "generic_files": ["texts/spdx/MIT.txt"]
            },
            {"ecosystem": "cargo", "version": "1.0.0", "license": "MIT"},
            "not an object",
            {
              "ecosystem": "cargo", "name": "ring", "version": "0.17.14",
              "license": "Apache-2.0 AND ISC", "restricted_terms": ["patent"],
              "files": ["texts/by-hash/dddd/LICENSE"]
            }
          ]
        }
        """

    /// 小清单用到的原文（写进临时目录）。
    static let inventoryTexts: [String: String] = [
        "texts/by-hash/aaaa/LICENSE-MIT":
            "MIT License\r\n\r\nCopyright (c) Zeta\r\n\r\nPermission is hereby granted...\r\n",
        "texts/by-hash/bbbb/LICENSE-APACHE": "Apache License\nVersion 2.0, January 2004\n\n   1. Definitions.\n",
        "texts/by-hash/cccc/LICENSE": "Inner license\n",
        "texts/by-hash/dddd/LICENSE": "ring license\n",
        "texts/spdx/MIT.txt": "MIT License\n\nStandard text\n",
        "NOTICES.md": "# 第三方组件许可证\n\n| 许可证 | 组件数 |\n|---|---|\n| MIT | 2 |\n",
    ]

    /// 写好小清单和原文的目录。
    static func inventoryDirectory() throws -> URL {
        let directory = try temporaryDirectory()
        try write(inventoryJSON, to: LicenseInventory.fileName, in: directory)
        for (path, text) in inventoryTexts {
            try write(text, to: path, in: directory)
        }
        return directory
    }

    /// 真实的清单目录：本机生成的 ThinktinCore 包（Linux 是 target/linux，macOS 是 target/apple）里的 `Licenses/`。
    /// 都没生成时为 nil（相关的测试跳过）。
    static let realLicensesDirectory: URL? = {
        var root = URL(fileURLWithPath: #filePath)
        // Tests/ThinktinKitTests/Settings/这个文件 → 仓库根：往上七级。
        for _ in 0..<7 { root.deleteLastPathComponent() }
        // 和 Package.swift 一样：THINKTIN_DESKTOP=1 时用的是 macOS App 那种包（target/linux-desktop）。
        let desktop = ProcessInfo.processInfo.environment["THINKTIN_DESKTOP"] == "1"
        for platform in desktop ? ["linux-desktop", "apple"] : ["linux", "apple"] {
            let directory = root.appendingPathComponent("target/\(platform)/ThinktinCore/Sources/ThinktinCore/Licenses")
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(LicenseInventory.fileName).path)
            {
                return directory
            }
        }
        return nil
    }()
}
