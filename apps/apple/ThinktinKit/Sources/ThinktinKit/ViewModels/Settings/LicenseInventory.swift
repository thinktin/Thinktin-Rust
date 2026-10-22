import Foundation

/// 第三方组件的许可证清单（WBS 12.12、16.5；docs/licenses.md 第 1 节）：`tools/licenses/licenses.py` 生成的
/// `inventory.json`（schema 2），和 `NOTICES.md`、`texts/` 一起放在 ThinktinCore 包的资源 `Licenses/` 里
/// （`CoreLicenses.locate()` 找它）。开源许可页（`.licenses`）按许可证分组列出来、可以搜，点进去看原文。
///
/// 解析是宽松的：认不出的字段跳过，没有名字的组件不要，原文路径不在清单目录里的（Debian 包记的是镜像里的位置）不列。
public struct LicenseInventory: Hashable, Sendable {
    /// 这里按哪一版的格式解析（更新的版本也照样读认得出的字段）。
    public static let supportedSchema = 2
    public static let fileName = "inventory.json"
    public static let noticesFileName = "NOTICES.md"

    public var schema: Int
    /// 清单是给谁的（App 里是 `client-core`）。
    public var subject: String
    public var components: [LicenseComponent]

    public init(schema: Int = LicenseInventory.supportedSchema, subject: String, components: [LicenseComponent]) {
        self.schema = schema
        self.subject = subject
        self.components = components
    }

    /// 解析 `inventory.json`。不是 JSON 对象、没有 `components` 时抛 `malformed`。
    public init(data: Data) throws {
        let document: InventoryDocument
        do {
            document = try JSONDecoder().decode(InventoryDocument.self, from: data)
        } catch {
            throw LicenseInventoryError.malformed(String(describing: error))
        }
        var seen: [String: Int] = [:]
        let components = document.components.compactMap { $0.component }.map { component -> LicenseComponent in
            // 同一个包同一个版本出现两次（不该有）：id 后面加序号，列表里不打架。
            var component = component
            let count = seen[component.id, default: 0]
            seen[component.id] = count + 1
            if count > 0 { component.id += "#\(count + 1)" }
            return component
        }
        self.init(schema: document.schema ?? 0, subject: document.subject ?? "", components: components)
    }

    /// 读目录里的 `inventory.json`。
    public static func load(from directory: URL) throws -> LicenseInventory {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LicenseInventoryError.unreadable(fileName)
        }
        return try LicenseInventory(data: data)
    }

    /// 有几种许可证（分组后的组数）。
    public var licenseCount: Int { Set(components.map(\.groupKey)).count }

    /// 按许可证分组：组件多的组在前（一样多的按名字），没声明许可证的放最后；组里按名字、版本排。
    /// `query` 不为空时只留匹配的组件（`LicenseComponent.matches(_:)`），空的组不要。
    public func groups(matching query: String = "") -> [LicenseGroup] {
        let tokens = LicenseSearch.tokens(query)
        let matching = tokens.isEmpty ? components : components.filter { $0.matches(tokens: tokens) }
        let grouped = Dictionary(grouping: matching, by: \.groupKey)
        return grouped.map { key, list in
            LicenseGroup(license: key, components: list.sorted(by: LicenseComponent.displayOrder))
        }
        .sorted { a, b in
            if a.license.isEmpty != b.license.isEmpty { return !a.license.isEmpty }
            if a.components.count != b.components.count { return a.components.count > b.components.count }
            return a.license.lowercased() < b.license.lowercased()
        }
    }

    /// 分组用的许可证写法：只用 `OR` 连起来的几个简单标识（没有括号、`AND`、`WITH`）排个序、去掉重复的，
    /// “MIT OR Apache-2.0”和“Apache-2.0 OR MIT”是同一组（选哪个都行，顺序不影响意思）；别的原样（多余的空白合并）。
    /// 空的、没写的是空串。
    public static func normalizedLicense(_ expression: String?) -> String {
        let collapsed = (expression ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        let parts = collapsed.components(separatedBy: " OR ")
        let isSimple = parts.allSatisfy { part in
            !part.isEmpty && !part.contains(" ") && !part.contains("(") && !part.contains(")")
        }
        guard parts.count > 1, isSimple else { return collapsed }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }
            .sorted { $0.lowercased() < $1.lowercased() }
            .joined(separator: " OR ")
    }
}

