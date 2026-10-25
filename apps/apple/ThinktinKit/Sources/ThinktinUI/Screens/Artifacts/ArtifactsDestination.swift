import SwiftUI
import ThinktinKit

/// 产出物（WBS 12.18）的接入点：`AppShell` 把 `route.feature == .artifacts` 的页面都交给它。
///
/// 页面：产出物库（`.artifacts`：`instanceID` 为 nil 时是全部实例的，`ArtifactLibraryScreen`）、一个产出物（`.artifact`，
/// 对话和运行详情里的产出物卡片、产出物库点进来，`ArtifactDetailScreen`）。视图模型在 `ThinktinKit/ViewModels/Artifacts/`。
struct ArtifactsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .artifacts(let instanceID): ArtifactLibraryScreen(instanceID: instanceID).id(instanceID)
        case .artifact(let id, let runID): ArtifactDetailScreen(artifactID: id, runID: runID).id(id)
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("产出物库 · 浅色中文") {
    ArtifactsDestination(route: .artifacts(instanceID: nil)).previewShell()
}

#Preview("一个产出物 · 深色英文") {
    ArtifactsDestination(route: .artifact(DemoData.weeklyArtifactID, runID: DemoData.weeklyRunID))
        .previewShell(.english, scheme: .dark)
}
