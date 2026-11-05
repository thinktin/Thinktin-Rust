import Foundation
import Testing

@testable import ThinktinKit

// 保险箱的卡片、联系信息、登录信息的网站（参考 58、60、61、94–99；规范 4.9.6、4.9.7）：本地的输入整理和校验。

@Suite("保险箱的卡片、联系信息、网站")
struct VaultExtraFormsTests {
    @Test("“+”菜单：登录信息、卡、联系信息；只有登录信息能存")
    func kinds() {
        #expect(VaultItemKind.allCases == [.login, .card, .contact])
        #expect(VaultItemKind.allCases.filter(\.isSupported) == [.login])
        #expect(VaultItemKind.card.newTitle(.chinese) == "新卡片")
        #expect(VaultItemKind.contact.newTitle(.chinese) == "新建联系信息")
        #expect(VaultItemKind.login.newTitle(.chinese) == "新登录信息")
        #expect(Set(VaultItemKind.allCases.map(\.systemImage)).count == 3)
    }

    @Test("多值字段：加到上限、删到剩一个、设为首选")
    func fieldList() {
        var list = VaultFieldList(limit: 3)
        #expect(list.entries.count == 1)
        let first = list.entries[0].id
        let second = list.add()
        let third = list.add()
        #expect(second != nil && third != nil)
        #expect(!list.canAdd)
        #expect(list.add() == nil)
        list.update(third!, to: " b.com ")
        list.makePrimary(third!)
        #expect(list.entries.map(\.id) == [third!, first, second!])
        #expect(list.isPrimary(third!))
        #expect(list.filledValues == ["b.com"])
        list.remove(first)
        list.remove(second!)
        #expect(list.entries.map(\.id) == [third!])
        list.remove(third!)
        #expect(list.entries.count == 1, "只剩一个时不删")
        #expect(list.value(of: third!) == " b.com ")
        // 删掉的 id 不会再发出去。
        let next = list.add()
        #expect(next != nil && ![first, second!, third!].contains(next!))
    }

    @Test("网站：没写协议补 https，要有带点的主机名")
    func websites() {
        #expect(VaultWebsiteRules.normalized("example.com")?.absoluteString == "https://example.com")
        #expect(VaultWebsiteRules.normalized(" https://a.example.com/login ")?.host == "a.example.com")
        #expect(VaultWebsiteRules.normalized("HTTP://example.com") != nil)
        #expect(VaultWebsiteRules.normalized("") == nil)
        #expect(VaultWebsiteRules.normalized("localhost") == nil)
        #expect(VaultWebsiteRules.normalized("ftp://example.com") == nil)
        #expect(VaultWebsiteRules.normalized("exa mple.com") == nil)
        var list = VaultFieldList(values: ["example.com", "", "bad"])
        #expect(VaultWebsiteRules.invalidEntries(list) == [list.entries[2].id])
        list.update(list.entries[2].id, to: "good.example")
        #expect(VaultWebsiteRules.invalidEntries(list).isEmpty)
    }

    @Test("卡号：只留数字、每 4 位一格、最多 19 位；Luhn 校验")
    func cardNumber() {
        #expect(VaultCardDraft.formatNumber("4242424242424242") == "4242 4242 4242 4242")
        #expect(VaultCardDraft.formatNumber("4242-4242 42ab") == "4242 4242 42")
        #expect(VaultCardDraft.formatNumber(String(repeating: "1", count: 25)).filter(\.isNumber).count == 19)
        #expect(VaultCardDraft.formatNumber("４２") == "", "全角数字不算")
        #expect(VaultCardDraft.passesLuhn("4242424242424242"))
        #expect(!VaultCardDraft.passesLuhn("4242424242424241"))
        var draft = VaultCardDraft()
        draft.number = "4242 4242 4242 4242"
        #expect(draft.isNumberValid)
        #expect(draft.lastFour == "4242")
        draft.number = "4242 4242 42"
        #expect(!draft.isNumberValid, "太短")
    }

