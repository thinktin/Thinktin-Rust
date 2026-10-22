import Foundation
import Testing

@testable import ThinktinKit

// key 详情：哪些路由在用、改备注、启用 / 停用、换 key、删除、最近的用量。

@MainActor
@Suite("模型 key 详情")
struct CredentialDetailModelTests {
    @Test("加载：key、哪些别名在用它（主 key 在前）、最近 30 天的用量")
    func load() async throws {
        let model = CredentialDetailModel(client: ModelsFixture.mock(), credentialID: DemoData.deepseekCredentialID)
        await model.load()
        #expect(model.hasLoaded && model.error == nil && model.detailsError == nil && !model.isMissing)
        #expect(model.credential?.label == "DeepSeek")
        let refs = try #require(model.references)
        // 代码审查的 main 用它当主 key，写作助手的 main 用它当备用 1。
        #expect(refs.map(\.instanceName) == ["代码审查", "写作助手"])
        #expect(refs.map(\.position) == [0, 1])
        #expect(refs[0].role(.chinese) == "主 key")
        #expect(refs[1].role(.chinese) == "备用 1")
        #expect(refs[1].isFallback)
        #expect(model.referencingInstances == [DemoData.reviewerID, DemoData.writerID])
        #expect(!model.canDelete)
        #expect(model.deleteBlockedReason(.chinese) == "还有 2 个实例的模型路由在用它，先在路由里换成别的 key 才能删。")
        #expect(model.disableWarning(.chinese)?.hasPrefix("有 2 个别名在用它") == true)
        let usage = try #require(model.recentUsage)
        #expect(usage.key == DemoData.deepseekCredentialID.rawValue)
        #expect(usage.requests > 0)
        #expect(model.summary(.chinese)?.vendorName == "DeepSeek")
    }

