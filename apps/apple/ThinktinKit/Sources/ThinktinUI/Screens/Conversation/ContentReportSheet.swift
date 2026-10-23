import SwiftUI
import ThinktinKit

/// 一次举报（sheet 用 `Identifiable`）。
struct ReportRequest: Identifiable {
    let id = UUID()
    let target: ContentReportTarget
}

/// 举报 agent 的输出（5.5）：选原因、写说明（可选，最多 1000 个字符），提交后显示“已收到”。
struct ContentReportSheet: View {
    @State private var model: ContentReportModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, target: ContentReportTarget) {
        _model = State(initialValue: ContentReportModel(client: client, target: target))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                    if model.report != nil {
                        EmptyStateView(
                            systemImage: "checkmark.circle", title: ConversationText.reportDone(language),
                            actionTitle: language == .chinese ? "完成" : "Done"
                        ) {
                            dismiss()
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(ContentReportModel.reasons, id: \.self) { reason in
                                reasonRow(reason, selected: model.reason == reason) { model.reason = reason }
                            }
                        }
                        .cardSurface()
                        TextField(
                            ConversationText.reportNotePlaceholder(language), text: $model.note, axis: .vertical
                        )
                        .lineLimit(3...6)
                        .textFieldStyle(.plain)
                        .vaultFieldStyle()
                        if model.isNoteTooLong {
                            Text(
                                language == .chinese
                                    ? "说明最多 \(ContentReport.maxNoteLength) 个字"
                                    : "Keep it under \(ContentReport.maxNoteLength) characters"
                            )
                            .typography(.caption)
                            .foregroundStyle(Theme.danger)
                        }
                        if let error = model.error {
                            ErrorBanner(error) { Task { await model.submit() } }
                        }
                        PillButton(ConversationText.reportSubmit(language), systemImage: "flag") {
                            Task { await model.submit() }
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(!model.canSubmit)
                    }
                }
                .padding(Metrics.Spacing.m)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.paper)
            .navigationTitle(ConversationText.reportTitle(model.target, language: language))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language == .chinese ? "取消" : "Cancel") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large])
    }

    private func reasonRow(_ reason: ReportReason, selected: Bool, action: @escaping @MainActor () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack {
                Text(ConversationText.reportReasonName(reason, language: language))
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
