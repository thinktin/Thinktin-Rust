import SwiftUI
import ThinktinKit

/// IM 渠道（`.imChannels`，WBS 12.14）：绑定的群机器人。改版成 insetGrouped `List`（规范 7.3 E，参考里没有这一页）：每个群一组，
/// 系统开关一行（名字（备注，没有时“飞书群机器人 …x7k2”）、平台和订阅的事件、上次发送），“发测试消息”“修改”、红字“删除”；
/// 发送失败的处理办法在脚注里。右上玻璃“+”新建（最多 20 个），编辑页是 `Form`。离线时显示已经拉到的，写操作禁用。
struct ImChannelsScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        ImChannelsContent(model: ImChannelsModel(client: client))
    }
}

private struct ImChannelsContent: View {
    @State private var model: ImChannelsModel
    /// 打开的编辑页：新建（nil 渠道）或修改。
    @State private var editing: EditorTarget?
    @State private var confirmsDelete: ImChannel?

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: ImChannelsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error, onDismiss: { model.error = nil })
                }
                .clearListRow()
            }
            if let notice = model.notice {
                Section {
                    Label(
                        text(notice), systemImage: noticeIsWarning(notice) ? "exclamationmark.triangle" : "paperplane"
                    )
                    .foregroundStyle(noticeIsWarning(notice) ? StatusTone.waiting.color : StatusTone.success.color)
                }
                .themedRow()
            }
            if model.hasLoaded {
                if model.channels.isEmpty {
                    Section {
                        Text(ImChannelText.emptyTitle(language))
                            .foregroundStyle(Theme.inkSecondary)
                    } footer: {
                        Text(ImChannelText.emptyMessage(language))
                    }
                    .themedRow()
                } else {
                    ForEach(model.channels) { channel in
                        channelSection(channel)
                    }
                    Section {
                    } footer: {
                        Text(
                            model.canAdd ? ImChannelText.emptyMessage(language) : ImChannelText.limitReached(language))
                    }
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if !model.hasLoaded && model.error == nil { ProgressView() }
        }
        .inlineNavigationTitle(AppRoute.imChannels.title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Button {
                    editing = EditorTarget(channel: nil)
                } label: {
                    Label(zh ? "绑定群机器人" : "Add a group bot", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(app.isOffline || !model.hasLoaded || !model.canAdd)
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $editing) { target in
            NavigationStack {
                ImChannelEditorView(channel: target.channel) { saved in
                    editing = nil
                    if let saved { model.replace(saved) }
                }
            }
        }
        .confirmationDialog(
            zh ? "删除这个群？" : "Remove this group?", isPresented: deleteDialogShown, titleVisibility: .visible,
            presenting: confirmsDelete
        ) { channel in
            Button(zh ? "删除" : "Remove", role: .destructive) { Task { await model.delete(channel.id) } }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: { _ in
            Text(ImChannelText.deleteConfirm(language))
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { confirmsDelete != nil }, set: { if !$0 { confirmsDelete = nil } })
    }

    /// 一个群一组：开关（名字、平台和地址尾巴、发哪些消息、上次发送），发测试消息、修改，红字删除；上次出错写在脚注里。
    private func channelSection(_ channel: ImChannel) -> some View {
        let zh = language == .chinese
        let model = self.model
        let busy = model.busy.contains(channel.id)
        let disabled = busy || app.isOffline
        let detail = [
            "\(ImChannelText.vendor(channel.vendor, language: language)) \(channel.hint)",
            channel.events.map { ImChannelText.event($0, language: language) }.joined(separator: zh ? "、" : ", "),
            channel.lastSentAt.map { ImChannelText.lastSent($0, now: Date(), language: language) },
        ].compactMap { $0 }.joined(separator: " · ")
        return Section {
            Toggle(
                isOn: Binding(
                    get: { channel.isEnabled },
                    set: { on in Task { await model.setEnabled(channel.id, on) } })
            ) {
                SettingsRowLabel(title: ImChannelText.title(channel, language: language), subtitle: detail)
            }
            .disabled(disabled)
            Button(zh ? "发测试消息" : "Send test") { Task { await model.sendTest(channel.id) } }
                .disabled(disabled)
            Button(zh ? "修改" : "Edit") { editing = EditorTarget(channel: channel) }
                .disabled(app.isOffline)
            Button(zh ? "删除" : "Remove", role: .destructive) { confirmsDelete = channel }
                .foregroundStyle(Theme.danger)
                .disabled(disabled)
        } footer: {
            if let error = channel.lastError {
                Text(ImChannelText.lastError(error, language: language))
                    .foregroundStyle(StatusTone.waiting.color)
            }
        }
        .themedRow()
    }

    private func noticeIsWarning(_ notice: ImChannelNotice) -> Bool {
        notice == .testRateLimited || notice == .turnOnFirst
    }

    private func text(_ notice: ImChannelNotice) -> String {
        switch notice {
        case .testQueued: ImChannelText.testQueued(language)
        case .testRateLimited: ImChannelText.testRateLimited(language)
        case .turnOnFirst: ImChannelText.turnOnFirst(language)
        }
    }
}

/// 编辑页的目标（sheet 用）。
private struct EditorTarget: Identifiable {
    let channel: ImChannel?
    var id: String { channel?.id.rawValue ?? "new" }
}

/// 新建、修改一个群机器人（sheet，`Form`，左上 ×、右上“保存”）：地址（边粘边认出平台）、签名密钥（企业微信没有）、备注、事件
/// （标签在上的输入框，`VaultLabeledField`）。修改时“换地址”打开后才填新地址和密钥。
struct ImChannelEditorView: View {
    let channel: ImChannel?
    /// 关掉（保存了带上渠道，取消是 nil）。
    let onFinish: @MainActor (ImChannel?) -> Void

    @Environment(\.client) private var client

    var body: some View {
        ImChannelEditorContent(model: ImChannelEditorModel(client: client, channel: channel), onFinish: onFinish)
    }
}

private struct ImChannelEditorContent: View {
    @State private var model: ImChannelEditorModel
    let onFinish: @MainActor (ImChannel?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: ImChannelEditorModel, onFinish: @escaping @MainActor (ImChannel?) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        let zh = language == .chinese
        @Bindable var bindable = self.model
        let shows = model.attemptedSave
        Form {
            if let error = model.error {
                Section {
                    ErrorBanner(error, onDismiss: { model.error = nil })
                }
                .clearListRow()
            }
            if let original = model.original {
                Section {
                    Toggle(isOn: $bindable.isReplacingWebhook) {
                        SettingsRowLabel(
                            title: "\(ImChannelText.vendor(original.vendor, language: language)) \(original.hint)",
                            subtitle: original.hasSecret ? (zh ? "有签名密钥" : "Signed") : nil)
                    }
                } footer: {
                    Text(zh ? "打开“换地址”后填新的地址和密钥。" : "Turn this on to enter a new address and secret.")
                }
                .themedRow()
            }
            if model.editsWebhook {
                Section {
                    VaultLabeledField(title: zh ? "webhook 地址" : "Webhook address") {
                        TextField("https://…", text: $bindable.webhookURL)
                            .fontDesign(.monospaced)
                            .modelsKeyboard(.url)
                    }
                    if model.supportsSecret {
                        VaultLabeledField(title: zh ? "签名密钥（可选）" : "Signing secret (optional)") {
                            SecureField(zh ? "签名密钥" : "Signing secret", text: $bindable.secret)
                                .fontDesign(.monospaced)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        if shows, let problem = model.webhookProblem {
                            Text(ImChannelText.problem(problem, language: language)).foregroundStyle(Theme.danger)
                        } else if let vendor = model.vendor {
                            Text(
                                zh
                                    ? "认出来了：\(ImChannelText.vendor(vendor, language: language))"
                                    : "Recognised: \(ImChannelText.vendor(vendor, language: language))")
                        } else if model.isNew {
                            Text(ImChannelText.setupHint(language))
                        }
                        if model.supportsSecret {
                            if shows, let problem = model.secretProblem {
                                Text(ImChannelText.problem(problem, language: language)).foregroundStyle(Theme.danger)
                            } else {
                                Text(ImChannelText.secretHint(model.vendor, language: language))
                            }
                        }
                    }
                }
                .themedRow()
            }
            Section {
                VaultLabeledField(title: zh ? "备注" : "Note") {
                    TextField(zh ? "比如：研发群" : "For example: Dev team", text: $bindable.label)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    if shows, let problem = model.labelProblem {
                        Text(ImChannelText.problem(problem, language: language)).foregroundStyle(Theme.danger)
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    Text(verbatim: "\(labelCount)/\(ImChannelRules.maxLabelLength)")
                        .monospacedDigit()
                        .foregroundStyle(labelCount > ImChannelRules.maxLabelLength ? Theme.danger : Theme.inkTertiary)
                }
            }
            .themedRow()
            Section {
                ForEach(ImEvent.knownCases, id: \.self) { event in
                    Toggle(
                        ImChannelText.event(event, language: language),
                        isOn: Binding(get: { model.isSelected(event) }, set: { _ in model.toggle(event) }))
                }
            } header: {
                Text(zh ? "发哪些消息" : "Send messages for").textCase(nil)
            } footer: {
                if shows, let problem = model.eventsProblem {
                    Text(ImChannelText.problem(problem, language: language)).foregroundStyle(Theme.danger)
                }
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .inlineNavigationTitle(model.isNew ? (zh ? "绑定群机器人" : "Add a group bot") : (zh ? "修改" : "Edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { onFinish(nil) }
                    .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "保存" : "Save", isWorking: model.isSaving) {
                    Task {
                        if let saved = await model.save() { onFinish(saved) }
                    }
                }
                .disabled(app.isOffline || !model.hasChanges)
            }
        }
        .interactiveDismissDisabled(model.isSaving)
    }

    private var labelCount: Int {
        model.label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }
}

#Preview("IM 渠道 · 浅色中文") {
    ImChannelsScreen().previewShell()
}

#Preview("绑定群机器人 · 深色英文") {
    NavigationStack {
        ImChannelEditorView(channel: nil) { _ in }
    }
    .previewShell(.english, scheme: .dark)
}
