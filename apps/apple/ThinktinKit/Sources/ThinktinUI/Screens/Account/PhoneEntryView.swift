import SwiftUI
import ThinktinKit

/// 手机号页（WBS 12.2）：区号（默认 +86，点开选）、手机号（系统可以自动填本机号码），“获取验证码”。
/// 发码之后 60 秒内按钮上倒数；被限流（429）时按 `Retry-After` 倒数，提示里有剩余秒数。
struct PhoneEntryView: View {
    @Bindable var model: SignInModel

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isPhoneFocused: Bool
    @State private var showsRegionPicker = false

    var body: some View {
        let zh = language == .chinese
        AccountScrollPage {
            AccountPageHeader(
                title: zh ? "输入手机号" : "Enter your phone number",
                message: zh
                    ? "我们会发一条短信验证码。没注册过的手机号，验证后自动创建账号。"
                    : "We'll text you a verification code. If the number is new to us, we'll create an account for it.")

            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                phoneField
                if let fieldError = model.fieldError, fieldError == .invalidPhone {
                    FieldMessage(text: fieldError.message(language))
                }
                CountdownNotice { date in model.rateLimitMessage(at: date, language: language) }
            }

            if let error = model.error {
                ErrorBanner(
                    error, onRetry: { Task { await model.retry() } }, onDismiss: { model.dismissError() })
            }

            TimelineView(.periodic(from: Date(), by: 1)) { context in
                requestButton(now: context.date)
            }

            Text(AttributedString.termsConsent(language))
                .typography(.footnote)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle(zh ? "手机号登录" : "Phone sign-in")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showsRegionPicker) {
            RegionPickerView(selected: model.region) { region in
                model.selectRegion(region)
                isPhoneFocused = true
            }
        }
        .navigationDestination(isPresented: $model.showsCodeEntry) {
            CodeEntryView(model: model)
        }
        .onAppear { isPhoneFocused = true }
    }

    /// 区号按钮和号码框放在同一个圆角框里。
    private var phoneField: some View {
        let zh = language == .chinese
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        return HStack(spacing: Metrics.Spacing.s) {
            Button {
                showsRegionPicker = true
            } label: {
                HStack(spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: model.region.dialCodeText)
                        .font(Typography.body.font.monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.down")
                        .font(Typography.caption.font.weight(.semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    zh
                        ? "区号 \(model.region.dialCodeText)，\(model.region.name(language))"
                        : "Country code \(model.region.dialCodeText), \(model.region.name(language))")
            )
            .accessibilityHint(Text(zh ? "选择国家或地区" : "Choose a country or region"))

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: Metrics.hairline(scale: displayScale), height: Metrics.Spacing.xl)
                .accessibilityHidden(true)

            TextField(
                zh ? "手机号" : "Phone number",
                text: Binding(get: { model.phoneText }, set: { model.updatePhone($0) })
            )
            .font(Typography.body.font.monospacedDigit())
            .foregroundStyle(Theme.ink)
            .phoneNumberInput()
            .focused($isPhoneFocused)
            .submitLabel(.continue)
            .onSubmit { Task { await model.requestCode() } }
            .accessibilityLabel(Text(zh ? "手机号" : "Phone number"))
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.s)
        .background(Theme.paperElevated, in: shape)
        .overlay {
            shape.strokeBorder(
                model.fieldError == .invalidPhone ? Theme.danger : (isPhoneFocused ? Theme.accent : Theme.hairline),
                lineWidth: isPhoneFocused ? 1 : Metrics.hairline(scale: displayScale))
        }
    }

    /// “获取验证码”：倒计时中显示“N 秒后可重新获取”，正在发时转圈。
    private func requestButton(now: Date) -> some View {
        let zh = language == .chinese
        let seconds = model.secondsUntilResend(at: now)
        let title =
            seconds > 0
            ? (zh ? "\(seconds) 秒后可重新获取" : "Resend in \(seconds) s")
            : (zh ? "获取验证码" : "Send code")
        return Button {
            Task { await model.requestCode() }
        } label: {
            HStack(spacing: Metrics.Spacing.xs) {
                if model.isSendingCode {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.onAccent)
                }
                Text(title)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pill)
        .disabled(!model.canRequestCode(at: now))
    }
}

/// 选区号（sheet）：搜索名字或区号，点一个就选上、关掉。
struct RegionPickerView: View {
    let selected: PhoneRegion
    let onSelect: @MainActor (PhoneRegion) -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let zh = language == .chinese
        let regions = PhoneRegion.all.filter { $0.matches(query) }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if regions.isEmpty {
                        EmptyStateView(
                            systemImage: "magnifyingglass", title: zh ? "没有找到" : "No matches",
                            message: zh
                                ? "不在列表里的号码，可以在手机号框里直接输入“+区号号码”。"
                                : "If your country isn't listed, type the full number starting with + instead.")
                    }
                    ForEach(regions) { region in
                        Button {
                            onSelect(region)
                            dismiss()
                        } label: {
                            HStack(spacing: Metrics.Spacing.s) {
                                Text(region.name(language))
                                    .typography(.body)
                                    .foregroundStyle(Theme.ink)
                                Spacer(minLength: Metrics.Spacing.xs)
                                Text(verbatim: region.dialCodeText)
                                    .font(Typography.body.font.monospacedDigit())
                                    .foregroundStyle(Theme.inkSecondary)
                                if region == selected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, Metrics.Spacing.m)
                            .frame(minHeight: Metrics.minTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(region == selected ? .isSelected : [])
                        AccountRowDivider()
                    }
                }
                .padding(.vertical, Metrics.Spacing.xs)
            }
            .background(Theme.paper)
            .searchable(text: $query, prompt: Text(zh ? "搜索国家、地区或区号" : "Search countries or codes"))
            .navigationTitle(zh ? "选择国家或地区" : "Country or region")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(zh ? "取消" : "Cancel") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }
}

/// 预览用：已经同意协议、填好号码的登录模型。
@MainActor
enum SignInPreviewModels {
    static func phone(rateLimited: Bool = false) -> SignInModel {
        let mock = AccountPreviewClients.signedOut()
        let model = SignInModel(client: mock, consent: AccountConsentStore(defaults: nil))
        model.setAgreedToTerms(true)
        model.updatePhone("13800138000")
        if rateLimited {
            mock.failNext(with: .api(status: 429, code: .rateLimited, message: "too many codes", retryAfterSecs: 45))
        }
        return model
    }
}

#Preview("手机号 · 浅色中文") {
    NavigationStack {
        PhoneEntryView(model: SignInPreviewModels.phone())
    }
    .environment(\.displayLanguage, .chinese)
}

#Preview("手机号 · 深色英文、限流") {
    let model = SignInPreviewModels.phone(rateLimited: true)
    NavigationStack {
        PhoneEntryView(model: model)
    }
    .task { await model.requestCode() }
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}

#Preview("选区号 · 浅色中文") {
    RegionPickerView(selected: .mainland) { _ in }
        .environment(\.displayLanguage, .chinese)
}

#Preview("选区号 · 深色英文") {
    RegionPickerView(selected: PhoneRegion.region(id: "HK")!) { _ in }
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
