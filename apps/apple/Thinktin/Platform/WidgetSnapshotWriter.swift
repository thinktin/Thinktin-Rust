import Foundation
import OSLog
import ThinktinKit
import WidgetKit

/// 主屏小组件的快照（WBS 12.20）：写进 App Group 的共享目录（`WidgetSnapshotFile`），再让 WidgetKit 重新取时间线。
/// 小组件只读这个文件，不连服务端、不带客户端核心。`AppModel` 在角标变了、退出登录时调。
struct AppGroupWidgetSink: WidgetSnapshotSink {
    private static let log = Logger(subsystem: "cn.thinktin.app", category: "widgets")
    let file: WidgetSnapshotFile

    /// 拿不到 App Group 的目录（描述文件里没有这个 App Group）时为 nil，不写。
    init?(appGroup: String = WidgetSnapshotFile.appGroup) {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        file = WidgetSnapshotFile(directory: directory)
    }

    func publish(_ snapshot: WidgetSnapshot) async {
        do {
            try file.save(snapshot)
        } catch {
            Self.log.error("cannot write the widget snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }
        await MainActor.run { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind) }
    }
}
