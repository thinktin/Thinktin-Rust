import Foundation

// 保险箱的另外两种条目和登录信息的“网站”（参考 58、60、61、94–99；规范 4.9.6、4.9.7、6.16）。ThinkTin 的保险箱接口只有
// 登录信息一种（名字、用途、账号、密码、能用的 Botin），卡片要“Botin 看不到完整卡号”的代填和 PCI 合规，联系信息要后端
// 加类型和结构化字段，网站要后端加字段（6.16）。这里先把表单照参考做出来：输入、格式、校验都在本地，保存弹“即将推出”
// （`SettingsComingSoon.saveCard` / `.saveContact`），登录信息的网站填了不保存（脚注说明）。不改 `ClientProtocol`。

/// 保险箱“+”菜单里的条目种类（参考 58）。
public enum VaultItemKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 登录信息：现在唯一能存的。
    case login
    /// 卡片（参考 60）。
    case card
    /// 联系信息（参考 61）。
    case contact

    public var id: String { rawValue }

    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .login: return zh ? "登录信息" : "Sign-in"
        case .card: return zh ? "卡" : "Card"
        case .contact: return zh ? "联系信息" : "Contact info"
        }
    }

    /// 菜单项的 SF Symbol。
    public var systemImage: String {
        switch self {
        case .login: "key"
        case .card: "creditcard"
        case .contact: "person.crop.circle"
        }
    }

    /// 新建表单的标题（参考 59、60、61）。
    public func newTitle(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .login: return zh ? "新登录信息" : "New sign-in"
        case .card: return zh ? "新卡片" : "New card"
        case .contact: return zh ? "新建联系信息" : "New contact info"
        }
    }

    /// 现在能不能真的存（只有登录信息有接口）。
    public var isSupported: Bool { self == .login }
}

