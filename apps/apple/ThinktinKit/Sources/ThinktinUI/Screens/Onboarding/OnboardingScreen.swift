import SwiftUI
import ThinktinKit

/// 新用户引导（`.onboarding`，WBS 12.17）：四步清单（领养 → 加 key → 配默认模型 → 发第一个任务）加可选的“打开通知”，
/// 每一步按服务端的现状打勾，当前这一步有按钮去做（关掉引导、跳到对应的页面；回来时从设置里再打开，或者下次登录）。
/// 通知权限在这一步才问（“用到时再问”），拒绝过的去系统设置。
struct OnboardingScreen: View {
    @Environment(\.client) private var client
    @Environment(\.notificationPermissionReader) private var reader
    @Environment(\.notificationAuthorizer) private var authorizer

    var body: some View {
        OnboardingContent(model: OnboardingModel(client: client, notifications: reader, authorizer: authorizer))
    }
}

private struct OnboardingContent: View {
    @State private var model: OnboardingModel

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language
    @Environment(\.openURL) private var openURL

    init(model: OnboardingModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        List {
            Section {
                VStack(spacing: Metrics.Spacing.xs) {
                    Text(OnboardingText.title(language))
                        .font(.title2.bold())
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(OnboardingText.intro(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Spacing.s)
                .clearListRow()
            }
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if model.hasLoaded {
                Section {
                    ForEach(OnboardingStep.allCases, id: \.self) { step in
                        OnboardingStepCard(
                            step: step, isDone: model.isDone(step), isCurrent: model.currentStep == step,
                            isBusy: step == .notifications && model.isRequestingNotifications,
                            denied: model.notificationsDenied
                        ) {
                            perform(step)
                        }
                    }
                } footer: {
                    if model.isComplete {
                        Label(OnboardingText.allSet(language), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(StatusTone.success.color)
                    }
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if !model.hasLoaded, visibleError(model.error) == nil { ProgressView() }
        }
        // 只做一件事的页（规范 2.7）：底部全宽的玻璃胶囊，做完了是“完成”，没做完是“以后再说”。
        .floatingBar(edge: .bottom) {
            Button {
                close()
            } label: {
                Text(model.isComplete ? OnboardingText.done(language) : OnboardingText.later(language))
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(model.isComplete ? .prominent : .regular)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.bottom, Metrics.Spacing.xs)
        }
        .inlineNavigationTitle(AppRoute.onboarding.title(language))
        .task { await model.load() }
    }

    /// 关掉引导：sheet 里（第一层，或叠在设置上的第二层）收起，设置里压栈打开的退回去。
    private func close() {
        if router.frontSheet == .onboarding { router.dismissSheet() } else { router.pop() }
    }

    private func perform(_ step: OnboardingStep) {
        switch step {
        case .adopt:
            close()
            router.open(.adopt(agentID: nil))
        case .addKey:
            router.present(.addCredential)
        case .routeMain:
            guard let instance = model.instance else { return }
            close()
            router.open(.modelRoutes(instance.id))
        case .firstTask:
            guard let instance = model.instance else { return }
            close()
            router.requestNewTask(in: instance.id)
        case .notifications:
            if model.notificationsDenied {
                if let url = SystemSettingsLink.notifications { openURL(url) }
            } else {
                Task { await model.requestNotifications() }
            }
        }
    }
}

/// 一步，是列表里的一行：左边序号圆（做完是成功色的对勾，当前这一步是强调色）、标题、说明；当前这一步在下面放一个
/// 玻璃胶囊去做（可选的那一步不突出）。
struct OnboardingStepCard: View {
    let step: OnboardingStep
    let isDone: Bool
    let isCurrent: Bool
    let isBusy: Bool
    let denied: Bool
    let action: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                ZStack {
                    Circle()
                        .fill(isDone ? Theme.success : (isCurrent ? Theme.accent : Theme.userBubble))
                        .frame(width: 28, height: 28)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.onAccent)
                    } else {
                        Text(verbatim: "\(step.rawValue + 1)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isCurrent ? Theme.onAccent : Theme.inkSecondary)
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(OnboardingText.stepTitle(step, language: language))
                        .typography(.body)
                        .foregroundStyle(isDone ? Theme.inkSecondary : Theme.ink)
                    Text(OnboardingText.stepDetail(step, language: language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(isDone ? OnboardingText.done(language) : ""))
            if isCurrent && !isDone {
                Button {
                    action()
                } label: {
                    Label(OnboardingText.action(step, denied: denied, language: language), systemImage: "arrow.right")
                }
                .smallCapsuleButton(step.isOptional ? .regular : .prominent)
                .padding(.leading, 28 + Metrics.Spacing.s)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
    }
}

// MARK: - 请求通知权限

private struct NotificationAuthorizerKey: EnvironmentKey {
    static let defaultValue: any NotificationAuthorizing = FixedNotificationAuthorizer()
}

extension EnvironmentValues {
    /// 请求通知权限（12.17：引导的最后一步）。App 注入系统的（弹权限框并向 APNs 注册）；默认什么都不问。
    public var notificationAuthorizer: any NotificationAuthorizing {
        get { self[NotificationAuthorizerKey.self] }
        set { self[NotificationAuthorizerKey.self] = newValue }
    }
}
