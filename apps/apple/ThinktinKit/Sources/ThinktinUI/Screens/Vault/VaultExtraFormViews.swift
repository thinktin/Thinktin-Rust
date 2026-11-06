import SwiftUI
import ThinktinKit

// 保险箱“+”菜单里的另外两种条目（参考 58）：新卡片（参考 60、94–96）、新建联系信息（参考 61、97、98），和登录信息表单里的
// “网站”一组（参考 99）。都是系统的 `Form`：卡片、联系信息是“标签在左、输入在右”的行（`LabeledContent`，标签一样宽，
// 输入框对齐），“提示”是标签在上的多行输入；底部浮着全宽的“添加卡片 / 保存联系信息”（规范 2.7）。保险箱的接口只能存
// 登录信息（规范 6.16），所以这两个表单保存时弹“即将推出”，网站一组填了不保存（脚注写着）。输入整理和校验在 ThinktinKit
// 的 `VaultCardDraft`、`VaultContactDraft`、`VaultFieldList` 里测。

/// 新卡片（参考 60、94–96）：卡号（每 4 位一格）、有效期（MM / YY）、安全码（行尾眼睛）、持卡人姓名、备注名、账单地址
/// （系统菜单：不填 / 新地址，选了新地址多一组地址，参考 95、96；没选时和别的输入框一样在输入那一列写灰色的“可选”，行尾灰色的
/// ⌃⌄，参考 60）；脚注说 Botin 付款时只拿到备注名（`VaultExtraText.cardFooter`）；“提示”一组；右上相机（扫描卡片，即将推出）；
/// 底部“添加卡片”。
struct VaultCardFormView: View {
    @State private var draft = VaultCardDraft()
    @State private var showsSecurityCode = false
    @State private var comingSoon: SettingsComingSoon?
    @ScaledMetric(relativeTo: .body) private var labelWidth: CGFloat = VaultFormMetrics.labelWidth

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Form {
            Section {
                VaultInlineField(title: VaultExtraText.cardNumber(language), labelWidth: labelWidth) {
                    TextField(
                        VaultExtraText.cardNumberPlaceholder,
                        text: Binding(get: { draft.number }, set: { draft.number = VaultCardDraft.formatNumber($0) })
                    )
                    .monospacedDigit()
                    .vaultFieldInput(.cardNumber)
                }
                VaultInlineField(title: VaultExtraText.expiry(language), labelWidth: labelWidth) {
                    TextField(
                        VaultExtraText.expiryPlaceholder,
                        text: Binding(get: { draft.expiry }, set: { draft.expiry = VaultCardDraft.formatExpiry($0) })
                    )
                    .monospacedDigit()
                    .vaultFieldInput(.cardExpiration)
                }
                VaultInlineField(title: VaultExtraText.securityCode(language), labelWidth: labelWidth) {
                    HStack {
                        let code = Binding(
                            get: { draft.securityCode },
                            set: { draft.securityCode = VaultCardDraft.formatSecurityCode($0) })
                        Group {
                            if showsSecurityCode {
                                TextField(SettingsExtrasText.optional(language), text: code)
                            } else {
                                SecureField(SettingsExtrasText.optional(language), text: code)
                            }
                        }
                        .vaultFieldInput(.cardSecurityCode)
                        VaultRevealButton(isRevealed: $showsSecurityCode)
                    }
                }
                VaultInlineField(title: VaultExtraText.holder(language), labelWidth: labelWidth) {
                    TextField(SettingsExtrasText.optional(language), text: $draft.holder)
                        .vaultFieldInput(.cardName)
                }
                VaultInlineField(title: VaultExtraText.nickname(language), labelWidth: labelWidth) {
                    TextField(VaultExtraText.nicknamePlaceholder(language), text: $draft.nickname)
                }
                VaultInlineField(title: VaultExtraText.billingAddress(language), labelWidth: labelWidth) {
                    billingMenu
                }
            } footer: {
                if let problem = VaultExtraText.cardProblem(draft, language: language) {
                    Text(problem).foregroundStyle(Theme.danger)
                } else {
                    Text(VaultExtraText.cardFooter(language))
                }
            }
            .themedRow()
            if draft.billing == .newAddress {
                VaultAddressSection(address: $draft.address, header: nil, labelWidth: labelWidth)
            }
            VaultNotesSection(notes: $draft.notes)
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .settingsNavigationTitle(VaultItemKind.card.newTitle(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Button {
                    comingSoon = .scanCard
                } label: {
                    Label(VaultExtraText.scanCard(language), systemImage: "camera")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .floatingBar {
            SettingsBottomActions(title: VaultExtraText.addCard(language), isEnabled: draft.canSave()) {
                comingSoon = .saveCard
            }
        }
        .settingsComingSoon($comingSoon)
    }

    /// 账单地址：系统菜单（里面是行内的 `Picker`，系统打勾），标签照输入框排：值在输入那一列（没选是灰色的“可选”），
    /// 行尾灰色的上下箭头。以前是 `Picker(.menu)`，值靠右、强调色（和参考 60 不一样）。
    private var billingMenu: some View {
        let isEmpty = draft.billing == VaultBillingAddressChoice.none
        return Menu {
            Picker(selection: $draft.billing) {
                ForEach(VaultBillingAddressChoice.allCases, id: \.self) { choice in
                    if choice == .newAddress {
                        Label(VaultExtraText.billingChoice(choice, language: language), systemImage: "plus")
                            .tag(choice)
                    } else {
                        Text(VaultExtraText.billingChoice(choice, language: language)).tag(choice)
                    }
                }
            } label: {
                Text(VaultExtraText.billingAddress(language))
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Metrics.Spacing.xs) {
                Text(
                    isEmpty
                        ? SettingsExtrasText.optional(language)
                        : VaultExtraText.billingChoice(draft.billing, language: language)
                )
                .foregroundStyle(isEmpty ? Theme.inkTertiary : Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityValue(Text(VaultExtraText.billingChoice(draft.billing, language: language)))
    }
}

/// 新建联系信息（参考 61、97、98）：标签、姓名、手机（可以再加电话：“电话 2”下面“设为首选”“移除”）、“添加电话”，邮箱同样；
/// 脚注“至少要有地址、电话或邮箱中的一项”；“地址”一组；“提示”一组；底部“保存联系信息”。
struct VaultContactFormView: View {
    @State private var draft = VaultContactDraft()
    @State private var comingSoon: SettingsComingSoon?
    @ScaledMetric(relativeTo: .body) private var labelWidth: CGFloat = VaultFormMetrics.labelWidth

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Form {
            Section {
                VaultInlineField(title: VaultExtraText.label(language), labelWidth: labelWidth) {
                    TextField(VaultExtraText.labelPlaceholder(language), text: $draft.label)
                }
                VaultInlineField(title: VaultExtraText.name(language), labelWidth: labelWidth) {
                    TextField(SettingsExtrasText.optional(language), text: $draft.name)
                        .vaultFieldInput(.name)
                }
                VaultRepeatingRows(
                    list: $draft.phones, labelWidth: labelWidth, placeholder: VaultExtraText.phonePlaceholder,
                    input: .telephone, addTitle: VaultExtraText.addPhone(language)
                ) { index in
                    VaultExtraText.phone(index: index, language: language)
                }
                VaultRepeatingRows(
                    list: $draft.emails, labelWidth: labelWidth, placeholder: VaultExtraText.emailPlaceholder,
                    input: .email, addTitle: VaultExtraText.addEmail(language)
                ) { index in
                    VaultExtraText.email(index: index, language: language)
                }
            } footer: {
                if !draft.invalidEmails.isEmpty {
                    Text(VaultExtraText.invalidEmail(language)).foregroundStyle(Theme.danger)
                } else {
                    Text(VaultExtraText.contactFooter(language))
                }
            }
            .themedRow()
            VaultAddressSection(
                address: $draft.address, header: VaultExtraText.addressHeader(language), labelWidth: labelWidth)
            VaultNotesSection(notes: $draft.notes)
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .settingsNavigationTitle(VaultItemKind.contact.newTitle(language))
        .floatingBar {
            SettingsBottomActions(title: VaultExtraText.saveContact(language), isEnabled: draft.canSave) {
                comingSoon = .saveContact
            }
        }
        .settingsComingSoon($comingSoon)
    }
}

/// 登录信息表单里的“网站”一组（参考 59、99）：每个网站是“标签在上、输入在下”的一格，不止一个时标签那行右边有“移除”；
/// 最后一行强调色的“添加网站”。网站要后端（规范 6.16），脚注说现在不保存。
struct VaultWebsitesSection: View {
    @Binding var websites: VaultFieldList

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let invalid = VaultWebsiteRules.invalidEntries(websites)
        Section {
            ForEach(websites.entries) { entry in
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    HStack {
                        Text(VaultExtraText.website(language))
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .accessibilityHidden(true)
                        Spacer(minLength: Metrics.Spacing.xs)
                        if websites.entries.count > 1 {
                            Button(VaultExtraText.remove(language)) { websites.remove(entry.id) }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    TextField(
                        VaultExtraText.websitePlaceholder,
                        text: Binding(get: { websites.value(of: entry.id) }, set: { websites.update(entry.id, to: $0) })
                    )
                    .vaultFieldInput(.url)
                    .accessibilityLabel(Text(VaultExtraText.website(language)))
                }
                .padding(.vertical, Metrics.Spacing.xxs)
            }
            if websites.canAdd {
                Button(VaultExtraText.addWebsite(language)) { websites.add() }
                    .buttonStyle(.borderless)
            }
        } footer: {
            if invalid.isEmpty {
                Text(VaultExtraText.websitesFooter(language))
            } else {
                Text(VaultExtraText.invalidWebsite(language)).foregroundStyle(Theme.danger)
            }
        }
        .themedRow()
    }
}

/// 卡片、联系信息表单里标签的宽度（参考 60、61：输入框从同一列开始）。
enum VaultFormMetrics {
    static let labelWidth: CGFloat = 104
}

/// “标签在左、输入在右”的一行（参考 60、61）：标签一样宽，输入框对齐成一列。
struct VaultInlineField<Content: View>: View {
    let title: String
    let labelWidth: CGFloat
    let content: Content

    init(title: String, labelWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .foregroundStyle(Theme.ink)
                .frame(minWidth: labelWidth, alignment: .leading)
        }
    }
}

/// 可以有好几个值的字段（参考 61、97：电话、邮箱）：第一个是普通的一行；后面的每个下面一行“设为首选”“移除”；
/// 最后一行强调色的“添加 …”。
private struct VaultRepeatingRows: View {
    @Binding var list: VaultFieldList
    let labelWidth: CGFloat
    let placeholder: String
    let input: VaultFieldInput
    let addTitle: String
    let title: (Int) -> String

    @Environment(\.displayLanguage) private var language

    var body: some View {
        ForEach(Array(list.entries.enumerated()), id: \.element.id) { index, entry in
            VStack(alignment: .trailing, spacing: Metrics.Spacing.xxs) {
                VaultInlineField(title: title(index), labelWidth: labelWidth) {
                    TextField(
                        index == 0 ? placeholder : "",
                        text: Binding(get: { list.value(of: entry.id) }, set: { list.update(entry.id, to: $0) })
                    )
                    .vaultFieldInput(input)
                }
                if index > 0 {
                    HStack(spacing: Metrics.Spacing.l) {
                        Button(VaultExtraText.makePrimary(language)) { list.makePrimary(entry.id) }
                            .foregroundStyle(Theme.inkSecondary)
                        Button(VaultExtraText.remove(language), role: .destructive) { list.remove(entry.id) }
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
            }
        }
        if list.canAdd {
            Button(addTitle) { list.add() }
                .buttonStyle(.borderless)
        }
    }
}

/// 地址的一组（参考 95、96、98）：国家/地区、街道、公寓或单元（可选）、城市、州/省、邮政编码。
private struct VaultAddressSection: View {
    @Binding var address: VaultPostalAddress
    let header: String?
    let labelWidth: CGFloat

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Section {
            VaultInlineField(title: VaultExtraText.country(language), labelWidth: labelWidth) {
                TextField(VaultExtraText.countryPlaceholder(language), text: $address.country)
                    .vaultFieldInput(.country)
            }
            VaultInlineField(title: VaultExtraText.street(language), labelWidth: labelWidth) {
                TextField(VaultExtraText.streetPlaceholder(language), text: $address.street)
                    .vaultFieldInput(.street)
            }
            VaultInlineField(title: VaultExtraText.unit(language), labelWidth: labelWidth) {
                TextField(SettingsExtrasText.optional(language), text: $address.unit)
                    .vaultFieldInput(.unit)
            }
            VaultInlineField(title: VaultExtraText.city(language), labelWidth: labelWidth) {
                TextField(VaultExtraText.city(language), text: $address.city)
                    .vaultFieldInput(.city)
            }
            VaultInlineField(title: VaultExtraText.region(language), labelWidth: labelWidth) {
                TextField(VaultExtraText.region(language), text: $address.region)
                    .vaultFieldInput(.region)
            }
            VaultInlineField(title: VaultExtraText.postalCode(language), labelWidth: labelWidth) {
                TextField(VaultExtraText.postalCode(language), text: $address.postalCode)
                    .vaultFieldInput(.postalCode)
            }
        } header: {
            if let header {
                Text(header).groupHeader()
            }
        }
        .themedRow()
    }
}

/// 最后一组“提示”（参考 60、61）：标签在上的多行输入，脚注“告诉 Botin 什么时候用这一条。”。
private struct VaultNotesSection: View {
    @Binding var notes: String

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Section {
            SettingsMultilineField(title: VaultExtraText.notes(language), placeholder: "", text: $notes)
        } footer: {
            Text(VaultText.purposeFooter(language))
        }
        .themedRow()
    }
}

/// 密码、安全码行尾的眼睛：切换明文（只显示正在输入的）。
struct VaultRevealButton: View {
    @Binding var isRevealed: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        Button {
            isRevealed.toggle()
        } label: {
            Label(
                isRevealed ? (zh ? "隐藏" : "Hide") : (zh ? "显示" : "Show"),
                systemImage: isRevealed ? "eye.slash" : "eye"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.inkSecondary)
    }
}

/// 输入框是哪种内容：系统自动填充（`textContentType`）和键盘（只有 iOS 有，macOS 原样）。
enum VaultFieldInput {
    case cardNumber, cardExpiration, cardSecurityCode, cardName
    case name, telephone, email, url
    case country, street, unit, city, region, postalCode
}

extension View {
    /// 按内容配系统的自动填充和键盘（规范 4.9.7：`.creditCardNumber`、`.telephoneNumber`、`.postalCode` 这些）。
    @ViewBuilder
    func vaultFieldInput(_ input: VaultFieldInput) -> some View {
        #if os(iOS)
            switch input {
            case .cardNumber: textContentType(.creditCardNumber).keyboardType(.numberPad)
            case .cardExpiration: textContentType(.creditCardExpiration).keyboardType(.numberPad)
            case .cardSecurityCode: textContentType(.creditCardSecurityCode).keyboardType(.numberPad)
            case .cardName: textContentType(.creditCardName).textInputAutocapitalization(.words)
            case .name: textContentType(.name)
            case .telephone: textContentType(.telephoneNumber).keyboardType(.phonePad)
            case .email:
                textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .url:
                textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            case .country: textContentType(.countryName)
            case .street: textContentType(.streetAddressLine1)
            case .unit: textContentType(.streetAddressLine2)
            case .city: textContentType(.addressCity)
            case .region: textContentType(.addressState)
            case .postalCode: textContentType(.postalCode)
            }
        #else
            switch input {
            case .email, .url: autocorrectionDisabled()
            default: self
            }
        #endif
    }
}

#Preview("新卡片 · 深色中文") {
    VaultCardFormView().previewShell(scheme: .dark)
}

#Preview("新卡片 · 浅色英文") {
    VaultCardFormView().previewShell(.english)
}

#Preview("新建联系信息 · 深色中文") {
    VaultContactFormView().previewShell(scheme: .dark)
}

#Preview("新建联系信息 · 浅色英文") {
    VaultContactFormView().previewShell(.english)
}
