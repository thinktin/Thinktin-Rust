import SwiftUI
import ThinktinKit

/// 选择主 Botin（`.primaryBotin`，sheet；规范 4.4.5、6.10，参考 11）：左上玻璃 × 关闭，中间标题“选择主 Botin”，右上突出的
/// “确认”（没选、选的就是现在的主 Botin 时灰）；内容是分组列表里的系统单选（`Picker(.inline)`，打勾、读屏念“已选中”），
/// 一行是头像 + 名字 + 状态；底部系统搜索栏“搜索 Botin”（iOS 26 的 iPhone 上落在底部）。
///
/// - 列的是别的 Botin：现在的主 Botin、删掉的不列（`PrimaryBotinPicker.candidates`）。一个都没有时是参考 11 的空状态
///   “暂无其他可选的 Botin”；搜不到是系统的“没有结果”。
/// - 主 Botin 只记在这台设备上（`AppModel.local.primary`，App 里就是 `PrimaryBotinStore.shared`），列表下面的脚注说清楚
///   是干什么的。入口是 Botin 资料“…”菜单的“替换主 Botin…”。
struct PrimaryBotinPickerScreen: View {
    /// 测试、预览传自己的；nil 用 `AppModel.local.primary`。
    var store: PrimaryBotinStore? = nil

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language
    @State private var query = ""
    @State private var selection: InstanceID?

    var body: some View {
        let store = self.store ?? app.local.primary
        let candidates = PrimaryBotinPicker.candidates(app.instances, primaryID: store.primaryID, query: query)
        let current = store.primary(in: app.instances)
        List {
            if !candidates.isEmpty {
                Section {
                    Picker(selection: $selection) {
                        ForEach(candidates) { instance in
                            PrimaryBotinRow(instance: instance, appearance: app.appearances.resolved(for: instance.id))
                                .tag(Optional(instance.id))
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text(ConversationText.primaryBotinNote(current: current?.name, language: language))
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if candidates.isEmpty {
                if PrimaryBotinPicker.hasNoOthers(app.instances, primaryID: store.primaryID) {
                    ContentUnavailableView {
                        Text(ConversationText.noOtherBotins(language))
                            .typography(.body)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: Text(ConversationText.searchBotins(language)))
        .inlineNavigationTitle(AppRoute.primaryBotin.title(language))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { router.dismissSheet() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(ConversationText.confirm(language)) {
                    store.set(selection)
                    router.dismissSheet()
                }
                .disabled(!PrimaryBotinPicker.canConfirm(selection: selection, primaryID: store.primaryID))
            }
        }
        .appFeedback(.selection, trigger: selection)
    }
}

/// 一行：头像、名字、状态（参考 11 的列表行，和首页的行同一套头像）。
private struct PrimaryBotinRow: View {
    let instance: Instance
    let appearance: InstanceAppearance

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            InstanceAvatar(instance.name, appearance: appearance, size: Metrics.Avatar.search)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(verbatim: instance.name)
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(instance.state.localizedName(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("选择主 Botin · 浅色中文") {
    NavigationStack {
        PrimaryBotinPickerScreen(store: PrimaryBotinStore(defaults: nil))
    }
    .previewShell()
}

#Preview("选择主 Botin · 空状态 · 深色英文") {
    NavigationStack {
        PrimaryBotinPickerScreen(store: PrimaryBotinStore(defaults: nil))
    }
    .previewShell(.english, scheme: .dark, client: MockClient(state: DemoData.newAccountState(), autoReply: false))
}
