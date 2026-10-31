import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("产出物库与产出物详情（12.18）")
struct ArtifactModelsTests {
    private func state() -> MockState {
        var state = DemoData.state()
        let base = Date()
        state.artifacts += [
            Artifact(
                id: "0192f3a0-0000-7000-8000-000000000602", instanceID: DemoData.reviewerID,
                runID: DemoData.reviewRunID,
                name: "review.json", contentType: "application/json", size: 12, createdAt: base),
            Artifact(
                id: "0192f3a0-0000-7000-8000-000000000603", instanceID: DemoData.writerID, runID: DemoData.weeklyRunID,
                name: "chart.png", version: 2, contentType: "image/png", size: 4,
                createdAt: base.addingTimeInterval(-60)),
        ]
        state.artifactContents["0192f3a0-0000-7000-8000-000000000602"] = Data(#"{"ok":true}"#.utf8)
        state.artifactContents["0192f3a0-0000-7000-8000-000000000603"] = Data([0x89, 0x50, 0x4e, 0x47])
        return state
    }

    private func mock(_ state: MockState? = nil) -> MockClient {
        MockClient(state: state ?? self.state(), stepDelay: 0, autoReply: false)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("artifact-tests-\(UUID().uuidString)")
    }

    @Test("全部实例：最新的在前，实例名，按实例筛选")
    func libraryAllInstances() async {
        let model = ArtifactLibraryModel(client: mock())
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.artifacts.map(\.name) == ["review.json", "chart.png", "周报要点.md"])
        #expect(model.instanceName(DemoData.reviewerID) == "代码审查")
        #expect(model.filterInstances.count == 2)
        model.filter = DemoData.writerID
        #expect(model.visible.map(\.name) == ["chart.png", "周报要点.md"])
    }

    @Test("刷新时实例请求失败，保留之前的产出物并允许重试")
    func libraryRefreshFailure() async {
        let client = mock()
        let model = ArtifactLibraryModel(client: client, instanceID: nil)
        await model.load()
        let before = model.artifacts
        #expect(!before.isEmpty)
        for _ in client.state.instances.filter({ $0.state != .deleted }) {
            client.failNext("instanceArtifacts(_:limit:)", with: .network(message: "offline"))
        }
        await model.load()
        #expect(model.artifacts == before)
        #expect(model.error?.isOffline == true)
        await model.load()
        #expect(model.error == nil)
    }

    @Test("一个实例的；删除（已经没有的照样拿掉）")
    func libraryOneInstance() async throws {
        let client = mock()
        let model = ArtifactLibraryModel(client: client, instanceID: DemoData.writerID)
        await model.load()
        #expect(model.artifacts.count == 2)
        let first = try #require(model.artifacts.first)
        await model.delete(first)
        #expect(model.artifacts.count == 1)
        #expect(try await client.instanceArtifacts(DemoData.writerID, limit: 10).count == 1)
        let last = try #require(model.artifacts.first)
        try await client.deleteArtifact(last.id)
        await model.delete(last)
        #expect(model.artifacts.isEmpty)
        #expect(model.actionError == nil)
    }

