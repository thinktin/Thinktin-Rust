import Foundation

/// 模型 key、模型路由、用量（WBS 12.4）界面上的命名和文案：中英文都在这里，界面按 `DisplayLanguage` 取。
///
/// AI 生成标识（ios-packages.md 12.5 “AI 生成标识要有一张规则表”）：这几页上的文字都不是 agent 写的——
/// key 的备注、别名、上游模型名是用户填的，厂商名、推荐模型、厂商说明来自平台的厂商表（`vendors()`），实例名是用户起的，
/// 用量是模型网关的计量。所以这几页都不带 AI 生成标识（`showsAIGeneratedLabel` 恒为 false，测试里固定住，
/// 以后加了 agent 写的字段要改这里）。
public enum ModelsText {
    /// 这几页有没有要带 AI 生成标识的字段（见上面的说明）。
    public static let showsAIGeneratedLabel = false

    // MARK: 厂商与协议

    /// 厂商的显示名：预置厂商用厂商表里的名字，自定义地址写“自定义地址”，厂商表里没有的（下架了、没拉到）用 id。
    public static func vendorName(_ vendorID: String, vendors: [VendorInfo], language: DisplayLanguage = .current)
        -> String
    {
        if vendorID == NewCredential.customVendor { return customVendorName(language) }
        if let vendor = vendors.first(where: { $0.id == vendorID }) {
            let name = vendor.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return vendorID
    }

    /// “自定义地址”。
    public static func customVendorName(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "自定义地址" : "Custom endpoint"
    }

    /// 协议的显示名（和 Agent 目录里的一致）。
    public static func protocolName(_ modelProtocol: ModelProtocol) -> String {
        AgentsText.protocolName(modelProtocol)
    }

    /// 几个协议连起来（顺序按 `ModelProtocol.knownCases`，认不出的排后面）；没有协议（老的服务端）为 nil。
    public static func protocolList(_ protocols: [ModelProtocol], language: DisplayLanguage = .current) -> String? {
        guard !protocols.isEmpty else { return nil }
        let order = ModelProtocol.knownCases
        let sorted = protocols.sorted { a, b in
            (order.firstIndex(of: a) ?? order.count) < (order.firstIndex(of: b) ?? order.count)
        }
        var seen = Set<ModelProtocol>()
        let unique = sorted.filter { seen.insert($0).inserted }
        return AgentsText.list(unique.map(protocolName), language: language)
    }

    /// 头像上的字：厂商名的第一个字。不用厂商的标志。
    public static func monogram(_ name: String) -> String {
        AgentsText.monogram(of: name)
    }

    // MARK: key

    /// 每日上限：“每天最多 200 万 token” / “Up to 2M tokens a day”；没设为“不限”。
    public static func dailyLimit(_ limit: Int?, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        guard let limit else { return zh ? "不限" : "No limit" }
        let amount = Formatting.tokens(limit, language: language)
        return zh ? "每天最多 \(amount) token" : "Up to \(amount) tokens a day"
    }

    /// 启用状态的名字。
    public static func statusName(isDisabled: Bool, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        return isDisabled ? (zh ? "已停用" : "Disabled") : (zh ? "使用中" : "Active")
    }

    /// key 在界面上的名字：有备注用备注，没有用厂商名。
    public static func credentialName(
        _ credential: Credential, vendors: [VendorInfo], language: DisplayLanguage = .current
    )
        -> String
    {
        let label = credential.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? vendorName(credential.vendor, vendors: vendors, language: language) : label
    }

    /// 选 key 的菜单里的一项：“Claude 主力 · ••••Q7mA”。
    public static func credentialMenuTitle(
        _ credential: Credential, vendors: [VendorInfo], language: DisplayLanguage = .current
    )
        -> String
    {
        credentialName(credential, vendors: vendors, language: language) + " · " + credential.maskedKey
    }

    /// 添加、启用、换 key 后的说明（服务端会唤醒等 key 的运行，7.11：它们马上重试，key 能用才接着跑）。
    public static func wakeExplanation(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "添加、启用或换 key 之后，卡在“等待 key”的任务会马上重试，key 能用就接着跑。"
            : "After you add, enable or replace a key, tasks waiting for a key retry right away and continue if the "
                + "key works."
    }

    /// 每日上限只能在添加时设（服务端改不了）。
    public static func dailyLimitFootnote(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "用完当天的额度后，这把 key 当天不再用，降级链里有备用 key 时改用备用的。上限随时可以改，放宽或取消后等 key 的任务马上重试。"
            : "Once a day's budget is used up, the key is skipped for the rest of the day and fallbacks take over. You can "
                + "change the limit any time; raising or removing it lets tasks waiting for a key retry right away."
    }

    /// 别名里留着的停用 key 下面那句（11.9：实例原来就用着的可以留着）。
    public static func keptDisabledKeyNotice(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "这把 key 已经停用了，运行时会跳过它（有备用的改用备用）。可以先留着，也可以换一把。"
            : "This key is disabled, so it's skipped when tasks run (fallbacks take over). You can keep it here or "
                + "pick another."
    }

    // MARK: 别名

    /// 别名的标签：main 是“默认”，fast 是“轻量”，别的没有。
    public static func aliasTag(_ alias: String, language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch alias {
        case ModelRoute.mainAlias: return zh ? "默认" : "Default"
        case RouteRules.fastAlias: return zh ? "轻量" : "Light"
        default: return nil
        }
    }

    /// 别名是干什么用的。
    public static func aliasPurpose(_ alias: String, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch alias {
        case ModelRoute.mainAlias:
            return zh
                ? "默认模型：agent 平时都用它，必须配。"
                : "The default model. The agent uses it for everything unless told otherwise. Required."
        case RouteRules.fastAlias:
            return fastPurpose(language)
        default:
            return zh ? "agent 按这个名字调用的模型。" : "A model the agent calls by this name."
        }
    }

    /// fast 别名的用途（加 fast 的按钮下面也用）。
    public static func fastPurpose(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "可选。给轻量的活用的便宜、快的模型（起标题、写摘要、简单的子任务），对 Claude Agent 来说就是 Haiku 那一档。不配就都用 main。"
            : "Optional. A cheaper, faster model for light work such as titles, summaries and simple subtasks; for "
                + "Claude Agent this is the Haiku slot. Without it, everything uses main."
    }

    /// 降级链是什么。
    public static func fallbackExplanation(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "主 key 失效、欠费、被限流或连不上时，按顺序换用备用的，最多 \(ModelRoute.maxFallbacks) 个。"
            : "If the main key is invalid, out of credit, rate-limited or unreachable, these are tried in order "
                + "(up to \(ModelRoute.maxFallbacks))."
    }

    /// “备用 1”。
    public static func fallbackTitle(_ position: Int, language: DisplayLanguage = .current) -> String {
        language == .chinese ? "备用 \(position)" : "Fallback \(position)"
    }

    // MARK: 第三方 AI 数据共享（App Store 5.1.2(i)）

    /// 把对话、文件发给厂商处理的说明（添加 key 的勾选框、模型路由页的提示、保存前的确认都用它）。
    /// `vendorNames` 为空时说“你配置的模型厂商”。
    public static func dataSharingNotice(vendorNames: [String], language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let names =
            vendorNames.isEmpty
            ? (zh ? "你配置的模型厂商" : "the model vendors you set up")
            : AgentsText.list(
                vendorNames, language: language)
        return zh
            ? "用这把 key 的实例里，你的消息、文件和 agent 的产出会经 ThinkTin 的模型网关发给 \(names) 处理，受对方的服务条款和隐私政策约束。ThinkTin 不出售这些内容，也不拿它们训练模型。"
            : "In instances that use this key, your messages, files and the agent's output are sent through the ThinkTin "
                + "model gateway to \(names) for processing, under their terms of service and privacy policy. ThinkTin "
                + "doesn't sell this content or train models on it."
    }

    /// 勾选框那一句（添加 key 时要勾上才能保存）。
    public static func dataSharingConsent(vendorName: String, language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "我同意把这些内容发给 \(vendorName) 处理"
            : "I agree to send this content to \(vendorName) for processing"
    }

    /// 模型路由页上的提示：这个实例的对话发给哪些厂商。
    public static func routesDataSharing(
        instanceName: String, vendorNames: [String], language: DisplayLanguage = .current
    )
        -> String
    {
        let zh = language == .chinese
        if vendorNames.isEmpty {
            return zh
                ? "保存之后，“\(instanceName)”里的消息、文件和产出会发给你选的 key 所属的厂商处理。"
                : "Once saved, messages, files and output in “\(instanceName)” are sent to the vendors of the keys you pick."
        }
        let names = AgentsText.list(vendorNames, language: language)
        return zh
            ? "“\(instanceName)”里的消息、文件和产出会经模型网关发给 \(names) 处理，受对方的条款约束。"
            : "Messages, files and output in “\(instanceName)” are sent through the model gateway to \(names), under "
                + "their terms."
    }

    /// 保存路由前确认数据共享的那段话：说的是这个实例（不是某一把 key），再加上平台怎么对待这些内容。
    public static func routesConsentNotice(
        instanceName: String, vendorNames: [String], language: DisplayLanguage = .current
    ) -> String {
        let zh = language == .chinese
        return routesDataSharing(instanceName: instanceName, vendorNames: vendorNames, language: language)
            + (zh ? "ThinkTin 不出售这些内容，也不拿它们训练模型。" : " ThinkTin doesn't sell this content or train models on it.")
    }
}

// MARK: - 本地校验的规则（和服务端一致）

/// key 表单的规则（crates/gateway/src/routes/credentials.rs、crates/proto/src/vendors.rs 的 `check_key`）。
public enum CredentialRules {
    /// key 的字节数范围。
    public static let keyLength = 8...4096
    /// 接口地址的字符数范围。
    public static let baseURLLength = 9...512

