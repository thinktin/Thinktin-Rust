import Foundation
import Observation

/// 添加模型 key（WBS 12.4，`.addCredential`，sheet）：从 `vendors()` 选厂商，看它支持的协议、推荐模型和说明，填 key、
/// 备注、每日上限；选“自定义地址”时填 https 的 Anthropic / OpenAI Chat / Responses 地址（至少一个，本地先校验 https）。
///
/// - 保存前要勾选第三方 AI 数据共享的同意（App Store 5.1.2(i)）：这把 key 的实例里的消息、文件、产出会发给这个厂商。
///   同意是对“发给谁”说的：换了厂商、自定义地址换了主机，要重新勾。保存成功后记下同意（`ThirdPartyAIConsentStore`），
///   之后配路由时不再问这个厂商。
/// - 服务端拒收时（订阅类 key、套餐专用地址、不是 https……）按 `CredentialRejection` 显示本地化的原因，不显示接口的英文说明；
///   能认出是哪个字段的显示在那个字段下面（`rejection(for:)`，和安卓一样是字段级提示），改了那个字段就清掉。
/// - 订阅类 key、套餐专用地址不用等服务端（11.9）：厂商表里每家带着 `subscriptionKeyPrefixes`、`planOnlyBases`，按服务端的
///   规则边输边提示在那个字段下面（`localRejections`），有的时候保存不了；服务端照样检查。
/// - 从某个实例的模型路由页过来时（`targetAgentID`），提示这把 key 能不能给这个 agent 用（协议对不上时运行会卡在等 key）。
/// - 加好以后服务端会唤醒等 key 的运行，界面提示一句。
@Observable @MainActor
public final class AddCredentialModel {
    /// 选的厂商。
    public enum VendorChoice: Hashable, Sendable {
        /// 厂商表里的（`VendorInfo.id`）。
        case preset(String)
        /// 自定义地址。
        case custom
    }

    /// 表单的字段（错误显示在哪个输入框下面）。
    public enum Field: Hashable, Sendable {
        case vendor, apiKey, label, dailyLimit, consent
        case endpoint(CredentialEndpointField)
    }

    public private(set) var vendors: [VendorInfo] = []
    public private(set) var hasLoadedVendors = false
    public private(set) var isLoadingVendors = false
    /// 厂商表拉不到（离线时没法选厂商，只能选自定义地址……也提交不了，所以界面显示错误）。
    public private(set) var vendorsError: ClientError?

    public var choice: VendorChoice? {
        didSet {
            // 换了厂商：之前的拒收原因、勾过的同意都不算了（选回来也要重新勾）。
            if oldValue != choice {
                rejection = nil
                consentedRecipient = nil
            }
        }
    }
    public var apiKey = "" {
        didSet { fieldChanged(.apiKey) }
    }
    public var label = "" {
        didSet { fieldChanged(.label) }
    }
    public var dailyLimit = "" {
        didSet { fieldChanged(.dailyLimit) }
    }
    public var anthropicBase = "" {
        didSet { fieldChanged(.endpoint(.anthropic)) }
    }
    public var openaiBase = "" {
        didSet { fieldChanged(.endpoint(.openai)) }
    }
    public var responsesBase = "" {
        didSet { fieldChanged(.endpoint(.responses)) }
    }

    /// 勾了第三方 AI 数据共享的同意。同意是对“发给谁”说的：换了厂商、自定义地址换了主机（`consentRecipient` 变了）
    /// 就不算数了，要重新勾。
    public var hasConsented: Bool {
        get { consentedRecipient != nil && consentedRecipient == consentRecipient }
        set { consentedRecipient = newValue ? consentRecipient : nil }
    }
    /// 勾同意时的接收方。
    private var consentedRecipient: String?

    /// 点过保存（之后才显示“这一项要填”这类空字段的问题）。
    public private(set) var didAttemptSubmit = false
    public private(set) var isSubmitting = false
    /// 服务端拒收的原因（订阅类 key 等）。
    public private(set) var rejection: CredentialRejection?
    /// 别的错误（网络、限流……）。
    public private(set) var error: ClientError?
    /// 加好了的 key（界面换成“加好了”）。
    public private(set) var created: Credential?

    /// 要给哪个 agent 用（从实例的模型路由页过来时），没有为 nil。
    public let targetAgentID: AgentID?
    /// `targetAgentID` 在目录里的那一条（`load()` 之后有）。
    public private(set) var targetAgent: AgentInfo?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let consent: ThirdPartyAIConsentStore

    public init(
        client: any ClientProtocol, targetAgentID: AgentID? = nil, consent: ThirdPartyAIConsentStore = .init()
    ) {
        self.client = client
        self.targetAgentID = targetAgentID
        self.consent = consent
    }

    // MARK: 加载

