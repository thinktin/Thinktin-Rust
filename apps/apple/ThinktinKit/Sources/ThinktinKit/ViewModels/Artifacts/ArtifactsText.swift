import Foundation

/// 产出物库、产出物详情的文案（WBS 12.18）。卡片上的“产出物 · v1 · 2 KB”在 `ConversationText`。
public enum ArtifactsText {
    public static func intro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "Botin 在运行里生成的文件。分享、存到“文件”时文件名带“AI 生成”。"
            : "Files your Botins made in runs. Shared and saved copies keep “AI-generated” in the file name."
    }

    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "还没有产出物" : "No files yet"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese ? "Botin 写文件、出报告时会出现在这里。" : "Reports and files your Botins write show up here."
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
        language == .chinese ? "已删除的 Botin" : "Deleted Botin"
    }

    // MARK: 改版的库（规范 4.5.2）

    /// 产出物是什么类型（行的副标题、详情的“类型”）。
    public static func kindName(_ artifact: Artifact, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let type = artifact.contentType.lowercased()
        let ext = (artifact.name as NSString).pathExtension.lowercased()
        if type.hasPrefix("image/") { return zh ? "图片" : "Image" }
        if type.hasPrefix("video/") { return zh ? "视频" : "Video" }
        if type.hasPrefix("audio/") { return zh ? "音频" : "Audio" }
        if type == "application/pdf" || ext == "pdf" { return "PDF" }
        if type == "text/csv" || type.contains("spreadsheet") || type.contains("ms-excel")
            || ["csv", "xlsx", "xls"]
                .contains(ext)
        {
            return zh ? "表格" : "Spreadsheet"
        }
        if type.contains("presentation") || type.contains("powerpoint") || ["pptx", "ppt", "key"].contains(ext) {
            return zh ? "演示文稿" : "Presentation"
        }
        if type.contains("wordprocessing") || type == "application/msword" || ["docx", "doc"].contains(ext) {
            return zh ? "文档" : "Document"
        }
        if ["zip", "gzip", "x-tar", "x-7z-compressed", "x-rar-compressed"].contains(where: { type.hasSuffix($0) })
            || ["zip", "gz", "tgz", "tar", "7z", "rar"].contains(ext)
        {
            return zh ? "压缩包" : "Archive"
        }
        if ArtifactFiles.isText(artifact) { return zh ? "文本" : "Text" }
        return zh ? "文件" : "File"
    }

    /// 库里一行的副标题：“图片 · 9月7日 · 2 KB”，今天的写时间；全部 Botin 的库最后带上 Botin 名。
    public static func rowSubtitle(
        _ artifact: Artifact, instanceName: String?, now: Date = Date(), language: DisplayLanguage,
        calendar: Calendar = .current
    ) -> String {
        let date =
            calendar.isDate(artifact.createdAt, inSameDayAs: now)
            ? Formatting.clockTime(artifact.createdAt, calendar: calendar)
            : Formatting.shortDate(artifact.createdAt, now: now, language: language, calendar: calendar)
        var parts = [kindName(artifact, language: language), date, Formatting.bytes(artifact.size)]
        if artifact.version > 1 { parts.insert("v\(artifact.version)", at: 1) }
        if let instanceName { parts.append(instanceName) }
        return parts.joined(separator: " · ")
    }

    /// 列表最下面的“展开”。
    public static func expand(_ language: DisplayLanguage) -> String {
        language == .chinese ? "展开" : "Show more"
    }

    /// 某一类没有：“没有媒体” / “No media”。
    public static func noneOfKind(_ kind: ArtifactCategory, language: DisplayLanguage) -> String {
        switch kind {
        case .media: return language == .chinese ? "没有媒体" : "No media"
        case .file: return language == .chinese ? "没有文件" : "No files"
        }
    }

    /// 某一类没有时的说明。
    public static func noneOfKindMessage(_ kind: ArtifactCategory, language: DisplayLanguage) -> String {
        switch kind {
        case .media:
            return language == .chinese
                ? "Botin 生成的图片、视频、音频会出现在这里。" : "Images, video and audio your Botins make show up here."
        case .file:
            return language == .chinese
                ? "Botin 写的文档、表格、代码会出现在这里。" : "Documents, sheets and code your Botins write show up here."
        }
    }

    /// 右上按 Botin 筛选的菜单。
    public static func filterByBotin(_ language: DisplayLanguage) -> String {
        language == .chinese ? "按 Botin 筛选" : "Filter by Botin"
    }

    public static func allBotins(_ language: DisplayLanguage) -> String {
        language == .chinese ? "全部 Botin" : "All Botins"
    }

    /// 按大类筛选的胶囊整排的读屏标签。
    public static func filterByKind(_ language: DisplayLanguage) -> String {
        language == .chinese ? "按类型筛选" : "Filter by type"
    }

    public static func retry(_ language: DisplayLanguage) -> String {
        language == .chinese ? "重试" : "Try again"
    }

    // MARK: 详情的信息组

    public static func kindLabel(_ language: DisplayLanguage) -> String { language == .chinese ? "类型" : "Type" }
    public static func sizeLabel(_ language: DisplayLanguage) -> String { language == .chinese ? "大小" : "Size" }
    public static func versionLabel(_ language: DisplayLanguage) -> String { language == .chinese ? "版本" : "Version" }
    public static func botinLabel(_ language: DisplayLanguage) -> String { "Botin" }
    public static func createdLabel(_ language: DisplayLanguage) -> String {
        language == .chinese ? "生成于" : "Created"
    }
    public static func contentSection(_ language: DisplayLanguage) -> String {
        language == .chinese ? "内容" : "Contents"
    }
    public static func shareShort(_ language: DisplayLanguage) -> String { language == .chinese ? "分享" : "Share" }
    public static func more(_ language: DisplayLanguage) -> String { language == .chinese ? "更多操作" : "More" }

    // MARK: 图片全屏查看（规范 4.5.3，参考 24、25）

    public static func saveToPhotos(_ language: DisplayLanguage) -> String {
        language == .chinese ? "保存到相册" : "Save to Photos"
    }

    public static func details(_ language: DisplayLanguage) -> String {
        language == .chinese ? "详情" : "Details"
    }

    public static func imageUnavailable(_ language: DisplayLanguage) -> String {
        language == .chinese ? "打不开这张图片" : "Couldn't open this image"
    }

    public static func saveErrorTitle(_ error: ArtifactSaveError, language: DisplayLanguage) -> String {
        switch error {
        case .denied: return language == .chinese ? "没有相册权限" : "No access to Photos"
        case .failed: return language == .chinese ? "没存上" : "Couldn't save"
        }
    }

    public static func saveErrorMessage(_ error: ArtifactSaveError, language: DisplayLanguage) -> String {
        switch error {
        case .denied:
            return language == .chinese
                ? "去“设置”里允许 ThinkTin“添加照片”，再存一次。"
                : "Allow ThinkTin to add photos in Settings, then try again."
        case .failed:
            return language == .chinese ? "过一会儿再试，或者用“分享”存到别处。" : "Try again later, or use Share to save it elsewhere."
        }
    }

    public static func ok(_ language: DisplayLanguage) -> String { language == .chinese ? "好" : "OK" }
}
