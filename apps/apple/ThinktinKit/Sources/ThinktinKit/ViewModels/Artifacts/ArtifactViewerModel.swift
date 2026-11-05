import Foundation
import Observation

/// 图片全屏查看（规范 4.5.3，参考 24、25）：产出物库里点一张图片打开。下载整份文件（`data`，界面解码显示），
/// 同时落到本机（`fileURL`，文件名带 AI 标识，分享、存相册、放大预览用）。“保存到相册”由界面给出真正的保存办法
/// （iOS 是相册的“添加”权限），这里管状态：保存中、存好了几次（触感的触发器）、没权限或失败。
@Observable @MainActor
public final class ArtifactViewerModel {
    public let artifact: Artifact
    public private(set) var data: Data?
    public private(set) var fileURL: URL?
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isSaving = false
    /// 存好了几次（界面拿它触发成功的触感）。
    public private(set) var saveCount = 0
    public private(set) var saveError: ArtifactSaveError?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let language: DisplayLanguage
    @ObservationIgnored private let directory: URL

    public init(
        client: any ClientProtocol, artifact: Artifact, language: DisplayLanguage = .current,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.client = client
        self.artifact = artifact
        self.language = language
        self.directory = directory
    }

    /// 下载（打开时、点“重试”）。已经下好的不再下。
    public func load() async {
        guard data == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.artifactContent(artifact.id)
            data = fetched
            error = nil
            fileURL = try? ArtifactFiles.write(fetched, for: artifact, language: language, directory: directory)
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            self.error = failure
        }
    }

    /// 能分享、保存了（文件落到本机了）。
    public var canExport: Bool { fileURL != nil }

    /// 存一份：`saver` 拿到本机文件去存（抛 `ArtifactSaveError.denied` 是没权限，别的错误算没存上）。
    public func save(using saver: @MainActor (URL) async throws -> Void) async {
        guard let fileURL, !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await saver(fileURL)
            saveCount += 1
        } catch let failure as ArtifactSaveError {
            saveError = failure
        } catch {
            saveError = .failed
        }
    }

    public func clearSaveError() {
        saveError = nil
    }
}

/// 存相册没成。
public enum ArtifactSaveError: Error, Hashable, Sendable {
    /// 用户没给“添加照片”的权限。
    case denied
    case failed
}
