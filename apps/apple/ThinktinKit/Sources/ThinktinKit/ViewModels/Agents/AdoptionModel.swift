import Foundation
import Observation

/// 新建 Botin 的表单（WBS 12.3，规范 docs/ios-ui-redesign.md 4.7.1、6.4 A）：起名字、挑头像的形状和颜色、选一个引擎
/// （目录里的 agent），引擎的接入方式多于一个时再选一个。代码里还叫领养：新建就是 `adopt(agentID:name:harness:)`，
/// 每调一次建一个新实例，同一个 agent 可以给好几个 Botin 当引擎（服务端只限每个账号的实例数）。
///
/// - 名字默认是空的（用户自己起；以前默认填引擎名，2026-11-05 照参考改了），名字不对时“新建”不能点；输入框下面的
///   小字只在有用时出现（`nameNote`）。
/// - 头像：形状默认圆形、颜色默认按名字取（`InstanceAppearance.default`，和没选过的 Botin 一样）；建好之后记进
///   这台设备的 `InstanceAppearanceStore`（服务端还没有头像字段，规范 6.9）。
/// - 引擎列表是 `agents()` 的目录（`load()` 拉；传进来的先显示）。默认选哪个见 `defaultEngine`：预选的（引擎详情的
///   “用它新建 Botin”）、最近用过的（最近活跃的 Botin 的引擎）、目录里第一个能用的。不能用的（`canPowerNewBotin`）
///   列出来但选不了。
/// - 新建成功后界面关掉表单、压栈进新 Botin 的对话（`AppModel.openCreatedInstance`）；配模型路由的提示在对话页
///   （`ConversationText.setupNote`），没有能用的 key 时路由页上再引导加 key。
@Observable @MainActor
public final class AdoptionModel {
    /// 目录里的引擎，按服务端的顺序。
    public private(set) var agents: [AgentInfo]
    /// 目录拉到过一次（区分“加载中”和“目录是空的”）。
    public private(set) var hasLoadedAgents = false
    public private(set) var isLoadingAgents = false
    /// 最近一次拉目录的错误；成功后清掉。
    public private(set) var loadError: ClientError?
    /// 选的引擎；目录还没拉到、没有能用的引擎时为 nil。改它用 `selectEngine(_:)`。
    public private(set) var selectedAgentID: AgentID?
    /// 输入的名字（提交时去掉首尾空白），默认空的。
    public var name = ""
    /// 头像的形状，默认圆形。
    public var shape: AvatarShape = .circle
    /// 头像的颜色；nil 按名字取色（默认）。
    public var color: AvatarColor?
    /// 选的接入方式（选的引擎的 `harnesses` 里的一个；引擎没给接入方式时为空串，新建时不带）。
    public var harness: String
    public private(set) var isAdopting = false
    public private(set) var error: ClientError?
    /// 新建出来的 Botin；有了就不能再提交（界面关掉表单、进它的对话）。
    public private(set) var adopted: Instance?

    @ObservationIgnored private let client: any ClientProtocol
    /// 账号里已有的 Botin（默认引擎看最近活跃的那个；行上数几个 Botin 在用）。
    @ObservationIgnored private let instances: [Instance]
    @ObservationIgnored private let preselectedAgentID: AgentID?
    /// 建好之后把头像外观记在这里（App 里是 `AppModel.appearances`）；nil 不记。
    @ObservationIgnored private let appearances: InstanceAppearanceStore?
    /// 用户自己选过引擎（目录刷新时不再换成默认的）。
    @ObservationIgnored private var userChoseEngine = false
    /// 引擎详情要的引擎（`requestEngine(_:)`）还不在目录里（目录没拉到、拉到的是旧的）：`load()` 拉到后先选它。
    @ObservationIgnored private var requestedAgentID: AgentID?