    /// 拉厂商表（和目标 agent 的协议）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoadingVendors else { return }
        isLoadingVendors = true
        defer { isLoadingVendors = false }
        let client = self.client
        async let vendors = AgentsErrors.attempt { try await client.vendors() }
        if let targetAgentID, targetAgent == nil {
            if let agents = try? await client.agents() { targetAgent = agents.first { $0.id == targetAgentID } }
        }
        switch await vendors {
        case .success(let list):
            self.vendors = list
            hasLoadedVendors = true
            vendorsError = nil
            if case .preset(let id) = choice, !list.contains(where: { $0.id == id }) { choice = nil }
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { vendorsError = failure }
        }
    }

    // MARK: 选的厂商

    /// 选的预置厂商（自定义地址、还没选时为 nil）。
    public var selectedVendor: VendorInfo? {
        guard case .preset(let id) = choice else { return nil }
        return vendors.first { $0.id == id }
    }

    public var isCustom: Bool { choice == .custom }

    /// 选的厂商的名字（同意的那一句、拒收的原因里用）。
    public func vendorName(_ language: DisplayLanguage = .current) -> String {
        switch choice {
        case .custom: return customEndpointName(language)
        case .preset(let id): return ModelsText.vendorName(id, vendors: vendors, language: language)
        case nil: return ""
        }
    }

    /// 自定义地址的名字：填了地址时是这几个地址的主机名（“api.example.com”，几个不同的都列上，同意的那一句要说全
    /// 发给谁），否则“自定义地址”。
    private func customEndpointName(_ language: DisplayLanguage) -> String {
        let hosts = customHosts
        return hosts.isEmpty ? ModelsText.customVendorName(language) : AgentsText.list(hosts, language: language)
    }

    /// 填对了的自定义地址的主机名（去重，按 Anthropic、OpenAI、Responses 的顺序）。
    private var customHosts: [String] {
        var seen = Set<String>()
        return [anthropicBase, openaiBase, responsesBase].compactMap { base in
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, CredentialRules.baseURLProblem(trimmed) == nil,
                let host = URL(string: trimmed)?.host?.lowercased(), seen.insert(host).inserted
            else { return nil }
            return host
        }
    }

    /// 同意的对象：预置厂商是它的 id，自定义地址是填了的主机名。还没选厂商为 nil。
    var consentRecipient: String? {
        switch choice {
        case .preset(let id): "preset:" + id
        case .custom: "custom:" + customHosts.joined(separator: ",")
        case nil: nil
        }
    }

    /// 选的厂商的推荐模型。
    public var recommendedModels: [String] { selectedVendor?.models ?? [] }

    /// 选的厂商的说明（订阅类 key 不能用之类），没有为 nil。
    public var vendorNotes: String? {
        let notes = selectedVendor?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? nil : notes
    }

    /// 加好以后这把 key 能用的协议（预置厂商按厂商表，自定义地址按填了哪几个地址）。
    public var expectedProtocols: [ModelProtocol] {
        draft.expectedProtocols(vendors: vendors)
    }

    /// 和目标 agent 合不合得来：没有目标、算不出协议时为 nil。
    public var compatibility: CredentialCompatibility? {
        guard let agent = targetAgent, let required = agent.activeProtocol, choice != nil else { return nil }
        let protocols = expectedProtocols
        guard !protocols.isEmpty else { return nil }
        return protocols.contains(required)
            ? .compatible(agentName: AgentsText.displayName(of: agent))
            : .incompatible(agentName: AgentsText.displayName(of: agent), required: required)
    }

    // MARK: 校验

    /// 要提交的内容（已经规整过：key 去掉首尾空白，地址只给自定义厂商）。
    public var draft: NewCredential {
        let vendor: String
        switch choice {
        case .preset(let id): vendor = id
        case .custom: vendor = NewCredential.customVendor
        case nil: vendor = ""
        }
        func base(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return isCustom && !trimmed.isEmpty ? trimmed : nil
        }
        let limit = (try? CredentialRules.parseDailyLimit(dailyLimit).get()) ?? nil
        return NewCredential(
            vendor: vendor, label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: CredentialRules.normalizedKey(apiKey), anthropicBase: base(anthropicBase),
            openaiBase: base(openaiBase), responsesBase: base(responsesBase), dailyTokenLimit: limit)
    }

    /// 每个字段的问题（含空字段的“要填”）。
    public var problems: [Field: CredentialFieldProblem] {
        var out: [Field: CredentialFieldProblem] = [:]
        if choice == nil { out[.vendor] = .required }
        if let problem = CredentialRules.keyProblem(apiKey) { out[.apiKey] = problem }
        if let problem = CredentialRules.labelProblem(label) { out[.label] = problem }
        if case .failure(let problem) = CredentialRules.parseDailyLimit(dailyLimit) { out[.dailyLimit] = problem }
        if isCustom {
            let bases: [(CredentialEndpointField, String)] = [
                (.anthropic, anthropicBase), (.openai, openaiBase), (.responses, responsesBase),
            ]
            for (field, text) in bases {
                if let problem = CredentialRules.baseURLProblem(text) { out[.endpoint(field)] = problem }
            }
            if bases.allSatisfy({ $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                out[.endpoint(.anthropic)] = .required
            }
        }
        if !hasConsented { out[.consent] = .required }
        return out
    }

    /// 界面上这个字段下面显示的问题：“要填”只在点过保存之后显示，别的（格式不对）边输边显示。
    public func problem(for field: Field) -> CredentialFieldProblem? {
        guard let problem = problems[field] else { return nil }
        if problem == .required && !didAttemptSubmit { return nil }
        return problem
    }

    /// 能点保存。
    public var canSubmit: Bool {
        problems.isEmpty && localRejections.isEmpty && !isSubmitting && created == nil
    }

    // MARK: 本地提前提示（11.9）

    /// 不用等服务端就知道会被拒的（规则和 crates/proto/src/vendors.rs 的 `check_key`、`plan_only_base` 一样）：选的厂商的
    /// 订阅类 key（`VendorInfo.subscriptionKeyPrefix(of:)`，只查这家），自定义地址填了任何一家的套餐专用地址
    /// （`VendorInfo.planOnlyBase(of:vendors:)`）。显示在那个字段下面，有的时候保存不了。
    public var localRejections: [Field: CredentialRejection] {
        var out: [Field: CredentialRejection] = [:]
        if let vendor = selectedVendor, vendor.subscriptionKeyPrefix(of: apiKey) != nil {
            out[.apiKey] = .subscriptionKey
        }
        if isCustom {
            let bases: [(CredentialEndpointField, String)] = [
                (.anthropic, anthropicBase), (.openai, openaiBase), (.responses, responsesBase),
            ]
            for (field, text) in bases where VendorInfo.planOnlyBase(of: text, vendors: vendors) != nil {
                out[.endpoint(field)] = .planOnlyEndpoint(field: field)
            }
        }
        return out
    }

    // MARK: 服务端拒收的原因

    /// 服务端拒收的原因显示在哪个字段下面；说不清是哪个字段的（`endpointMismatch`、`other`、没说是哪个地址的）为 nil，
    /// 显示在表单下面。
    static func field(of rejection: CredentialRejection) -> Field? {
        switch rejection {
        case .subscriptionKey, .keyFormat: .apiKey
        case .planOnlyEndpoint(let field), .notHTTPS(let field): field.map(Field.endpoint)
        case .invalidEndpoint(let field): .endpoint(field)
        case .unknownVendor: .vendor
        case .dailyLimit: .dailyLimit
        case .label: .label
        case .endpointMismatch, .other: nil
        }
    }

    /// 这个字段下面要显示的拒收原因：服务端说的，没有时是本地就看得出的（`localRejections`）。
    public func rejection(for field: Field) -> CredentialRejection? {
        if let rejection, Self.field(of: rejection) == field { return rejection }
        return localRejections[field]
    }

    /// 不属于哪个字段的拒收原因（显示在表单下面）。
    public var formRejection: CredentialRejection? {
        guard let rejection, Self.field(of: rejection) == nil else { return nil }
        return rejection
    }

    /// 改了一个字段：拒收的原因是这个字段的（或者说不清是哪个字段的）就清掉，不留着已经改过的问题。
    private func fieldChanged(_ field: Field) {
        guard let rejection else { return }
        let target = Self.field(of: rejection)
        if target == nil || target == field { self.rejection = nil }
    }

    // MARK: 保存

    /// 保存。有问题时只把问题显示出来（`didAttemptSubmit`），不发请求。
    @discardableResult
    public func submit() async -> Credential? {
        didAttemptSubmit = true
        guard canSubmit else { return nil }
        isSubmitting = true
        rejection = nil
        error = nil
        defer { isSubmitting = false }
        do {
            let credential = try await client.addCredential(draft)
            consent.record([ThirdPartyAIConsentStore.vendorKey(for: credential)])
            created = credential
            apiKey = ""
            return credential
        } catch {
            guard let failure = AgentsErrors.from(error) else { return nil }
            if let rejection = CredentialRejection(failure) {
                self.rejection = rejection
            } else {
                self.error = failure
            }
            return nil
        }
    }

    /// 加好之后的说明：能用哪些协议、能不能给目标 agent 用、等 key 的任务会接着跑。
    public func createdMessage(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        var parts: [String] = []
        if let credential = created, let protocols = ModelsText.protocolList(credential.protocols, language: language) {
            parts.append(zh ? "这把 key 支持 \(protocols)。" : "This key supports \(protocols).")
        }
        parts.append(ModelsText.wakeExplanation(language))
        return parts.joined(separator: zh ? "" : " ")
    }
}

/// 一把 key 和某个 agent 合不合得来（模型网关不在协议之间转换）。
public enum CredentialCompatibility: Hashable, Sendable {
    case compatible(agentName: String)
    /// agent 要的协议这把 key 不支持：配上了运行会卡在等 key。
    case incompatible(agentName: String, required: ModelProtocol)

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .compatible(let name):
            return zh ? "能给 \(name) 用。" : "Works with \(name)."
        case .incompatible(let name, let required):
            let proto = ModelsText.protocolName(required)
            return zh
                ? "\(name) 要支持 \(proto) 的 key，这把不能给它用（可以留给别的实例）。"
                : "\(name) needs a key that supports \(proto); this one won't work for it (other instances can still use it)."
        }
    }
}
