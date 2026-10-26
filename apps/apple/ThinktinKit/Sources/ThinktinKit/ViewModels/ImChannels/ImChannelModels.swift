import Foundation
import Observation

/// 列表页上的一句提示。
public enum ImChannelNotice: Hashable, Sendable {
    /// 测试消息排上了。
    case testQueued(ImChannelID)
    /// 测试消息发得太勤（每小时 10 条）。
    case testRateLimited
    /// 渠道关着，先打开。
    case turnOnFirst
}

/// IM 渠道（WBS 12.14，`.imChannels`）：绑定的群机器人，开关、发测试消息、删除；新建、修改在 `ImChannelEditorModel`。
///
/// 发不出去的原因（服务端记的英文诊断）用 `ImChannelText.lastError` 换成怎么处理；机器人失效时后台会把渠道停掉，换上新地址
/// 就会重新打开。
@Observable @MainActor
public final class ImChannelsModel {
    public private(set) var channels: [ImChannel] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public var error: ClientError?
    public var notice: ImChannelNotice?
    /// 正在开关、测试、删除的渠道。
    public private(set) var busy: Set<ImChannelID> = []

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    /// 还能再绑（最多 20 个）。
    public var canAdd: Bool { channels.count < ImChannelRules.maxChannels }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            channels = try await client.imChannels()
            hasLoaded = true
            error = nil
        } catch {
            self.error = Self.clientError(error)
        }
    }

    public func setEnabled(_ id: ImChannelID, _ enabled: Bool) async {
        await perform(id) {
            let updated = try await self.client.updateImChannel(id, label: nil, events: nil, enabled: enabled)
            self.replace(updated)
        }
    }

    /// 发一条测试消息（经服务端的出箱，几秒内到群里；结果写回渠道的上次发送时间、错误）。
    public func sendTest(_ id: ImChannelID) async {
        notice = nil
        guard channels.first(where: { $0.id == id })?.isEnabled != false else {
            notice = .turnOnFirst
            return
        }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await client.testImChannel(id)
            notice = .testQueued(id)
            error = nil
        } catch let failure as ClientError where failure.isRateLimited {
            notice = .testRateLimited
        } catch {
            self.error = Self.clientError(error)
        }
    }

    /// 删除；已经没有了的照样拿掉。
    public func delete(_ id: ImChannelID) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await client.deleteImChannel(id)
            channels.removeAll { $0.id == id }
        } catch let failure as ClientError where failure.isNotFound {
            channels.removeAll { $0.id == id }
        } catch {
            self.error = Self.clientError(error)
        }
    }

    /// 编辑页存好了：换上新的（新建的加在后面）。
    public func replace(_ channel: ImChannel) {
        if let i = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[i] = channel
        } else {
            channels.append(channel)
        }
    }

    private func perform(_ id: ImChannelID, _ body: () async throws -> Void) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await body()
            error = nil
        } catch let failure as ClientError where failure.isNotFound {
            channels.removeAll { $0.id == id }
        } catch {
            self.error = Self.clientError(error)
        }
    }

    static func clientError(_ error: any Error) -> ClientError {
        (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}

/// 新建、修改一个 IM 渠道（sheet）。
///
/// - 新建：粘贴 webhook 地址（边粘边认出是哪家）、签名密钥（企业微信没有）、备注、事件（默认全选）。
/// - 修改：备注、事件；“换地址”打开后才填新地址和密钥（群机器人重建了、密钥重置了）。
/// - 规则见 `ImChannelRules`；点保存后问题标在对应的地方，改了就重新查。
@Observable @MainActor
public final class ImChannelEditorModel {
    /// 修改的渠道（存过一部分后换成存好的，再点保存只做剩下的）；新建时为 nil。
    public private(set) var original: ImChannel?
    public var webhookURL = ""
    public var secret = ""
    public var label = ""
    public private(set) var events: [ImEvent]
    /// 修改时：要不要换地址。
    public var isReplacingWebhook = false
    public private(set) var isSaving = false
    public private(set) var attemptedSave = false
    public var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, channel: ImChannel? = nil) {
        self.client = client
        original = channel
        label = channel?.label ?? ""
        events = channel?.events.filter { ImEvent.knownCases.contains($0) } ?? ImEvent.knownCases
    }

    public var isNew: Bool { original == nil }
    /// 要填地址（新建，或者修改时打开了“换地址”）。
    public var editsWebhook: Bool { isNew || isReplacingWebhook }

    /// 粘贴的地址是哪家的（还没粘完整也认得出）；修改时没换地址就是原来的。
    public var vendor: ImVendor? {
        editsWebhook ? ImChannelRules.vendor(of: webhookURL) : original?.vendor
    }

    public var supportsSecret: Bool { vendor.map(ImChannelRules.supportsSecret) ?? true }

    public func isSelected(_ event: ImEvent) -> Bool { events.contains(event) }

    public func toggle(_ event: ImEvent) {
        if events.contains(event) {
            events.removeAll { $0 == event }
        } else {
            events = ImEvent.knownCases.filter { $0 == event || events.contains($0) }
        }
    }

    // MARK: 问题（点了保存之后显示）

    public var webhookProblem: ImChannelProblem? {
        guard editsWebhook else { return nil }
        if case .failure(let problem) = ImChannelRules.parseWebhook(webhookURL) { return problem }
        return nil
    }

    public var secretProblem: ImChannelProblem? {
        guard editsWebhook, let vendor else { return nil }
        return ImChannelRules.checkSecret(secret, vendor: vendor)
    }

    public var labelProblem: ImChannelProblem? { ImChannelRules.checkLabel(trimmedLabel) }
    public var eventsProblem: ImChannelProblem? { ImChannelRules.checkEvents(events) }

    public var hasProblems: Bool {
        webhookProblem != nil || secretProblem != nil || labelProblem != nil || eventsProblem != nil
    }

    /// 修改时有没有改动。
    public var hasChanges: Bool {
        guard let original else { return true }
        return isReplacingWebhook || trimmedLabel != original.label || events != original.events
    }

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSecret: String? {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret.isEmpty ? nil : secret
    }

    // MARK: 保存

    /// 存下来，返回存好的渠道；有问题、出错时返回 nil（问题标在表单上，错误在 `error`）。修改时先改备注和事件，再换地址；
    /// 后一步失败时前一步已经存了（再点保存只会再换地址）。
    public func save() async -> ImChannel? {
        attemptedSave = true
        guard !hasProblems, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        let url = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let original else {
                return try await client.addImChannel(
                    NewImChannel(webhookURL: url, secret: trimmedSecret, label: trimmedLabel, events: events))
            }
            var saved = original
            let labelChanged = trimmedLabel != original.label
            let eventsChanged = events != original.events
            if labelChanged || eventsChanged {
                saved = try await client.updateImChannel(
                    original.id, label: labelChanged ? trimmedLabel : nil, events: eventsChanged ? events : nil,
                    enabled: nil)
                self.original = saved
            }
            if isReplacingWebhook {
                saved = try await client.replaceImWebhook(original.id, webhookURL: url, secret: trimmedSecret)
            }
            return saved
        } catch {
            self.error = ImChannelsModel.clientError(error)
            return nil
        }
    }
}