    /// - Parameters:
    ///   - agents: 已经有的目录（比如别的页面拉过的），先显示它；`load()` 再拉新的。
    ///   - instances: 账号里已有的 Botin（`AppModel.instances`）。
    ///   - preselectedAgentID: 预选的引擎（`AppRoute.adopt(agentID:)`，从引擎详情进来）。
    ///   - appearances: 建好之后记头像外观的地方（`AppModel.appearances`）；nil 不记。
    public init(
        client: any ClientProtocol, agents: [AgentInfo] = [], instances: [Instance] = [],
        preselectedAgentID: AgentID? = nil, appearances: InstanceAppearanceStore? = nil
    ) {
        self.client = client
        self.agents = agents
        self.instances = instances.filter { $0.state != .deleted }
        self.preselectedAgentID = preselectedAgentID
        self.appearances = appearances
        self.harness = ""
        applyDefaultEngine()
    }

    // MARK: 引擎

    /// 拉目录（打开表单、下拉、联网后）。正在拉时再调直接返回。选的引擎还在目录里、能用就留着，否则换成默认的。
    public func load() async {
        guard !isLoadingAgents else { return }
        isLoadingAgents = true
        defer { isLoadingAgents = false }
        do {
            agents = try await client.agents()
            hasLoadedAgents = true
            loadError = nil
            // 引擎详情要的那个现在拉到了、能用就选它。
            if let requested = requestedAgentID {
                requestedAgentID = nil
                if selectEngine(requested) { return }
            }
            // 用户选过、还在目录里能用的留着；否则按新目录重新挑默认的（预选的可能现在才拉到）。
            if userChoseEngine, let selected = selectedAgent, selected.canPowerNewBotin {
                select(selected)
            } else {
                userChoseEngine = false
                applyDefaultEngine()
            }
        } catch {
            if let failure = AgentsErrors.from(error) { loadError = failure }
        }
    }

    /// 选的引擎（目录里的那一项）。
    public var selectedAgent: AgentInfo? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    /// 选择器的每一行：名字、一句话介绍、能不能选、几个 Botin 在用。
    public func engineOptions(_ language: DisplayLanguage = .current) -> [EngineOption] {
        let counts = AgentCatalogModel.adoptedCounts(instances)
        return agents.map { EngineOption(agent: $0, usedBy: counts[$0.id] ?? 0, language: language) }
    }

    /// 换引擎（选择器、引擎详情的“用它新建 Botin”）。不在目录里、不能用的不换，返回 false。接入方式换成这个引擎默认的；
    /// 名字不动。
    @discardableResult
    public func selectEngine(_ id: AgentID) -> Bool {
        guard let agent = agents.first(where: { $0.id == id }), agent.canPowerNewBotin, !isAdopting else {
            return false
        }
        userChoseEngine = true
        requestedAgentID = nil
        select(agent)
        return true
    }

    /// 引擎详情上点了“用它新建 Botin”（表单在栈底下，`Router.engineRequest`）：目录里有、能用就马上换（同 `selectEngine`）；
    /// 还不在目录里（拉不到、压上引擎目录时那次拉被取消了）就先记下，`load()` 拉到后先选它，不会被默认的引擎盖掉。
    /// 在目录里但不能用的不记；之后用户自己选了别的，以自己选的为准。
    public func requestEngine(_ id: AgentID) {
        if selectEngine(id) || isAdopting || adopted != nil { return }
        if !agents.contains(where: { $0.id == id }) { requestedAgentID = id }
    }

    /// 默认选哪个引擎：`preferred`（预选的）在目录里、能用就是它；其次最近活跃的 Botin 用的引擎；再次目录里第一个能用的。
    /// 没有能用的为 nil。
    public static func defaultEngine(agents: [AgentInfo], instances: [Instance], preferred: AgentID? = nil) -> AgentID?
    {
        let usable = agents.filter(\.canPowerNewBotin)
        let ids = Set(usable.map(\.id))
        if let preferred, ids.contains(preferred) { return preferred }
        let recent =
            instances
            .filter { $0.state != .deleted && ids.contains($0.agentID) }
            .max { a, b in
                if a.lastActiveAt != b.lastActiveAt { return a.lastActiveAt < b.lastActiveAt }
                return a.createdAt < b.createdAt
            }
        return recent?.agentID ?? usable.first?.id
    }

