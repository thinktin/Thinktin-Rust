import SwiftUI
import ThinktinKit

/// 应用框架自己的页面（`feature == .shell`）：新任务的实例选择、冻结页、升级页。
struct ShellDestination: View {
    let route: AppRoute

    @Environment(AppModel.self) private var model

    var body: some View {
        switch route {
        case .newTask: NewTaskSheet(model: model)
        case .frozen: FrozenView(model: model)
        case .upgrade: UpgradeView()
        default: DestinationPlaceholder(route: route)
        }
    }
}

/// “新任务”的实例选择（有好几个实例时，从抽屉的“新任务”弹出）：选一个就回到它的对话、把焦点放进输入框；
/// 下面可以去领养新的 agent。
private struct NewTaskSheet: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                Text(zh ? "在哪个实例上下任务？" : "Which instance should take this task?")
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, Metrics.Spacing.xs)
                    .padding(.bottom, Metrics.Spacing.xs)
                if model.instances.isEmpty {
                    EmptyStateView(
                        systemImage: "square.stack.3d.up", title: zh ? "还没有实例" : "No instances yet",
                        message: zh ? "先领养一个 agent。" : "Adopt an agent first.")
                }
                ForEach(model.instances) { instance in
                    Button {
                        model.router.requestNewTask(in: instance.id)
                    } label: {
                        HStack(spacing: Metrics.Spacing.s) {
                            StatusDot(instance.state)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                                Text(instance.name)
                                    .typography(.body)
                                    .foregroundStyle(Theme.ink)
                                Text(instance.state.localizedName(language))
                                    .typography(.caption)
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer(minLength: Metrics.Spacing.xs)
                            if instance.id == model.router.currentInstanceID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(Metrics.Spacing.m)
                        .frame(minHeight: Metrics.minTapTarget)
                        .background(
                            Theme.paperElevated,
                            in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(instance.id == model.router.currentInstanceID ? .isSelected : [])
                }
                PillButton(zh ? "领养新的 agent" : "Adopt an agent", systemImage: "plus", kind: .secondary) {
                    model.router.open(.agentCatalog)
                }
                .padding(.top, Metrics.Spacing.s)
            }
            .padding(Metrics.Spacing.m)
        }
        .background(Theme.paper)
        .navigationTitle(AppRoute.newTask.title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") {
                    model.router.dismissSheet()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("新任务 · 浅色中文") {
    ShellDestination(route: .newTask).previewShell()
}

#Preview("新任务 · 深色英文") {
    ShellDestination(route: .newTask).previewShell(.english, scheme: .dark)
}
