import ActivityKit
import ThinktinKit

/// 实时活动的属性（WBS 12.10，backend-core 的 docs/live-activities.md 第 3 节）。App 和小组件扩展共用这一个文件
/// （project.yml 里两个 target 都加了 `Shared/`）。
///
/// 类型名、属性名是和后台的约定：远程开启按类型名 `RunActivityAttributes` 找，推送里的键名和属性名一模一样，不能改；
/// 以后加的字段要是可选的，老版本的 App 才解得开。内容就是 ThinktinKit 的 `RunActivityContentState`（有往返测试）。
struct RunActivityAttributes: ActivityAttributes {
    typealias ContentState = RunActivityContentState

    var runId: String
    var instanceId: String
    /// 实例名（远程开启时由后台填，命中内容过滤的换成“ThinkTin”）。
    var title: String
}
