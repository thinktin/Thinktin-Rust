import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 产出物（WBS 12.18）的界面：产出物库（全部实例、一个实例）、一个产出物、找不到的，在浅色中文、深色英文、大字号下都能布局；
/// 每种类型的行。视图模型的逻辑在 ThinktinKitTests 的 Artifacts 里测。
@MainActor
@Suite("产出物的界面")
struct ArtifactsScreensTests {
    static let routes: [AppRoute] = [
        .artifacts(instanceID: nil), .artifacts(instanceID: DemoData.writerID),
        .artifact(DemoData.weeklyArtifactID, runID: DemoData.weeklyRunID),
        .artifact("art-gone", runID: DemoData.weeklyRunID),
    ]

    private static func client(empty: Bool = false) -> MockClient {
        var state = DemoData.state()
        if empty { state.artifacts = [] }
        return MockClient(state: state, stepDelay: 0)
    }

    @Test("每个页面都能布局（中文浅色、英文深色、大字号）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(ArtifactsDestination(route: route).previewShell(client: Self.client()))
            hostAndLayout(
                ArtifactsDestination(route: route).previewShell(.english, scheme: .dark, client: Self.client()))
            hostAndLayout(
                ArtifactsDestination(route: route).previewShell(client: Self.client())
                    .dynamicTypeSize(.accessibility3))
        }
        hostAndLayout(ArtifactLibraryScreen(instanceID: nil).previewShell(client: Self.client(empty: true)))
    }

    @Test("每种类型的行和图标")
    func rows() {
        let types = ["text/markdown", "image/png", "application/pdf", "application/zip"]
        for type in types {
            let artifact = Artifact(
                id: "a", instanceID: DemoData.writerID, runID: DemoData.weeklyRunID, name: "报告", contentType: type,
                size: 2048, createdAt: Date())
            #expect(!ArtifactIcon.systemImage(artifact).isEmpty)
            for name in ["写作助手", nil] as [String?] {
                let row = ArtifactRow(
                    artifact: artifact, instanceName: name, isDeleting: name == nil, thumbnail: { _ in nil })
                hostAndLayout(row.previewShell())
                hostAndLayout(row.previewShell(.english, scheme: .dark))
            }
            renderInBothAppearances(ArtifactThumbnail(artifact: artifact))
        }
        #expect(ArtifactIcon.systemImage(Self.artifact(type: "video/mp4")) == "film")
        #expect(ArtifactIcon.systemImage(Self.artifact(type: "audio/mpeg")) == "waveform")
    }

    private static func artifact(type: String, name: String = "截图.png") -> Artifact {
        Artifact(
            id: "art-image", instanceID: DemoData.writerID, runID: DemoData.weeklyRunID, name: name,
            contentType: type, size: 4, createdAt: Date())
    }

    @Test("改版的库：只有某一类、折叠和展开、全部 Botin 的筛选菜单；图片全屏查看")
    func redesignedLibrary() {
        // 有图片、有文件，超过折叠的数量。
        var state = DemoData.state()
        state.artifacts += (0..<25).map { i in
            Artifact(
                id: ArtifactID(rawValue: "art-extra-\(i)"),
                instanceID: i.isMultiple(of: 2) ? DemoData.writerID : DemoData.reviewerID,
                runID: DemoData.weeklyRunID, name: "图 \(i).png", contentType: i < 3 ? "image/png" : "text/plain",
                size: 4, createdAt: Date().addingTimeInterval(Double(-i) * 86400))
        }
        state.artifactContents["art-extra-0"] = Data([0x89, 0x50, 0x4e, 0x47])
        let client = MockClient(state: state, stepDelay: 0)
        hostAndLayout(ArtifactLibraryScreen(instanceID: nil).previewShell(client: client))
        hostAndLayout(
            ArtifactLibraryScreen(instanceID: DemoData.writerID).previewShell(.english, scheme: .dark, client: client))

        let image = Self.artifact(type: "image/png")
        hostAndLayout(ArtifactImageViewer(artifact: image) {}.previewShell(client: client))
        hostAndLayout(ArtifactImageViewer(artifact: image) {}.previewShell(.english, scheme: .dark, client: client))
        hostAndLayout(
            ArtifactImageViewer(artifact: image) {}.previewShell(client: client).dynamicTypeSize(.accessibility3))
        #expect(ArtifactImageDecoder.decode(Data([0, 1, 2]), maxPixelSize: 10) == nil)
    }
}
