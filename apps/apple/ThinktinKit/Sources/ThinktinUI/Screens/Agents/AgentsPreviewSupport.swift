import SwiftUI
import ThinktinKit

// 预览和界面测试用的数据（12.3）。

/// 几种演示客户端。
enum AgentsPreviewClients {
    /// 写作助手上的一条流水线：第二步指定了代码审查、第三步依赖第二步（删代码审查时会列出来）。
    static let pipelinePlanID: PlanID = "0192f3a0-0000-7000-8000-00000000a401"

    /// 演示数据加上上面那条流水线。
    static func withPipeline() -> MockClient {
        var state = DemoData.state()
        state.plans.append(
            Plan(
                id: pipelinePlanID, instanceID: DemoData.writerID, title: "发版流水线", goal: "收集改动、审查、写发版说明。",
                createdBy: .agent, createdAt: Date(),
                steps: [
                    PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集这周的改动"),
                    PlanStep(key: "review", instanceID: DemoData.reviewerID, prompt: "审查改动", dependsOn: ["collect"]),
                    PlanStep(key: "notes", instanceID: DemoData.writerID, prompt: "写发版说明", dependsOn: ["review"]),
                ]))
        return MockClient(state: state, autoReply: false)
    }

    /// 目录是空的。
    static func emptyCatalog() -> MockClient {
        var state = DemoData.state()
        state.agents = []
        return MockClient(state: state, autoReply: false)
    }

    /// 还没配模型路由、也没有能用的 key 的新账号（领养后引导先加 key）。
    static func noKeys() -> MockClient {
        var state = DemoData.state()
        state.credentials = []
        state.routes = [:]
        return MockClient(state: state, autoReply: false)
    }
}

/// 直接显示一个实例的删除确认页（用环境里的客户端建实例详情的视图模型）。
struct InstanceDeletePreview: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client

    var body: some View {
        Content(client: client, instanceID: instanceID)
    }

    private struct Content: View {
        @State private var model: InstanceDetailModel

        init(client: any ClientProtocol, instanceID: InstanceID) {
            _model = State(initialValue: InstanceDetailModel(client: client, instanceID: instanceID))
        }

        var body: some View {
            let model = self.model
            InstanceDeleteSheet(model: model) {}
                .task { await model.load() }
        }
    }
}
