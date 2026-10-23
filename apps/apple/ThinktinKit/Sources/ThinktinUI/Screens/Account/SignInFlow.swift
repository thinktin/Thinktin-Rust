import SwiftUI
import ThinktinKit

/// 没登录时的整页（WBS 12.2，`AppShell` 在 `.signedOut` 时显示 `AccountDestination(route: .signIn)`）：
/// 欢迎页 → 手机号 → 验证码，三页共用一个 `SignInModel`，在 `AppShell` 给的导航栈里压栈。
///
/// 登录成功后 `AppModel` 自己切到主界面（客户端是 `ObservedClient`）。新用户（`isNewUser`）再弹出引导
/// （`router.show(.onboarding)`，没登录完时 `Router` 先记下，切到主界面后再弹）：引导的页面由 12.17 做。
struct SignInFlow: View {
    @Environment(\.client) private var client
    @Environment(\.signInPushRegistration) private var push
    @Environment(Router.self) private var router

    var body: some View {
        SignInFlowContent(model: SignInModel(client: client, pushRegistration: push.fetch), router: router)
    }
}

/// 持有 `SignInModel`（`@State` 只在第一次建，之后重绘时传进来的新模型不用）。
private struct SignInFlowContent: View {
    @State private var model: SignInModel
    let router: Router

    init(model: SignInModel, router: Router) {
        _model = State(initialValue: model)
        self.router = router
    }

    var body: some View {
        WelcomeView(model: model)
            .onAppear {
                model.onSignedIn = { [router] result in
                    // 新用户进引导（12.17 的入口）。
                    if let next = SignInModel.destination(after: result) { router.show(next) }
                }
            }
    }
}

/// 欢迎页：品牌、一句话简介、三条特点，底部“手机号登录”和同意协议的勾选框。没勾选就点登录先弹提示
/// （收集手机号之前必须先同意，16.4）。参考 Claude iOS 的欢迎页：大留白、衬线标题、底部一个主按钮。
struct WelcomeView: View {
    @Bindable var model: SignInModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        ScrollView {
            VStack(spacing: Metrics.Spacing.xxl) {
                VStack(spacing: Metrics.Spacing.l) {
                    BrandMark()
                    VStack(spacing: Metrics.Spacing.s) {
                        Text(zh ? "欢迎使用 ThinkTin" : "Welcome to ThinkTin")
                            .typography(.largeTitle)
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(
                            zh
                                ? "你的常驻 agent。交代下去的事在云端按计划完成，关掉手机也不会中断。"
                                : "Agents that stay on. Hand off a task and it gets done in the cloud on schedule, "
                                    + "even with your phone off."
                        )
                        .typography(.body)
                        .foregroundStyle(Theme.inkSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Metrics.Spacing.xxxl)

                VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                    WelcomeFeature(
                        systemImage: "cloud",
                        text: zh
                            ? "agent 在云端常驻，App 关了、手机没网，任务照样往下做"
                            : "Agents live in the cloud: tasks keep going when the app is closed or you're offline")
                    WelcomeFeature(
                        systemImage: "calendar.badge.clock",
                        text: zh
                            ? "按计划自动执行，做完的结果发到收件箱和通知"
                            : "Plans run on their own, and results land in your inbox and notifications")
                    WelcomeFeature(
                        systemImage: "checkmark.shield",
                        text: zh
                            ? "要紧的操作先问你，密码只进保险箱"
                            : "Anything important waits for your approval, and passwords stay in the vault")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: Metrics.Spacing.s) {
                    Button {
                        model.continueWithPhone()
                    } label: {
                        Label(zh ? "手机号登录" : "Continue with phone number", systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pill)
                    CheckboxRow(
                        isOn: model.hasAgreedToTerms, label: .termsConsent(language),
                        accessibilityLabel: zh ? "同意用户协议和隐私政策" : "Agree to the Terms of Service and Privacy Policy"
                    ) {
                        model.setAgreedToTerms(!model.hasAgreedToTerms)
                    }
                }
            }
            .frame(maxWidth: Metrics.readableWidth)
            .padding(.horizontal, Metrics.Spacing.xl)
            .padding(.bottom, Metrics.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .alert(zh ? "请先同意用户协议和隐私政策" : "Agree to continue", isPresented: $model.showsConsentPrompt) {
            Button(zh ? "同意并继续" : "Agree and continue") { model.agreeAndContinue() }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(
                zh
                    ? "登录要用你的手机号接收验证码。请先阅读页面下方的《用户协议》和《隐私政策》，同意后再继续。"
                    : "Signing in uses your phone number to send a verification code. Please read the Terms of Service "
                        + "and Privacy Policy linked below first."
            )
        }
        .navigationDestination(isPresented: $model.showsPhoneEntry) {
            PhoneEntryView(model: model)
        }
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 欢迎页的一条特点：图标加一句话。
private struct WelcomeFeature: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: Metrics.Spacing.xl)
                .accessibilityHidden(true)
            Text(text)
                .typography(.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ThinkTin 的字标：强调色圆角方块里一个衬线的 T（自有的标识，不用任何第三方的标志）。
struct BrandMark: View {
    var body: some View {
        Text(verbatim: "T")
            .font(Typography.largeTitle.font.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: Metrics.Spacing.xxxl + Metrics.Spacing.m, height: Metrics.Spacing.xxxl + Metrics.Spacing.m)
            .background(
                Theme.accent, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

#Preview("欢迎页 · 浅色中文") {
    AccountDestination(route: .signIn).previewShell(client: AccountPreviewClients.signedOut())
}

#Preview("欢迎页 · 深色英文") {
    AccountDestination(route: .signIn).previewShell(.english, scheme: .dark, client: AccountPreviewClients.signedOut())
}
