import Foundation
import Sparkle

/// 自动更新（WBS 14.9，docs/macos.md 第 6 节）：Sparkle 2。更新源（`SUFeedURL`）和验签公钥（`SUPublicEDKey`）在 Info.plist 里，
/// 由构建设置 `SPARKLE_FEED_URL`、`SPARKLE_PUBLIC_ED_KEY` 展开（发版工作流从仓库变量传进来）。公钥是空的（本机开发版、
/// 还没配发版密钥）时不启动更新器，菜单里也没有“检查更新”。
@MainActor
final class MacUpdater {
    private let controller: SPUStandardUpdaterController?

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        controller =
            Self.isConfigured(infoDictionary)
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// 公钥填了、更新源是 https 的地址。
    nonisolated static func isConfigured(_ infoDictionary: [String: Any]?) -> Bool {
        let key = (infoDictionary?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = (infoDictionary?["SUFeedURL"] as? String).flatMap(URL.init(string:))
        return !key.isEmpty && !key.hasPrefix("$(") && feed?.scheme == "https" && feed?.host != nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
