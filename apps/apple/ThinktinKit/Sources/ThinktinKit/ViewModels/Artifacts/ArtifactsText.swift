import Foundation

/// 产出物库、产出物详情的文案（WBS 12.18）。卡片上的“产出物 · v1 · 2 KB”在 `ConversationText`。
public enum ArtifactsText {
    public static func intro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "agent 在运行里生成的文件。分享、存到“文件”时文件名带“AI 生成”。"
            : "Files your agents made in runs. Shared and saved copies keep “AI-generated” in the file name."
    }

    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "还没有产出物" : "No files yet"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese ? "agent 写文件、出报告时会出现在这里。" : "Reports and files your agents write show up here."
    }

    public static func untitled(_ language: DisplayLanguage) -> String {
        language == .chinese ? "产出物" : "file"
    }

    public static func allInstances(_ language: DisplayLanguage) -> String {
        language == .chinese ? "全部" : "All"
    }

    public static func preview(_ language: DisplayLanguage) -> String {
        language == .chinese ? "预览" : "Preview"
    }

    public static func share(_ language: DisplayLanguage) -> String {
        language == .chinese ? "分享或存到“文件”" : "Share or save to Files"
    }

    public static func preparing(_ language: DisplayLanguage) -> String {
        language == .chinese ? "正在下载" : "Downloading"
    }

    public static func delete(_ language: DisplayLanguage) -> String {
        language == .chinese ? "删除" : "Delete"
    }

    public static func deleteTitle(_ name: String, language: DisplayLanguage) -> String {
        language == .chinese ? "删除“\(name)”？" : "Delete “\(name)”?"
    }

    public static func deleteMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "删除后在所有设备上都看不到了，已经分享出去的副本不受影响。"
            : "It's removed on all your devices. Copies you already shared aren't affected."
    }

    public static func cancel(_ language: DisplayLanguage) -> String {
        language == .chinese ? "取消" : "Cancel"
    }

    public static func createdAt(_ date: Date, language: DisplayLanguage) -> String {
        let text = Formatting.dateTime(date, language: language)
        return language == .chinese ? "生成于 \(text)" : "Created \(text)"
    }

    public static func openRun(_ language: DisplayLanguage) -> String {
        language == .chinese ? "查看生成它的运行" : "View the run that made it"
    }

    public static func truncated(_ language: DisplayLanguage) -> String {
        language == .chinese ? "只显示了开头，全文请预览或分享。" : "Showing the beginning only. Preview or share for the full file."
    }

    public static func missingTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "找不到这个产出物" : "File not found"
    }

    public static func missingMessage(_ language: DisplayLanguage) -> String {
        language == .chinese ? "可能已经删掉了。" : "It may have been deleted."
    }

    public static func deletedInstance(_ language: DisplayLanguage) -> String {
        language == .chinese ? "已删除的实例" : "Deleted instance"
    }
}
