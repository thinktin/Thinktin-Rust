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
        #expect(!model.hasHiddenReferences && !model.canDelete)
        // 原因只在删除按钮下面说一次，错误提示不重复。
        #expect(model.deleteBlockedReason(.chinese) == "还有 1 个实例的模型路由在用它，先在路由里换成别的 key 才能删。")
        #expect(model.deleteErrorMessage(.chinese) == nil)
    }

    @Test("服务端说还在用（409），可重新查了一个都没有（路由刚变过）：说明原因，先不让删，刷新后能再删")
    func deleteConflictHidden() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        await model.load()
        #expect(model.canDelete)
        mock.failNext(
            with: .api(
                status: 409, code: .conflict, message: "credential is used by 1 model route(s)", retryAfterSecs: nil))
        #expect(!(await model.delete()))
        #expect(model.references == [] && model.hasHiddenReferences)
        #expect(!model.canDelete)
        #expect(model.deleteBlockedReason(.chinese)?.contains("下拉刷新") == true)
        #expect(model.deleteBlockedReason(.chinese)?.contains("已删除") == false, "11.9 起已删除实例的别名不挡着")
        #expect(model.deleteBlockedReason(.english)?.contains("refresh") == true)
        #expect(model.deleteErrorMessage(.chinese) == nil)
        // 不发第二次删除请求。
        #expect(!(await model.delete()))
        #expect(mock.state.credentials.contains { $0.id == DemoData.qwenCredentialID })
        // 刷新之后重新查过引用，能删了。
        await model.load()
        #expect(!model.hasHiddenReferences && model.canDelete)
        #expect(await model.delete())
        #expect(!mock.state.credentials.contains { $0.id == DemoData.qwenCredentialID })
    }

    @Test("删除失败的其他错误照常按错误码说")
    func deleteNetworkError() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        #expect(!(await model.delete()))
        #expect(model.deleteError == .network(message: "offline"))
        #expect(
            model.deleteErrorMessage(.chinese) == ClientError.network(message: "offline").localizedMessage(.chinese))
        #expect(model.canDelete)
    }

    @Test("还没查到哪些别名在用：停用前也提醒（说得笼统些）")
    func disableWarningUnknown() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(
            client: mock, credentialID: DemoData.deepseekCredentialID, credential: mock.state.credentials[1])
        #expect(model.references == nil)
        #expect(model.disableWarning(.chinese)?.hasPrefix("还没查到哪些别名在用它") == true)
        #expect(model.disableWarning(.english)?.contains("fallbacks") == true)
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
        #expect(model.wakeResult == KeyWakeResult(retried: 1))
        #expect(model.wakeResult?.message(.chinese) == "1 个在等 key 的任务马上重试：key 能用就接着跑，还不能用的会继续等。")
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
        // 只说操作前在等的那 1 个马上重试，不说“还有 1 个在等”（真的服务端刚唤醒时运行的状态还没变）。
        #expect(model.wakeResult == KeyWakeResult(retried: 1))
        #expect(model.wakeResult?.message(.chinese)?.contains("还有") == false)
    }

    @Test("改每日上限（11.9）：放宽、取消时数一下等 key 的运行，收紧、原来不限的不数；没变、不合法的不发请求")
    func dailyLimit() async {
        let mock = ModelsFixture.mockWithWaitingRun(instanceID: DemoData.writerID)
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.claudeCredentialID)
        await model.load()
        let method = "setCredentialDailyLimit(_:dailyTokenLimit:)"
        #expect(model.credential?.dailyTokenLimit == 2_000_000)
        #expect(await model.setDailyLimit("2,000,000"), "没变：直接算成功")
        #expect(!(await model.setDailyLimit("0")))
        #expect(!(await model.setDailyLimit("两百万")))
        #expect(mock.callCount(method) == 0)

        #expect(await model.setDailyLimit("500000"))
        #expect(model.credential?.dailyTokenLimit == 500_000)
        #expect(!model.didWake && model.wakeResult == nil, "收紧不唤醒")

        #expect(await model.setDailyLimit("3 000 000"))
        #expect(mock.state.credentials.first { $0.id == DemoData.claudeCredentialID }?.dailyTokenLimit == 3_000_000)
        #expect(model.didWake && model.wakeResult == KeyWakeResult(retried: 1), "放宽：等 key 的任务马上重试")
        #expect(mock.state.runs.first { $0.id == ModelsFixture.waitingRunID }?.state == .starting, "Mock 也唤醒了它")

        // 它又卡住了（比如还是欠费）：取消上限时再唤醒一次。
        mock.update { s in
            if let i = s.runs.firstIndex(where: { $0.id == ModelsFixture.waitingRunID }) {
                s.runs[i].state = .waitingQuota
                s.runs[i].waitCode = .noBalance
            }
        }
        #expect(await model.setDailyLimit(""))
        #expect(model.credential?.dailyTokenLimit == nil)
        #expect(model.summary(.chinese)?.dailyLimit == "不限")
        #expect(model.didWake && model.wakeResult == KeyWakeResult(retried: 1), "取消上限也唤醒")

        #expect(await model.setDailyLimit("1000"))
        #expect(!model.didWake && model.wakeResult == nil, "原来不限：设上限不唤醒")
        #expect(mock.callCount(method) == 4)
    }

    @Test("改每日上限失败：记下错误，上限不变")
    func dailyLimitFails() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.claudeCredentialID)
        await model.load()
        mock.failNext("setCredentialDailyLimit(_:dailyTokenLimit:)", with: .network(message: "offline"))
        #expect(!(await model.setDailyLimit("100")))
        #expect(model.dailyLimitError == .network(message: "offline"))
        #expect(model.credential?.dailyTokenLimit == 2_000_000)
        #expect(!model.isSettingDailyLimit)
        model.clearDailyLimitError()
        #expect(model.dailyLimitError == nil)
    }

    @Test("改上限会不会唤醒等 key 的运行：和服务端一样，原来有上限、改成不限或更大的才唤醒")
    func limitChangeWakes() {
        #expect(CredentialDetailModel.limitChangeWakes(from: 100, to: nil))
        #expect(CredentialDetailModel.limitChangeWakes(from: 100, to: 101))
        #expect(!CredentialDetailModel.limitChangeWakes(from: 100, to: 100))
        #expect(!CredentialDetailModel.limitChangeWakes(from: 100, to: 50))
        #expect(!CredentialDetailModel.limitChangeWakes(from: nil, to: 50))
        #expect(!CredentialDetailModel.limitChangeWakes(from: nil, to: nil))
    }

    @Test("启用前没数到等 key 的运行：只说通用的一句")
    func wakeUncounted() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.qwenCredentialID)
        await model.load()
        // 启用前数等 key 的运行（第一个调用）失败了，启用照常。
        mock.failNext(with: .network(message: "offline"))
        #expect(await model.setDisabled(false))
        #expect(model.didWake && model.wakeResult == nil)
    }

    @Test("换 key 被拒（订阅类 key）：显示原因")
    func replaceRejected() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.deepseekCredentialID)
        await model.load()
        // 换 key 前先数等 key 的运行（第一个调用，失败了只是不数），第二个调用才是换 key。
        mock.failNext(with: .network(message: "offline"))
        mock.failNext(
            with: .api(
                status: 422, code: .invalid,
                message: "DeepSeek subscription keys (sk-plan-...) can only be used in the vendor's own tools",
                retryAfterSecs: nil))
        #expect(model.keyRejection(for: "sk-plan-0123456789") == nil, "厂商表里没有这个前缀：服务端才知道")
        #expect(!(await model.replaceSecret("sk-plan-0123456789")))
        #expect(model.replaceRejection == .subscriptionKey)
        #expect(model.replaceError == nil)
        #expect(!model.didReplace)
        #expect(model.credential?.last4 == "x9Lk")
        model.clearReplaceErrors()
        #expect(model.replaceRejection == nil)
    }

    @Test("换成这家的订阅类 key（11.9，厂商表的前缀）：本地就拦下，不发请求")
    func replaceSubscriptionKeyLocally() async {
        let mock = ModelsFixture.mock()
        let model = CredentialDetailModel(client: mock, credentialID: DemoData.claudeCredentialID)
        await model.load()
        #expect(model.keyRejection(for: " sk-ant-oat01-0123456789") == .subscriptionKey)
        #expect(model.keyRejection(for: "sk-ant-api03-0123456789") == nil)
        #expect(!(await model.replaceSecret("sk-ant-oat01-0123456789")))
        #expect(model.replaceRejection == .subscriptionKey)
        #expect(mock.callCount("replaceCredentialSecret(_:apiKey:)") == 0)
        #expect(model.credential?.last4 == "Q7mA")
        #expect(await model.replaceSecret("sk-ant-api03-0123456789"))
        #expect(model.replaceRejection == nil && model.credential?.last4 == "6789")
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
