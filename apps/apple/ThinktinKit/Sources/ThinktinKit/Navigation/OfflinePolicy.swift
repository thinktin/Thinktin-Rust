import Foundation

/// 离线时一个页面怎么显示（ios-packages.md 12.16 “离线时哪些页面有缓存”，表见 docs/ios.md 第 6.2 节）。
///
/// client-core 只缓存实例、运行、事件、收件箱（还有续传位置和离线标的已读）；计划、审批、key、路由、用量、保险箱、
/// 团队、agent 目录、IM 渠道、设备都不缓存。所有页面用同一个离线横幅（`AppShell` 统一放在页面顶部），文案按这里取。
///
/// 离线时所有写操作都禁用，只有收件箱标已读例外：它先在本地生效，联网后补发（`allowsWritesOffline`）。
public enum OfflinePolicy: Hashable, Sendable, CaseIterable {
    /// 有本地缓存：照常显示缓存，横幅写“离线，显示的是缓存内容”。
    case cached
    /// 没有缓存：横幅写“离线，暂无数据”，页面显示空状态，联网后自动刷新。
    case unavailable
    /// 不用联网（关于、开源许可、本机搜索）：不显示离线横幅。
    case local

    /// 离线横幅的文案；`local` 不显示横幅，为 nil。
    public func bannerMessage(_ language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch self {
        case .cached: return zh ? "离线，显示的是缓存内容" : "Offline. Showing saved content."
        case .unavailable: return zh ? "离线，暂无数据。联网后会自动刷新。" : "Offline. This will refresh when you're back online."
        case .local: return nil
        }
    }
}

extension AppRoute {
    /// 离线时还能不能在这个页面上改东西：只有收件箱能离线标已读（联网后补发），其余写操作一律禁用。
    public var allowsWritesOffline: Bool {
        switch self {
        case .inbox, .inboxItem: true
        default: false
        }
    }
}