    private func applyDefaultEngine() {
        let id = Self.defaultEngine(agents: agents, instances: instances, preferred: preselectedAgentID)
        if let id, let agent = agents.first(where: { $0.id == id }) {
            select(agent)
        } else {
            selectedAgentID = nil
            harness = ""
        }
    }

    /// 选上这个引擎。接入方式：换了引擎，或者原来选的这个引擎已经没有了，就换成它默认的。
    private func select(_ agent: AgentInfo) {
        if selectedAgentID != agent.id || !agent.harnesses.contains(harness) {
            harness = agent.catalogHarnesses.first ?? ""
        }
        selectedAgentID = agent.id
    }

    // MARK: 表单

    /// 选的引擎的接入方式多于一个：表单里让用户选。
    public var showsHarnessChoice: Bool { (selectedAgent?.harnesses.count ?? 0) > 1 }

    /// 可以选的接入方式，默认的在前。
    public var harnessOptions: [String] { selectedAgent?.catalogHarnesses ?? [] }

    /// 名字有什么问题；没问题为 nil。空的也算（“新建”不能点），但输入框下面只在 `nameNote` 说有用时才提示。
    public var nameProblem: InstanceNameProblem? { InstanceNameRule.problem(name) }

    /// 输入框下面的小字：只在有用时有。还没输入（空的）不提示（按钮灰着就够了）；只输了空格说“起个名字吧。”；
    /// 太长了说最多几个字；快到上限（还剩 `nameHintThreshold` 个字以内）时提示上限；别的时候为 nil。
    public func nameNote(_ language: DisplayLanguage = .current) -> NameNote? {
        if let problem = nameProblem {
            if problem == .empty && name.isEmpty { return nil }
            return NameNote(text: problem.message(language), isProblem: true)
        }
        let count = InstanceNameRule.normalized(name).unicodeScalars.count
        guard count > InstanceNameRule.maxLength - Self.nameHintThreshold else { return nil }
        return NameNote(text: NewBotinText.nameHint(language), isProblem: false)
    }

    /// 名字还剩几个字到上限时开始提示上限。
    public static let nameHintThreshold = 10

    /// 名字对、选了能用的引擎、没在新建、还没建过。离线由界面另外禁用（`canCreate(isOffline:)`）。
    public var canSubmit: Bool {
        nameProblem == nil && selectedAgent?.canPowerNewBotin == true && !isAdopting && adopted == nil
    }

    /// 底部的“新建”能不能点：`canSubmit`，而且在线。
    public func canCreate(isOffline: Bool) -> Bool {
        canSubmit && !isOffline
    }

    /// 头像的外观（形状 + 颜色；颜色没选时按名字取）。
    public var appearance: InstanceAppearance {
        InstanceAppearance(shape: shape, color: color)
    }

    /// 头像实际画的颜色（色板上带环的那个）：选了的，没选按现在的名字取。
    public var resolvedColor: AvatarColor {
        appearance.resolvedColor(name: name)
    }

    /// 用户填了东西（名字不是空的，或者挑过形状、颜色）：取消前先确认。
    public var hasUserInput: Bool {
        adopted == nil && (!InstanceNameRule.normalized(name).isEmpty || !appearance.isDefault)
    }

    // MARK: 新建

    /// 新建（领养）。名字不对、没选引擎、正在新建、已经建过时什么也不做，返回 nil；失败记下错误（可以再试）。
    /// 建好了把头像外观记进 `appearances`（默认的不记）。
    @discardableResult
    public func adopt() async -> Instance? {
        guard canSubmit, let agent = selectedAgent else { return nil }
        isAdopting = true
        error = nil
        defer { isAdopting = false }
        let harness: String? = agent.harnesses.contains(self.harness) ? self.harness : nil
        do {
            let instance = try await client.adopt(
                agentID: agent.id, name: InstanceNameRule.normalized(name), harness: harness)
            adopted = instance
            appearances?.set(appearance, for: instance.id)
            return instance
        } catch {
            self.error = AgentsErrors.from(error)
            return nil
        }
    }
}

