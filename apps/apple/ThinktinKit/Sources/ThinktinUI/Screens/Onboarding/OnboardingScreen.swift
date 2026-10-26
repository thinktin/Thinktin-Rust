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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsPageHeader(title: OnboardingText.title(language), message: OnboardingText.intro(language))
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if !model.hasLoaded {
                    AgentsLoadingView()
                } else {
                    ForEach(OnboardingStep.allCases, id: \.self) { step in
                        OnboardingStepCard(
                            step: step, isDone: model.isDone(step), isCurrent: model.currentStep == step,
                            isBusy: step == .notifications && model.isRequestingNotifications,
                            denied: model.notificationsDenied
                        ) {
                            perform(step)
                        }
                    }
                    if model.isComplete {
                        NoticeText(text: OnboardingText.allSet(language), tone: .success)
                    }
                }
                Button {
                    close()
                } label: {
                    Text(model.isComplete ? OnboardingText.done(language) : OnboardingText.later(language))
                        .typography(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.onboarding.title(language))
        .task { await model.load() }
    }

    /// 关掉引导：sheet 里收起，设置里压栈打开的退回去。
    private func close() {
        if router.sheet == .onboarding { router.dismissSheet() } else { router.pop() }
    }

    private func perform(_ step: OnboardingStep) {
        switch step {
        case .adopt:
            close()
            router.openFromDrawer(.agentCatalog)
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

/// 一步：序号或对勾、标题、说明；当前这一步有按钮。
struct OnboardingStepCard: View {
    let step: OnboardingStep
    let isDone: Bool
    let isCurrent: Bool
    let isBusy: Bool
    let denied: Bool
    let action: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                ZStack {
                    Circle()
                        .fill(isDone ? Theme.success : (isCurrent ? Theme.accent : Theme.hairline))
                        .frame(width: 28, height: 28)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(Typography.footnote.font)
                            .foregroundStyle(Theme.onAccent)
                    } else {
                        Text(verbatim: "\(step.rawValue + 1)")
                            .typography(.footnote)
                            .foregroundStyle(isCurrent ? Theme.onAccent : Theme.inkSecondary)
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(OnboardingText.stepTitle(step, language: language))
                        .typography(.headline)
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
                PillButton(
                    OnboardingText.action(step, denied: denied, language: language), systemImage: "arrow.right",
                    kind: step.isOptional ? .secondary : .primary
                ) {
                    action()
                }
                .frame(maxWidth: .infinity)
                .disabled(isBusy)
            }
        }
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
