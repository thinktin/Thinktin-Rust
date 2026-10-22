import SwiftUI
import ThinktinKit

/// App 内注销账号（WBS 12.2，App Store 审核指南 5.1.1(v)，16.4）：先列出会删掉什么、勾选“我已了解”，再给本人手机号
/// 发验证码，输入后最后确认一次再注销。注销成功后应用框架回到登录页（客户端是 `ObservedClient`）。
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
        AccountScrollPage {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Typography.largeTitle.font)
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
                AccountPageHeader(
                    title: zh ? "注销账号" : "Delete your account",
                    message: zh
                        ? "注销后，账号和下面这些内容会被永久删除，无法恢复："
                        : "Deleting your account permanently removes it along with everything below. This can't be undone:"
                )
            }

            AccountSection {
                VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                    ForEach(AccountDeletionNotice.deletedItems(language), id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Theme.danger)
                                .accessibilityHidden(true)
                            Text(item)
                                .typography(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Metrics.Spacing.m)
            }

            Text(AccountDeletionNotice.footnote(language))
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            CheckboxRow(
                isOn: model.hasAcknowledged,
                label: AttributedString(
                    zh ? "我已了解，注销后账号和内容都无法恢复" : "I understand my account and content can't be recovered"),
                accessibilityLabel: zh ? "我已了解注销后无法恢复" : "I understand this can't be undone"
            ) {
                model.hasAcknowledged.toggle()
            }
            .disabled(model.isDeleting)

            if let error = model.error {
                ErrorBanner(error, onDismiss: { model.dismissError() })
            }

            TimelineView(.periodic(from: Date(), by: 1)) { context in
                codeSection(now: context.date)
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
                Task { await model.deleteAccount() }
            }
            Button(zh ? "再想想" : "Cancel", role: .cancel) {}
        } message: {
            Text(zh ? "这一步不能撤销。" : "This can't be undone.")
        }
    }

    /// 发验证码、输入验证码、注销按钮。
    @ViewBuilder
    private func codeSection(now: Date) -> some View {
        let zh = language == .chinese
        let seconds = model.secondsUntilResend(at: now)
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            if let message = model.rateLimitMessage(at: now, language: language) {
                Label(message, systemImage: "clock.arrow.circlepath")
                    .font(Typography.footnote.font.monospacedDigit())
                    .foregroundStyle(StatusTone.waiting.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.codeSent {
                Text(
                    zh
                        ? "验证码已发送至 \(maskedPhone)，5 分钟内有效。"
                        : "We sent a code to \(maskedPhone). It's valid for 5 minutes."
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                VerificationCodeField(
                    code: model.code, onChange: { model.updateCode($0) }, isDisabled: model.isDeleting)
                if model.codeIncorrect {
                    FieldMessage(text: DeleteAccountModel.incorrectCodeMessage(language))
                }
            }
            Button {
                Task { await model.sendCode() }
            } label: {
                HStack(spacing: Metrics.Spacing.xs) {
                    if model.isSendingCode {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(sendTitle(seconds: seconds))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill(.secondary))
            .disabled(!model.canSendCode(at: now) || app.isOffline)
            if model.codeSent {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        if model.isDeleting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.onAccent)
                        }
                        Text(zh ? "注销账号" : "Delete account")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.destructive))
                .disabled(!model.canDelete || app.isOffline)
            }
        }
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