    /// 粘贴时常带的首尾空白、换行去掉。
    public static func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// key 有什么问题；没问题为 nil。只能是可见的 ASCII 字符（会拼进请求头）。
    public static func keyProblem(_ key: String) -> CredentialFieldProblem? {
        let key = normalizedKey(key)
        if key.isEmpty { return .required }
        if key.utf8.contains(where: { !(0x21...0x7e).contains($0) }) { return .invalidCharacters }
        if key.utf8.count < keyLength.lowerBound { return .tooShort(min: keyLength.lowerBound) }
        if key.utf8.count > keyLength.upperBound { return .tooLong(max: keyLength.upperBound) }
        return nil
    }

    /// 自定义的接口地址有什么问题（空的算没填，不算问题）。只认 https。
    public static func baseURLProblem(_ base: String) -> CredentialFieldProblem? {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return nil }
        // 和服务端一样区分大小写：只认小写的 https://。
        guard base.hasPrefix("https://") else { return .notHTTPS }
        guard !base.contains(where: \.isWhitespace), let url = URL(string: base), url.host?.isEmpty == false
        else { return .invalidURL }
        if base.unicodeScalars.count > baseURLLength.upperBound { return .tooLong(max: baseURLLength.upperBound) }
        return nil
    }

    /// 备注有什么问题（可以为空）。
    public static func labelProblem(_ label: String) -> CredentialFieldProblem? {
        label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > Credential.maxLabelLength
            ? .tooLong(max: Credential.maxLabelLength) : nil
    }

