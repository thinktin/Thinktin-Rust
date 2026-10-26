import SwiftUI
import ThinktinKit

/// IM 渠道（`.imChannels`，WBS 12.14）：绑定的群机器人。每个一组：名字（备注，没有时“飞书群机器人 …x7k2”）、平台和
/// 订阅的事件、上次发送，右边是开关；发送失败时下面一句怎么处理；“发测试消息”“修改”“删除”。右上角新建（最多 20 个）。
/// 离线时显示已经拉到的，写操作禁用。
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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                PageHeader(
                    title: AppRoute.imChannels.title(language), message: ImChannelText.emptyMessage(language))
                if let error = visibleError(model.error) {
                    ErrorBanner(error, onDismiss: { model.error = nil })
                }
                if let notice = model.notice {
                    InlineNotice(
                        systemImage: notice == .testRateLimited || notice == .turnOnFirst
                            ? "exclamationmark.triangle" : "paperplane",
                        tone: notice == .testRateLimited || notice == .turnOnFirst ? .waiting : .success,
                        text: text(notice))
                }
                if !model.hasLoaded {
                    if model.error == nil { LoadingStateView() }
                } else if model.channels.isEmpty {
                    InlineNotice(
                        systemImage: "bubble.left.and.bubble.right", tone: .neutral,
                        text: ImChannelText.emptyTitle(language))
                } else {
                    if !model.canAdd {
                        InlineNotice(
                            systemImage: "exclamationmark.triangle", tone: .waiting,
                            text: ImChannelText.limitReached(language))
                    }
                    ForEach(model.channels) { channel in
                        channelGroup(channel)
                    }
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(AppRoute.imChannels.title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = EditorTarget(channel: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(app.isOffline || !model.hasLoaded || !model.canAdd)
                .accessibilityLabel(Text(zh ? "绑定群机器人" : "Add a group bot"))
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

    private func channelGroup(_ channel: ImChannel) -> some View {
        let zh = language == .chinese
        let model = self.model
        let busy = model.busy.contains(channel.id)
        let disabled = busy || app.isOffline
        let detail = [
            "\(ImChannelText.vendor(channel.vendor, language: language)) \(channel.hint)",
            channel.events.map { ImChannelText.event($0, language: language) }.joined(separator: zh ? "、" : ", "),
            channel.lastSentAt.map { ImChannelText.lastSent($0, now: Date(), language: language) },
        ].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            GroupedSection {
                ListRow(
                    systemImage: "bubble.left.and.bubble.right",
                    title: ImChannelText.title(channel, language: language),
                    detail: detail, showsChevron: false,
                    accessory: {
                        Toggle(
                            isOn: Binding(
                                get: { channel.isEnabled },
                                set: { on in Task { await model.setEnabled(channel.id, on) } })
                        ) {
                            Text(zh ? "开启" : "On")
                        }
                        .labelsHidden()
                        .tint(Theme.accent)
                        .disabled(disabled)
                    })
                Divider()
                HStack(spacing: Metrics.Spacing.m) {
                    Button(zh ? "发测试消息" : "Send test") { Task { await model.sendTest(channel.id) } }
                        .disabled(disabled)
                    Button(zh ? "修改" : "Edit") { editing = EditorTarget(channel: channel) }
                        .disabled(app.isOffline)
                    Spacer(minLength: 0)
                    Button(zh ? "删除" : "Remove", role: .destructive) { confirmsDelete = channel }
                        .disabled(disabled)
                }
                .typography(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(Metrics.Spacing.s)
            }
            if let error = channel.lastError {
                InlineNotice(
                    systemImage: "exclamationmark.triangle", tone: .waiting,
                    text: ImChannelText.lastError(error, language: language))
            }
        }
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

/// 新建、修改一个群机器人（sheet）：地址（边粘边认出平台）、签名密钥（企业微信没有）、备注、事件。修改时“换地址”打开后
/// 才填新地址和密钥。
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
        let model = self.model
        let shows = model.attemptedSave
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = model.error {
                    ErrorBanner(error, onDismiss: { model.error = nil })
                }
                if let original = model.original {
                    GroupedSection {
                        ListRow(
                            systemImage: "bubble.left.and.bubble.right",
                            title: "\(ImChannelText.vendor(original.vendor, language: language)) \(original.hint)",
                            detail: original.hasSecret ? (zh ? "有签名密钥" : "Signed") : nil, showsChevron: false,
                            accessory: {
                                Toggle(isOn: $model.isReplacingWebhook) { Text(zh ? "换地址" : "New address") }
                                    .tint(Theme.accent)
                                    .fixedSize()
                            })
                    }
                } else {
                    InlineNotice(systemImage: "info.circle", tone: .neutral, text: ImChannelText.setupHint(language))
                }
                if model.editsWebhook {
                    PlansTextField(
                        title: zh ? "webhook 地址" : "Webhook address", text: $model.webhookURL, prompt: "https://…",
                        problem: shows
                            ? model.webhookProblem.map { ImChannelText.problem($0, language: language) } : nil,
                        hint: model.vendor.map {
                            zh
                                ? "认出来了：\(ImChannelText.vendor($0, language: language))"
                                : "Recognised: \(ImChannelText.vendor($0, language: language))"
                        },
                        monospaced: true)
                    if model.supportsSecret {
                        secretField(problem: shows ? model.secretProblem : nil)
                    }
                }
                PlansTextField(
                    title: zh ? "备注" : "Note", text: $model.label, prompt: zh ? "比如：研发群" : "For example: Dev team",
                    limit: ImChannelRules.maxLabelLength,
                    count: model.label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count,
                    problem: shows ? model.labelProblem.map { ImChannelText.problem($0, language: language) } : nil)
                SectionHeader(title: zh ? "发哪些消息" : "Send messages for")
                GroupedSection {
                    ForEach(ImEvent.knownCases, id: \.self) { event in
                        if event != ImEvent.knownCases.first { Divider() }
                        Toggle(
                            isOn: Binding(get: { model.isSelected(event) }, set: { _ in model.toggle(event) })
                        ) {
                            Text(ImChannelText.event(event, language: language))
                                .typography(.body)
                                .foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.accent)
                        .padding(Metrics.Spacing.s)
                    }
                }
                if shows, let problem = model.eventsProblem {
                    Text(ImChannelText.problem(problem, language: language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            .pageLayout()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .inlineNavigationTitle(model.isNew ? (zh ? "绑定群机器人" : "Add a group bot") : (zh ? "修改" : "Edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onFinish(nil) }
                    .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSaving ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存" : "Save")) {
                    Task {
                        if let saved = await model.save() { onFinish(saved) }
                    }
                }
                .disabled(model.isSaving || app.isOffline || !model.hasChanges)
            }
        }
        .interactiveDismissDisabled(model.isSaving)
    }

    private func secretField(problem: ImChannelProblem?) -> some View {
        let zh = language == .chinese
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(zh ? "签名密钥（可选）" : "Signing secret (optional)")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            SecureField(zh ? "签名密钥" : "Signing secret", text: $model.secret)
                .textFieldStyle(.plain)
                .font(Typography.body.monospacedFont)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Metrics.Spacing.s)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Theme.paperElevated, in: shape)
            Text(
                problem.map { ImChannelText.problem($0, language: language) }
                    ?? ImChannelText.secretHint(model.vendor, language: language)
            )
            .typography(.footnote)
            .foregroundStyle(problem == nil ? Theme.inkSecondary : StatusTone.failure.color)
        }
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
