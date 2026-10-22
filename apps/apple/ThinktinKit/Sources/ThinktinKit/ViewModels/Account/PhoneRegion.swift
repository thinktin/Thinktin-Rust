import Foundation

/// 登录页的国家 / 地区区号（WBS 12.2）。默认中国大陆 +86；4.1 已接国际和港澳台的短信模板，其他区号的号码也能收到验证码。
///
/// 名字的写法照国内的规范：中国香港、中国澳门、中国台湾。列表只放常用的几个，不在列表里的号码可以直接输“+区号号码”
/// （`PhoneNumberInput` 按 E.164 处理）。
public struct PhoneRegion: Identifiable, Hashable, Sendable {
    /// ISO 3166-1 的两位代码（`CN`、`HK`）。区号相同的（美国、加拿大都是 +1）靠它区分。
    public var id: String
    /// 区号，不带 `+`（`86`）。
    public var dialCode: String
    public var chineseName: String
    public var englishName: String
    /// 本地号码（不含区号）有几位。
    public var nationalLength: ClosedRange<Int>
    /// 本地习惯在号码前加一个 0（英国的 07…、日本的 090…）：拼 E.164 时去掉。
    public var dropsTrunkZero: Bool

    public init(
        id: String, dialCode: String, chineseName: String, englishName: String, nationalLength: ClosedRange<Int>,
        dropsTrunkZero: Bool = false
    ) {
        self.id = id
        self.dialCode = dialCode
        self.chineseName = chineseName
        self.englishName = englishName
        self.nationalLength = nationalLength
        self.dropsTrunkZero = dropsTrunkZero
    }

    /// 界面上的名字。
    public func name(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? chineseName : englishName
    }

    /// `+86`。
    public var dialCodeText: String { "+" + dialCode }

    /// 搜索：名字（中英文）、区号、ISO 代码里有没有这段文字（不分大小写，可以带 `+`）。
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let digits = q.hasPrefix("+") ? String(q.dropFirst()) : q
        return chineseName.lowercased().contains(q) || englishName.lowercased().contains(q)
            || id.lowercased() == q || (!digits.isEmpty && dialCode.hasPrefix(digits))
    }

    /// 本地号码去掉开头的 0（`dropsTrunkZero` 时）之后的数字。
    public func nationalDigits(_ national: String) -> String {
        var digits = PhoneNumberInput.asciiDigits(national)
        if dropsTrunkZero, digits.hasPrefix("0") { digits.removeFirst() }
        return digits
    }

    /// 本地号码对不对（位数，中国大陆还要以 1 开头）。
    public func isValidNational(_ national: String) -> Bool {
        let digits = nationalDigits(national)
        guard nationalLength.contains(digits.count) else { return false }
        if id == "CN" { return digits.hasPrefix("1") }
        return true
    }

    /// 号码给人看的样子：中国大陆按 3-4-4 分组（`138 0013 8000`），其余原样。
    public func formatted(national: String) -> String {
        let digits = nationalDigits(national)
        guard id == "CN", digits.count == 11 else { return digits }
        let a = digits.prefix(3)
        let b = digits.dropFirst(3).prefix(4)
        let c = digits.suffix(4)
        return "\(a) \(b) \(c)"
    }
}

extension PhoneRegion {
    /// 中国大陆（默认）。
    public static let mainland = PhoneRegion(
        id: "CN", dialCode: "86", chineseName: "中国大陆", englishName: "Mainland China", nationalLength: 11...11)

    /// 列表里的国家和地区：中国大陆、港澳台在前，其余按常用程度。
    public static let all: [PhoneRegion] = [
        mainland,
        PhoneRegion(
            id: "HK", dialCode: "852", chineseName: "中国香港", englishName: "Hong Kong, China", nationalLength: 8...8),
        PhoneRegion(id: "MO", dialCode: "853", chineseName: "中国澳门", englishName: "Macao, China", nationalLength: 8...8),
        PhoneRegion(
            id: "TW", dialCode: "886", chineseName: "中国台湾", englishName: "Taiwan, China", nationalLength: 9...9,
            dropsTrunkZero: true),
        PhoneRegion(id: "US", dialCode: "1", chineseName: "美国", englishName: "United States", nationalLength: 10...10),
        PhoneRegion(id: "CA", dialCode: "1", chineseName: "加拿大", englishName: "Canada", nationalLength: 10...10),
        PhoneRegion(id: "SG", dialCode: "65", chineseName: "新加坡", englishName: "Singapore", nationalLength: 8...8),
        PhoneRegion(
            id: "JP", dialCode: "81", chineseName: "日本", englishName: "Japan", nationalLength: 9...10,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "KR", dialCode: "82", chineseName: "韩国", englishName: "South Korea", nationalLength: 9...10,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "MY", dialCode: "60", chineseName: "马来西亚", englishName: "Malaysia", nationalLength: 9...10,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "TH", dialCode: "66", chineseName: "泰国", englishName: "Thailand", nationalLength: 9...9,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "GB", dialCode: "44", chineseName: "英国", englishName: "United Kingdom", nationalLength: 10...10,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "DE", dialCode: "49", chineseName: "德国", englishName: "Germany", nationalLength: 10...11,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "FR", dialCode: "33", chineseName: "法国", englishName: "France", nationalLength: 9...9,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "AU", dialCode: "61", chineseName: "澳大利亚", englishName: "Australia", nationalLength: 9...9,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "NZ", dialCode: "64", chineseName: "新西兰", englishName: "New Zealand", nationalLength: 8...10,
            dropsTrunkZero: true),
        PhoneRegion(
            id: "AE", dialCode: "971", chineseName: "阿联酋", englishName: "United Arab Emirates", nationalLength: 9...9,
            dropsTrunkZero: true),
    ]