    @Test("没人用的 key 能删；删掉后算删掉了")
    func deleteUnused() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        await model.load()
        #expect(model.references == [])
        #expect(model.canDelete)
        #expect(model.deleteBlockedReason() == nil)
        #expect(model.disableWarning() == nil)
        // 停用的 key 没有用量：用量是 0。
        #expect(model.recentUsage?.requests == 0)
        #expect(await model.delete())
        #expect(model.isDeleted)
        #expect(!mock.state.credentials.contains { $0.id == DemoData.qwenCredentialID })
    }

    @Test("还在路由里的不发删除请求")
    func deleteBlocked() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.claudeCredentialID)
        await model.load()
        #expect(model.references?.map(\.alias) == ["fast", "main"])
        #expect(!(await model.delete()))
        #expect(mock.state.credentials.contains { $0.id == DemoData.claudeCredentialID })
    }

    @Test("服务端说还在用（409）：重新查引用，说明换成“先改路由”")
    func deleteConflict() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        await model.load()
        // 别处刚把它配进了写作助手的 fast。
        mock.update { state in
            state.credentials[2].isDisabled = false
            state.routes[DemoData.writerID]?[1].credentialID = DemoData.qwenCredentialID
        }
        mock.failNext(
            with: .api(
                status: 409, code: .conflict, message: "credential is used by 1 model route(s)", retryAfterSecs: nil))
        #expect(!(await model.delete()))
        #expect(!model.isDeleted)
        #expect(model.references?.map(\.alias) == ["fast"])
        #expect(model.deleteErrorMessage(.chinese) == "还有 1 个实例的模型路由在用它，先在路由里换成别的 key 才能删。")
    }

    @Test("已经被删掉的 key：找不到")
    func missing() async {
        let model = CredentialDetailModel(client: ModelsFixture.mock(), credentialID: "gone")
        await model.load()
        #expect(model.isMissing && model.hasLoaded)
        #expect(model.references == nil)
    }

    @Test("改备注：去掉首尾空白，可以清空，太长不发")
    func rename() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.deepseekCredentialID)
        await model.load()
        #expect(await model.rename(to: "  DeepSeek 主力 "))
        #expect(model.credential?.label == "DeepSeek 主力")
        #expect(mock.state.credentials[1].label == "DeepSeek 主力")
        #expect(await model.rename(to: "DeepSeek 主力"))
        #expect(!(await model.rename(to: String(repeating: "长", count: 65))))
        #expect(await model.rename(to: ""))
        #expect(model.summary(.chinese)?.name == "DeepSeek")
    }

    @Test("启用：唤醒用它的实例上等 key 的运行")
    func enableWakes() async {
        let mock = ModelsFixture.mock(latency: 0.03) { state in
            state.runs.append(ModelsFixture.waitingRun(instanceID: DemoData.writerID))
            state.routes[DemoData.writerID]?[1].credentialID = DemoData.qwenCredentialID
        }
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        await model.load()
        #expect(model.references?.map(\.instanceID) == [DemoData.writerID])
        ModelsFixture.wakeWaitingRuns(in: mock) { state in
            state.credentials.first { $0.id == DemoData.qwenCredentialID }?.isDisabled == false
        }
        #expect(await model.setDisabled(false))
        #expect(model.credential?.isDisabled == false)
        #expect(model.didWake)
        #expect(model.wakeResult == KeyWakeResult(waitingBefore: 1, waitingAfter: 0))
        #expect(model.wakeResult?.message(.chinese) == "已唤醒 1 个在等 key 的任务，它们会接着跑。")
    }

    @Test("停用不数唤醒；状态没变不发请求")
    func disable() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.deepseekCredentialID)
        await model.load()
        #expect(!(await model.setDisabled(false)))
        #expect(await model.setDisabled(true))
        #expect(mock.state.credentials[1].isDisabled)
        #expect(model.wakeResult == nil && !model.didWake)
        // 启用前先数等 key 的运行（第一个调用），再改：两个都失败。
        mock.failNext(with: .network(message: "offline"))
        mock.failNext(with: .network(message: "offline"))
        #expect(!(await model.setDisabled(false)))
        #expect(model.toggleError == .network(message: "offline"))
        #expect(model.credential?.isDisabled == true)
    }

    @Test("换 key：新的后 4 位，数一下还在等 key 的运行")
    func replace() async {
        let mock = ModelsFixture.mockWithWaitingRun(instanceID: DemoData.reviewerID)
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.deepseekCredentialID)
        await model.load()
        #expect(!(await model.replaceSecret("short")))
        #expect(await model.replaceSecret("  sk-new-key-0123WXYZ\n"))
        #expect(model.credential?.last4 == "WXYZ")
        #expect(model.didReplace)
        // Mock 不模拟唤醒：前后都是 1 个在等。
        #expect(model.wakeResult == KeyWakeResult(waitingBefore: 1, waitingAfter: 1))
    }

    @Test("换 key 被拒（订阅类 key）：显示原因")
    func replaceRejected() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.claudeCredentialID)
        await model.load()
        // 换 key 前先数等 key 的运行（第一个调用，失败了只是不数），第二个调用才是换 key。
        mock.failNext(with: .network(message: "offline"))
        mock.failNext(
            with: .api(
                status: 422, code: .invalid,
                message:
                    "Anthropic (Claude) subscription keys (sk-ant-oat...) can only be used in the vendor's own tools",
                retryAfterSecs: nil))
        #expect(!(await model.replaceSecret("sk-ant-oat01-0123456789")))
        #expect(model.replaceRejection == .subscriptionKey)
        #expect(model.replaceError == nil)
        #expect(!model.didReplace)
        #expect(model.credential?.last4 == "Q7mA")
        model.clearReplaceErrors()
        #expect(model.replaceRejection == nil)
    }

    @Test("路由查不全：算失败，不让删")
    func referencesFailed() async {
        let mock = ModelsFixture.mock()
        mock.failNext(with: .network(message: "offline"))
        let result = await CredentialDetailModel.findReferences(to: DemoData.qwenCredentialID, client: mock)
        guard case .failure(let error) = result else {
            Issue.record("should fail")
            return
        }
        #expect(error as? ClientError == .network(message: "offline"))
        // 还没查到时也不让删。
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        #expect(model.references == nil && !model.canDelete)
        #expect(model.deleteBlockedReason(.chinese) == "正在查哪些模型路由在用它…")
    }
}
