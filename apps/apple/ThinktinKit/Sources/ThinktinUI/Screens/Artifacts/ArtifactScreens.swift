import SwiftUI
import ThinktinKit

#if canImport(QuickLook)
    import QuickLook
#endif

/// 产出物库（`.artifacts(instanceID:)`，WBS 12.18）：最新的在前；全部实例的可以按实例筛选。点开进详情，“更多”和长按里删除
/// （二次确认）。离线策略是“没有缓存”：离线时显示已经拉到的。
struct ArtifactLibraryScreen: View {
    let instanceID: InstanceID?

    @Environment(\.client) private var client

    var body: some View {
        ArtifactLibraryContent(model: ArtifactLibraryModel(client: client, instanceID: instanceID))
    }
}

private struct ArtifactLibraryContent: View {
    @State private var model: ArtifactLibraryModel
    @State private var pendingDeletion: Artifact?
    @State private var isConfirmingDeletion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: ArtifactLibraryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        let title = AppRoute.artifacts(instanceID: model.instanceID).title(language)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                PageHeader(title: title, message: ArtifactsText.intro(language))
                if model.instanceID == nil, model.filterInstances.count > 1 { filterBar }
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let error = model.actionError {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                }
                let list = model.visible
                if list.isEmpty {
                    if model.hasLoaded {
                        EmptyStateView(
                            systemImage: "doc.text", title: ArtifactsText.emptyTitle(language),
                            message: ArtifactsText.emptyMessage(language))
                    } else {
                        LoadingStateView()
                    }
                } else {
                    GroupedSection {
                        ForEach(list) { artifact in
                            if artifact.id != list.first?.id { Divider() }
                            ArtifactRow(
                                artifact: artifact,
                                instanceName: model.instanceID == nil
                                    ? (model.instanceName(artifact.instanceID)
                                        ?? ArtifactsText.deletedInstance(language))
                                    : nil,
                                isDeleting: model.deleting.contains(artifact.id), canWrite: !app.isOffline,
                                onOpen: { router.open(.artifact(artifact.id, runID: artifact.runID)) },
                                onDelete: {
                                    pendingDeletion = artifact
                                    isConfirmingDeletion = true
                                })
                        }
                    }
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(title)
        .refreshable { await model.load() }
        // 每次回到这一页都重新拉（详情页里可能删了）。
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .confirmationDialog(
            ArtifactsText.deleteTitle(pendingDeletion?.name ?? "", language: language),
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let artifact = pendingDeletion { Task { await model.delete(artifact) } }
            } label: {
                Text(ArtifactsText.delete(language))
            }
            Button(role: .cancel) {
                pendingDeletion = nil
            } label: {
                Text(ArtifactsText.cancel(language))
            }
        } message: {
            Text(ArtifactsText.deleteMessage(language))
        }
    }

    private var filterBar: some View {
        let model = self.model
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.Spacing.xs) {
                PlansFilterChip(
                    title: ArtifactsText.allInstances(language), count: model.artifacts.count,
                    isSelected: model.filter == nil
                ) {
                    model.filter = nil
                }
                ForEach(model.filterInstances, id: \.self) { id in
                    PlansFilterChip(
                        title: model.instanceName(id) ?? ArtifactsText.deletedInstance(language),
                        count: model.artifacts.filter { $0.instanceID == id }.count, isSelected: model.filter == id
                    ) {
                        model.filter = id
                    }
                }
            }
            .padding(.horizontal, Metrics.Spacing.xxs)
        }
    }
}

/// 产出物库的一行：类型图标、名字（AI 生成标识）、实例 · 版本 · 大小 · 时间；右边“更多”。
struct ArtifactRow: View {
    let artifact: Artifact
    /// 全部实例的库里显示实例名；一个实例的为 nil。
    let instanceName: String?
    let isDeleting: Bool
    let canWrite: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Spacing.xs) {
            Button {
                onOpen()
            } label: {
                HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                    ArtifactIcon(artifact: artifact)
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        Text(verbatim: artifact.name)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(verbatim: meta)
                            .typography(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                        AIGeneratedLabel()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .contextMenu { menuItems }
            if isDeleting {
                ProgressView()
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            } else {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(
                    Text(language == .chinese ? "“\(artifact.name)”的更多操作" : "More for “\(artifact.name)”"))
            }
        }
        .padding(.leading, Metrics.Spacing.m)
        .padding(.trailing, Metrics.Spacing.xxs)
        .padding(.vertical, Metrics.Spacing.s)
    }

    private var meta: String {
        let parts = [
            instanceName,
            ConversationText.artifactMeta(version: artifact.version, size: artifact.size, language: language),
            Formatting.relativeTime(artifact.createdAt, language: language),
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label(ArtifactsText.delete(language), systemImage: "trash")
        }
        .disabled(!canWrite)
    }
}