/// 一个第三方组件。
public struct LicenseComponent: Identifiable, Hashable, Sendable {
    /// `cargo:aho-corasick@1.1.5`。
    public var id: String
    /// `cargo`、`npm`、`pypi`、`deb`、`runtime`、`upstream`、`swift`。
    public var ecosystem: String
    public var name: String
    public var version: String
    /// SPDX 表达式（`MIT OR Apache-2.0`）；没认出来时为 nil。
    public var license: String?
    /// 作者（包的元数据；用 SPDX 标准文本的组件，版权方就是它）。
    public var authors: String?
    /// 源码在哪（源码仓库，或者 crates.io、npm、PyPI 上这个版本的页面）：只认 http(s)。
    public var sourceURL: URL?
    /// 原文里有限制性的说法（登记过的例外）。
    public var restrictedTerms: [String]
    /// 能在 App 里打开的原文。
    public var texts: [LicenseText]

    public init(
        id: String? = nil, ecosystem: String, name: String, version: String, license: String?, authors: String? = nil,
        sourceURL: URL? = nil, restrictedTerms: [String] = [], texts: [LicenseText] = []
    ) {
        self.id = id ?? "\(ecosystem):\(name)@\(version)"
        self.ecosystem = ecosystem
        self.name = name
        self.version = version
        self.license = license
        self.authors = authors
        self.sourceURL = sourceURL
        self.restrictedTerms = restrictedTerms
        self.texts = texts
    }

    /// 所在的组（`LicenseInventory.normalizedLicense`）。
    public var groupKey: String { LicenseInventory.normalizedLicense(license) }

    /// 列表里的顺序：名字（不分大小写），同名的按版本号。
    static func displayOrder(_ a: LicenseComponent, _ b: LicenseComponent) -> Bool {
        let (na, nb) = (a.name.lowercased(), b.name.lowercased())
        if na != nb { return na < nb }
        return a.version.compare(b.version, options: .numeric) == .orderedAscending
    }

    /// 生态的名字（详情页“来源”一行）。
    public func ecosystemName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch ecosystem {
        case "cargo": return "Rust crate"
        case "npm": return zh ? "npm 包" : "npm package"
        case "pypi": return zh ? "Python 包" : "Python package"
        case "deb": return zh ? "Debian 包" : "Debian package"
        case "swift": return zh ? "Swift 包" : "Swift package"
        case "runtime": return zh ? "运行时" : "Runtime"
        case "upstream": return zh ? "上游组件" : "Upstream component"
        default: return ecosystem.isEmpty ? (zh ? "其他" : "Other") : ecosystem
        }
    }

    /// 许可证那一行：没认出来时说明一下。
    public func licenseText(_ language: DisplayLanguage = .current) -> String {
        let trimmed = license?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return language == .chinese ? "未声明许可证" : "No license declared" }
        return trimmed
    }

    /// 搜索：每个词都要出现在名字、版本、许可证、作者里的某一处（不分大小写）。
    public func matches(_ query: String) -> Bool {
        matches(tokens: LicenseSearch.tokens(query))
    }

    func matches(tokens: [String]) -> Bool {
        let fields = [name, version, license ?? "", groupKey, authors ?? ""]
        return tokens.allSatisfy { token in fields.contains { LicenseSearch.contains($0, token) } }
    }
}

