import SwiftUI
import WidgetKit

/// 小组件扩展的入口（WBS 12.20）。实时活动（12.10）以后也放在这个扩展里。
@main
struct ThinktinWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}