    /// 每日上限：空的是不限；能写千分位逗号和空格。不是正整数为 `.failure`。
    public static func parseDailyLimit(_ text: String) -> Result<Int?, CredentialFieldProblem> {
        let digits = text.filter { !$0.isWhitespace && $0 != "," && $0 != "，" && $0 != "_" }
        if digits.isEmpty { return .success(nil) }
        guard digits.allSatisfy(\.isASCII), let value = Int(digits), value > 0 else {
            return .failure(.notPositiveInteger)
        }
        return .success(value)
    }
}

/// 表单里一个字段的问题。
public enum CredentialFieldProblem: Error, Hashable, Sendable {
    case required
    case tooShort(min: Int)
    case tooLong(max: Int)
    /// 有空格、换行、中文之类请求头放不下的字符。
    case invalidCharacters
    case notHTTPS
    case invalidURL
    case notPositiveInteger

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .required: return zh ? "这一项要填。" : "This is required."
        case .tooShort(let min): return zh ? "太短了，至少 \(min) 个字符。" : "Too short; at least \(min) characters."
        case .tooLong(let max): return zh ? "太长了，最多 \(max) 个字符。" : "Too long; at most \(max) characters."
        case .invalidCharacters:
            return zh ? "key 里不能有空格、换行或中文字符。" : "Keys can't contain spaces, line breaks or non-ASCII characters."
        case .notHTTPS: return zh ? "只支持 https:// 开头的地址。" : "Only https:// addresses are supported."
        case .invalidURL: return zh ? "地址格式不对。" : "This isn't a valid address."
        case .notPositiveInteger:
            return zh ? "填一个正整数（token 数），不限就留空。" : "Enter a whole number of tokens, or leave it empty."
        }
    }
}

