import Foundation

/// 一条内容举报（5.5）和它的处理结果：用户长按 agent 的回复或产出物举报。
///
/// 举报的对象：`eventSeq` 是运行里的一条事件（实例事件流的序号），`artifactID` 是一个产出物，都为 nil 是整个运行（它的回复）。
/// 被举报的内容在提交时由服务端复制一份给运营看，接口不回显。
public struct ContentReport: Identifiable, Hashable, Codable, Sendable {
    public var id: ContentReportID
    public var runID: RunID
    public var instanceID: InstanceID
    public var eventSeq: UInt64?
    public var artifactID: ArtifactID?
    public var reason: ReportReason
    /// 用户写的说明（最多 1000 个字符）。
    public var note: String?
    public var state: ReportState
    /// 处理结果（运营写的，处理完也发到收件箱和推送）；还没处理时为 nil。
    public var resolution: String?
    public var createdAt: Date
    public var handledAt: Date?

    public init(
        id: ContentReportID, runID: RunID, instanceID: InstanceID, eventSeq: UInt64? = nil,
        artifactID: ArtifactID? = nil, reason: ReportReason, note: String? = nil, state: ReportState = .open,
        resolution: String? = nil, createdAt: Date, handledAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.instanceID = instanceID
        self.eventSeq = eventSeq
        self.artifactID = artifactID
        self.reason = reason
        self.note = note
        self.state = state
        self.resolution = resolution
        self.createdAt = createdAt
        self.handledAt = handledAt
    }

    /// 说明最长几个字符。
    public static let maxNoteLength = 1000

    /// 每人每小时最多举报几次（再举报同一条也算），超了服务端返回 rate_limited。
    public static let maxPerHour = 30

    /// 还在等处理。
    public var isOpen: Bool { state == .open }

    /// 举报的是什么。
    public var target: Target {
        if let artifactID { return .artifact(artifactID) }
        if let eventSeq { return .event(seq: eventSeq) }
        return .run
    }

    /// 举报的对象。
    public enum Target: Hashable, Sendable {
        /// 整个运行（它的回复）。
        case run
        /// 运行里的一条事件。
        case event(seq: UInt64)
        case artifact(ArtifactID)
    }
}
