import SwiftUI
import WidgetKit

/// 小组件扩展的入口：主屏小组件（WBS 12.20）和运行的实时活动（12.10）。
@main
struct ThinktinWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        RunLiveActivity()
    }
}
