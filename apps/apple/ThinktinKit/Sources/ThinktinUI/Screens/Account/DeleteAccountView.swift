import SwiftUI
import ThinktinKit

/// App 内注销账号（WBS 12.2，App Store 审核指南 5.1.1(v)，16.4）：先列出会删掉什么、勾选“我已了解”，再给本人手机号
/// 发验证码，输入后最后确认一次再注销。注销成功后应用框架回到登录页（客户端是 `ObservedClient`）。
///
/// 改版（参考里没有这一页，照账号页排，规范 2.5、2.7）：`Form`，居中的警告头部，会删掉的内容一组，“我已了解”是系统 `Toggle`，
/// 验证码一组（发送 / 重发的按钮行、系统输入框），最后一步“注销账号”是底部浮动的红色全宽胶囊。
struct DeleteAccountView: View {
    @State private var model: DeleteAccountModel
    let maskedPhone: String

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var confirmsDeletion = false

    init(client: any ClientProtocol, maskedPhone: String) {
        _model = State(initialValue: DeleteAccountModel(client: client))
        self.maskedPhone = maskedPhone
    }

    var body: some View {
        let zh = language == .chinese
        @Bindable var bindable = model
        Form {
            Section {
                VStack(spacing: Metrics.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.danger)
                        .accessibilityHidden(true)
                    Text(zh ? "注销账号" : "Delete your account")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        zh
                            ? "注销后，账号和下面这些内容会被永久删除，无法恢复："
                            : "Deleting your account permanently removes it along with everything below. This can't be undone:"
                    )
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Spacing.s)
                .clearListRow()
            }
            Section {
                ForEach(AccountDeletionNotice.deletedItems(language), id: \.self) { item in
                    Label {
                        Text(item)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Theme.danger)
                    }
                }
            } footer: {
                Text(AccountDeletionNotice.footnote(language)).settingsGroupFooter()
            }
            .themedRow()
            Section {
                Toggle(
                    zh ? "我已了解，注销后账号和内容都无法恢复" : "I understand my account and content can't be recovered",
                    isOn: $bindable.hasAcknowledged
                )
                .disabled(model.isDeleting)
            }
            .themedRow()
            if let error = model.error {
                Section {
                    ErrorBanner(error, onDismiss: { model.dismissError() })
                        .clearListRow()
                }
            }
            codeSection
        }
        .formStyle(.grouped)
        .settingsGroupedList()
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .floatingBar(edge: .bottom) {
            if model.codeSent {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    ZStack {
                        Text(zh ? "注销账号" : "Delete account")
                            .opacity(model.isDeleting ? 0 : 1)
                        if model.isDeleting { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(.prominent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(StatusTone.failure.color)
                .disabled(!model.canDelete || app.isOffline)
                .accessibilityLabel(
                    Text(model.isDeleting ? (zh ? "正在注销" : "Deleting") : (zh ? "注销账号" : "Delete account"))
                )
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.vertical, Metrics.Spacing.s)
                .frame(maxWidth: Metrics.readableWidth)
            }
        }
        .navigationTitle(zh ? "注销账号" : "Delete account")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            zh ? "确定注销账号？" : "Delete your account?", isPresented: $confirmsDeletion, titleVisibility: .visible
        ) {
            Button(zh ? "注销账号" : "Delete account", role: .destructive) {
                // 这个账号的 Botin 在这台设备上记的东西（头像外观、置顶和隐藏、语音、表情回应、主 Botin）一起删掉
                // （注销后实例列表就清空了，先记下 id）。
                let ids = app.instances.map(\.id)
                let local = app.local
                Task {
                    if await model.deleteAccount() { local.forgetAccount(ids) }
                }
            }
            Button(zh ? "再想想" : "Cancel", role: .cancel) {}
        } message: {
            Text(zh ? "这一步不能撤销。" : "This can't be undone.")
        }
    }

    /// 验证码一组：发送 / 重发（倒计时的那一行每秒刷新，输入框不跟着重绘）、系统输入框；限流和验证码不对写在脚注里。
    private var codeSection: some View {
        let zh = language == .chinese
        return Section {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Button {
                    Task { await model.sendCode() }
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(sendTitle(seconds: model.secondsUntilResend(at: context.date)))
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        if model.isSendingCode {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(!model.canSendCode(at: context.date) || app.isOffline)
            }
            if model.codeSent {
                TextField(
                    zh ? "6 位验证码" : "6-digit code",
                    text: Binding(get: { model.code }, set: { model.updateCode($0) })
                )
                .font(Typography.title3.monospacedFont)
                .oneTimeCodeInput()
                .disabled(model.isDeleting)
                .accessibilityLabel(Text(zh ? "验证码" : "Verification code"))
            }
        } header: {
            Text(zh ? "验证本人手机号" : "Verify your phone number").settingsGroupHeader()
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                if model.codeSent {
                    Text(
                        zh
                            ? "验证码已发送至 \(maskedPhone)，5 分钟内有效。"
                            : "We sent a code to \(maskedPhone). It's valid for 5 minutes.")
                }
                if model.codeIncorrect {
                    FieldMessage(text: DeleteAccountModel.incorrectCodeMessage(language))
                }
                CountdownNotice { date in model.rateLimitMessage(at: date, language: language) }
            }
        }
        .themedRow()
    }

    private func sendTitle(seconds: Int) -> String {
        let zh = language == .chinese
        if seconds > 0 { return zh ? "\(seconds) 秒后可重新获取" : "Resend in \(seconds) s" }
        if model.codeSent { return zh ? "重新获取验证码" : "Resend code" }
        return zh ? "发送验证码到 \(maskedPhone)" : "Send a code to \(maskedPhone)"
    }
}

#Preview("注销账号 · 浅色中文") {
    DeleteAccountView(client: AccountPreviewClients.signedIn(), maskedPhone: "138****8000")
        .previewShell()
}

#Preview("注销账号 · 深色英文") {
    DeleteAccountView(client: AccountPreviewClients.signedIn(), maskedPhone: "138****8000")
        .previewShell(.english, scheme: .dark)
}
