import Foundation
import Testing

@testable import ThinktinKit

/// 产出物库改版的本地逻辑（规范 4.5.2、4.5.3）：大类筛选、日期分组、本地折叠、空状态、缩略图的限制、行的副标题、
/// 图片全屏查看的下载和保存。
@MainActor
@Suite("产出物库的版式和图片查看")
struct ArtifactLibraryLayoutTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.firstWeekday = 2
        return c
    }()

    /// 2026-11-05（星期四）15:00，上海。
    private static let now = Date(timeIntervalSince1970: 1_793_862_000)

    private static func artifact(
        _ id: String, type: String, ageHours: Double = 0, size: Int = 10, instance: InstanceID = DemoData.writerID
    ) -> Artifact {
        Artifact(
            id: ArtifactID(rawValue: id), instanceID: instance, runID: DemoData.weeklyRunID, name: id,
            contentType: type, size: size, createdAt: now.addingTimeInterval(-ageHours * 3600))
    }

    private static func mock(_ artifacts: [Artifact], contents: [String: Data] = [:]) -> MockClient {
        var state = DemoData.state()
        state.artifacts = artifacts
        for (id, data) in contents { state.artifactContents[ArtifactID(rawValue: id)] = data }
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    @Test("大类：图片、视频、音频算媒体，别的算文件；SVG 不当图片看")
    func categories() {
        #expect(ArtifactFiles.category(Self.artifact("a", type: "image/png")) == .media)
        #expect(ArtifactFiles.category(Self.artifact("b", type: "video/mp4")) == .media)
        #expect(ArtifactFiles.category(Self.artifact("c", type: "audio/mpeg")) == .media)
        #expect(ArtifactFiles.category(Self.artifact("d", type: "application/pdf")) == .file)
        #expect(ArtifactFiles.category(Self.artifact("e", type: "text/markdown")) == .file)
        #expect(ArtifactFiles.isViewableImage(Self.artifact("f", type: "IMAGE/JPEG")))
        #expect(!ArtifactFiles.isViewableImage(Self.artifact("g", type: "image/svg+xml")))
        #expect(ArtifactCategory.media.title(.chinese) == "媒体")
        #expect(ArtifactCategory.file.title(.english) == "Files")
    }

    @Test("日期分组：今天、本周（周一开始）、更早；将来的算今天")
    func dateGroups() {
        let c = Self.calendar
        let now = Self.now
        #expect(ArtifactDateGroup.of(now.addingTimeInterval(-3600), now: now, calendar: c) == .today)
        #expect(ArtifactDateGroup.of(now.addingTimeInterval(3600 * 30), now: now, calendar: c) == .today)
        // 星期二。
        #expect(ArtifactDateGroup.of(now.addingTimeInterval(-2 * 86400), now: now, calendar: c) == .thisWeek)
        // 上个星期天。
        #expect(ArtifactDateGroup.of(now.addingTimeInterval(-4 * 86400), now: now, calendar: c) == .earlier)
        #expect(ArtifactDateGroup.earlier.title(.chinese) == "更早")
        #expect(ArtifactDateGroup.today < ArtifactDateGroup.earlier)
    }

    @Test("按大类筛、按日期分组、折叠和展开、胶囊上的数")
    func sectionsAndCollapse() async {
        var list = [
            Self.artifact("img", type: "image/png", ageHours: 1),
            Self.artifact("doc", type: "text/markdown", ageHours: 2 * 24),
        ]
        list += (0..<25).map { Self.artifact("old-\($0)", type: "application/pdf", ageHours: Double(10 * 24 + $0)) }
        let model = ArtifactLibraryModel(client: Self.mock(list), instanceID: DemoData.writerID)
        await model.load()
        #expect(model.count(of: nil) == 27)
        #expect(model.count(of: .media) == 1)
        #expect(model.count(of: .file) == 26)

        var sections = model.sections(now: Self.now, calendar: Self.calendar)
        #expect(sections.map(\.group) == [.today, .thisWeek, .earlier])
        #expect(sections.flatMap(\.artifacts).count == ArtifactLibraryModel.collapsedLimit)
        #expect(model.hasMore)
        model.expand()
        #expect(!model.hasMore)
        sections = model.sections(now: Self.now, calendar: Self.calendar)
        #expect(sections.flatMap(\.artifacts).count == 27)

        model.kind = .media
        #expect(model.filtered.map(\.id.rawValue) == ["img"])
        #expect(model.sections(now: Self.now, calendar: Self.calendar).map(\.group) == [.today])
        #expect(model.placeholder == nil)
    }

    @Test("空状态：拉之前转圈、一个都没有、没有这一类的、拉不到")
    func placeholders() async {
        let empty = ArtifactLibraryModel(client: Self.mock([]), instanceID: DemoData.writerID)
        #expect(empty.placeholder == .loading)
        await empty.load()
        #expect(empty.placeholder == .empty)

        let files = ArtifactLibraryModel(
            client: Self.mock([Self.artifact("doc", type: "text/plain")]), instanceID: DemoData.writerID)
        await files.load()
        files.kind = .media
        #expect(files.placeholder == .noneOfKind(.media))

        let mock = Self.mock([])
        let failing = ArtifactLibraryModel(client: mock, instanceID: DemoData.writerID)
        mock.failNext("instanceArtifacts(_:limit:)", with: .network(message: "offline"))
        await failing.load()
        #expect(failing.placeholder == .unavailable(offline: true))
    }

    @Test("缩略图：只给小于上限的图片，下过的记住，失败的不重试")
    func thumbnails() async {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let list = [
            Self.artifact("small", type: "image/png", size: 4),
            Self.artifact("huge", type: "image/png", size: ArtifactThumbnailLoader.maxBytes + 1),
            Self.artifact("text", type: "text/plain", size: 4),
            Self.artifact("missing", type: "image/jpeg", size: 4),
        ]
        let mock = Self.mock(list, contents: ["small": png])
        let model = ArtifactLibraryModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        #expect(await model.thumbnail(for: list[0]) == png)
        #expect(await model.thumbnail(for: list[1]) == nil)
        #expect(await model.thumbnail(for: list[2]) == nil)
        #expect(await model.thumbnail(for: list[3]) == nil)
        // 记住了：不再请求（下一次请求会失败，也照样拿得到）。
        mock.failNext(with: .network(message: "offline"))
        #expect(await model.thumbnail(for: list[0]) == png)
        #expect(!ArtifactThumbnailLoader.isEligible(list[1]))
    }

    @Test("行的副标题和类型名")
    func rowSubtitle() {
        let c = Self.calendar
        let image = Self.artifact("chart.png", type: "image/png", ageHours: 6 * 24, size: 2048)
        #expect(
            ArtifactsText.rowSubtitle(image, instanceName: nil, now: Self.now, language: .chinese, calendar: c)
                == "图片 · 10月30日 · 2 KB")
        var today = Self.artifact("notes.md", type: "text/markdown", ageHours: 1, size: 12)
        today.version = 3
        #expect(
            ArtifactsText.rowSubtitle(today, instanceName: "写作助手", now: Self.now, language: .chinese, calendar: c)
                == "文本 · v3 · 14:00 · 12 B · 写作助手")
        let kinds: [(String, String, String)] = [
            ("a.pdf", "application/pdf", "PDF"), ("a.csv", "text/csv", "Spreadsheet"),
            ("a.zip", "application/zip", "Archive"), ("a.bin", "application/octet-stream", "File"),
            ("a.mp4", "video/mp4", "Video"), ("a.docx", "application/octet-stream", "Document"),
        ]
        for (name, type, expected) in kinds {
            let artifact = Artifact(
                id: "k", instanceID: DemoData.writerID, runID: DemoData.weeklyRunID, name: name, contentType: type,
                size: 1, createdAt: Self.now)
            #expect(ArtifactsText.kindName(artifact, language: .english) == expected)
        }
    }

    @Test("图片全屏查看：下载并落到本机；保存成功、没权限、失败")
    func viewer() async {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let image = Self.artifact("chart.png", type: "image/png", size: 4)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-\(UUID().uuidString)")
        let model = ArtifactViewerModel(
            client: Self.mock([image], contents: ["chart.png": png]), artifact: image, language: .chinese,
            directory: directory)
        #expect(!model.canExport)
        await model.save { _ in Issue.record("还没下载不该保存") }
        await model.load()
        #expect(model.data == png)
        #expect(model.canExport)
        #expect(model.fileURL?.lastPathComponent.contains("AI 生成") == true)

        var saved: [URL] = []
        await model.save { saved.append($0) }
        #expect(saved == [model.fileURL!])
        #expect(model.saveCount == 1)
        await model.save { _ in throw ArtifactSaveError.denied }
        #expect(model.saveError == .denied)
        model.clearSaveError()
        await model.save { _ in throw CancellationError() }
        #expect(model.saveError == .failed)
        #expect(model.saveCount == 1)

        let failing = ArtifactViewerModel(client: Self.mock([image]), artifact: image, directory: directory)
        await failing.load()
        #expect(failing.error != nil)
        #expect(failing.data == nil)
        #expect(ArtifactsText.saveErrorTitle(.denied, language: .chinese) == "没有相册权限")
    }
}