    /// 按 ISO 代码找。
    public static func region(id: String) -> PhoneRegion? {
        all.first { $0.id == id.uppercased() }
    }

    /// `E.164` 的数字（不带 `+`）开头是哪个区号：取最长的匹配；区号相同的几个里优先 `preferred`
    /// （正在选着加拿大时粘贴 +1 的号码，不跳回美国）。
    public static func matching(e164Digits digits: String, preferred: PhoneRegion? = nil) -> PhoneRegion? {
        let candidates = all.filter { digits.hasPrefix($0.dialCode) }
        guard let longest = candidates.map(\.dialCode.count).max() else { return nil }
        let best = candidates.filter { $0.dialCode.count == longest }
        if let preferred, best.contains(preferred) { return preferred }
        return best.first
    }
}

/// 手机号输入框里的内容怎么变成登录用的号码（E.164，`+8613800138000`）。纯函数，测试里直接调。
///
/// - 只认 ASCII 数字，空格、横线、括号都去掉（粘贴来的“138-0013-8000”照样能用）；
/// - 以 `+` 开头的当成带区号的完整号码：认得出区号就切到那个国家或地区、框里只留本地号码（系统自动填充的
///   手机号带 +86），认不出的照原样当 E.164 用（列表里没有的国家）；
/// - 和服务端的规则一致（crates/auth/src/secrets.rs `normalize_phone`）：E.164 是 `+` 加 8 到 15 位数字，不以 0 开头。
public enum PhoneNumberInput {
    /// E.164 最多几位数字（不含 `+`）。
    public static let maxDigits = 15
    /// E.164 最少几位数字。
    public static let minDigits = 8

    /// 只留 ASCII 的 0–9（全角数字、字母、符号都去掉）。
    public static func asciiDigits(_ text: String) -> String {
        String(text.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))
    }

    /// 用户输入了（或粘贴了）`text`：返回整理后的区号和框里该显示的文字。
    ///
    /// 以 `+` 开头、认得出区号的：切换区号，框里只留本地号码；认不出的：框里留“+数字”。其余只留数字。
    /// 都截到最多 15 位数字。
    public static func normalize(_ text: String, region: PhoneRegion) -> (region: PhoneRegion, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = String(asciiDigits(trimmed).prefix(maxDigits))
        guard trimmed.hasPrefix("+") || trimmed.hasPrefix("＋") else { return (region, digits) }
        guard let match = PhoneRegion.matching(e164Digits: digits, preferred: region),
            digits.count > match.dialCode.count
        else {
            // 只输了一个“+”或者区号还没输完，先原样留着。
            return (region, "+" + digits)
        }
        return (match, String(digits.dropFirst(match.dialCode.count)))
    }

    /// 框里的文字（`normalize` 整理过的）在这个区号下对应的 E.164；不像手机号时为 nil。
    public static func e164(_ text: String, region: PhoneRegion) -> String? {
        if text.hasPrefix("+") {
            let digits = asciiDigits(text)
            guard (minDigits...maxDigits).contains(digits.count), !digits.hasPrefix("0") else { return nil }
            // 认得出区号的按那个国家或地区的规则查位数。
            if let match = PhoneRegion.matching(e164Digits: digits),
                !match.isValidNational(String(digits.dropFirst(match.dialCode.count)))
            {
                return nil
            }
            return "+" + digits
        }
        guard region.isValidNational(text) else { return nil }
        let e164 = "+" + region.dialCode + region.nationalDigits(text)
        return (minDigits...maxDigits).contains(e164.count - 1) ? e164 : nil
    }

    /// 给人看的完整号码：“+86 138 0013 8000”。
    public static func display(_ text: String, region: PhoneRegion) -> String {
        if text.hasPrefix("+") { return "+" + asciiDigits(text) }
        return region.dialCodeText + " " + region.formatted(national: text)
    }
}

/// 短信验证码（6 位数字，服务端 crates/auth/src/secrets.rs `generate_code`）。
public enum VerificationCode {
    public static let length = 6

    /// 只留 ASCII 数字，最多 6 位（粘贴来的“123 456”、自动填充的都能用）。
    public static func sanitize(_ text: String) -> String {
        String(PhoneNumberInput.asciiDigits(text).prefix(length))
    }

    public static func isComplete(_ code: String) -> Bool {
        code.count == length && code == sanitize(code)
    }
}

/// 发验证码之后多久才能再发（服务端 `code_resend_interval` 是 60 秒；限流时按 `Retry-After`）。
/// 只记“什么时候能再发”，剩几秒按传进来的时间算，界面每秒刷新一次（`TimelineView`），测试传固定的时间。
public struct CodeCooldown: Hashable, Sendable {
    /// 服务端两次发码的最短间隔（秒）。
    public static let resendInterval: TimeInterval = 60

    /// 到这个时间才能再发；nil 表示现在就能发。
    public private(set) var availableAt: Date?

    public init(availableAt: Date? = nil) {
        self.availableAt = availableAt
    }

    /// 刚发了（或者被限流了）：`seconds` 秒之后才能再发。已经在倒计时、而且比这个晚的，不提前。
    public mutating func start(at now: Date, seconds: TimeInterval = CodeCooldown.resendInterval) {
        let next = now.addingTimeInterval(max(0, seconds))
        if let current = availableAt, current > next { return }
        availableAt = next
    }

    public mutating func reset() {
        availableAt = nil
    }

    /// 还要等几秒（向上取整）；能发了是 0。
    public func remainingSeconds(at now: Date) -> Int {
        guard let availableAt else { return 0 }
        return max(0, Int(availableAt.timeIntervalSince(now).rounded(.up)))
    }

    public func isWaiting(at now: Date) -> Bool { remainingSeconds(at: now) > 0 }
}
