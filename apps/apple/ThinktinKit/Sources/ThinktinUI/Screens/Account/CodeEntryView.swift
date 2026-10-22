import SwiftUI
import ThinktinKit

/// 验证码页（WBS 12.2）：6 位验证码（系统从短信里自动填充，`textContentType(.oneTimeCode)`），输满自动登录；
/// 60 秒后可以重新获取，限流时倒数剩余秒数。登录成功后应用框架自己切到主界面。
struct CodeEntryView: View {
    @Bindable var model: SignInModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        AccountScrollPage {
            AccountPageHeader(
                title: zh ? "输入验证码" : "Enter the code",
                message: zh
                    ? "验证码已发送至 \(model.displayPhone)，5 分钟内有效。"
                    : "We sent a code to \(model.displayPhone). It's valid for 5 minutes.")

            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                VerificationCodeField(
                    code: model.code, onChange: { model.updateCode($0) }, isDisabled: model.isSigningIn,
                    onSubmit: { Task { await model.signIn() } })
                if model.fieldError == .incorrectCode {
                    FieldMessage(text: SignInModel.FieldError.incorrectCode.message(language))
                }
                CountdownNotice { date in model.rateLimitMessage(at: date, language: language) }
            }

            if let error = model.error {
                ErrorBanner(error, onRetry: { Task { await model.retry() } }, onDismiss: { model.dismissError() })
            }

            Button {
                Task { await model.signIn() }
            } label: {
                HStack(spacing: Metrics.Spacing.xs) {
                    if model.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.onAccent)
                    }
                    Text(zh ? "登录" : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
            .disabled(!model.canSignIn)

            TimelineView(.periodic(from: Date(), by: 1)) { context in
                resendRow(now: context.date)
            }

            Text(
                zh
                    ? "收不到验证码？请确认区号和号码没错，短信可能会晚一两分钟到。"
                    : "No code? Check the country code and number; texts can take a minute or two to arrive."
            )
            .typography(.footnote)
            .foregroundStyle(Theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle(zh ? "验证码" : "Verification code")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: model.code) {
            // 输满 6 位（手动、自动填充）就登录；同一个错码不重复交。
            if model.shouldAutoSubmit { Task { await model.signIn() } }
        }
    }

    /// “重新获取验证码”：倒计时中显示剩余秒数。
    private func resendRow(now: Date) -> some View {
        let zh = language == .chinese
        let seconds = model.secondsUntilResend(at: now)
        return HStack {
            Spacer()
            if seconds > 0 {
                Text(zh ? "\(seconds) 秒后可重新获取" : "Resend in \(seconds) s")
                    .font(Typography.subheadline.font.monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                Button {
                    Task { await model.requestCode() }
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        if model.isSendingCode {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(zh ? "重新获取验证码" : "Resend code")
                    }
                }
                .buttonStyle(.pill(.secondary, size: .compact))
                .disabled(!model.canRequestCode(at: now))
            }
            Spacer()
        }
        .frame(minHeight: Metrics.minTapTarget)
    }
}

#Preview("验证码 · 浅色中文") {
    let model = SignInPreviewModels.phone()
    NavigationStack {
        CodeEntryView(model: model)
    }
    .task { await model.requestCode() }
    .environment(\.displayLanguage, .chinese)
}

#Preview("验证码 · 深色英文、验证码不对") {
    let model = SignInPreviewModels.phone()
    NavigationStack {
        CodeEntryView(model: model)
    }
    .task {
        await model.requestCode()
        model.updateCode("000000")
        await model.signIn()
    }
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
