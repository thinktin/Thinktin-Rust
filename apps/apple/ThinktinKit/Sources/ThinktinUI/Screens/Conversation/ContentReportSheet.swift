import SwiftUI
import ThinktinKit

/// 一次举报（sheet 用 `Identifiable`）。
struct ReportRequest: Identifiable {
    let id = UUID()
    let target: ContentReportTarget
}

/// 举报 agent 的输出（5.5）：系统表单（规范 2.6、2.8）——原因是整组单选（`Picker(.inline)`，系统打勾），说明（可选，最多
/// 1000 个字符）一格；左上关闭、右上“提交”（提交中转圈）。提交后换成“已收到”和“完成”。
struct ContentReportSheet: View {
    @State private var model: ContentReportModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, target: ContentReportTarget) {
        _model = State(initialValue: ContentReportModel(client: client, target: target))
    }

    var body: some View {
        NavigationStack {
            content
                .inlineNavigationTitle(ConversationText.reportTitle(model.target, language: language))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
                    if model.report == nil {
                        ToolbarItem(placement: .confirmationAction) {
                            ConfirmButton(
                                ConversationText.reportSubmit(language), isWorking: model.isSubmitting,
                                workingLabel: language == .chinese ? "正在提交" : "Submitting"
                            ) {
                                Task { await model.submit() }
                            }
                            .disabled(!model.canSubmit)
                        }
                    }
                }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large])
    }

    /// 提交前是表单，提交后是“已收到”。
    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        if model.report != nil {
            ContentUnavailableView {
                Label(ConversationText.reportDone(language), systemImage: "checkmark.circle")
            } actions: {
                Button(language == .chinese ? "完成" : "Done") { dismiss() }
                    .glassButtonStyle(.prominent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
        } else {
            Form {
                Section {
                    Picker(selection: $model.reason) {
                        ForEach(ContentReportModel.reasons, id: \.self) { reason in
                            Text(ConversationText.reportReasonName(reason, language: language))
                                .tag(ReportReason?.some(reason))
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
                .themedRow()
                Section {
                    TextField(
                        ConversationText.reportNotePlaceholder(language), text: $model.note, axis: .vertical
                    )
                    .lineLimit(3...6)
                } footer: {
                    if model.isNoteTooLong {
                        Text(
                            language == .chinese
                                ? "说明最多 \(ContentReport.maxNoteLength) 个字"
                                : "Keep it under \(ContentReport.maxNoteLength) characters"
                        )
                        .foregroundStyle(Theme.danger)
                    }
                }
                .themedRow()
                if let error = model.error {
                    Section {
                        ErrorBanner(error) { Task { await model.submit() } }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .themedGroupedBackground()
        }
    }
}

#Preview("举报 · 浅色中文") {
    ContentReportSheet(client: MockClient(autoReply: false), target: .run(DemoData.weeklyRunID))
        .previewShell()
}

#Preview("举报 · 深色英文") {
    ContentReportSheet(
        client: MockClient(autoReply: false),
        target: .artifact(runID: DemoData.weeklyRunID, artifactID: DemoData.weeklyArtifactID)
    )
    .previewShell(.english, scheme: .dark)
}
