import Foundation

/// 产出物落到本机的文件（WBS 12.18）：预览（QuickLook）、分享、存到“文件”都用它。
///
/// 文件名带“AI 生成”标识（16.3：agent 生成的内容离开 App 时也要能看出来）：`周报要点（AI 生成）.md`、
/// `notes (AI-generated).md`。名字里不能放进文件系统的字符（`/`、`:`、控制字符）换成 `_`，空的叫“产出物”。
/// 每个产出物一个目录（`<临时目录>/ThinktinArtifacts/<id>/`），同名的不同产出物不会互相覆盖。
public enum ArtifactFiles {
    /// 分享出去的文件名。
    public static func exportName(_ artifact: Artifact, language: DisplayLanguage) -> String {
        let cleaned = String(
            artifact.name.unicodeScalars.map { scalar -> Character in
                if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.properties.generalCategory == .control {
                    return "_"
                }
                return Character(scalar)
            }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? ArtifactsText.untitled(language) : cleaned
        let label = language == .chinese ? "（AI 生成）" : " (AI-generated)"
        // 扩展名留在最后，系统才认得类型；以点开头的（`.env`）当作没有扩展名。
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...]
            if !ext.isEmpty, ext.count <= 10, !ext.contains(" ") {
                return String(name[..<dot]) + label + "." + ext
            }
        }
        return name + label
    }

    /// 写进临时目录，返回文件地址（已经有同样内容的就直接用）。
    public static func write(
        _ data: Data, for artifact: Artifact, language: DisplayLanguage,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let folder = directory.appendingPathComponent("ThinktinArtifacts", isDirectory: true)
            .appendingPathComponent(artifact.id.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(exportName(artifact, language: language))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 能直接在页面里显示成文字的（纯文本、Markdown、JSON、CSV、代码……）。
    public static func isText(_ artifact: Artifact) -> Bool {
        let type = artifact.contentType.lowercased()
        if type.hasPrefix("text/") { return true }
        let textual = [
            "application/json", "application/xml", "application/yaml", "application/x-yaml", "application/toml",
            "application/javascript", "application/x-sh",
        ]
        if textual.contains(where: { type.hasPrefix($0) }) { return true }
        let ext = (artifact.name as NSString).pathExtension.lowercased()
        return [
            "md", "txt", "json", "csv", "yaml", "yml", "toml", "log", "py", "js", "ts", "swift", "kt", "rs", "go",
            "sh", "html", "xml", "sql",
        ].contains(ext)
    }

    /// 是图片。
    public static func isImage(_ artifact: Artifact) -> Bool {
        artifact.contentType.lowercased().hasPrefix("image/")
    }

    /// 页面里直接显示的文字最多多少字节（再长的只显示开头，全文用预览或分享）。
    public static let textPreviewLimit = 64 * 1024
}
