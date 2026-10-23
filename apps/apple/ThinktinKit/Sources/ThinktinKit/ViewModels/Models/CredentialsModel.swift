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

/// 保存路由、添加 / 启用 / 换 key 之后，服务端会唤醒卡在“等待 key”的运行（7.11）。
///
/// 服务端的“唤醒”只是把这些运行的下次尝试时间改成现在（`wake_waiting_runs`），状态还是“等待 key”，要等执行器接手
/// 才变（key 还是不能用的会接着等）。所以接口一返回就去数，数到的和操作前一样多，不能拿“前后之差”说接着跑了几个。
/// 这里只在操作前数一次：这么多个在等 key 的任务这次会马上重试。操作后照样拉一次运行，刷新各实例的运行缓存。
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

/// 唤醒等 key 的运行的结果（界面显示一句话）。
public struct KeyWakeResult: Hashable, Sendable {
    /// 操作前在等 key、这次会马上重试的运行数。
    public var retried: Int

    public init(retried: Int) {
        self.retried = max(0, retried)
    }

    /// 操作前没数到（拉不到）时为 nil，界面只说通用的“等 key 的任务会接着跑”。
    init?(retried: Int?) {
        guard let retried else { return nil }
        self.init(retried: retried)
    }

    /// 要说的话；操作前没有等 key 的运行时为 nil（不用提）。不说“还有几个在等”：刚唤醒时它们的状态还没变（见 `KeyWaitProbe`）。
    public func message(_ language: DisplayLanguage = .current) -> String? {
        guard retried > 0 else { return nil }
        return language == .chinese
            ? "\(retried) 个在等 key 的任务马上重试：key 能用就接着跑，还不能用的会继续等。"
            : "\(retried) task(s) waiting for a key are retrying now. They continue if a key works; otherwise they keep "
                + "waiting."
    }
}
