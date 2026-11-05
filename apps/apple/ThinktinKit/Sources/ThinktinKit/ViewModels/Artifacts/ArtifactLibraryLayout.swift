import Foundation

// 产出物库的版式（规范 4.5.2，参考 22、23、81–84）：顶上“全部 / 媒体 / 文件”三个胶囊（参考的“链接”没有数据来源，
// 规范 6.19 C：换成“文件”），下面按日期分组（今天、本周、更早），最下面“展开”（本地折叠，`instanceArtifacts` 没有游标，6.19 B）。
// 都是本地做的，不发新的请求。

/// 产出物的大类（库顶上的筛选胶囊）。
public enum ArtifactCategory: String, CaseIterable, Hashable, Sendable {
    /// 图片、视频、音频。
    case media
    /// 其余的（文档、表格、代码、压缩包……）。
    case file

    public func title(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .media: return zh ? "媒体" : "Media"
        case .file: return zh ? "文件" : "Files"
        }
    }
}

/// 库里的日期分组（新的在前）。
public enum ArtifactDateGroup: Int, CaseIterable, Hashable, Sendable, Comparable {
    case today
    /// 这个日历周里、今天以前的。
    case thisWeek
    case earlier

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// 一个产出物落在哪一组。将来的时间（设备时钟慢了）算今天。
    public static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> ArtifactDateGroup {
        if calendar.isDate(date, inSameDayAs: now) || date > now { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }

    public func title(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .today: return zh ? "今天" : "Today"
        case .thisWeek: return zh ? "本周" : "This week"
        case .earlier: return zh ? "更早" : "Earlier"
        }
    }
}

/// 库里的一组。
public struct ArtifactSection: Identifiable, Hashable, Sendable {
    public var group: ArtifactDateGroup
    public var artifacts: [Artifact]

    public var id: ArtifactDateGroup { group }
}

extension ArtifactFiles {
    /// 是媒体（图片、视频、音频）。
    public static func isMedia(_ artifact: Artifact) -> Bool {
        let type = artifact.contentType.lowercased()
        return type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/")
    }

    public static func category(_ artifact: Artifact) -> ArtifactCategory {
        isMedia(artifact) ? .media : .file
    }

    /// 能在库里画缩略图、点了全屏看的图片：`image/*`，SVG 除外（系统的图片解码认不了）。
    public static func isViewableImage(_ artifact: Artifact) -> Bool {
        isImage(artifact) && !artifact.contentType.lowercased().hasPrefix("image/svg")
    }
}

extension ArtifactLibraryModel {
    /// 折起来时最多列几个（参考 81：一屏多一点，最下面“展开”）。
    public nonisolated static let collapsedLimit = 20

    /// 按 Botin 和大类筛过的（不折叠）。
    public var filtered: [Artifact] {
        guard let kind else { return visible }
        return visible.filter { ArtifactFiles.category($0) == kind }
    }

    /// 这一类有几个（胶囊上的数）；nil 是全部。跟着 Botin 筛选走。
    public func count(of kind: ArtifactCategory?) -> Int {
        guard let kind else { return visible.count }
        return visible.filter { ArtifactFiles.category($0) == kind }.count
    }

    /// 还有折起来的（显示“展开”）。
    public var hasMore: Bool { !isExpanded && filtered.count > Self.collapsedLimit }

    /// 按日期分好的组（折起来时只到第 `collapsedLimit` 个）。
    public func sections(now: Date = Date(), calendar: Calendar = .current) -> [ArtifactSection] {
        let list = isExpanded ? filtered : Array(filtered.prefix(Self.collapsedLimit))
        var groups: [ArtifactDateGroup: [Artifact]] = [:]
        for artifact in list {
            groups[ArtifactDateGroup.of(artifact.createdAt, now: now, calendar: calendar), default: []].append(artifact)
        }
        return ArtifactDateGroup.allCases.compactMap { group in
            groups[group].map { ArtifactSection(group: group, artifacts: $0) }
        }
    }

    /// 列表空着时显示什么；有东西可列时为 nil。
    public var placeholder: ArtifactLibraryPlaceholder? {
        guard filtered.isEmpty else { return nil }
        if !hasLoaded { return .loading }
        if artifacts.isEmpty, let error { return .unavailable(offline: error.isOffline) }
        if let kind, !visible.isEmpty { return .noneOfKind(kind) }
        return .empty
    }
}

/// 产出物库空着时（`ArtifactLibraryModel.placeholder`）。
public enum ArtifactLibraryPlaceholder: Hashable, Sendable {
    case loading
    /// 一个都没拉到、出错了。
    case unavailable(offline: Bool)
    /// 有产出物，但没有这一类的（“没有媒体”）。
    case noneOfKind(ArtifactCategory)
    /// 还没有产出物。
    case empty
}

/// 库里图片的缩略图：要下载整份文件（服务端没有缩略图接口，6.19 B），所以只给能显示的图片、小于 `maxBytes` 的、
/// 一次打开最多 `maxCount` 张，下载过的记在内存里（失败的也记下，不重试）。
@MainActor
final class ArtifactThumbnailLoader {
    nonisolated static let maxBytes = 4 * 1024 * 1024
    nonisolated static let maxCount = 30

    private var cache: [ArtifactID: Data?] = [:]
    private var inFlight: [ArtifactID: Task<Data?, Never>] = [:]

    func data(for artifact: Artifact, client: any ClientProtocol) async -> Data? {
        if let cached = cache[artifact.id] { return cached }
        if let task = inFlight[artifact.id] { return await task.value }
        guard Self.isEligible(artifact), cache.count + inFlight.count < Self.maxCount else { return nil }
        let id = artifact.id
        let task = Task { try? await client.artifactContent(id) }
        inFlight[id] = task
        let data = await task.value
        inFlight[id] = nil
        cache[id] = data
        return data
    }

    nonisolated static func isEligible(_ artifact: Artifact) -> Bool {
        ArtifactFiles.isViewableImage(artifact) && artifact.size > 0 && artifact.size <= maxBytes
    }
}
