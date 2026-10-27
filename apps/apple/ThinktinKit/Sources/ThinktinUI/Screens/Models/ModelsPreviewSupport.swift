import SwiftUI
import ThinktinKit

// 预览和界面测试用的数据（12.4）。

/// 几种演示客户端。
enum ModelsPreviewClients {
    /// 写作助手上一个卡在等 key 的运行。
    static let waitingRunID: RunID = "0192f3a0-0000-7000-8000-00000000c401"

    /// 一把 key 都没有（新账号）：列表是空的，路由页提示先加 key。
    static func noKeys() -> MockClient {
        var state = DemoData.state()
        state.credentials = []
        state.routes = [:]
        return MockClient(state: state, autoReply: false)
    }

    /// 写作助手还没配路由，有一个任务在等 key（领养完、引导里第一次进路由页）。
    static func waitingForKey() -> MockClient {
        var state = DemoData.state()
        state.routes[DemoData.writerID] = []
        state.runs.append(
            Run(
                id: waitingRunID, instanceID: DemoData.writerID, prompt: "整理今天的新闻", state: .waitingQuota,
                stateReason: "没有能用的 key", createdAt: Date(), waitCode: .unavailable))
        return MockClient(state: state, autoReply: false)
    }

    /// 还没有用量。
    static func noUsage() -> MockClient {
        var state = DemoData.state()
        state.dailyUsage = []
        return MockClient(state: state, autoReply: false)
    }

    /// 多一把自定义地址的 key，写作助手的 fast 用它。
    static func customKey() -> MockClient {
        var state = DemoData.state()
        let id: CredentialID = "0192f3a0-0000-7000-8000-00000000c501"
        state.credentials.append(
            Credential(
                id: id, vendor: NewCredential.customVendor, label: "公司网关", last4: "c0de", createdAt: Date(),
                protocols: [.anthropic]))
        state.routes[DemoData.writerID]?[1].credentialID = id
        return MockClient(state: state, autoReply: false)
    }
}
