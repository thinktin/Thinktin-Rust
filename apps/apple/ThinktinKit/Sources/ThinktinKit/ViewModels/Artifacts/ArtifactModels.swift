import Foundation
import Observation

/// 产出物库（WBS 12.18，`.artifacts(instanceID:)`：抽屉里的“产出物”是全部实例的，实例详情进来的是一个实例的）：
/// 最新的在前，每条显示所属实例、版本、大小、时间；全部实例时可以按实例筛选。点开进产出物详情，长按删除。
///
/// 全部实例的：先拉实例列表（不含已删除的），再并发拉每个实例最近的 `perInstanceLimit` 个，合起来按时间排；某个实例拉不到
/// 不影响别的。离线策略是“没有缓存”。
@Observable @MainActor
public final class ArtifactLibraryModel {
    /// 每个实例拉多少个（服务端一页最多 `Artifact.maxListLimit`）。
    public nonisolated static let perInstanceLimit = 100

    public let instanceID: InstanceID?
    public private(set) var artifacts: [Artifact] = []
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var actionError: ClientError?
    public private(set) var deleting: Set<ArtifactID> = []
    /// 全部实例时按实例筛选（nil 是全部）。
    public var filter: InstanceID?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, instanceID: InstanceID? = nil) {
        self.client = client
        self.instanceID = instanceID
    }

    /// 筛选后的。
    public var visible: [Artifact] {
        guard let filter else { return artifacts }
        return artifacts.filter { $0.instanceID == filter }
    }

    /// 有产出物的实例（筛选条用），按名字排。
    public var filterInstances: [InstanceID] {
        Array(Set(artifacts.map(\.instanceID))).sorted {
            (instanceNames[$0] ?? $0.rawValue) < (instanceNames[$1] ?? $1.rawValue)
        }
    }

    public func instanceName(_ id: InstanceID) -> String? { instanceNames[id] }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if instanceNames.isEmpty, let cached = try? client.cachedInstances() { instanceNames = Self.names(cached) }
        do {
            if let instanceID {
                artifacts = Self.sorted(try await client.instanceArtifacts(instanceID, limit: Self.perInstanceLimit))
                error = nil
            } else {
                let instances = try await client.instances().filter { $0.state != .deleted }
                instanceNames = Self.names(instances)
                await loadArtifacts(for: instances.map(\.id))
            }
            if let filter, !artifacts.contains(where: { $0.instanceID == filter }) { self.filter = nil }
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
        if instanceID != nil, let fresh = try? await client.instances() {
            instanceNames.merge(Self.names(fresh)) { _, new in new }
        }
        hasLoaded = true
    }

    /// 删一个（页面先二次确认）。已经没有了的照样拿掉。
    public func delete(_ artifact: Artifact) async {
        guard !deleting.contains(artifact.id) else { return }
        deleting.insert(artifact.id)
        defer { deleting.remove(artifact.id) }
        do {
            try await client.deleteArtifact(artifact.id)
            artifacts.removeAll { $0.id == artifact.id }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound {
                artifacts.removeAll { $0.id == artifact.id }
            } else {
                actionError = failure
            }
        }
    }

    public func clearActionError() {
        actionError = nil
    }

    private func loadArtifacts(for ids: [InstanceID]) async {
        let client = self.client
        var next: [Artifact] = []
        var firstError: ClientError?
        await withTaskGroup(of: (InstanceID, Result<[Artifact], any Error>).self) { group in
            for id in ids {
                group.addTask {
                    let result = await AgentsErrors.attempt {
                        try await client.instanceArtifacts(id, limit: Self.perInstanceLimit)
                    }
                    return (id, result)
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let list):
                    next += list
                case .failure(let failure):
                    // 某个实例暂时拉不到时保留它上次的结果，其余实例仍正常更新。
                    next += artifacts.filter { $0.instanceID == id }
                    firstError = firstError ?? ConversationErrors.from(failure)
                }
            }
        }
        artifacts = Self.sorted(next)
        error = firstError
    }

    static func sorted(_ list: [Artifact]) -> [Artifact] {
        list.sorted { ($0.createdAt, $0.id.rawValue) > ($1.createdAt, $1.id.rawValue) }
    }

    static func names(_ instances: [Instance]) -> [InstanceID: String] {
        Dictionary(
            instances.filter { $0.state != .deleted }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 一个产出物（WBS 12.18，`.artifact(id, runID:)`）：名字（agent 起的，AI 生成标识）、类型、版本、大小、时间、所属实例和运行；
/// 文字类的直接显示开头（`textPreview`）；“预览”“分享”先下载到本机（`prepareFile`，文件名带 AI 标识），删除。
@Observable @MainActor
public final class ArtifactDetailModel {
    public let artifactID: ArtifactID
    public let runID: RunID
    public private(set) var artifact: Artifact?
    public private(set) var instanceName: String?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 运行里没有这个产出物了（删了）。
    public private(set) var isMissing = false
    /// 文字类的开头（`ArtifactFiles.textPreviewLimit` 字节以内）。
    public private(set) var textPreview: String?
    /// 文字只显示了开头。
    public private(set) var isTruncated = false
    /// 下载到本机的文件（预览、分享用）。
    public private(set) var fileURL: URL?
    public private(set) var isPreparing = false
    public private(set) var fileError: ClientError?
    public private(set) var isDeleting = false
    public private(set) var isDeleted = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let language: DisplayLanguage
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var content: Data?

    public init(
        client: any ClientProtocol, artifactID: ArtifactID, runID: RunID, language: DisplayLanguage = .current,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.client = client
        self.artifactID = artifactID
        self.runID = runID
        self.language = language
        self.directory = directory
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.runArtifacts(runID)
            guard let found = list.first(where: { $0.id == artifactID }) else {
                isMissing = true
                hasLoaded = true
                return
            }
            artifact = found
            isMissing = false
            error = nil
            if instanceName == nil {
                let cached = (try? client.cachedInstances()) ?? []
                instanceName = cached.first { $0.id == found.instanceID && $0.state != .deleted }?.name
                if instanceName == nil, let fresh = try? await client.instances() {
                    instanceName = fresh.first { $0.id == found.instanceID && $0.state != .deleted }?.name
                }
            }
            if ArtifactFiles.isText(found), textPreview == nil { await loadText(found) }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isMissing = true } else { self.error = failure }
        }
        hasLoaded = true
    }

    /// 下载到本机（预览、分享前）。已经下载过的直接用。
    @discardableResult
    public func prepareFile() async -> URL? {
        if let fileURL { return fileURL }
        guard let artifact, !isPreparing else { return nil }
        isPreparing = true
        fileError = nil
        defer { isPreparing = false }
        do {
            let data = try await data()
            let url = try ArtifactFiles.write(data, for: artifact, language: language, directory: directory)
            fileURL = url
            return url
        } catch {
            guard let failure = ConversationErrors.from(error) else { return nil }
            fileError = failure
            return nil
        }
    }

    public func delete() async {
        guard artifact != nil, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await client.deleteArtifact(artifactID)
            isDeleted = true
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isDeleted = true } else { fileError = failure }
        }
    }

    public func clearFileError() {
        fileError = nil
    }

    private func loadText(_ artifact: Artifact) async {
        guard let data = try? await data() else { return }
        let limit = ArtifactFiles.textPreviewLimit
        isTruncated = data.count > limit
        // 截断处可能在一个字的中间：解不出来就往前退几个字节。
        var slice = data.prefix(limit)
        var text = String(data: slice, encoding: .utf8)
        var trimmed = 0
        while text == nil, trimmed < 4, !slice.isEmpty {
            slice = slice.dropLast()
            trimmed += 1
            text = String(data: slice, encoding: .utf8)
        }
        textPreview = text
    }

    private func data() async throws -> Data {
        if let content { return content }
        let fetched = try await client.artifactContent(artifactID)
        content = fetched
        return fetched
    }
}
