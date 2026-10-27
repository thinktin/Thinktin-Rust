import Foundation
import Observation

/// 领养表单（WBS 12.3）：起名字，接入方式多于一个时选一个；领养成功后引导去配模型路由（12.4 的路由页）。
///
/// 领养出来的实例还没有模型路由，直接下任务会卡在“等待 key”（ios-packages.md 12.17）。所以成功后顺带查一下
/// 有没有能给这个 agent 用的 key（启用的、支持 agent 的模型接口的，`AgentInfo.canUse(_:)`）：有就直接去配路由，
/// 没有就先去加 key（`nextStep`）。
@Observable @MainActor
public final class AdoptionModel {
    public let agent: AgentInfo
    /// 输入的名字（提交时去掉首尾空白）。
    public var name: String
    /// 选的接入方式（`agent.harnesses` 里的一个；agent 没给接入方式时为空串，领养时不带）。
    public var harness: String
    public private(set) var isAdopting = false
    public private(set) var error: ClientError?
    /// 领养出来的实例；有了就显示“领养好了”和下一步。
    public private(set) var adopted: Instance?
    /// 领养后查到的、能给这个 agent 用的 key；nil 是没查（或查不到）。
    public private(set) var usableCredentials: [Credential]?

    @ObservationIgnored private let client: any ClientProtocol

    /// - Parameters:
    ///   - existingNames: 已有实例的名字（建议的名字不和它们重复）。
    public init(client: any ClientProtocol, agent: AgentInfo, existingNames: [String] = []) {
        self.client = client
        self.agent = agent
        self.name = Self.suggestedName(for: agent, existingNames: existingNames)
        self.harness = agent.catalogHarnesses.first ?? ""
    }

    // MARK: 表单

    /// 接入方式多于一个：表单里让用户选。
    public var showsHarnessChoice: Bool { agent.harnesses.count > 1 }

    /// 可以选的接入方式，默认的在前。
    public var harnessOptions: [String] { agent.catalogHarnesses }

    /// 名字有什么问题（界面在输入框下面提示）；没问题为 nil。
    public var nameProblem: InstanceNameProblem? { InstanceNameRule.problem(name) }

    public var canSubmit: Bool { nameProblem == nil && !isAdopting && adopted == nil }

    /// 建议的名字：agent 的名字，和已有实例重名时加上序号（“Claude Agent 2”）。
    public static func suggestedName(for agent: AgentInfo, existingNames: [String]) -> String {
        let base = AgentsText.displayName(of: agent)
        let taken = Set(existingNames.map { InstanceNameRule.normalized($0).lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: 领养

    /// 领养。成功后再查能用的 key（查不到不算失败）。名字不对、正在领养、已经领养过时什么也不做，返回 nil。
    @discardableResult
    public func adopt() async -> Instance? {
        guard canSubmit else { return nil }
        isAdopting = true
        error = nil
        defer { isAdopting = false }
        let harness: String? = agent.harnesses.contains(self.harness) ? self.harness : nil
        do {
            let instance = try await client.adopt(
                agentID: agent.id, name: InstanceNameRule.normalized(name), harness: harness)
            adopted = instance
            await loadUsableCredentials()
            return instance
        } catch {
            self.error = AgentsErrors.from(error)
            return nil
        }
    }

    /// 查能给这个 agent 用的 key（启用的、协议对的）。
    public func loadUsableCredentials() async {
        do {
            let credentials = try await client.credentials()
            usableCredentials = credentials.filter { !$0.isDisabled && agent.canUse($0) }
        } catch {
            usableCredentials = nil
        }
    }

    /// 领养好之后的下一步。
    public var nextStep: AdoptionNextStep {
        usableCredentials?.isEmpty == true ? .addCredentialFirst : .configureRoutes
    }

    /// 下一步的说明（“领养好了”下面那段）。
    public func nextStepMessage(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let agentName = AgentsText.displayName(of: agent)
        switch nextStep {
        case .configureRoutes:
            return zh
                ? "还差一步：给它配模型路由，选一把 key 和模型作为 main。没配之前，任务会停在“等待 key”。"
                : "One more step: set up its model routes by choosing a key and model for main. Until then, tasks "
                    + "will wait for a key."
        case .addCredentialFirst:
            let protocols =
                agent.activeProtocol.map { [AgentsText.protocolName($0)] }
                ?? agent.protocols.map(AgentsText.protocolName)
            if protocols.isEmpty {
                return zh
                    ? "还没有能给 \(agentName) 用的模型 key。先添加一把，再配模型路由。"
                    : "You don't have a model key \(agentName) can use yet. Add one, then set up its model routes."
            }
            let names = AgentsText.list(protocols, language: language)
            return zh
                ? "还没有能给 \(agentName) 用的模型 key（要支持 \(names)）。先添加一把，再配模型路由。"
                : "You don't have a model key \(agentName) can use yet (it needs \(names)). Add one, then set up "
                    + "its model routes."
        }
    }
}

/// 领养好之后的下一步。
public enum AdoptionNextStep: Hashable, Sendable {
    /// 去配模型路由（已经有能用的 key，或者没查到有没有）。
    case configureRoutes
    /// 还没有能给这个 agent 用的 key：先加 key，再配路由。
    case addCredentialFirst
}
