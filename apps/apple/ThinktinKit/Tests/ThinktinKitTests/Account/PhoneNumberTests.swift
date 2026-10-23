import Foundation
import Testing

@testable import ThinktinKit

// 区号、手机号整理、验证码、重发倒计时（WBS 12.2）。规则和服务端 crates/auth/src/secrets.rs 的 normalize_phone 一致。

@Suite("区号与手机号")
struct PhoneNumberTests {
    private let cn = PhoneRegion.mainland
    private let hk = PhoneRegion.region(id: "HK")!
    private let us = PhoneRegion.region(id: "US")!
    private let ca = PhoneRegion.region(id: "CA")!
    private let gb = PhoneRegion.region(id: "GB")!
    private let tw = PhoneRegion.region(id: "TW")!

    @Test("默认中国大陆 +86；列表里 ISO 代码不重复，中国大陆、港澳台在前")
    func regions() {
        #expect(cn.dialCodeText == "+86")
        #expect(PhoneRegion.all.first == cn)
        #expect(PhoneRegion.all.prefix(4).map(\.id) == ["CN", "HK", "MO", "TW"])
        #expect(Set(PhoneRegion.all.map(\.id)).count == PhoneRegion.all.count)
        #expect(hk.name(.chinese) == "中国香港")
        #expect(hk.name(.english) == "Hong Kong, China")
        #expect(PhoneRegion.region(id: "hk") == hk)
        #expect(PhoneRegion.region(id: "XX") == nil)
    }

    @Test("搜索：中英文名字、区号（可以带 +）、ISO 代码")
    func search() {
        #expect(hk.matches("香港"))
        #expect(hk.matches("hong"))
        #expect(hk.matches("+852"))
        #expect(hk.matches("85"))
        #expect(hk.matches("HK"))
        #expect(hk.matches("  "))
        #expect(!hk.matches("日本"))
        #expect(!hk.matches("+86"))
        #expect(PhoneRegion.all.filter { $0.matches("+1") }.map(\.id) == ["US", "CA"])
    }

    @Test("只留数字：空格、横线、全角数字、字母都去掉，最多 15 位")
    func digitsOnly() {
        #expect(PhoneNumberInput.normalize("138-0013 8000", region: cn) == (cn, "13800138000"))
        #expect(PhoneNumberInput.normalize("(138)abc", region: cn).text == "138")
        #expect(PhoneNumberInput.normalize("１３８", region: cn).text == "")
        #expect(PhoneNumberInput.normalize(String(repeating: "1", count: 20), region: cn).text.count == 15)
    }

    @Test("粘贴、自动填充带区号的号码：切到对应的区号，框里只留本地号码")
    func pasteWithCountryCode() {
        #expect(PhoneNumberInput.normalize("+86 138 0013 8000", region: hk) == (cn, "13800138000"))
        #expect(PhoneNumberInput.normalize("+852 9123 4567", region: cn) == (hk, "91234567"))
        #expect(PhoneNumberInput.normalize("＋852 9123 4567", region: cn) == (hk, "91234567"))
        // 区号相同的优先正在选着的。
        #expect(PhoneNumberInput.normalize("+1 416 555 0123", region: ca) == (ca, "4165550123"))
        #expect(PhoneNumberInput.normalize("+1 415 555 0123", region: cn) == (us, "4155550123"))
        // 认不出的区号、只输了“+”：原样留着。
        #expect(PhoneNumberInput.normalize("+999 1234 5678", region: cn) == (cn, "+99912345678"))
        #expect(PhoneNumberInput.normalize("+", region: cn) == (cn, "+"))
        #expect(PhoneNumberInput.normalize("+86", region: hk) == (hk, "+86"))
    }

    @Test("E.164：中国大陆 11 位、以 1 开头；去掉本地的 0；认不出区号的按 8 到 15 位")
    func e164() {
        #expect(PhoneNumberInput.e164("13800138000", region: cn) == "+8613800138000")
        #expect(PhoneNumberInput.e164("1380013800", region: cn) == nil)
        #expect(PhoneNumberInput.e164("23800138000", region: cn) == nil)
        #expect(PhoneNumberInput.e164("", region: cn) == nil)
        #expect(PhoneNumberInput.e164("91234567", region: hk) == "+85291234567")
        #expect(PhoneNumberInput.e164("9123456", region: hk) == nil)
        #expect(PhoneNumberInput.e164("07911123456", region: gb) == "+447911123456")
        #expect(PhoneNumberInput.e164("7911123456", region: gb) == "+447911123456")
        #expect(PhoneNumberInput.e164("0912345678", region: tw) == "+886912345678")
        #expect(PhoneNumberInput.e164("4155550123", region: us) == "+14155550123")
        #expect(PhoneNumberInput.e164("+99912345678", region: cn) == "+99912345678")
        #expect(PhoneNumberInput.e164("+9991234", region: cn) == nil)
        #expect(PhoneNumberInput.e164("+0123456789", region: cn) == nil)
        #expect(PhoneNumberInput.e164("+", region: cn) == nil)
        // 带“+”但认得出区号的，按那里的位数查。
        #expect(PhoneNumberInput.e164("+861380013800", region: cn) == nil)
    }

    @Test("给人看的号码：中国大陆 3-4-4 分组")
    func display() {
        #expect(PhoneNumberInput.display("13800138000", region: cn) == "+86 138 0013 8000")
        #expect(PhoneNumberInput.display("91234567", region: hk) == "+852 91234567")
        #expect(PhoneNumberInput.display("+99912345678", region: cn) == "+99912345678")
        #expect(SignInModel.display(e164: "+8613800138000", region: cn) == "+86 138 0013 8000")
        #expect(SignInModel.display(e164: "+14165550123", region: ca) == "+1 4165550123")
    }

    @Test("验证码：只留 ASCII 数字，最多 6 位")
    func verificationCode() {
        #expect(VerificationCode.sanitize("123 456") == "123456")
        #expect(VerificationCode.sanitize("1234567") == "123456")
        #expect(VerificationCode.sanitize("12a3") == "123")
        #expect(VerificationCode.sanitize("１２３") == "")
        #expect(VerificationCode.isComplete("123456"))
        #expect(!VerificationCode.isComplete("12345"))
        #expect(!VerificationCode.isComplete("12345a"))
    }

    @Test("重发倒计时：向上取整，限流的更晚就不提前，可以清掉")
    func cooldown() {
        let t0 = Fixture.now
        var cooldown = CodeCooldown()
        #expect(cooldown.remainingSeconds(at: t0) == 0)
        #expect(!cooldown.isWaiting(at: t0))
        cooldown.start(at: t0)
        #expect(cooldown.remainingSeconds(at: t0) == 60)
        #expect(cooldown.remainingSeconds(at: t0.addingTimeInterval(0.5)) == 60)
        #expect(cooldown.remainingSeconds(at: t0.addingTimeInterval(59.2)) == 1)
        #expect(cooldown.remainingSeconds(at: t0.addingTimeInterval(60)) == 0)
        cooldown.start(at: t0, seconds: 3600)
        cooldown.start(at: t0.addingTimeInterval(1))
        #expect(cooldown.remainingSeconds(at: t0) == 3600)
        cooldown.reset()
        #expect(cooldown.availableAt == nil)
        cooldown.start(at: t0, seconds: -5)
        #expect(cooldown.remainingSeconds(at: t0) == 0)
    }
}
