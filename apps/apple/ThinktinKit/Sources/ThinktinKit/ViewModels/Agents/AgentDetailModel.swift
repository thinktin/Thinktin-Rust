import Foundation
import Observation

/// Agent 详情（WBS 12.3）：介绍、许可证和许可说明、上游仓库、接入方式、可用版本、模型接口，以及“领养”。
///
/// 从目录点进来时带着目录里的那一条先显示；从深链、别的页面进来时自己拉目录找。目录里没有了（下架）时
/// `isMissing`，界面不给领养。
@Observable @MainActor
public final class AgentDetailModel {
    public let agentID: AgentID
    public private(set) var agent: AgentInfo?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, agentID: AgentID, agent: AgentInfo? = nil) {
        self.client = client
        self.agentID = agentID
        self.agent = agent?.id == agentID ? agent : nil
    }

    /// 拉目录，找出这个 agent（服务端没有单个 agent 的接口）。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let agents = try await client.agents()
            agent = agents.first { $0.id == agentID }
            hasLoaded = true
            error = nil
        } catch {
            if let failure = AgentsErrors.from(error) { self.error = failure }
        }
    }

    /// 目录里已经没有这个 agent 了（下架，或者 id 不对）。
    public var isMissing: Bool { hasLoaded && agent == nil }

    /// 界面上的名字（没拉到时按 id 认）。
    public var displayName: String {
        agent.map(AgentsText.displayName(of:)) ?? AgentsText.displayName(agentID: agentID)
    }

    /// 这个 agent 领养出来的实例（详情页下面列出来，点开去实例详情）。
    public func adoptedInstances(in instances: [Instance]) -> [Instance] {
        instances.filter { $0.agentID == agentID && $0.state != .deleted }
    }
}
