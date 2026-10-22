import SwiftUI
import ThinktinKit

/// 发送前的密码拦截弹层（11.6，docs/vault.md 第 7 节）：消息里认出来的每一处一张卡片——能存的预填建议名、用途、账号，
/// “存进保险箱并换成引用”后引用放回输入框；私钥这类存不进的只提示删掉；像模型厂商的 key 提示“添加为模型 key”。
/// 底部“仍然发送”（二次确认后带 `allowSecrets` 发）。
struct SecretInterceptionSheet: View {
    let model: ConversationModel

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language
    @State private var isConfirmingSend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                    Text(ConversationText.interceptionMessage(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let interception = model.interception {
                        if interception.entries.isEmpty, let count = interception.serverCount {
                            NoticeText(
                                text: ConversationText.interceptionServerOnly(count, language: language), tone: .waiting
                            )
                        }
                        ForEach(interception.savedNames, id: \.self) { name in
                            NoticeText(text: ConversationText.savedSecret(name, language: language), tone: .success)
                        }
                        ForEach(interception.entries) { entry in
                            SecretEntryCard(entry: entry, model: model) {
                                model.dismissInterception()
                                router.open(.addCredential)
                            }
                        }
                    }
                }
                .padding(Metrics.Spacing.m)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.paper)
            .navigationTitle(ConversationText.interceptionTitle(language))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ConversationText.backToEdit(language)) {
                        model.dismissInterception()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Metrics.Spacing.xs) {
                    if let error = model.sendError {
                        ErrorBanner(error, onDismiss: { model.clearSendError() })
                    }
                    PillButton(
                        ConversationText.sendAnyway(language), systemImage: "exclamationmark.triangle",
                        kind: .secondary
                    ) {
                        isConfirmingSend = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(model.isSending)
                }
                .padding(Metrics.Spacing.m)
                .background(Theme.paper)
            }
            .confirmationDialog(
                ConversationText.sendAnyway(language), isPresented: $isConfirmingSend, titleVisibility: .visible
            ) {
                Button(ConversationText.sendAnyway(language), role: .destructive) {
                    Task { await model.sendAnyway() }
                }
                Button(language == .chinese ? "取消" : "Cancel", role: .cancel) {}
            } message: {
                Text(ConversationText.sendAnywayWarning(language))
            }
        }
        .tint(Theme.accent)
    }
}

/// 拦下的一处。
struct SecretEntryCard: View {
    let entry: SecretInterception.Entry
    let model: ConversationModel
    let onAddModelKey: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Card {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: entry.isStorable ? "key" : "exclamationmark.lock")
                    .foregroundStyle(entry.isStorable ? Theme.warning : Theme.danger)
                    .accessibilityHidden(true)
                Text(ConversationText.secretKindName(entry.secret.kind, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(verbatim: ConversationText.maskedValue(entry.secret.value))
                    .font(Typography.caption.monospacedFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            if entry.isStorable {
                field(ConversationText.vaultNameField(language), text: nameBinding)
                if let problem = entry.nameProblem {
                    Text(ConversationText.vaultNameProblem(problem, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.danger)
                }
                field(ConversationText.vaultPurposeField(language), text: purposeBinding)
                field(ConversationText.vaultUsernameField(language), text: usernameBinding)
                Toggle(ConversationText.onlyThisInstance(language), isOn: scopeBinding)
                    .typography(.subheadline)
                    .tint(Theme.accent)
                if let error = entry.error {
                    if error.isConflict {
                        NoticeText(text: ConversationText.vaultNameTaken(language), tone: .waiting)
                    } else {
                        ErrorBanner(error)
                    }
                }
                HStack(spacing: Metrics.Spacing.xs) {
                    PillButton(ConversationText.saveSecret(language), systemImage: "lock", size: .compact) {
                        Task { await model.saveSecret(entry.id) }
                    }
                    .disabled(!entry.canSave)
                    if entry.isSaving { ProgressView().controlSize(.small) }
                }
            } else {
                NoticeText(text: ConversationText.interceptionBlocked(language), tone: .failure)
            }
            if entry.looksLikeModelKey {
                NoticeText(text: ConversationText.interceptionModelKey(language), tone: .waiting)
                PillButton(
                    ConversationText.addModelKey(language), systemImage: "plus", kind: .secondary, size: .compact,
                    action: onAddModelKey)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .vaultFieldStyle()
    }

    // 表单的输入改到视图模型的拦截状态里。条目名只能是小写（服务端的规则），输入时直接转成小写。

    private var nameBinding: Binding<String> {
        let id = entry.id
        return Binding(
            get: { model.interception?.entry(id)?.name ?? "" },
            set: { value in model.editInterception(id) { $0.name = value.lowercased() } })
    }

    private var purposeBinding: Binding<String> {
        let id = entry.id
        return Binding(
            get: { model.interception?.entry(id)?.purpose ?? "" },
            set: { value in model.editInterception(id) { $0.purpose = value } })
    }

    private var usernameBinding: Binding<String> {
        let id = entry.id
        return Binding(
            get: { model.interception?.entry(id)?.username ?? "" },
            set: { value in model.editInterception(id) { $0.username = value } })
    }

    private var scopeBinding: Binding<Bool> {
        let id = entry.id
        return Binding(
            get: { model.interception?.entry(id)?.onlyThisInstance ?? true },
            set: { value in model.editInterception(id) { $0.onlyThisInstance = value } })
    }
}

#Preview("密码拦截 · 浅色中文") {
    SecretInterceptionPreview(message: ConversationPreviewData.secretMessage)
        .previewShell()
}

#Preview("密码拦截 · 深色英文") {
    SecretInterceptionPreview(message: ConversationPreviewData.secretMessage)
        .previewShell(.english, scheme: .dark)
}
