import SwiftUI
import ThinktinKit

/// 选择主 Botin（`.primaryBotin`，sheet；规范 4.4.5、6.10，参考 11）：左上玻璃 × 关闭，中间标题“选择主 Botin”，右上突出的
/// “确认”（没选、选的就是现在的主 Botin 时灰）；内容是分组列表里的系统单选（`Picker(.inline)`，打勾、读屏念“已选中”），
/// 一行是头像（带状态角标）+ 名字 + 状态（`BotinPickerRow`，和新任务的选择同一种行）；底部系统搜索栏“搜索 Botin”（iOS 26 的
/// iPhone 上落在底部）。
///
/// - 列的是别的 Botin：现在的主 Botin、删掉的不列（`PrimaryBotinPicker.candidates`）。一个都没有时是参考 11 的空状态：
///   一句灰字靠上放（不是居中的 `ContentUnavailableView`），自己的话“没有别的 Botin 可选”；搜不到是系统的“没有结果”。
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

    /// 空状态那句话离导航栏下沿多远（参考 11 量的：字的中线在 sheet 顶下面约 128pt；2026-11-11 截图里导航栏那一行占 sheet
    /// 顶上约 66pt，字高约 22pt）。
    private static let emptyNoteTop = Metrics.Spacing.xxxl + Metrics.Spacing.xxs

    var body: some View {
        let store = self.store ?? app.local.primary
        let candidates = PrimaryBotinPicker.candidates(app.instances, primaryID: store.primaryID, query: query)
        let hasNoOthers = PrimaryBotinPicker.hasNoOthers(app.instances, primaryID: store.primaryID)
        let current = store.primary(in: app.instances)
        List {
            if !candidates.isEmpty {
                Section {
                    Picker(selection: $selection) {
                        ForEach(candidates) { instance in
                            BotinPickerRow(
                                name: instance.name, appearance: app.appearances.resolved(for: instance.id),
                                badge: .instance(instance.state), mood: app.faceMood(for: instance.id),
                                detail: instance.state.localizedName(language)
                            )
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
        // 没有别的 Botin：一句灰字靠上放（参考 11：字的中线在 ×、“确认”那一行的中线下面约 91pt），不是居中的空状态。
        .overlay(alignment: .top) {
            if candidates.isEmpty, hasNoOthers {
                Text(ConversationText.noOtherBotins(language))
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Metrics.Spacing.xl)
                    .padding(.top, Self.emptyNoteTop)
            }
        }
        .overlay {
            if candidates.isEmpty, !hasNoOthers {
                ContentUnavailableView.search(text: query)
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
