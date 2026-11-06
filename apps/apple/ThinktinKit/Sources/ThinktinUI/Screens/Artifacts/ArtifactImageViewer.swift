import SwiftUI
import ThinktinKit

#if canImport(QuickLook)
    import QuickLook
#endif

/// 图片全屏查看（规范 4.5.3，参考 24、25）：产出物库里点一张图片，iOS 全屏盖上来（macOS 是 sheet），不加路由。
///
/// - 纯黑底；左上玻璃 ×，右上玻璃“…”：分享（系统分享面板，文件名带 AI 标识）、保存到相册（只有 iOS，只要“添加”权限）；
///   第二组“详情”进产出物详情（版本、大小、生成它的运行、删除）。参考还有“转发”（发给另一个 Bot），要后端，不做。
/// - 图片按屏宽适配，左右留 16，圆角 12；点图片用系统的预览（QuickLook）放大、平移。
/// - 底部一行灰字：文件名，带 AI 生成标识。
/// - 加载中转圈；下不到时说打不开、可以重试；没下好时分享和保存灰掉。
struct ArtifactImageViewer: View {
    let artifact: Artifact
    /// “详情”：关掉自己，由库压进产出物详情。
    let onShowDetails: @MainActor () -> Void

    @Environment(\.client) private var client
    @Environment(\.displayLanguage) private var language

    var body: some View {
        ArtifactImageViewerContent(
            model: ArtifactViewerModel(client: client, artifact: artifact, language: language),
            onShowDetails: onShowDetails)
    }
}

private struct ArtifactImageViewerContent: View {
    @State private var model: ArtifactViewerModel
    @State private var image: CGImage?
    @State private var previewURL: URL?
    let onShowDetails: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    init(model: ArtifactViewerModel, onShowDetails: @escaping @MainActor () -> Void) {
        _model = State(initialValue: model)
        self.onShowDetails = onShowDetails
    }

    /// 解码时最长边的像素（屏幕再大也够看；放大看交给系统预览，那里用原图）。
    private static let maxPixelSize = 2400

    var body: some View {
        let model = self.model
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .safeAreaInset(edge: .bottom) { caption }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    moreMenu
                }
            }
            .task {
                await model.load()
                decode()
            }
            .appFeedback(.success, trigger: model.saveCount)
            .alert(
                model.saveError.map { ArtifactsText.saveErrorTitle($0, language: language) } ?? "",
                isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.clearSaveError() } })
            ) {
                Button(ArtifactsText.ok(language)) { model.clearSaveError() }
            } message: {
                if let error = model.saveError { Text(ArtifactsText.saveErrorMessage(error, language: language)) }
            }
            #if canImport(QuickLook)
                .quickLookPreview($previewURL)
            #endif
        }
        // 参考 24 是纯黑底上的玻璃按钮：深色外观，按钮和字都按深色画。
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        let model = self.model
        if let image {
            Button {
                previewURL = model.fileURL
            } label: {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, Metrics.Spacing.m)
            }
            .buttonStyle(.plain)
            .disabled(model.fileURL == nil)
            .accessibilityLabel(Text(verbatim: model.artifact.name))
            .accessibilityHint(Text(ArtifactsText.preview(language)))
        } else if model.isLoading || (model.data == nil && model.error == nil) {
            ProgressView()
                .tint(.white)
                .accessibilityLabel(Text(ArtifactsText.preparing(language)))
        } else {
            ContentUnavailableView {
                Label(ArtifactsText.imageUnavailable(language), systemImage: "photo")
            } description: {
                if let error = model.error { Text(ErrorPresentation(error, language: language).message) }
            } actions: {
                if model.data == nil {
                    Button(ArtifactsText.retry(language)) {
                        Task {
                            await model.load()
                            decode()
                        }
                    }
                    .glassButtonStyle()
                }
            }
        }
    }

    /// 底部的文件名（参考 24 的那行灰字），带 AI 生成标识。
    private var caption: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            Text(verbatim: model.artifact.name)
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            AIGeneratedLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.bottom, Metrics.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    /// 右上“…”（参考 25：转发、分享、保存；转发要后端，换成“详情”放第二组）。
    private var moreMenu: some View {
        let model = self.model
        return Menu {
            Section {
                if let url = model.fileURL {
                    ShareLink(item: url) {
                        Label(ArtifactsText.shareShort(language), systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                    } label: {
                        Label(ArtifactsText.shareShort(language), systemImage: "square.and.arrow.up")
                    }
                    .disabled(true)
                }
                #if os(iOS)
                    Button {
                        Task { await model.save { try await PhotoLibrarySaver.saveImage(at: $0) } }
                    } label: {
                        Label(ArtifactsText.saveToPhotos(language), systemImage: "square.and.arrow.down")
                    }
                    .disabled(!model.canExport || model.isSaving)
                #endif
            }
            Section {
                Button {
                    onShowDetails()
                } label: {
                    Label(ArtifactsText.details(language), systemImage: "info.circle")
                }
            }
        } label: {
            Label(ArtifactsText.more(language), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }

    private func decode() {
        guard image == nil, let data = model.data else { return }
        image = ArtifactImageDecoder.decode(data, maxPixelSize: Self.maxPixelSize)
    }
}

#Preview("图片全屏查看") {
    ArtifactImageViewer(
        artifact: Artifact(
            id: "art-image", instanceID: DemoData.writerID, runID: DemoData.weeklyRunID, name: "首页截图.png",
            contentType: "image/png", size: 2048, createdAt: Date()),
        onShowDetails: {}
    )
    .previewShell()
}
