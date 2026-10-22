import Foundation
import Observation

/// 模型 key 列表（WBS 12.4，`.credentials`，入口：设置 → 模型 key、对话页“等待 key”的“去处理”）：每把 key 显示厂商、
/// 备注、后 4 位、停用状态、每日上限、支持的协议。在用的排前面，停用的单独一组。
///
/// key 不缓存（docs/ios.md 第 6.2 节：离线时“暂无数据”）：拉不到时留着上次拉到的，错误给界面显示。
/// 厂商表拉不到不影响列表（厂商名退回成 id）。
@Observable @MainActor
public final class CredentialsModel {
    public private(set) var credentials: [Credential] = []
    public private(set) var vendors: [VendorInfo] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 最近一次拉取 key 列表的错误；成功后清掉。
    public private(set) var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    /// 拉 key 列表和厂商表（打开页面、下拉刷新、添加 key 的 sheet 关掉后、联网后）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = self.client
        async let credentials = AgentsErrors.attempt { try await client.credentials() }
        async let vendors = AgentsErrors.attempt { try await client.vendors() }
        switch await credentials {
        case .success(let list):
            self.credentials = list
            hasLoaded = true
            error = nil
        case .failure(let failure):
            if let failure = AgentsErrors.from(failure) { error = failure }
        }
        if case .success(let list) = await vendors { self.vendors = list }
    }

    /// 拉过了，一把 key 都没有。
    public var isEmpty: Bool { hasLoaded && credentials.isEmpty }

    /// 在用的 key（先加的在前）。
    public var activeCredentials: [Credential] {
        credentials.filter { !$0.isDisabled }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 停用了的 key。
    public var disabledCredentials: [Credential] {
        credentials.filter(\.isDisabled).sorted { $0.createdAt < $1.createdAt }
    }

    /// 列表里一行显示的内容。
    public func summary(of credential: Credential, language: DisplayLanguage = .current) -> CredentialSummary {
        CredentialSummary(credential: credential, vendors: vendors, language: language)
    }
}

/// key 列表里的一行（界面直接显示这些字段）。
public struct CredentialSummary: Identifiable, Hashable, Sendable {
    public var id: CredentialID
    /// 备注，没有备注时是厂商名。
    public var name: String
    public var vendorName: String
    /// 头像上的字（厂商名的第一个字，不用厂商标志）。
    public var monogram: String
    /// `••••Q7mA`。
    public var maskedKey: String
    public var isDisabled: Bool
    public var statusName: String
    public var dailyLimit: String
    /// 支持的协议（老的服务端没给时为 nil）。
    public var protocols: String?

    public init(credential: Credential, vendors: [VendorInfo], language: DisplayLanguage = .current) {
        id = credential.id
        vendorName = ModelsText.vendorName(credential.vendor, vendors: vendors, language: language)
        name = ModelsText.credentialName(credential, vendors: vendors, language: language)
        monogram = ModelsText.monogram(vendorName)
        maskedKey = credential.maskedKey
        isDisabled = credential.isDisabled
        statusName = ModelsText.statusName(isDisabled: credential.isDisabled, language: language)
        dailyLimit = ModelsText.dailyLimit(credential.dailyTokenLimit, language: language)
        protocols = ModelsText.protocolList(credential.protocols, language: language)
    }

    /// 名字下面那一行：“Anthropic (Claude) · ••••Q7mA”（名字就是厂商名时不重复）。
    public var subtitle: String {
        name == vendorName ? maskedKey : vendorName + " · " + maskedKey
    }

    /// 读屏念的一句话。后 4 位逐个字符念（不然会念成一个词）。
    public func accessibilityLabel(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let last4 = maskedKey.replacingOccurrences(of: "•", with: "").map(String.init).joined(separator: " ")
        var parts = [name]
        if name != vendorName { parts.append(vendorName) }
        parts.append((zh ? "尾号 " : "ending in ") + last4)
        parts.append(statusName)
        parts.append(dailyLimit)
        if let protocols { parts.append((zh ? "支持 " : "supports ") + protocols) }
        return parts.joined(separator: zh ? "，" : ", ")
    }
}

// MARK: - 等 key 的运行

/// 保存路由、启用或换 key 之后，服务端会唤醒卡在“等待 key”的运行（7.11）。这里数一下等 key 的运行，
/// 操作前后各数一次，界面据此说“已唤醒 N 个任务”“还有 N 个在等 key”。
enum KeyWaitProbe {
    /// 这些实例上在等 key 的运行数（`instanceIDs` 为 nil 时是全部实例）。拉不到为 nil。
    /// 用跨实例的进行中运行（`listRuns(filter: .active)`），它同时刷新每个实例的运行缓存，对话页能看到新状态。
    static func waitingRuns(client: any ClientProtocol, instanceIDs: Set<InstanceID>?) async -> Int? {
        do {
            let runs = try await client.listRuns(filter: .active, before: nil, limit: RunFilter.maxLimit)
            return runs.filter { run in
                run.state == .waitingQuota && (instanceIDs?.contains(run.instanceID) ?? true)
            }.count
        } catch {
            return nil
        }
    }
}

/// 唤醒等 key 的运行之后的结果（界面显示一句话）。
public struct KeyWakeResult: Hashable, Sendable {
    /// 操作前在等 key 的运行数。
    public var waitingBefore: Int
    /// 操作后还在等 key 的。
    public var waitingAfter: Int

    public init(waitingBefore: Int, waitingAfter: Int) {
        self.waitingBefore = waitingBefore
        self.waitingAfter = waitingAfter
    }

    /// 接着跑了的。
    public var resumed: Int { max(0, waitingBefore - waitingAfter) }

    /// 前后有一次没数到（拉不到）时为 nil，界面只说通用的“等 key 的任务会接着跑”。
    init?(before: Int?, after: Int?) {
        guard let before, let after else { return nil }
        self.init(waitingBefore: before, waitingAfter: after)
    }

    /// 要说的话；前后都没有等 key 的运行时为 nil（不用提）。
    public func message(_ language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch (resumed, waitingAfter) {
        case (0, 0):
            return nil
        case (let n, 0):
            return zh ? "已唤醒 \(n) 个在等 key 的任务，它们会接着跑。" : "Resumed \(n) task(s) that were waiting for a key."
        case (0, let left):
            return zh
                ? "还有 \(left) 个任务在等 key，可能是别的别名或别的实例的 key 有问题。"
                : "\(left) task(s) are still waiting for a key; another alias or instance may need attention."
        case (let n, let left):
            return zh
                ? "已唤醒 \(n) 个任务；还有 \(left) 个在等 key。"
                : "Resumed \(n) task(s); \(left) are still waiting for a key."
        }
    }
}