/// 名字输入框下面的小字（`AdoptionModel.nameNote`）。
public struct NameNote: Hashable, Sendable {
    public var text: String
    /// 是名字的问题（用失败色），不是提示。
    public var isProblem: Bool

    public init(text: String, isProblem: Bool) {
        self.text = text
        self.isProblem = isProblem
    }
}

/// 新建表单里引擎选择器的一行。
public struct EngineOption: Identifiable, Hashable, Sendable {
    public var id: AgentID
    /// 按商标要求处理过的名字（`AgentsText.displayName(of:)`）。
    public var name: String
    /// 一句话介绍（服务端给的，按请求语言；老的服务端为空）。
    public var summary: String
    /// 能拿它新建 Botin（`AgentInfo.canPowerNewBotin`）；不能的列出来但选不了。
    public var isAvailable: Bool
    /// 几个 Botin 在用它（已删除的不算）。
    public var usedBy: Int
    /// “N 个 Botin 在用”；没有时为 nil。
    public var usageLabel: String?

    public init(agent: AgentInfo, usedBy: Int = 0, language: DisplayLanguage = .current) {
        id = agent.id
        name = AgentsText.displayName(of: agent)
        summary = agent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        isAvailable = agent.canPowerNewBotin
        self.usedBy = usedBy
        usageLabel = AgentCatalogCard(agent: agent, adoptedCount: usedBy, language: language).adoptedLabel(language)
    }

    /// 名字下面那一行：不能用时说不能用；否则是一句话介绍，没有介绍时写几个 Botin 在用（都没有为空串）。
    public func detail(_ language: DisplayLanguage = .current) -> String {
        if !isAvailable { return language == .chinese ? "暂时不能用来新建 Botin" : "Can't be used for new Botins right now" }
        return summary.isEmpty ? (usageLabel ?? "") : summary
    }

    /// 读屏念的：名字、介绍（或不能用）、几个 Botin 在用。
    public func accessibilityLabel(_ language: DisplayLanguage = .current) -> String {
        var parts = [name]
        let detail = detail(language)
        if !detail.isEmpty { parts.append(detail) }
        if let usageLabel, usageLabel != detail { parts.append(usageLabel) }
        return parts.joined(separator: language == .chinese ? "，" : ", ")
    }
}

extension AgentInfo {
    /// 能不能拿它新建 Botin。目录（11.8）还没有“下架”“这个地区不能用”这类字段，现在只有没给接入方式的（不知道怎么
    /// 跑它）算不能用；服务端加了字段以后在这里接上，表单和选择器跟着变。
    public var canPowerNewBotin: Bool { !harnesses.isEmpty }
}

/// 新建 Botin 表单的文案（标题用 `AppRoute.adopt` 的“新建 Botin”）。
public enum NewBotinText {
    /// 底部的主按钮。
    public static func create(_ language: DisplayLanguage) -> String {
        language == .chinese ? "新建" : "Create"
    }

    /// 新建中（转圈的读屏文字）。
    public static func creating(_ language: DisplayLanguage) -> String {
        language == .chinese ? "正在新建" : "Creating"
    }

