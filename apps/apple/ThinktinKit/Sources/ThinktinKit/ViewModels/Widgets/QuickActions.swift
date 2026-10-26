import Foundation

/// 快捷指令、Siri、控制中心用的操作（WBS 12.20，App Intents 调它们；逻辑放在这里好测）：全部停止、给实例下任务、
/// 查待审批数、暂停 / 恢复计划。
public enum QuickActionError: Error, Hashable, Sendable {
    /// 没登录。
    case signedOut
    /// 任务里有像密码、key 的内容：要在 App 里先存进保险箱（快捷指令里不能弹拦截面板）。
    case containsSecrets
    case emptyTask
    /// 实例、计划找不到了（删掉了）。
    case notFound
    /// 别的错误（网络等），带着原来的错误。
    case failed(ClientError)
}

public struct QuickActions: Sendable {
    private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    /// 全部停止：取消所有运行、暂停所有计划、收回预授权（和设置里的“全部停止”一样）。
    public func stopAll() async throws(QuickActionError) -> StopAllResult {
        try await run { try await client.stopAll() }
    }

    /// 还没处理的审批有几个（过期的不算，和抽屉的角标一样数）。
    public func pendingApprovals(now: Date = Date()) async throws(QuickActionError) -> Int {
        try await run { try await client.approvals() }.filter { $0.isPending && !$0.isExpired(now: now) }.count
    }

    /// 给实例下一个任务。任务里有像密码的内容时不发（要在 App 里先存进保险箱）。
    public func sendTask(to instanceID: InstanceID, text: String) async throws(QuickActionError) -> Run {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTask }
        guard client.detectSecrets(in: trimmed).isEmpty else { throw .containsSecrets }
        return try await run { try await client.sendMessage(instanceID: instanceID, text: trimmed) }
    }

    public func setPlanPaused(_ planID: PlanID, paused: Bool) async throws(QuickActionError) -> Plan {
        try await run { try await client.setPlanPaused(planID, paused: paused) }
    }

    /// 能选的实例（不含已删除的），最近活跃的在前（快捷指令里选实例用）。
    public func instances() async throws(QuickActionError) -> [Instance] {
        try await run { try await client.instances() }.filter { $0.state != .deleted }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// 能暂停 / 恢复的计划（不含已删除的）。
    public func plans() async throws(QuickActionError) -> [Plan] {
        try await run { try await client.plans(instanceID: nil) }
    }

    private func run<T>(_ body: () async throws -> T) async throws(QuickActionError) -> T {
        do {
            return try await body()
        } catch let error as ClientError {
            if error == .signedOut { throw .signedOut }
            if error.isNotFound { throw .notFound }
            if case .containsSecrets = error { throw .containsSecrets }
            throw .failed(error)
        } catch {
            throw .failed(.internal(message: String(describing: error)))
        }
    }
}

/// 快捷指令说给用户听的话（中英文）。
public enum QuickActionText {
    public static func stopped(_ result: StopAllResult, language: DisplayLanguage) -> String {
        language == .chinese
            ? "已经全部停止：取消了 \(result.runsCancelled) 个运行，暂停了 \(result.plansPaused) 个计划。"
            : "Stopped everything: \(result.runsCancelled) runs cancelled, \(result.plansPaused) plans paused."
    }

    public static func pendingApprovals(_ count: Int, language: DisplayLanguage) -> String {
        if language == .chinese { return count == 0 ? "没有待审批的。" : "有 \(count) 个待审批。" }
        return count == 0
            ? "Nothing is waiting for approval."
            : (count == 1 ? "1 approval is waiting." : "\(count) approvals are waiting.")
    }

    public static func sent(to instance: String, language: DisplayLanguage) -> String {
        language == .chinese ? "已经交给“\(instance)”。" : "Sent to “\(instance)”."
    }

    public static func planPaused(_ title: String, paused: Bool, language: DisplayLanguage) -> String {
        if language == .chinese { return paused ? "已暂停“\(title)”。" : "已恢复“\(title)”。" }
        return paused ? "Paused “\(title)”." : "Resumed “\(title)”."
    }

    public static func error(_ error: QuickActionError, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch error {
        case .signedOut: return zh ? "先打开 ThinkTin 登录。" : "Open ThinkTin and sign in first."
        case .containsSecrets:
            return zh
                ? "任务里像是有密码或 key，打开 App 存进保险箱再发。"
                : "That looks like it contains a password or key. Open the app to save it to the vault first."
        case .emptyTask: return zh ? "要做什么？" : "What should it do?"
        case .notFound: return zh ? "找不到了，可能已经删掉了。" : "It can't be found. It may have been deleted."
        case .failed(let error): return error.localizedMessage(language)
        }
    }
}