/// 服务端拒收 key 或地址的原因（`invalid` 错误）。接口的说明是英文、给开发者看的，界面不显示它，只用来认出是哪种原因，
/// 再显示本地化的说明；认不出的按“填写的内容不正确”。
public enum CredentialRejection: Hashable, Sendable {
    /// 订阅类 key（编程套餐、Claude 订阅的 OAuth 令牌之类）：按厂商条款只能在它自己的工具里用，平台不能中转（9.12）。
    case subscriptionKey
    /// 套餐专用的接口地址（coding plan 之类）。`field` 是哪个地址。
    case planOnlyEndpoint(field: CredentialEndpointField?)
    /// 不是 https 的地址。
    case notHTTPS(field: CredentialEndpointField?)
    /// 地址的长度、格式不对。
    case invalidEndpoint(field: CredentialEndpointField)
    /// key 的长度或字符不对。
    case keyFormat
    /// 厂商表里没有这个厂商（下架了）。
    case unknownVendor
    /// 自定义地址才能填地址，自定义地址又必须填。
    case endpointMismatch
    /// 每日上限不对。
    case dailyLimit
    /// 备注太长。
    case label
    /// 别的 `invalid`。
    case other

    /// 从接口错误认出原因；不是 `invalid`（网络、限流……）的为 nil，照常用 `ErrorBanner` 显示。
    public init?(_ error: ClientError) {
        guard case .api(_, .invalid, let message, _) = error else { return nil }
        let text = message.lowercased()
        let field = CredentialEndpointField.allCases.first { text.hasPrefix($0.rawValue) }
        if text.contains("subscription key") {
            self = .subscriptionKey
        } else if text.contains("subscription plan address") || text.contains("coding or subscription") {
            self = .planOnlyEndpoint(field: field)
        } else if text.contains("https") {
            self = .notHTTPS(field: field)
        } else if let field {
            self = .invalidEndpoint(field: field)
        } else if text.contains("api_key") || text.contains("api key") {
            self = .keyFormat
        } else if text.contains("unknown vendor") {
            self = .unknownVendor
        } else if text.contains("base url") {
            self = .endpointMismatch
        } else if text.contains("daily_token_limit") {
            self = .dailyLimit
        } else if text.contains("label") {
            self = .label
        } else {
            self = .other
        }
    }

    /// 出问题的是 key 本身（显示在 key 输入框下面）。
    public var concernsKey: Bool {
        switch self {
        case .subscriptionKey, .keyFormat: true
        default: false
        }
    }

