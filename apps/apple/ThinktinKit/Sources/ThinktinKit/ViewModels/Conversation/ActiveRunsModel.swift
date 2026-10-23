import Foundation
import Observation

/// 进行中（`.activeRuns`，抽屉里的“进行中”，对应 Claude 的后台会话列表）：跨实例、还没结束的运行（11.8 的
/// `listRuns(filter: .active)`），等你处理的（等审批、等 key、等电脑、等子任务）排在前面，其余按创建时间新的在前。
/// 往下翻用 `loadMore()`（一页 50 个）。点开去运行详情。
@Observable @MainActor
public final class ActiveRunsModel {
    public nonisolated static let pageSize = 50

    public private(set) var runs: [Run] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = false
    public private(set) var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    /// 等你处理的。
    public var waiting: [Run] { runs.filter(\.state.isWaiting) }

    /// 其余还没结束的（运行中、排队、启动、退避）。
    public var others: [Run] { runs.filter { !$0.state.isWaiting } }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.listRuns(filter: .active, before: nil, limit: Self.pageSize)
            runs = Self.sorted(page)
            hasMore = page.count >= Self.pageSize
            self.error = nil
        } catch {
            self.error = ConversationErrors.from(error)
        }
        hasLoaded = true
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        // 游标是上一页最后一个（服务端的顺序：新的在前）。
        guard let last = runs.min(by: { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }) else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.listRuns(filter: .active, before: last.id, limit: Self.pageSize)
            let known = Set(runs.map(\.id))
            runs = Self.sorted(runs + page.filter { !known.contains($0.id) })
            hasMore = page.count >= Self.pageSize
        } catch {
            self.error = ConversationErrors.from(error)
        }
    }

    /// 等你处理的在前，其余新的在前。
    static func sorted(_ runs: [Run]) -> [Run] {
        runs.filter(RunFilter.active.matches).sorted { a, b in
            if a.state.isWaiting != b.state.isWaiting { return a.state.isWaiting }
            return (a.createdAt, a.id.rawValue) > (b.createdAt, b.id.rawValue)
        }
    }
}
