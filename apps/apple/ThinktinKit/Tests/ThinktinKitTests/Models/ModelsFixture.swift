import Foundation
import Testing

@testable import ThinktinKit

// 模型 key、路由、用量（12.4）测试共用的数据。名字都放在 `ModelsFixture` 里，不和别的功能的测试工具重名。

enum ModelsFixture {
    /// 演示数据上的 Mock：不自动回答、不等待。`edit` 可以先改一下状态。
    static func mock(latency: TimeInterval = 0, _ edit: (inout MockState) -> Void = { _ in }) -> MockClient {
        var state = DemoData.state()
        edit(&state)
        return MockClient(state: state, latency: latency, stepDelay: 0, autoReply: false)
    }

    /// 一个只给这次测试用的 `UserDefaults`（同意记录不串）。
    static func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "cn.thinktin.tests.models.\(name).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    /// 同意记录（每次新的）。
    @MainActor
    static func consent(_ name: String = #function) -> ThirdPartyAIConsentStore {
        ThirdPartyAIConsentStore(defaults: defaults(name))
    }

    /// 写作助手上一个卡在等 key 的运行。
    static let waitingRunID: RunID = "0192f3a0-0000-7000-8000-00000000c401"

    static func waitingRun(instanceID: InstanceID = DemoData.writerID) -> Run {
        Run(
            id: waitingRunID, instanceID: instanceID, prompt: "整理今天的新闻", state: .waitingQuota,
            stateReason: "没有能用的 key", createdAt: Date(), waitCode: .unavailable)
    }

    /// 带一个等 key 的运行的 Mock。
    static func mockWithWaitingRun(latency: TimeInterval = 0, instanceID: InstanceID = DemoData.writerID)
        -> MockClient
    {
        mock(latency: latency) { $0.runs.append(waitingRun(instanceID: instanceID)) }
    }

    /// 服务端一样唤醒等 key 的运行：等 `trigger` 成立（比如路由已经存进去了）就把等 key 的运行改成排队。
    /// MockClient 自己也唤醒（改成“开始”），测试用它在“保存之后、重新拉运行之前”改成别的状态（Mock 要设 `latency`）。
    @discardableResult
    static func wakeWaitingRuns(
        in mock: MockClient, when trigger: @escaping @Sendable (MockState) -> Bool
    ) -> Task<Void, Never> {
        Task.detached {
            for _ in 0..<2000 {
                if trigger(mock.state) {
                    mock.update { state in
                        for i in state.runs.indices where state.runs[i].state == .waitingQuota {
                            state.runs[i].state = .queued
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    /// 只有一把自定义地址的 key（Anthropic 地址）。
    static let customCredentialID: CredentialID = "0192f3a0-0000-7000-8000-00000000c501"

    static func customCredential(label: String = "公司网关") -> Credential {
        Credential(
            id: customCredentialID, vendor: NewCredential.customVendor, label: label, last4: "c0de",
            createdAt: Date(), protocols: [.anthropic])
    }
}