    @Test("详情：文字类直接显示，下载的文件名带 AI 标识，删除")
    func detail() async throws {
        let directory = temporaryDirectory()
        let client = mock()
        let model = ArtifactDetailModel(
            client: client, artifactID: DemoData.weeklyArtifactID, runID: DemoData.weeklyRunID, language: .chinese,
            directory: directory)
        await model.load()
        #expect(model.artifact?.name == "周报要点.md")
        #expect(model.instanceName == "写作助手")
        #expect(model.textPreview?.isEmpty == false)
        #expect(!model.isTruncated)
        let url = try #require(await model.prepareFile())
        #expect(url.lastPathComponent == "周报要点（AI 生成）.md")
        #expect(try Data(contentsOf: url) == client.state.artifactContents[DemoData.weeklyArtifactID])
        // 已经下载过的直接用，不再请求。
        let calls = client.callCount("artifactContent(_:)")
        #expect(await model.prepareFile() == url)
        #expect(client.callCount("artifactContent(_:)") == calls)
        await model.delete()
        #expect(model.isDeleted)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("详情：图片不显示文字；长文字只显示开头；不在运行里的说找不到")
    func detailStates() async throws {
        var state = state()
        let long = String(repeating: "长", count: ArtifactFiles.textPreviewLimit)
        state.artifacts.append(
            Artifact(
                id: "0192f3a0-0000-7000-8000-000000000604", instanceID: DemoData.writerID, runID: DemoData.weeklyRunID,
                name: "long.txt", contentType: "text/plain", size: long.utf8.count, createdAt: Date()))
        state.artifactContents["0192f3a0-0000-7000-8000-000000000604"] = Data(long.utf8)
        let client = mock(state)
        let image = ArtifactDetailModel(
            client: client, artifactID: "0192f3a0-0000-7000-8000-000000000603", runID: DemoData.weeklyRunID)
        await image.load()
        #expect(image.textPreview == nil)

        let text = ArtifactDetailModel(
            client: client, artifactID: "0192f3a0-0000-7000-8000-000000000604", runID: DemoData.weeklyRunID)
        await text.load()
        #expect(text.isTruncated)
        let preview = try #require(text.textPreview)
        #expect(preview.utf8.count <= ArtifactFiles.textPreviewLimit)
        #expect(preview.allSatisfy { $0 == "长" })

        let missing = ArtifactDetailModel(client: client, artifactID: "art-gone", runID: DemoData.weeklyRunID)
        await missing.load()
        #expect(missing.isMissing)
    }

    @Test("分享的文件名：带 AI 标识、扩展名在最后、去掉放不进文件名的字符")
    func exportNames() {
        func name(_ raw: String, _ language: DisplayLanguage = .chinese) -> String {
            ArtifactFiles.exportName(
                Artifact(
                    id: "a", instanceID: "i", runID: "r", name: raw, contentType: "text/plain", size: 0,
                    createdAt: Date()),
                language: language)
        }
        #expect(name("周报要点.md") == "周报要点（AI 生成）.md")
        #expect(name("notes.md", .english) == "notes (AI-generated).md")
        #expect(name("a/b:c.txt") == "a_b_c（AI 生成）.txt")
        #expect(name(".env") == ".env（AI 生成）")
        #expect(name("README") == "README（AI 生成）")
        #expect(name("  ") == "产出物（AI 生成）")
        #expect(name("archive.tar.gz") == "archive.tar（AI 生成）.gz")
        #expect(name("v1.0 final draft") == "v1.0 final draft（AI 生成）")
    }

    @Test("服务端允许的 200 字中文文件名也能导出，保留 AI 标识和扩展名")
    func exportLongName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = Artifact(
            id: "a", instanceID: "i", runID: "r", name: String(repeating: "报", count: 197) + ".md",
            contentType: "text/markdown", size: 2, createdAt: Date())
        let contents = Data("OK".utf8)
        let url = try ArtifactFiles.write(contents, for: artifact, language: .chinese, directory: directory)
        #expect(url.lastPathComponent.utf8.count <= 255)
        #expect(url.lastPathComponent.hasSuffix("（AI 生成）.md"))
        #expect(try Data(contentsOf: url) == contents)
    }

    @Test("哪些能直接显示成文字")
    func textKinds() {
        func artifact(_ name: String, _ type: String) -> Artifact {
            Artifact(id: "a", instanceID: "i", runID: "r", name: name, contentType: type, size: 0, createdAt: Date())
        }
        #expect(ArtifactFiles.isText(artifact("a.md", "text/markdown")))
        #expect(ArtifactFiles.isText(artifact("a.json", "application/json")))
        #expect(ArtifactFiles.isText(artifact("main.rs", "application/octet-stream")))
        #expect(!ArtifactFiles.isText(artifact("a.png", "image/png")))
        #expect(ArtifactFiles.isImage(artifact("a.png", "image/png")))
        #expect(!ArtifactFiles.isText(artifact("a.pdf", "application/pdf")))
    }
}
