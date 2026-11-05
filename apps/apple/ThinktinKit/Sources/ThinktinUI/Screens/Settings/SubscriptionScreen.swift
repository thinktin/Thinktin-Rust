import SwiftUI
import ThinktinKit

/// 订阅（`.subscription`，参考 56；规范 4.9.4、6.20）：参考是停在转圈的网页容器。ThinkTin 照它先在页面中间转圈
/// （`SubscriptionModel.isLoading`），拿到方案后换成 insetGrouped 的 `List`：每个方案一组（名字、价格、“当前方案”标记、
/// 一条条权益；不是当前的方案底下一个全宽的“订阅”），最后一组“恢复购买”，脚注说这是示例、以后走 App Store。
/// App 内购买（WBS 12.23）还没定：方案是演示数据（`SubscriptionDemoData`），订阅、恢复购买弹“即将推出”。
struct SubscriptionScreen: View {
    @State private var model = SubscriptionModel()
    @State private var comingSoon: SettingsComingSoon?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Group {
            if let plans = model.plans {
                List {
                    ForEach(plans) { plan in
                        planSection(plan)
                    }
                    Section {
                        Button(SubscriptionText.restore(language)) { comingSoon = .restorePurchases }
                    } footer: {
                        Text(SubscriptionText.footer(language))
                    }
                    .themedRow()
                }
                .insetGroupedList()
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(SubscriptionText.loading(language)))
            }
        }
        .themedGroupedBackground()
        .inlineNavigationTitle(AppRoute.subscription.title(language))
        .task(id: language) { await model.load(language) }
        .settingsComingSoon($comingSoon)
    }

    private func planSection(_ plan: SubscriptionPlan) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(plan.name)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(plan.price)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: Metrics.Spacing.xs)
                if plan.isCurrent {
                    Text(SubscriptionText.current(language))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.vertical, Metrics.Spacing.unit)
            .accessibilityElement(children: .combine)
            ForEach(plan.features, id: \.self) { feature in
                Label {
                    Text(feature)
                        .foregroundStyle(Theme.ink)
                } icon: {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            if !plan.isCurrent {
                Button {
                    comingSoon = .subscribe
                } label: {
                    Text(SubscriptionText.subscribe(language))
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(.prominent)
                .controlSize(.large)
                .accessibilityLabel(Text("\(SubscriptionText.subscribe(language)) \(plan.name)"))
            }
        }
        .themedRow()
    }
}

#Preview("订阅 · 深色中文") {
    SettingsDestination(route: .subscription).previewShell(scheme: .dark)
}

#Preview("订阅 · 浅色英文") {
    SettingsDestination(route: .subscription).previewShell(.english)
}
