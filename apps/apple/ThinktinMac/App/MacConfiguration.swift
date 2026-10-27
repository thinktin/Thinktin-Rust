import Foundation
import ThinktinKit

/// macOS App 才有的配置（WBS 14.5）：设备中继的地址、电脑端工具服务的本地状态放哪。客户端怎么选、接口地址、缓存
/// 和 iOS 一样（`AppConfiguration`，两个 App 共用那个文件）。
extension AppConfiguration {
    /// Info.plist 里的中继地址（project.yml 用构建设置 `THINKTIN_RELAY_URL` 展开进去）。
    static let relayURLInfoKey = "ThinktinRelayURL"
    static let defaultRelayURL = URL(string: "wss://relay.thinktin.cn/v1/connect")!
    /// 工具服务的本地状态（配对的手机、能力令牌、审计日志）：Application Support/Thinktin/desktop/<设备 id>/。
    /// 每次登录是一台新设备，之前的配对不带过来。
    static let desktopDirectoryName = "desktop"

    /// Info.plist 里的中继地址；没有、为空、没展开或不是 ws(s) 的绝对地址时用默认地址。
    static func relayURL(infoDictionary: [String: Any]?) -> URL {
        guard
            let raw = (infoDictionary?[relayURLInfoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
            let host = url.host, !host.isEmpty
        else { return defaultRelayURL }
        return url
    }

    /// 这台电脑（登录后的设备 id）的工具服务状态目录；不存在就建。
    static func desktopDataDirectory(deviceID: DeviceID, fileManager: FileManager = .default) throws -> URL {
        let directory =
            try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(desktopDirectoryName, isDirectory: true)
            .appendingPathComponent(deviceID.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