/// 一份原文。
public struct LicenseText: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// 包里带的 LICENSE、NOTICE、COPYING。
        case original
        /// 包里子目录下的原文（打包进来的第三方代码、字体、图标的）。
        case bundled
        /// 包里没带原文，用的 SPDX 标准文本（版权方按作者）。
        case standard
    }

    /// 相对清单目录的路径（`texts/by-hash/0f96a83840e146e4/LICENSE-MIT`）。
    public var path: String
    /// 在包里叫什么（`LICENSE-MIT`、`aws-lc/LICENSE`）；标准文本是 SPDX 标识（`MIT`）。
    public var name: String
    /// 认出来是哪个许可证的原文（SPDX 标识）。
    public var spdx: String?
    public var kind: Kind

    public init(path: String, name: String, spdx: String? = nil, kind: Kind) {
        self.path = path
        self.name = name
        self.spdx = spdx
        self.kind = kind
    }

    public var id: String { kind.rawValue + ":" + path }

    /// 列表里的名字：`LICENSE-MIT`、“包内：aws-lc/LICENSE”、“SPDX 标准文本：MIT”。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch kind {
        case .original: return name
        case .bundled: return (zh ? "包内：" : "Bundled: ") + name
        case .standard: return (zh ? "SPDX 标准文本：" : "SPDX text: ") + name
        }
    }
}

/// 许可证一样的一组组件。
public struct LicenseGroup: Identifiable, Hashable, Sendable {
    /// 分组的许可证（`LicenseInventory.normalizedLicense`）；空串是没声明的。
    public var license: String
    public var components: [LicenseComponent]

    public init(license: String, components: [LicenseComponent]) {
        self.license = license
        self.components = components
    }

    public var id: String { license }

    public func title(_ language: DisplayLanguage = .current) -> String {
        license.isEmpty ? (language == .chinese ? "未声明许可证" : "No license declared") : license
    }
}

/// 读清单、原文出的错。
public enum LicenseInventoryError: Error, Hashable, Sendable {
    /// App 里没找到清单目录（ThinktinCore 的资源没打进包里）。
    case notBundled
    /// 文件读不出来（不在、没权限）。
    case unreadable(String)
    /// 不是清单的格式。
    case malformed(String)
    /// 原文的路径不在清单目录里（`..`、绝对路径）。
    case invalidPath(String)
    /// 文件太大，不在 App 里显示。
    case tooLarge(String)

    /// 给用户看的一句话。
    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .notBundled:
            return zh ? "这个版本没有带许可证清单。" : "This build doesn't include the license list."
        case .unreadable, .invalidPath:
            return zh ? "这份原文没有打包进 App。" : "This text isn't included in the app."
        case .malformed:
            return zh ? "许可证清单的格式认不出来。" : "The license list couldn't be read."
        case .tooLarge:
            return zh ? "这份原文太大，App 里不显示。" : "This text is too large to show in the app."
        }
    }
}

/// 读清单目录里的文件（原文、`NOTICES.md`）。
public enum LicenseFiles {
    /// 原文最大多少字节（清单工具不复制超过 1 MiB 的，这里留点余量）。
    public static let maxTextBytes = 2 * 1024 * 1024

    /// 相对路径对应的文件；路径要在目录里面：不能是绝对路径，不能有 `..`、`.`、空的路径段、反斜杠。
    public static func resolve(_ relativePath: String, in directory: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~"),
            !relativePath.contains("\\"), !relativePath.contains("\0")
        else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.reduce(directory) { url, part in url.appendingPathComponent(String(part), isDirectory: false) }
    }