    public static func nameTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "Botin 的名字" : "Botin name"
    }

    /// 大号输入框里的占位字。
    public static func namePrompt(_ language: DisplayLanguage) -> String {
        language == .chinese ? "给 Botin 取个名字" : "Name your Botin"
    }

    /// 名字快到上限时输入框下面的提示（`AdoptionModel.nameNote`）。
    public static func nameHint(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "最多 \(InstanceNameRule.maxLength) 个字，之后可以改。"
            : "Up to \(InstanceNameRule.maxLength) characters. You can change it later."
    }

    public static func engineTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "引擎" : "Engine"
    }

    public static func harnessTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "接入方式" : "How it runs"
    }

    /// 去引擎目录看介绍、许可、版本的链接。
    public static func aboutEngines(_ language: DisplayLanguage) -> String {
        language == .chinese ? "了解引擎" : "About engines"
    }

    /// 头像的形状网格、色板（读屏的分组名）。
    public static func shapeTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "头像形状" : "Avatar shape"
    }

    public static func colorTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "头像颜色" : "Avatar color"
    }

    /// 底部按钮上面那一行小字：专有许可（目录给了许可说明）写“新建即表示同意 X 的许可条款”（同意的说法只给专有许可，
    /// 开源的不用同意什么）；别的写用的什么许可证。后面跟一个“查看”，打开 `licenseDetails` 的全文。
    public static func licenseCaption(_ agent: AgentInfo, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let name = AgentsText.displayName(of: agent)
        if requiresConsent(agent) {
            return zh ? "新建即表示同意 \(name) 的许可条款" : "By creating, you agree to the \(name) license terms"
        }
        let license = agent.license?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if license.isEmpty { return zh ? "\(name) 没有注明许可证" : "\(name) doesn't state a license" }
        let licenseName = AgentsText.licenseName(license, language: language)
        return zh ? "\(name) 采用 \(licenseName) 许可" : "\(name) is licensed under \(licenseName)"
    }

    /// 新建要同意许可条款：目录给了许可说明（专有许可才给，比如 Anthropic 的商业条款）。
    public static func requiresConsent(_ agent: AgentInfo) -> Bool {
        let note = agent.licenseNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !note.isEmpty
    }

    /// “查看”：打开许可条款的全文。
    public static func viewLicense(_ language: DisplayLanguage) -> String {
        language == .chinese ? "查看" : "View"
    }

    /// 许可条款全文那张小 sheet 的标题。
    public static func licenseTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "许可条款" : "License terms"
    }

    /// 许可条款全文（点“查看”看到的）：许可证（没写的不提），专有许可的许可说明和“新建即表示同意”，别的说一句在哪里
    /// 运行、模型请求发到哪。
    public static func licenseDetails(_ agent: AgentInfo, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        var parts: [String] = []
        if let license = agent.license?.trimmingCharacters(in: .whitespacesAndNewlines), !license.isEmpty {
            let name = AgentsText.licenseName(license, language: language)
            parts.append(zh ? "许可证：\(name)。" : "License: \(name).")
        }
        if requiresConsent(agent), let note = agent.licenseNote?.trimmingCharacters(in: .whitespacesAndNewlines) {
            parts.append(note)
            parts.append(
                zh ? "新建即表示你同意按上面的条款使用这个引擎。" : "By creating this Botin, you agree to use the engine under these terms.")
        } else {
            parts.append(
                zh
                    ? "Botin 在自己的沙箱里运行，模型请求只经平台的模型网关发给你配置的厂商。"
                    : "The Botin runs in its own sandbox, and model requests go only through the platform's model "
                        + "gateway to the vendor you configure.")
        }
        return parts.joined(separator: zh ? "" : " ")
    }

    /// 目录还没拉到（离线、出错）时引擎那一行。
    public static func enginesUnavailable(_ language: DisplayLanguage) -> String {
        language == .chinese ? "暂时拉不到引擎列表" : "Couldn't load the engines"
    }

    /// 目录里有引擎、但都不能用（没有选上的）：引擎菜单按钮上的字。
    public static func noUsableEngine(_ language: DisplayLanguage) -> String {
        language == .chinese ? "暂时没有能用的" : "None available"
    }

    /// 目录拉到了但是空的。
    public static func noEngines(_ language: DisplayLanguage) -> String {
        language == .chinese ? "还没有能用的引擎，稍后再来看看。" : "No engines are available yet. Check back later."
    }

    public static func offlineNote(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "离线时不能新建 Botin，联网后再试。" : "You can't create a Botin while offline. Try again once you're back online."
    }

    /// 填了名字又点 ×：确认框。
    public static func discardTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "不建这个 Botin 了？" : "Discard this Botin?"
    }

    public static func discard(_ language: DisplayLanguage) -> String {
        language == .chinese ? "不建了" : "Discard"
    }

    public static func keepEditing(_ language: DisplayLanguage) -> String {
        language == .chinese ? "继续填写" : "Keep Editing"
    }
}