    public func message(vendorName: String, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .subscriptionKey:
            return zh
                ? "这是 \(vendorName) 的订阅类 key（编程套餐、会员订阅之类），按厂商的条款只能在它自己的工具里用，不能经第三方平台调用。请到厂商控制台创建按量计费的 API key。"
                : "This is a \(vendorName) subscription key (a coding plan or membership). Under the vendor's terms it "
                    + "only works in the vendor's own tools, not through third-party platforms. Create a pay-as-you-go "
                    + "API key in the vendor's console instead."
        case .planOnlyEndpoint(let field):
            let which = field.map { $0.title(language) } ?? (zh ? "这个地址" : "This address")
            return zh
                ? "\(which)是套餐专用的地址，只能在厂商自己的工具里用。请换成按量计费的接口地址。"
                : "\(which) is a plan-only address that works only in the vendor's own tools. Use the pay-as-you-go "
                    + "API address instead."
        case .notHTTPS(let field):
            let which = field.map { $0.title(language) } ?? (zh ? "接口地址" : "The address")
            return zh ? "\(which)只支持 https:// 开头的。" : "\(which) must start with https://."
        case .invalidEndpoint(let field):
            return zh
                ? "\(field.title(language))的格式不对（要 \(CredentialRules.baseURLLength.lowerBound) 到 \(CredentialRules.baseURLLength.upperBound) 个字符的 https 地址）。"
                : "\(field.title(language)) isn't valid (an https address of \(CredentialRules.baseURLLength.lowerBound)–"
                    + "\(CredentialRules.baseURLLength.upperBound) characters)."
        case .keyFormat:
            return zh
                ? "key 的格式不对：要 8 到 4096 个字符，不能有空格或换行。"
                : "The key format isn't valid: 8 to 4096 characters, no spaces or line breaks."
        case .unknownVendor:
            return zh ? "这个厂商暂时不能用了，请刷新后重新选。" : "This vendor isn't available any more. Refresh and pick again."
        case .endpointMismatch:
            return zh
                ? "只有“自定义地址”能填接口地址，而且至少要填一个。"
                : "Only a custom endpoint takes addresses, and it needs at least one."
        case .dailyLimit:
            return zh ? "每日上限要是正整数。" : "The daily limit must be a positive whole number."
        case .label:
            return zh
                ? "备注最多 \(Credential.maxLabelLength) 个字符。"
                : "Notes can be up to \(Credential.maxLabelLength) characters."
        case .other:
            return zh ? "填写的内容不正确，请检查后再试。" : "Some of the details aren't valid. Check them and try again."
        }
    }
}

/// 自定义厂商的三个接口地址。`rawValue` 是接口的字段名。
public enum CredentialEndpointField: String, CaseIterable, Hashable, Sendable {
    case anthropic = "anthropic_base"
    case openai = "openai_base"
    case responses = "responses_base"

    /// 填了这个地址的 key 能用的协议。
    public var modelProtocol: ModelProtocol {
        switch self {
        case .anthropic: .anthropic
        case .openai: .chat
        case .responses: .responses
        }
    }

    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .anthropic: return zh ? "Anthropic Messages 地址" : "Anthropic Messages address"
        case .openai: return zh ? "OpenAI Chat Completions 地址" : "OpenAI Chat Completions address"
        case .responses: return zh ? "OpenAI Responses 地址" : "OpenAI Responses address"
        }
    }

    /// 输入框里的示例。
    public var placeholder: String {
        switch self {
        case .anthropic: "https://api.example.com/anthropic"
        case .openai: "https://api.example.com/v1"
        case .responses: "https://api.example.com/v1"
        }
    }
}

// MARK: - 别名的规则

/// 模型别名的规则（服务端：crates/gateway/src/routes/instances.rs 的 `set_routes`、model_routes 表的 CHECK）。
public enum RouteRules {
    /// 轻量任务的别名。
    public static let fastAlias = "fast"
    /// 一个实例最多几个别名。
    public static let maxAliases = 16
    /// 别名最长几个字符。
    public static let maxAliasLength = 64
    /// 上游模型名的字符数范围。
    public static let modelLength = 1...128

    /// 别名合法：小写字母或数字开头，只有小写字母、数字、`.`、`_`、`-`，最长 64。
    public static func isValidAlias(_ alias: String) -> Bool {
        let scalars = Array(alias.unicodeScalars)
        guard let first = scalars.first, scalars.count <= maxAliasLength else { return false }
        func isLowerAlnum(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        guard isLowerAlnum(first) else { return false }
        return scalars.dropFirst().allSatisfy { isLowerAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// 输入的别名先规整一下：去掉首尾空白、转小写。
    public static func normalizedAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
