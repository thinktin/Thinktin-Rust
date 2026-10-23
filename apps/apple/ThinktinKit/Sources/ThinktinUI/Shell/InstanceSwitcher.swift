import SwiftUI
import ThinktinKit

/// 对话页导航栏的标题：当前实例的名字和状态点，点开是实例切换菜单（对应 Claude 标题栏的模型 / 项目菜单）。
/// 菜单里列出所有实例（当前的打勾），下面是“实例详情”“领养新的 agent”。没有实例时只显示 ThinkTin。
struct InstanceSwitcher: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        if let current = model.currentInstance {
            Menu {
                ForEach(model.instances) { instance in
                    Button {
                        model.selectInstance(instance.id)
                    } label: {
                        if instance.id == current.id {
                            Label(instance.name, systemImage: "checkmark")
                        } else {
                            Text(instance.name)
                        }
                    }
                }
                Divider()
                Button {
                    model.router.open(.instance(current.id))
                } label: {
                    Label(AppRoute.instance(current.id).title(language), systemImage: "info.circle")
                }
                Button {
                    model.router.open(.agentCatalog)
                } label: {
                    Label(language == .chinese ? "领养新的 agent" : "Adopt an agent", systemImage: "plus")
                }
            } label: {
                HStack(spacing: Metrics.Spacing.xs) {
                    StatusDot(current.state)
                        .accessibilityHidden(true)
                    Text(current.name)
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(Typography.caption.font.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(current.name))
            .accessibilityValue(Text(current.state.localizedName(language)))
            .accessibilityHint(Text(language == .chinese ? "切换实例" : "Switch instance"))
        } else {
            Text(verbatim: "ThinkTin")
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

#Preview("实例切换 · 浅色中文") {
    let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
    InstanceSwitcher(model: model)
        .padding()
        .background(Theme.paper)
        .task { await model.start() }
        .environment(\.displayLanguage, .chinese)
}

#Preview("实例切换 · 深色英文、没有实例") {
    let model = AppModel(client: ShellPreviewClients.empty(), defaults: nil)
    InstanceSwitcher(model: model)
        .padding()
        .background(Theme.paper)
        .task { await model.start() }
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
