import ImageIO
import SwiftUI
import ThinktinKit

#if os(iOS)
    import Photos
#endif

// 产出物里的图片（规范 4.5.2、4.5.3，参考 22、24、25）：库里一行的 28pt 缩略图、全屏查看、存相册。
// 解码用 ImageIO 按需缩小（iOS、macOS 一套写法，大图不整张解进内存）。

/// 把图片的字节解成 `CGImage`，最长边缩到 `maxPixelSize` 以内（带 EXIF 的方向）。解不出来为 nil。
enum ArtifactImageDecoder {
    static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 库里一行左边的东西：能看的图片画缩略图（`ArtifactLibraryModel.thumbnail(for:)`，下不到、解不出时画类型图标），
/// 别的画类型图标。28pt，圆角 6（参考 22 的大小）。
struct ArtifactThumbnail: View {
    let artifact: Artifact
    /// 拿缩略图的字节；nil（预览、测试）只画图标。
    var load: (@MainActor (Artifact) async -> Data?)?

    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    static let size: CGFloat = 28

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ArtifactIcon(artifact: artifact)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .task(id: artifact.id) {
            guard image == nil, let load, ArtifactFiles.isViewableImage(artifact) else { return }
            guard let data = await load(artifact) else { return }
            image = ArtifactImageDecoder.decode(data, maxPixelSize: Int(Self.size * max(displayScale, 1)))
        }
    }
}

#if os(iOS)
    /// 存进系统相册：只申请“添加照片”的权限（Info.plist 的 `NSPhotoLibraryAddUsageDescription`）。没给权限抛
    /// `ArtifactSaveError.denied`。
    enum PhotoLibrarySaver {
        nonisolated static func saveImage(at url: URL) async throws {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw ArtifactSaveError.denied }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
        }
    }
#endif