    @Test("有效期：MM / YY，月份 1–12，本月还算有效")
    func expiry() {
        let now = Fixture.date(2026, 11, 5)
        #expect(VaultCardDraft.formatExpiry("1") == "1")
        #expect(VaultCardDraft.formatExpiry("12") == "12")
        #expect(VaultCardDraft.formatExpiry("123") == "12 / 3")
        #expect(VaultCardDraft.formatExpiry("12/345") == "12 / 34")
        var draft = VaultCardDraft()
        draft.expiry = "11 / 26"
        #expect(draft.isExpiryValid(now: now, calendar: Fixture.calendar))
        draft.expiry = "10 / 26"
        #expect(!draft.isExpiryValid(now: now, calendar: Fixture.calendar))
        draft.expiry = "13 / 30"
        #expect(draft.expiryParts == nil)
        #expect(!draft.isExpiryValid(now: now, calendar: Fixture.calendar))
        draft.expiry = "01 / 31"
        #expect(draft.isExpiryValid(now: now, calendar: Fixture.calendar))
    }

    @Test("卡片能不能添加：卡号、有效期必填；选了新地址要填街道和城市；安全码 3–4 位")
    func cardCanSave() {
        let now = Fixture.date(2026, 11, 5)
        var draft = VaultCardDraft()
        #expect(!draft.canSave(now: now))
        draft.number = "4242 4242 4242 4242"
        #expect(!draft.canSave(now: now))
        draft.expiry = "12 / 29"
        #expect(draft.canSave(now: now))
        draft.securityCode = "12"
        #expect(!draft.canSave(now: now))
        #expect(VaultExtraText.cardProblem(draft, now: now, language: .chinese) == "安全码是 3 或 4 位数字。")
        draft.securityCode = VaultCardDraft.formatSecurityCode("123a45")
        #expect(draft.securityCode == "1234")
        #expect(draft.canSave(now: now))
        draft.billing = .newAddress
        #expect(!draft.canSave(now: now))
        draft.address.street = "人民路 1 号"
        draft.address.city = "上海"
        #expect(draft.canSave(now: now))
        #expect(VaultExtraText.cardProblem(draft, now: now, language: .chinese) == nil)
        draft.number = "4242 4242 4242 4241"
        #expect(VaultExtraText.cardProblem(draft, now: now, language: .chinese) == "卡号看起来不对，再核对一下。")
        draft.number = "4242 4242 4242 4242"
        draft.expiry = "01 / 20"
        #expect(VaultExtraText.cardProblem(draft, now: now, language: .chinese) == "这张卡已经过期了。")
    }

    @Test("联系信息：至少一种联系方式，邮箱要像邮箱（参考 61 的脚注）")
    func contact() {
        var draft = VaultContactDraft()
        #expect(!draft.canSave)
        draft.label = "家"
        draft.name = "张三"
        #expect(!draft.canSave, "只有标签和姓名不够")
        draft.phones.update(draft.phones.entries[0].id, to: "138 0000 0000")
        #expect(draft.canSave)
        let email = draft.emails.entries[0].id
        draft.emails.update(email, to: "not-an-email")
        #expect(draft.invalidEmails == [email])
        #expect(!draft.canSave)
        draft.emails.update(email, to: "zhang@example.com")
        #expect(draft.canSave)

        var addressOnly = VaultContactDraft()
        addressOnly.address.street = "人民路 1 号"
        #expect(!addressOnly.canSave, "地址要有街道和城市")
        addressOnly.address.city = "上海"
        #expect(addressOnly.canSave)
        #expect(!addressOnly.address.isEmpty)
        #expect(VaultPostalAddress().isEmpty)
    }

    @Test("电话、邮箱的标签：第一个是手机 / 邮箱，后面带序号（参考 97）")
    func contactLabels() {
        #expect(VaultExtraText.phone(index: 0, language: .chinese) == "手机")
        #expect(VaultExtraText.phone(index: 1, language: .chinese) == "电话 2")
        #expect(VaultExtraText.email(index: 0, language: .english) == "Email")
        #expect(VaultExtraText.email(index: 2, language: .english) == "Email 3")
        #expect(VaultContactDraft.looksLikeEmail("a@b.co"))
        #expect(!VaultContactDraft.looksLikeEmail("a@b"))
        #expect(!VaultContactDraft.looksLikeEmail("a b@c.com"))
        #expect(!VaultContactDraft.looksLikeEmail("@c.com"))
    }
}
