import Foundation
import Testing

@testable import ThinktinKit

// 实例详情：加载（实例、本实例的计划）、改名、找不到、离线、先读缓存。删除在 `InstanceDeletionTests`。

@MainActor
@Suite("实例详情")
struct InstanceDetailModelTests {
    @Test("加载：实例和本实例的计划（别的 Botin 的不算）")
    func load() async {
        let mock = AgentsFixture.mockWithPipeline()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.error == nil && model.detailsError == nil)
        #expect(model.instance?.name == "写作助手")
        #expect(Set(model.plans?.map(\.id) ?? []) == [DemoData.digestPlanID, AgentsFixture.pipelinePlanID])
        #expect(model.plans?.allSatisfy { $0.instanceID == DemoData.writerID } == true)
    }

    @Test("计划拉不到：记在 detailsError，实例照样显示；再拉一次好了就清掉")
    func plansFail() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        mock.failNext("plans(instanceID:)", with: .network(message: "offline"))
        await model.load()
        #expect(model.instance?.name == "写作助手")
        #expect(model.error == nil)
        #expect(model.detailsError?.isOffline == true)
        #expect(model.plans == nil && model.activePlanCount == nil)
        await model.load()
        #expect(model.detailsError == nil)
        #expect(model.plans != nil)
    }

    @Test("先显示传进来的实例；传错的不用")
    func seeded() {
        let mock = AgentsFixture.mock()
        let writer = mock.state.instances[0]
        #expect(InstanceDetailModel(client: mock, instanceID: DemoData.writerID, instance: writer).instance == writer)
        #expect(InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID, instance: writer).instance == nil)
    }

    @Test("改名：去掉首尾空白；名字不对不发请求；没变直接成功")
    func rename() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        #expect(await model.rename(to: "  周报助手 "))
        #expect(model.instance?.name == "周报助手")
        #expect(mock.state.instances.first { $0.id == DemoData.writerID }?.name == "周报助手")
        #expect(!(await model.rename(to: "  ")))
        #expect(!(await model.rename(to: String(repeating: "名", count: 65))))
        #expect(await model.rename(to: "周报助手"))
        #expect(model.renameError == nil)
    }

    @Test("改名失败：记下错误，清掉后再试")
    func renameFails() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        #expect(!(await model.rename(to: "新名字")))
        #expect(model.renameError?.isOffline == true)
        #expect(model.instance?.name == "写作助手")
        model.clearRenameError()
        #expect(model.renameError == nil)
    }

    @Test("实例不存在了：标成不存在，不再拉别的")
    func missing() async {
        let model = InstanceDetailModel(client: AgentsFixture.mock(), instanceID: "gone")
        await model.load()
        #expect(model.isMissing)
        #expect(model.error == nil)
        #expect(model.hasLoaded)
        #expect(model.plans == nil)
    }

    @Test("离线：照样显示已有的实例，记下网络错误")
    func offline() async {
        let mock = AgentsFixture.mock()
        let reviewer = mock.state.instances[1]
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID, instance: reviewer)
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.instance?.name == "代码审查")
        #expect(model.error?.isOffline == true)
        #expect(!model.isMissing)
        #expect(model.hasLoaded)
    }

    @Test("没传实例时先读缓存，网络的结果回来之前就能显示")
    func cacheFirst() async {
        let mock = MockClient(state: DemoData.state(), latency: 0.3, stepDelay: 0, autoReply: false)
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        let loading = Task { await model.load() }
        #expect(await eventually { model.instance != nil })
        #expect(model.isLoading)
        #expect(model.instance?.name == "代码审查")
        await loading.value
        #expect(model.plans != nil && model.detailsError == nil)
    }
}
