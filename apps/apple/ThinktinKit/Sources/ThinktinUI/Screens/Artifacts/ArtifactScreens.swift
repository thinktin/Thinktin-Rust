import SwiftUI
import ThinktinKit

#if canImport(QuickLook)
    import QuickLook
#endif

/// 产出物库（`.artifacts(instanceID:)`，规范 4.5.2，参考 22、23、81–84）：Botin 资料、对话的“…”进来的是一个 Botin 的，
/// 工作台进来的是全部 Botin 的。
///
/// - 压栈页，inline 标题“产出物”；insetGrouped 列表，第一行是“全部 / 媒体 / 文件”三个筛选胶囊（`FilterChipBar`，带数，
///   跟着内容滚；参考的“链接”没有数据来源，换成“文件”，规范 6.19 C）。
/// - 下面按日期分组（今天、本周、更早），每行 28pt 缩略图或类型图标、单行名字、灰色副标题（类型 · 日期 · 大小，全部 Botin 的
///   带 Botin 名），行尾 AI 生成标识。图片点了全屏查看（`ArtifactImageViewer`），别的进产出物详情。左滑、长按删除（二次确认）。
/// - 超过 `ArtifactLibraryModel.collapsedLimit` 个时最下面居中一个灰色“展开”（本地折叠，规范 6.19 B）。
/// - 全部 Botin 的库右上一个筛选菜单（按 Botin，系统的单选菜单），有筛选时图标是实心的。
///
/// 离线策略是“没有缓存”：离线时显示已经拉到的。
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
    /// 正在全屏看的图片。
    @State private var viewing: Artifact?
    /// 全屏查看里点了“详情”：关掉之后压进它的详情。
    @State private var detailsAfterViewer: Artifact?
    @Namespace private var zoom

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: ArtifactLibraryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        let sections = model.sections()
        List {
            if !model.artifacts.isEmpty {
                Section {
                    kindBar
                        .clearListRow()
                }
            }
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let error = model.actionError {
                Section {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                        .clearListRow()
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.artifacts) { artifact in
                        row(artifact)
                    }
                } header: {
                    Text(section.group.title(language))
                        .textCase(nil)
                }
                .themedRow()
            }
            if model.hasMore {
                Section {
                    Button(ArtifactsText.expand(language)) { model.expand() }
                        .buttonStyle(.plain)
                        .typography(.body)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                        .clearListRow()
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(AppRoute.artifacts(instanceID: model.instanceID).title(language))
        .toolbar {
            if model.instanceID == nil, model.filterInstances.count > 1 {
                ToolbarItem(placement: ToolbarSlot.trailing) { botinFilter }
            }
        }
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
        .imageViewer(item: $viewing, onDismiss: showDetailsAfterViewer) { artifact in
            ArtifactImageViewer(artifact: artifact) {
                detailsAfterViewer = artifact
                viewing = nil
            }
            .zoomNavigationTransition(sourceID: artifact.id, in: zoom)
            .shellEnvironment(app)
            .tint(Theme.accent)
        }
    }

    // MARK: 筛选

    /// 顶上的“全部 / 媒体 / 文件”（参考 22 的位置）。
    private var kindBar: some View {
        @Bindable var model = model
        let options: [FilterChipBar<ArtifactCategory?>.Option] =
            [.init(value: nil, title: ArtifactsText.allInstances(language), count: model.count(of: nil))]
            + ArtifactCategory.allCases.map { .init(value: $0, title: $0.title(language), count: model.count(of: $0)) }
        return FilterChipBar(options, selection: $model.kind, horizontalInset: 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(ArtifactsText.filterByKind(language)))
    }

    /// 右上的“按 Botin 筛选”（全部 Botin 的库、不止一个 Botin 有产出物时）。
    private var botinFilter: some View {
        @Bindable var model = model
        return Menu {
            Picker(ArtifactsText.filterByBotin(language), selection: $model.filter) {
                Text(ArtifactsText.allBotins(language)).tag(InstanceID?.none)
                ForEach(model.filterInstances, id: \.self) { id in
                    Text(model.instanceName(id) ?? ArtifactsText.deletedInstance(language)).tag(InstanceID?.some(id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                ArtifactsText.filterByBotin(language),
                systemImage: model.filter == nil
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
            )
            .labelStyle(.iconOnly)
        }
    }

    // MARK: 行

    /// 图片点了全屏查看，别的压进详情。
    @ViewBuilder
    private func rowLink(_ artifact: Artifact) -> some View {
        let model = self.model
        let instanceName =
            model.instanceID == nil
            ? (model.instanceName(artifact.instanceID) ?? ArtifactsText.deletedInstance(language)) : nil
        let content = ArtifactRow(
            artifact: artifact, instanceName: instanceName, isDeleting: model.deleting.contains(artifact.id),
            thumbnail: { await model.thumbnail(for: $0) }
        )
        if ArtifactFiles.isViewableImage(artifact) {
            Button {
                viewing = artifact
            } label: {
                content
                    .zoomTransitionSource(id: artifact.id, in: zoom)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.artifact(artifact.id, runID: artifact.runID)) {
                content
            }
        }
    }

    private func row(_ artifact: Artifact) -> some View {
        rowLink(artifact)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    confirmDeletion(artifact)
                } label: {
                    Label(ArtifactsText.delete(language), systemImage: "trash")
                }
                .disabled(app.isOffline)
            }
            .contextMenu {
                Section {
                    Button {
                        router.open(.artifact(artifact.id, runID: artifact.runID))
                    } label: {
                        Label(ArtifactsText.details(language), systemImage: "info.circle")
                    }
                    Button {
                        router.open(.run(artifact.runID))
                    } label: {
                        Label(ArtifactsText.openRun(language), systemImage: "list.bullet.rectangle")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmDeletion(artifact)
                    } label: {
                        Label(ArtifactsText.delete(language), systemImage: "trash")
                    }
                    .disabled(app.isOffline)
                }
            }
    }

    private func confirmDeletion(_ artifact: Artifact) {
        pendingDeletion = artifact
        isConfirmingDeletion = true
    }

    private func showDetailsAfterViewer() {
        guard let artifact = detailsAfterViewer else { return }
        detailsAfterViewer = nil
        router.open(.artifact(artifact.id, runID: artifact.runID))
    }

    // MARK: 空状态

    @ViewBuilder
    private var placeholder: some View {
        let model = self.model
        switch model.placeholder {
        case .loading:
            ProgressView()
        case .unavailable(let offline):
            ContentUnavailableView {
                Label(
                    language == .chinese ? "暂时拉不到产出物" : "Couldn't load files",
                    systemImage: offline ? "wifi.slash" : "exclamationmark.triangle")
            } actions: {
                Button(ArtifactsText.retry(language)) { Task { await model.load() } }
                    .glassButtonStyle()
            }
        case .noneOfKind(let kind):
            // 胶囊那一行还在上面，空状态往下让一点。
            ContentUnavailableView(
                ArtifactsText.noneOfKind(kind, language: language),
                systemImage: kind == .media ? "photo.on.rectangle" : "doc",
                description: Text(ArtifactsText.noneOfKindMessage(kind, language: language)))
        case .empty:
            ContentUnavailableView(
                ArtifactsText.emptyTitle(language), systemImage: "folder",
                description: Text(ArtifactsText.emptyMessage(language)))
        case nil:
            EmptyView()
        }
    }
}

extension View {
    /// 图片全屏查看：iOS `fullScreenCover`（参考 24 是盖满全屏的），macOS 没有，用 sheet。
    @ViewBuilder
    fileprivate func imageViewer<Content: View>(
        item: Binding<Artifact?>, onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping (Artifact) -> Content
    ) -> some View {
        #if os(iOS)
            fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
            sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}

/// 产出物库的一行（参考 22）：28pt 缩略图或类型图标、单行名字（尾部截断）、灰色副标题（类型 · 日期 · 大小 · Botin），
/// 行尾 AI 生成标识；正在删时换成转圈。
struct ArtifactRow: View {
    let artifact: Artifact
    /// 全部 Botin 的库里显示 Botin 名；一个 Botin 的为 nil。
    let instanceName: String?
    var isDeleting = false
    /// 拿图片缩略图的字节（`ArtifactLibraryModel.thumbnail(for:)`）；nil 只画图标。
    var thumbnail: (@MainActor (Artifact) async -> Data?)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            ArtifactThumbnail(artifact: artifact, load: thumbnail)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(verbatim: artifact.name)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(verbatim: ArtifactsText.rowSubtitle(artifact, instanceName: instanceName, language: language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.Spacing.xs)
            if isDeleting {
                ProgressView()
            } else {
                AIGeneratedLabel()
            }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// 产出物的类型图标（参考 22 的地球图标那样：没有底，灰色）。
struct ArtifactIcon: View {
    let artifact: Artifact

    var body: some View {
        Image(systemName: Self.systemImage(artifact))
            .font(Typography.title3.font)
            .foregroundStyle(Theme.inkSecondary)
            .frame(width: ArtifactThumbnail.size, height: ArtifactThumbnail.size)
            .accessibilityHidden(true)
    }

    static func systemImage(_ artifact: Artifact) -> String {
        let type = artifact.contentType.lowercased()
        if ArtifactFiles.isImage(artifact) { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type == "application/pdf" { return "doc.richtext" }
        if ArtifactFiles.isText(artifact) { return "doc.plaintext" }
        return "doc"
    }
}

/// 一个产出物（`.artifact(id, runID:)`，规范 4.5.3 的产出物详情）：对话、运行详情里的产出物卡片、库里点进来，
/// 图片全屏查看的“详情”。insetGrouped 列表：
///
/// - 头部（透明行）：图标、名字、AI 生成标识；
/// - 信息：Botin、类型、版本、大小、生成于；文字类的“内容”一组直接显示开头；“查看生成它的运行”；
/// - 底部浮着两个按钮：“预览”（QuickLook）和“分享”（下载后给系统的分享面板，文件名带 AI 标识）；
/// - 右上“…”里删除（二次确认，删了退回去）。
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
        List {
            if let artifact = model.artifact, !model.isMissing {
                Section {
                    header(artifact)
                        .clearListRow()
                }
                if let error = model.fileError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.clearFileError() })
                            .clearListRow()
                    }
                }
                infoSection(artifact)
                if let text = model.textPreview {
                    Section {
                        Text(verbatim: text)
                            .font(Typography.footnote.monospacedFont)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        Text(ArtifactsText.contentSection(language)).textCase(nil)
                    } footer: {
                        if model.isTruncated { Text(ArtifactsText.truncated(language)) }
                    }
                    .themedRow()
                }
                Section {
                    NavigationLink(value: AppRoute.run(model.runID)) {
                        Label(ArtifactsText.openRun(language), systemImage: "list.bullet.rectangle")
                    }
                }
                .themedRow()
            } else if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .floatingBar {
            if model.artifact != nil, !model.isMissing { actions }
        }
        .inlineNavigationTitle(
            model.artifact?.name ?? AppRoute.artifact(model.artifactID, runID: model.runID).title(language)
        )
        .toolbar {
            if model.artifact != nil, !model.isMissing {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingDeletion = true
                        } label: {
                            Label(ArtifactsText.delete(language), systemImage: "trash")
                        }
                        .disabled(app.isOffline || model.isDeleting)
                    } label: {
                        Label(ArtifactsText.more(language), systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
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

    @ViewBuilder
    private var placeholder: some View {
        if model.isMissing {
            ContentUnavailableView(
                ArtifactsText.missingTitle(language), systemImage: "questionmark.folder",
                description: Text(ArtifactsText.missingMessage(language)))
        } else if model.artifact == nil, model.error == nil {
            ProgressView()
        }
    }

    /// 头部：类型图标、名字、AI 生成标识（居中，和 Botin 资料的头部一个意思）。
    private func header(_ artifact: Artifact) -> some View {
        VStack(spacing: Metrics.Spacing.xs) {
            Image(systemName: ArtifactIcon.systemImage(artifact))
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(verbatim: artifact.name)
                .font(Font.title3.bold())
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            AIGeneratedLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.s)
    }

    private func infoSection(_ artifact: Artifact) -> some View {
        Section {
            LabeledContent(
                ArtifactsText.botinLabel(language),
                value: model.instanceName ?? ArtifactsText.deletedInstance(language))
            LabeledContent(
                ArtifactsText.kindLabel(language), value: ArtifactsText.kindName(artifact, language: language))
            LabeledContent(ArtifactsText.versionLabel(language), value: "v\(artifact.version)")
            LabeledContent(ArtifactsText.sizeLabel(language), value: Formatting.bytes(artifact.size))
            LabeledContent(
                ArtifactsText.createdLabel(language), value: Formatting.dateTime(artifact.createdAt, language: language)
            )
        }
        .themedRow()
    }

    /// 底部的“预览”“分享”（规范 4.5.3：放底部，删除在“…”里）。
    private var actions: some View {
        let model = self.model
        return HStack(spacing: Metrics.Spacing.s) {
            Button {
                Task { previewURL = await model.prepareFile() }
            } label: {
                Label(ArtifactsText.preview(language), systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(.prominent)
            .disabled(model.isPreparing || app.isOffline && model.fileURL == nil)
            if let url = model.fileURL {
                ShareLink(item: url) {
                    Label(ArtifactsText.shareShort(language), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
            } else {
                Button {
                    Task { await model.prepareFile() }
                } label: {
                    if model.isPreparing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text(ArtifactsText.preparing(language)))
                    } else {
                        Label(ArtifactsText.shareShort(language), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .glassButtonStyle()
                .disabled(model.isPreparing || app.isOffline)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.bottom, Metrics.Spacing.xs)
    }
}