/// 一格可以有好几个值的字段（登录信息的网站、联系信息的电话和邮箱）：第一个是首选，可以加、删、设为首选。
public struct VaultFieldList: Hashable, Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public var value: String

        public init(id: Int, value: String = "") {
            self.id = id
            self.value = value
        }
    }

    /// 最多几个。
    public let limit: Int
    public private(set) var entries: [Entry]
    private var nextID: Int

    /// 一开始有一个空的。
    public init(limit: Int = 5, values: [String] = [""]) {
        self.limit = max(1, limit)
        let values = values.isEmpty ? [""] : Array(values.prefix(self.limit))
        self.entries = values.enumerated().map { Entry(id: $0.offset, value: $0.element) }
        self.nextID = values.count
    }

    public var canAdd: Bool { entries.count < limit }

    /// 在最后加一个空的；满了不加。返回新的那个的 id。
    @discardableResult
    public mutating func add() -> Int? {
        guard canAdd else { return nil }
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id))
        return id
    }

    /// 删掉一个；只剩一个时不删（留一个空的输入框）。
    public mutating func remove(_ id: Int) {
        guard entries.count > 1 else { return }
        entries.removeAll { $0.id == id }
    }

    /// 挪到第一个（参考 97 的“设为首选”）。
    public mutating func makePrimary(_ id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
    }

    public mutating func update(_ id: Int, to value: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].value = value
    }

    public func value(of id: Int) -> String {
        entries.first { $0.id == id }?.value ?? ""
    }

    /// 是不是第一个（首选）。
    public func isPrimary(_ id: Int) -> Bool { entries.first?.id == id }

    /// 填了的值（去掉首尾空白、空的不要）。
    public var filledValues: [String] {
        entries.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// 网站字段（参考 99）：没写协议的按 https 补上；要有带点的主机名。
public enum VaultWebsiteRules {
    /// 规范化成网址；不像网址时为 nil。
    public static func normalized(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let lower = trimmed.lowercased()
        let candidate = lower.hasPrefix("http://") || lower.hasPrefix("https://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, host.contains("."),
            !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }

    /// 填了但不像网址的那几个（脚注标红）。
    public static func invalidEntries(_ list: VaultFieldList) -> [Int] {
        list.entries.filter { entry in
            !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalized(entry.value) == nil
        }.map(\.id)
    }
}

/// 地址（卡片的账单地址、联系信息的地址，参考 95、96、98）。
public struct VaultPostalAddress: Hashable, Sendable {
    public var country = ""
    public var street = ""
    /// 公寓或单元（可选）。
    public var unit = ""
    public var city = ""
    /// 州 / 省。
    public var region = ""
    public var postalCode = ""

    public init() {}

    /// 什么都没填。
    public var isEmpty: Bool {
        [country, street, unit, city, region, postalCode].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 够用了：至少有街道和城市。
    public var isUsable: Bool {
        !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 卡片的账单地址怎么填（参考 94：菜单里“新地址”）。
public enum VaultBillingAddressChoice: String, CaseIterable, Hashable, Sendable {
    /// 不填（可选）。
    case none
    /// 填一个新地址（表单里多出一组地址，参考 95）。
    case newAddress
}

/// 新卡片的表单（参考 60、94–96）。卡号、有效期必填，其余可选。
public struct VaultCardDraft: Hashable, Sendable {
    /// 卡号最多几位数字（ISO/IEC 7812）。
    public static let maxDigits = 19
    /// 卡号最少几位数字。
    public static let minDigits = 12

    public var number = ""
    public var expiry = ""
    public var securityCode = ""
    public var holder = ""
    public var nickname = ""
    public var billing: VaultBillingAddressChoice = .none
    public var address = VaultPostalAddress()
    public var notes = ""

    public init() {}

    /// 卡号里的数字。
    public var digits: String { String(number.filter(\.isASCIIDigit).prefix(Self.maxDigits)) }

    /// 输入时整理卡号：只留数字，每 4 位空一格（“1234 5678 9012 3456”）。
    public static func formatNumber(_ text: String) -> String {
        let digits = text.filter(\.isASCIIDigit).prefix(maxDigits)
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && index % 4 == 0 { result.append(" ") }
            result.append(digit)
        }
        return result
    }

    /// 输入时整理有效期：只留数字，“MMYY” 写成 “MM / YY”。
    public static func formatExpiry(_ text: String) -> String {
        let digits = String(text.filter(\.isASCIIDigit).prefix(4))
        guard digits.count > 2 else { return digits }
        return "\(digits.prefix(2)) / \(digits.dropFirst(2))"
    }

    /// 安全码只留 3–4 位数字。
    public static func formatSecurityCode(_ text: String) -> String {
        String(text.filter(\.isASCIIDigit).prefix(4))
    }

    /// Luhn 校验（卡号最后一位是校验位）。
    public static func passesLuhn(_ digits: String) -> Bool {
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return false }
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    public var isNumberValid: Bool {
        (Self.minDigits...Self.maxDigits).contains(digits.count) && Self.passesLuhn(digits)
    }

    /// 有效期的月和年（两位）：格式不对为 nil。
    public var expiryParts: (month: Int, year: Int)? {
        let digits = expiry.filter(\.isASCIIDigit)
        guard digits.count == 4, let month = Int(digits.prefix(2)), let year = Int(digits.suffix(2)),
            (1...12).contains(month)
        else { return nil }
        return (month, year)
    }

    /// 有效期没过：`now` 所在的月份还算有效。
    public func isExpiryValid(now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let parts = expiryParts else { return false }
        let today = calendar.dateComponents([.year, .month], from: now)
        guard let year = today.year, let month = today.month else { return false }
        let current = (year % 100) * 12 + month
        return parts.year * 12 + parts.month >= current
    }

    public var isSecurityCodeValid: Bool {
        securityCode.isEmpty || (3...4).contains(securityCode.filter(\.isASCIIDigit).count)
    }

    /// 底部“添加卡片”能不能点（参考 60：空的时候灰）。
    public func canSave(now: Date = Date()) -> Bool {
        isNumberValid && isExpiryValid(now: now) && isSecurityCodeValid
            && (billing == .none || address.isUsable)
    }

    /// 卡号的后 4 位（列表里只显示这几位）。
    public var lastFour: String { String(digits.suffix(4)) }
}

/// 新联系信息的表单（参考 61、97、98）：标签、姓名、电话（可多个）、邮箱（可多个）、地址、提示。
public struct VaultContactDraft: Hashable, Sendable {
    public var label = ""
    public var name = ""
    public var phones = VaultFieldList()
    public var emails = VaultFieldList()
    public var address = VaultPostalAddress()
    public var notes = ""

    public init() {}

    /// 至少有电话、邮箱、地址里的一样（参考 61 的脚注）。
    public var hasContactMethod: Bool {
        !phones.filledValues.isEmpty || !emails.filledValues.isEmpty || address.isUsable
    }

    /// 填了但不像邮箱的那几个。
    public var invalidEmails: [Int] {
        emails.entries.filter { entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !Self.looksLikeEmail(value)
        }.map(\.id)
    }

    /// 底部“保存联系信息”能不能点。
    public var canSave: Bool { hasContactMethod && invalidEmails.isEmpty }

    /// 粗查邮箱：一个 @，前后都有字，域名里有点。
    public static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

/// 卡片、联系信息、网站的文案（参考 58–61、94–99）。
public enum VaultExtraText {
    /// “+”菜单的读屏标签。
    public static func addMenu(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "新建条目" : "New item"
    }

    /// 菜单里还不能存的种类的副标题。
    public static func comingSoonSubtitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出" : "Coming soon"
    }

    // MARK: 网站（参考 99）

    public static func website(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "网站" : "Website"
    }

    public static func addWebsite(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加网站" : "Add website"
    }

    public static func remove(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "移除" : "Remove"
    }

    public static let websitePlaceholder = "https://example.com"

    /// 网站那组的脚注：现在不保存。
    public static func websitesFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "网站即将推出：Botin 以后能按网站找到这一条。现在填了不会保存。"
            : "Websites are coming soon so Botins can find this sign-in by site. What you enter here isn't saved yet."
    }

    public static func invalidWebsite(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "网址看起来不对，比如 https://example.com。" : "That doesn't look like a web address, e.g. https://example.com."
    }

    // MARK: 卡片（参考 60、94–96）

    public static func cardNumber(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "卡号" : "Card number"
    }

    public static func expiry(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "有效期" : "Expiry"
    }

    public static func securityCode(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "安全码" : "Security code"
    }

    public static func holder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "持卡人姓名" : "Name on card"
    }

    public static func nickname(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "备注名" : "Nickname"
    }

    public static func nicknamePlaceholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "比如：出差用" : "e.g. Travel"
    }

    public static func billingAddress(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "账单地址" : "Billing address"
    }

    public static func billingChoice(_ choice: VaultBillingAddressChoice, language: DisplayLanguage = .current)
        -> String
    {
        let zh = language == .chinese
        switch choice {
        case .none: return zh ? "不填" : "None"
        case .newAddress: return zh ? "新地址" : "New address"
        }
    }

    public static let cardNumberPlaceholder = "1234 5678 9012 3456"
    public static let expiryPlaceholder = "MM / YY"

    /// 卡片第一组的脚注（参考 60）。
    public static func cardFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "Botin 永远看不到你的完整卡号和安全码。" : "Botins never see your full card number or security code."
    }

    /// 卡片的字段有问题时脚注换成的话。
    public static func cardProblem(_ draft: VaultCardDraft, now: Date = Date(), language: DisplayLanguage = .current)
        -> String?
    {
        let zh = language == .chinese
        if !draft.digits.isEmpty && draft.digits.count >= VaultCardDraft.minDigits && !draft.isNumberValid {
            return zh ? "卡号看起来不对，再核对一下。" : "That card number doesn't look right."
        }
        if draft.expiry.filter(\.isASCIIDigit).count == 4 && !draft.isExpiryValid(now: now) {
            return draft.expiryParts == nil
                ? (zh ? "有效期写成 MM / YY。" : "Write the expiry as MM / YY.")
                : (zh ? "这张卡已经过期了。" : "This card has expired.")
        }
        if !draft.isSecurityCodeValid {
            return zh ? "安全码是 3 或 4 位数字。" : "The security code is 3 or 4 digits."
        }
        return nil
    }

    /// 扫描卡片按钮的读屏标签。
    public static func scanCard(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "扫描卡片" : "Scan card"
    }

    /// 底部全宽按钮（参考 60）。
    public static func addCard(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加卡片" : "Add card"
    }

    // MARK: 地址（参考 95、96、98）

    public static func addressHeader(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "地址" : "Address"
    }

    public static func country(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "国家/地区" : "Country/Region"
    }

    public static func countryPlaceholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "中国" : "China"
    }

    public static func street(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "街道" : "Street"
    }

    public static func streetPlaceholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "街道地址" : "Street address"
    }

    public static func unit(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "公寓或单元" : "Apt or unit"
    }

    public static func city(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "城市" : "City"
    }

    public static func region(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "州/省" : "State/Province"
    }

    public static func postalCode(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "邮政编码" : "Postal code"
    }

    // MARK: 联系信息（参考 61、97、98）

    public static func label(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "标签" : "Label"
    }

    public static func labelPlaceholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "家" : "Home"
    }

    public static func name(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "姓名" : "Name"
    }

    /// 第一个电话叫“手机”，后面的叫“电话 2”“电话 3”（参考 97）。
    public static func phone(index: Int, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        if index == 0 { return zh ? "手机" : "Mobile" }
        return zh ? "电话 \(index + 1)" : "Phone \(index + 1)"
    }

    /// 第一个邮箱叫“邮箱”，后面的叫“邮箱 2”。
    public static func email(index: Int, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        if index == 0 { return zh ? "邮箱" : "Email" }
        return zh ? "邮箱 \(index + 1)" : "Email \(index + 1)"
    }

    public static let phonePlaceholder = "138 0000 0000"
    public static let emailPlaceholder = "name@example.com"

    public static func addPhone(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加电话" : "Add phone"
    }

    public static func addEmail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加邮箱" : "Add email"
    }

    public static func makePrimary(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "设为首选" : "Make primary"
    }

    /// 联系信息第一组的脚注（参考 61）。
    public static func contactFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "联系信息至少要有地址、电话或邮箱中的一项。" : "Contact info needs at least an address, a phone number or an email."
    }

    public static func invalidEmail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "邮箱看起来不对。" : "That email doesn't look right."
    }

    /// 底部全宽按钮（参考 61）。
    public static func saveContact(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "保存联系信息" : "Save contact info"
    }

    // MARK: 提示（参考 60、61 的最后一组）

    public static func notes(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "提示" : "Notes"
    }
}

extension Character {
    /// ASCII 的 0–9（`isNumber` 还算全角数字、汉字数字，卡号里不要）。
    fileprivate var isASCIIDigit: Bool { isASCII && isWholeNumber }
}