/// 产出物的类型图标。
struct ArtifactIcon: View {
    let artifact: Artifact

    var body: some View {
        Image(systemName: Self.systemImage(artifact))
            .font(Typography.title3.font)
            .foregroundStyle(Theme.accent)
            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            .background(
                Theme.userBubble, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    static func systemImage(_ artifact: Artifact) -> String {
        if ArtifactFiles.isImage(artifact) { return "photo" }
        if artifact.contentType.lowercased() == "application/pdf" { return "doc.richtext" }
        if ArtifactFiles.isText(artifact) { return "doc.plaintext" }
        return "doc"
    }
}

/// 一个产出物（`.artifact(id, runID:)`）：名字（AI 生成标识）、版本、大小、时间、实例；文字类直接显示开头；“预览”用 QuickLook，
/// “分享或存到‘文件’”下载后给系统的分享面板（文件名带 AI 标识）；链到生成它的运行；右上角删除（二次确认，删了退回去）。
struct ArtifactDetailScreen: View {
    let artifactID: ArtifactID
    let runID: RunID

    @Environment(\.client) private var client
    @Environment(\.displayLanguage) private var language

    var body: some View {
        ArtifactDetailContent(
            model: ArtifactDetailModel(client: client, artifactID: artifactID, runID: runID, language: language))
    }
}

private struct ArtifactDetailContent: View {
    @State private var model: ArtifactDetailModel
    @State private var previewURL: URL?
    @State private var isConfirmingDeletion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: ArtifactDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.circle", title: ArtifactsText.missingTitle(language),
                        message: ArtifactsText.missingMessage(language))
                } else if let artifact = model.artifact {
                    header(artifact)
                    if let error = model.fileError {
                        ErrorBanner(error, onDismiss: { model.clearFileError() })
                    }
                    actions(artifact)
                    if let text = model.textPreview { textCard(text) }
                    Button {
                        router.open(.run(model.runID))
                    } label: {
                        Label(ArtifactsText.openRun(language), systemImage: "list.bullet.rectangle")
                            .typography(.subheadline)
                            .frame(minHeight: Metrics.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                } else if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    LoadingStateView()
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(
            model.artifact?.name ?? AppRoute.artifact(model.artifactID, runID: model.runID).title(language)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.artifact != nil {
                    Button {
                        isConfirmingDeletion = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(app.isOffline || model.isDeleting)
                    .accessibilityLabel(Text(ArtifactsText.delete(language)))
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: model.isDeleted) {
            if model.isDeleted { router.pop() }
        }
        .confirmationDialog(
            ArtifactsText.deleteTitle(model.artifact?.name ?? "", language: language),
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.delete() }
            } label: {
                Text(ArtifactsText.delete(language))
            }
            Button(role: .cancel) {
            } label: {
                Text(ArtifactsText.cancel(language))
            }
        } message: {
            Text(ArtifactsText.deleteMessage(language))
        }
        #if canImport(QuickLook)
            .quickLookPreview($previewURL)
        #endif
    }

    private func header(_ artifact: Artifact) -> some View {
        Card {
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                ArtifactIcon(artifact: artifact)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: artifact.name)
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    AIGeneratedLabel()
                }
            }
            Text(
                verbatim: [
                    model.instanceName ?? ArtifactsText.deletedInstance(language),
                    ConversationText.artifactMeta(version: artifact.version, size: artifact.size, language: language),
                ].joined(separator: " · ")
            )
            .typography(.subheadline)
            .foregroundStyle(Theme.inkSecondary)
            Text(ArtifactsText.createdAt(artifact.createdAt, language: language))
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    @ViewBuilder
    private func actions(_ artifact: Artifact) -> some View {
        let model = self.model
        VStack(spacing: Metrics.Spacing.xs) {
            PillButton(ArtifactsText.preview(language), systemImage: "eye") {
                Task { previewURL = await model.prepareFile() }
            }
            .frame(maxWidth: .infinity)
            .disabled(model.isPreparing || app.isOffline && model.fileURL == nil)
            if let url = model.fileURL {
                ShareLink(item: url) {
                    Label(ArtifactsText.share(language), systemImage: "square.and.arrow.up")
                        .typography(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                }
            } else {
                PillButton(ArtifactsText.share(language), systemImage: "square.and.arrow.up", kind: .secondary) {
                    Task { await model.prepareFile() }
                }
                .frame(maxWidth: .infinity)
                .disabled(model.isPreparing || app.isOffline)
            }
            if model.isPreparing {
                ProgressView()
                    .accessibilityLabel(Text(ArtifactsText.preparing(language)))
            }
        }
    }

    private func textCard(_ text: String) -> some View {
        Card {
            Text(verbatim: text)
                .font(Typography.footnote.monospacedFont)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.isTruncated {
                Text(ArtifactsText.truncated(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}