    /// 读一份原文：UTF-8，不是的按 Latin-1；换行统一成 `\n`。
    public static func readText(_ relativePath: String, in directory: URL) throws -> String {
        guard let url = resolve(relativePath, in: directory) else {
            throw LicenseInventoryError.invalidPath(relativePath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LicenseInventoryError.unreadable(relativePath)
        }
        guard data.count <= maxTextBytes else { throw LicenseInventoryError.tooLarge(relativePath) }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// 分成段落（空行、只有空白的行隔开），段落里的换行和行首缩进保留（许可证原文的编号列表要原样），行尾空白去掉。
    /// 长文分段显示，滚动时只画看得见的几段。
    public static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = trimmingTrailingSpaces(line)
            if trimmed.isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    private static func trimmingTrailingSpaces(_ line: Substring) -> Substring {
        var end = line.endIndex
        while end > line.startIndex {
            let before = line.index(before: end)
            guard line[before] == " " || line[before] == "\t" else { break }
            end = before
        }
        return line[line.startIndex..<end]
    }
}

/// 在 App 里找 ThinktinCore 资源包里的 `Licenses/`（docs/licenses.md 第 1 节：`Bundle.module` 的 Licenses 目录）。
///
/// ThinktinKit 不依赖 ThinktinCore，拿不到它的 `Bundle.module`，按 SwiftPM 资源包的名字找：iOS App 里在 App 包的根上
/// （`ThinktinCore_ThinktinCore.bundle/Licenses`），macOS 在 `Contents/Resources` 下（包里还有一层 `Contents/Resources`），
/// Linux 上是 `ThinktinCore_ThinktinCore.resources/Licenses`；测试和预览里在测试包旁边。
public enum CoreLicenses {
    /// SwiftPM 给 ThinktinCore 包的 ThinktinCore 目标起的资源包名。
    public static let resourceBundleName = "ThinktinCore_ThinktinCore"
    public static let directoryName = "Licenses"

    /// 在这几个目录里找资源包，返回里面有 `inventory.json` 的 `Licenses/`。
    public static func locate(searching locations: [URL], fileManager: FileManager = .default) -> URL? {
        let relatives = [
            "\(resourceBundleName).bundle/\(directoryName)",
            "\(resourceBundleName).bundle/Contents/Resources/\(directoryName)",
            "\(resourceBundleName).resources/\(directoryName)",
        ]
        for location in locations {
            for relative in relatives {
                let directory = location.appendingPathComponent(relative, isDirectory: true)
                let inventory = directory.appendingPathComponent(LicenseInventory.fileName, isDirectory: false)
                if fileManager.fileExists(atPath: inventory.path) { return directory }
            }
        }
        return nil
    }

    /// 在 App（`Bundle.main`）和 ThinktinKit 所在的包里找。找不到为 nil（开源许可页显示“没有带清单”）。
    public static func locate() -> URL? {
        locate(searching: searchLocations)
    }

    /// 找的地方：App 包的资源目录和根，ThinktinKit 所在的包（静态链接时和 ThinktinCore 在同一个包里）的资源目录、
    /// 根和它所在的目录（测试包、预览旁边的资源包）。
    public static var searchLocations: [URL] {
        let ours = Bundle(for: BundleToken.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL, Bundle.main.bundleURL, ours.resourceURL, ours.bundleURL,
            ours.bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private final class BundleToken {}
}

/// App 自己用的第三方 Swift 包（`ThinktinKit/Package.swift`、`project.yml` 的依赖）。
///
/// 现在一个都没有：ThinktinKit 只依赖 ThinktinCore（我们自己的 Rust 客户端核心，它带的第三方组件就是 `LicenseInventory`
/// 那份清单），App 只用系统框架。加了第三方包就在这里加一条（许可证、作者、源码地址），原文放进 App 的资源。
public enum SwiftPackageLicenses {
    public static let components: [LicenseComponent] = []
}

/// 搜索用的小工具。
enum LicenseSearch {
    /// 按空白切成词。
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 不分大小写、不分变音符号地包含。
    static func contains(_ text: String, _ token: String) -> Bool {
        text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

// MARK: - inventory.json 的格式（宽松解析）

/// 整个文件。
private struct InventoryDocument: Decodable {
    var schema: Int?
    var subject: String?
    var components: [LossyComponent]

    enum CodingKeys: String, CodingKey { case schema, subject, components }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try? c.decodeIfPresent(Int.self, forKey: .schema)
        subject = try? c.decodeIfPresent(String.self, forKey: .subject)
        components = try c.decode([LossyComponent].self, forKey: .components)
    }
}

/// 一个组件；认不出（没有名字、不是对象）时 `component` 为 nil，跳过。
private struct LossyComponent: Decodable {
    var component: LicenseComponent?

    enum CodingKeys: String, CodingKey {
        case ecosystem, name, version, license, authors
        case sourceURL = "source_url"
        case restrictedTerms = "restricted_terms"
        case files
        case genericFiles = "generic_files"
        case bundledFiles = "bundled_files"
        case fileLicenses = "file_licenses"
    }

    init(from decoder: any Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
            let name = (try? c.decodeIfPresent(String.self, forKey: .name))?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else {
            component = nil
            return
        }
        func strings(_ key: CodingKeys) -> [String] { (try? c.decodeIfPresent([String].self, forKey: key)) ?? [] }
        func string(_ key: CodingKeys) -> String? {
            let value = (try? c.decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let detections = (try? c.decodeIfPresent([LossyFileLicense].self, forKey: .fileLicenses)) ?? []
        let ecosystem = string(.ecosystem) ?? ""
        let version = string(.version) ?? ""
        component = LicenseComponent(
            ecosystem: ecosystem, name: name, version: version, license: string(.license), authors: string(.authors),
            sourceURL: string(.sourceURL).flatMap(Self.webURL), restrictedTerms: strings(.restrictedTerms),
            texts: Self.texts(
                files: strings(.files), bundled: strings(.bundledFiles), generic: strings(.genericFiles),
                detections: detections))
    }

    /// 原文列表：包里的、包内子目录的、标准文本；同一个文件只列一次，路径不在清单目录里的不列。
    static func texts(files: [String], bundled: [String], generic: [String], detections: [LossyFileLicense])
        -> [LicenseText]
    {
        var seen = Set<String>()
        var result: [LicenseText] = []
        func add(_ path: String, kind: LicenseText.Kind) {
            // 只用来校验路径的形状，不碰文件系统。
            guard LicenseFiles.resolve(path, in: URL(fileURLWithPath: "/")) != nil, seen.insert(path).inserted else {
                return
            }
            let fileName = path.split(separator: "/").last.map(String.init) ?? path
            switch kind {
            case .standard:
                let id = fileName.hasSuffix(".txt") ? String(fileName.dropLast(4)) : fileName
                result.append(LicenseText(path: path, name: id, spdx: id, kind: .standard))
            case .original, .bundled:
                let detection =
                    detections.first { $0.file == path && ($0.bundled ?? false) == (kind == .bundled) }
                    ?? detections.first { $0.file == path }
                let name = detection?.path.flatMap { $0.isEmpty ? nil : $0 } ?? fileName
                result.append(LicenseText(path: path, name: name, spdx: detection?.proposed, kind: kind))
            }
        }
        for path in files { add(path, kind: .original) }
        for path in bundled { add(path, kind: .bundled) }
        for path in generic { add(path, kind: .standard) }
        return result
    }

    /// 只认 http(s) 的绝对地址。
    static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// `file_licenses` 里的一条：哪个文件、在包里的路径、认出来是什么许可证、是不是包内子目录的。
private struct LossyFileLicense: Decodable {
    var file: String?
    var path: String?
    var proposed: String?
    var bundled: Bool?

    enum CodingKeys: String, CodingKey { case file, path, proposed, bundled }

    init(from decoder: any Decoder) {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        file = try? c?.decodeIfPresent(String.self, forKey: .file)
        path = try? c?.decodeIfPresent(String.self, forKey: .path)
        proposed = try? c?.decodeIfPresent(String.self, forKey: .proposed)
        bundled = try? c?.decodeIfPresent(Bool.self, forKey: .bundled)
    }
}
