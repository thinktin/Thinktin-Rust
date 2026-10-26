import Foundation

/// 主屏小组件读的快照（WBS 12.20）：App 在角标变了、登录状态变了时写进 App Group 的共享目录，小组件只读这个文件，
/// 不连服务端、不带客户端核心。只有几个数，没有任务原文、实例名这些（锁屏、主屏谁都看得见）。
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public var signedIn: Bool
    public var inboxUnread: Int
    public var pendingApprovals: Int
    public var activeRuns: Int
    public var updatedAt: Date

    public init(signedIn: Bool, inboxUnread: Int = 0, pendingApprovals: Int = 0, activeRuns: Int = 0, updatedAt: Date) {
        self.signedIn = signedIn
        self.inboxUnread = inboxUnread
        self.pendingApprovals = pendingApprovals
        self.activeRuns = activeRuns
        self.updatedAt = updatedAt
    }

    public init(badges: ShellBadges, updatedAt: Date) {
        self.init(
            signedIn: true, inboxUnread: badges.inboxUnread, pendingApprovals: badges.pendingApprovals,
            activeRuns: badges.activeRuns, updatedAt: updatedAt)
    }

    /// 没登录（退出登录、注销后写这个，小组件显示“打开 App 登录”）。
    public static func signedOut(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(signedIn: false, updatedAt: date)
    }

    /// 只比较数，不比时间（数没变就不重写文件、不刷新小组件）。
    public func sameCounts(as other: WidgetSnapshot) -> Bool {
        signedIn == other.signedIn && inboxUnread == other.inboxUnread && pendingApprovals == other.pendingApprovals
            && activeRuns == other.activeRuns
    }
}

/// 快照写到哪（App 里是 App Group 的文件，再让 WidgetKit 刷新；测试里记下来）。
public protocol WidgetSnapshotSink: Sendable {
    func publish(_ snapshot: WidgetSnapshot) async
}

/// App Group 共享目录里的 `widget-snapshot.json`：App 写、小组件读。
public struct WidgetSnapshotFile: Sendable {
    public static let fileName = "widget-snapshot.json"
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public func save(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// 读不到（还没写过、坏了）时为 nil。
    public func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// 小组件上的文案（中英文，跟着系统语言：小组件读不到 App 里选的语言）。
public enum WidgetText {
    public static func title(_ language: DisplayLanguage) -> String {
        language == .chinese ? "ThinkTin" : "ThinkTin"
    }

    public static func unread(_ language: DisplayLanguage) -> String { language == .chinese ? "未读" : "Unread" }

    public static func approvals(_ language: DisplayLanguage) -> String {
        language == .chinese ? "待审批" : "Approvals"
    }

    public static func active(_ language: DisplayLanguage) -> String { language == .chinese ? "进行中" : "Active" }

    public static func signedOut(_ language: DisplayLanguage) -> String {
        language == .chinese ? "打开 App 登录" : "Open the app to sign in"
    }

    public static func description(_ language: DisplayLanguage) -> String {
        language == .chinese ? "未读通知、待审批、进行中的任务" : "Unread notifications, approvals and active tasks"
    }

    /// 上次更新：“5 分钟前更新”。
    public static func updated(_ date: Date, now: Date, language: DisplayLanguage) -> String {
        let text = Formatting.relativeTime(date, now: now, language: language)
        return language == .chinese ? "\(text)更新" : "Updated \(text)"
    }
}
