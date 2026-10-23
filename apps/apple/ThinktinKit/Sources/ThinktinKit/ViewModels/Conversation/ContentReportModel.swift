import Foundation
import Observation

/// 举报的对象（长按 agent 的回复、产出物，或者运行详情里举报整个运行）。
public enum ContentReportTarget: Hashable, Sendable {
    /// 一条回复：`seq` 是它的第一条事件（服务端复制运行的任务、摘要和这条事件给运营看）。
    case message(runID: RunID, seq: UInt64)
    case artifact(runID: RunID, artifactID: ArtifactID)
    /// 整个运行（它的回复）。
    case run(RunID)

    public var runID: RunID {
        switch self {
        case .message(let id, _), .artifact(let id, _), .run(let id): id
        }
    }

    /// 对话里的一项能举报什么：agent 的回复、思考是那条事件，产出物是那个产出物；别的（用户消息、状态行）不能举报。
    public init?(item: ConversationItem) {
        guard let runID = item.runID else { return nil }
        switch item.content {
        case .assistantText, .thought, .agentPlan:
            guard let seq = item.eventSeq else { return nil }
            self = .message(runID: runID, seq: seq)
        case .artifact(let card):
            self = .artifact(runID: runID, artifactID: card.artifactID)
        default:
            return nil
        }
    }
}

extension ConversationItem {
    /// 这一项的第一条事件的序号（归并时 id 是 `seq-<序号>` 的项）；没有为 nil。
    public var eventSeq: UInt64? {
        guard id.hasPrefix("seq-") else { return nil }
        return UInt64(id.dropFirst(4))
    }
}

/// 举报表单（5.5，审核 1.2 对 AI 聊天类 App 的要求）：选原因、写说明（最多 1000 个字符），提交 `reportContent`。
/// 同一条内容还有待处理的举报时服务端返回那一条，不重复建；每人每小时 30 次，超了按限流提示。
@Observable @MainActor
public final class ContentReportModel {
    public let target: ContentReportTarget
    public var reason: ReportReason?
    public var note = ""
    public private(set) var isSubmitting = false
    public private(set) var error: ClientError?
    /// 提交好了（界面显示“已收到”，然后关掉）。
    public private(set) var report: ContentReport?

    /// 可选的原因（界面按这个顺序列）。
    public nonisolated static let reasons: [ReportReason] = ReportReason.knownCases

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, target: ContentReportTarget) {
        self.client = client
        self.target = target
    }

    /// 说明超长了。
    public var isNoteTooLong: Bool { note.count > ContentReport.maxNoteLength }

    public var canSubmit: Bool { reason != nil && !isNoteTooLong && !isSubmitting && report == nil }

    @discardableResult
    public func submit() async -> Bool {
        guard canSubmit, let reason else { return false }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch target {
            case .message(let runID, let seq):
                report = try await client.reportContent(
                    runID: runID, eventSeq: seq, artifactID: nil, reason: reason, note: text.isEmpty ? nil : text)
            case .artifact(let runID, let artifactID):
                report = try await client.reportContent(
                    runID: runID, eventSeq: nil, artifactID: artifactID, reason: reason, note: text.isEmpty ? nil : text
                )
            case .run(let runID):
                report = try await client.reportRun(runID, reason: reason, note: text.isEmpty ? nil : text)
            }
            return true
        } catch {
            self.error = ConversationErrors.from(error)
            return false
        }
    }
}
