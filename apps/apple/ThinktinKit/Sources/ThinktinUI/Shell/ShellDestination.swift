import SwiftUI
import ThinktinKit

/// 应用框架自己的页面（`feature == .shell`）：首页（`.home`，主导航栈永远的根，实例列表 `Shell/Home/`）、
/// 已隐藏的 Botin（`.hiddenBotins`，压栈）、新任务的实例选择、冻结页、升级页。
struct ShellDestination: View {
    let route: AppRoute

    @Environment(AppModel.self) private var model

    var body: some View {
        switch route {
        case .home: HomeScreen()
        case .hiddenBotins: HiddenInstancesScreen(model: model)
        case .newTask: NewTaskSheet(model: model)
        case .frozen: FrozenView(model: model)
        case .upgrade: UpgradeView()
        default: DestinationPlaceholder(route: route)
        }
    }
}

/// “新任务”的 Botin 选择（引导、快捷指令的“新任务”有好几个 Botin 时弹出），照参考 11 的选择器版式（规范 4.4.5）：
/// 左上 `CloseButton`、中间标题、右上 `ConfirmButton("确认")`；一行一个 Botin（头像、名字、状态），选中的右边系统勾，
/// 默认选主 Botin（`AppModel.local.primary`，排最前、头像是星标、说明写“主 Botin”），没有主 Botin 时选当前的；
/// `.searchable` 按名字筛（iOS 26 的 iPhone 上落在底部）；最后一组“新建 Botin”。
/// 确认就进它的对话（先关掉 sheet）、把焦点放进输入框。没有 Botin、没搜到时 `ContentUnavailableView`。
private struct NewTaskSheet: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language
    @State private var selection: InstanceID?
    @State private var query = ""

    init(model: AppModel) {
        self.model = model
        _selection = State(
            initialValue: model.local.primary.defaultSelection(
                in: model.instances, current: model.router.currentInstanceID))
    }

    private var shown: [Instance] {
        let instances = model.local.primary.primaryFirst(model.instances)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return instances }
        return instances.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        let zh = language == .chinese
        let shown = self.shown
        List {
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { instance in
                        row(instance)
                    }
                } header: {
                    Text(zh ? "交给哪个 Botin？" : "Which Botin should take this task?").textCase(nil)
                }
                .themedRow()
            }
            if !model.instances.isEmpty, query.isEmpty {
                Section {
                    // 叠在新任务上面的第二层；建好了关掉两层、进新 Botin 的对话。
                    Button {
                        model.router.open(.adopt(agentID: nil))
                    } label: {
                        Label(AppRoute.adopt(agentID: nil).title(language), systemImage: "plus")
                    }
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.instances.isEmpty {
                ContentUnavailableView {
                    Label(zh ? "还没有 Botin" : "No Botins yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text(zh ? "先新建一个。" : "Create one first.")
                } actions: {
                    Button(AppRoute.adopt(agentID: nil).title(language)) {
                        model.router.open(.adopt(agentID: nil))
                    }
                    .glassButtonStyle(.prominent)
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: Text(zh ? "搜索 Botin" : "Search Botins"))
        .inlineNavigationTitle(AppRoute.newTask.title(language))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { model.router.dismissSheet() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "确认" : "Confirm") {
                    if let selection { model.router.requestNewTask(in: selection) }
                }
                .disabled(selection.map { id in !model.instances.contains { $0.id == id } } ?? true)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ instance: Instance) -> some View {
        let isSelected = instance.id == selection
        let isPrimary = model.local.primary.isPrimary(instance.id)
        let state = instance.state.localizedName(language)
        return Button {
            selection = instance.id
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                InstanceAvatar(
                    instance.name, appearance: model.appearances.resolved(for: instance.id),
                    size: Metrics.Avatar.search, badge: isPrimary ? .primary : .instance(instance.state)
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(verbatim: instance.name)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(isPrimary ? ConversationText.primaryBotin(language) + " · " + state : state)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: Metrics.Spacing.xs)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("新任务 · 浅色中文") {
    ShellDestination(route: .newTask).previewShell()
}

#Preview("新任务 · 深色英文") {
    ShellDestination(route: .newTask).previewShell(.english, scheme: .dark)
}
