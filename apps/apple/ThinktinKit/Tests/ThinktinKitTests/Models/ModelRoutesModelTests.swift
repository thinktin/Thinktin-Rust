import Foundation
import Testing

@testable import ThinktinKit

// 实例的模型路由：main 在前、按协议过滤 key、降级链、别名规则、保存（同意数据共享、唤醒等 key 的运行）。

@MainActor
@Suite("实例的模型路由")
struct ModelRoutesModelTests {
    private func make(
        _ mock: MockClient = ModelsFixture.mock(), instanceID: InstanceID = DemoData.writerID, name: String = #function
    ) -> (MockClient, ModelRoutesModel, ThirdPartyAIConsentStore) {
        let consent = ModelsFixture.consent(name)
        return (mock, ModelRoutesModel(client: mock, instanceID: instanceID, consent: consent), consent)
    }

    @Test("加载：main 在第一个，草稿和服务端一样，没有改动")
    func load() async throws {
        let (_, model, _) = make()
        await model.load()
        #expect(model.hasLoaded && model.isEditable && model.error == nil && model.detailsError == nil)
        #expect(model.instanceName == "写作助手")
        #expect(model.agentName == "Claude Agent")
        #expect(model.requiredProtocol == .anthropic)
        #expect(model.drafts.map(\.alias) == ["main", "fast"])
        let main = try #require(model.drafts.first)
        #expect(main.isMain && main.credentialID == DemoData.claudeCredentialID)
        #expect(main.upstreamModel == "claude-sonnet-5-5")
        #expect(main.fallbacks.map(\.credentialID) == [DemoData.deepseekCredentialID])
        #expect(!model.hasChanges && !model.hasUserEdits && !model.canSave)
        #expect(model.isValid)
        #expect(model.waitingRuns == 0)
        #expect(model.hasFast)
    }

    @Test("服务端按别名排序返回：main 照样放第一个")
    func mainFirst() async {
        let (_, model, _) = make(
            ModelsFixture.mock { state in
                state.routes[DemoData.writerID] = [
                    ModelRoute(
                        alias: "fast", credentialID: DemoData.claudeCredentialID, upstreamModel: "claude-haiku-5-5"),
                    ModelRoute(
                        alias: "main", credentialID: DemoData.claudeCredentialID, upstreamModel: "claude-opus-5-5"),
                    ModelRoute(
                        alias: "vision", credentialID: DemoData.claudeCredentialID, upstreamModel: "claude-opus-5-5"),
                ]
            })
        await model.load()
        #expect(model.drafts.map(\.alias) == ["main", "fast", "vision"])
        #expect(model.routesToSave?.map(\.alias) == ["main", "fast", "vision"])
    }

    @Test("可选的 key 按 agent 的协议过滤，停用的不列")
    func filtering() async {
        // Claude Agent 要 anthropic：Claude 的 key、DeepSeek 都行，百炼停用了。
        let (_, writer, _) = make()
        await writer.load()
        #expect(writer.selectableCredentials.map(\.id) == [DemoData.claudeCredentialID, DemoData.deepseekCredentialID])
        #expect(writer.incompatibleCredentialCount == 0)

        // Codex 只会 responses：Claude 的 key（anthropic、chat）不能用。
        let (_, reviewer, _) = make(instanceID: DemoData.reviewerID, name: "filtering-codex")
        await reviewer.load()
        #expect(reviewer.requiredProtocol == .responses)
        #expect(reviewer.selectableCredentials.map(\.id) == [DemoData.deepseekCredentialID])
        #expect(reviewer.incompatibleCredentialCount == 1)
        #expect(
            reviewer.keyProblem(DemoData.claudeCredentialID)
                == .keyIncompatible(agentName: "Codex", required: .responses))
        #expect(reviewer.keyProblem(DemoData.qwenCredentialID) == .keyDisabled)
        #expect(reviewer.keyProblem("gone") == .keyDeleted)
        #expect(reviewer.keyProblem(nil) == .keyMissing)
        #expect(reviewer.keyProblem(DemoData.deepseekCredentialID) == nil)
    }

    @Test("目录拉不到（不知道协议）：不过滤，照常能编辑")
    func noAgent() async {
        let (_, model, _) = make(ModelsFixture.mock { $0.agents = [] })
        await model.load()
        #expect(model.agent == nil && model.requiredProtocol == nil)
        #expect(model.selectableCredentials.count == 2)
        #expect(model.agentName == "Claude Agent")
        #expect(model.isEditable)
    }

    @Test("还没有路由：先放一个 main 草稿，选最新加的能用的 key 和它的推荐模型")
    func prefilledMain() async throws {
        let (_, model, _) = make(ModelsFixture.mock { $0.routes[DemoData.writerID] = [] })
        await model.load()
        let main = try #require(model.drafts.first)
        #expect(model.drafts.count == 1 && main.isMain)
        // DeepSeek 比 Claude 的 key 后加。
        #expect(main.credentialID == DemoData.deepseekCredentialID)
        #expect(main.upstreamModel == "deepseek-v4-pro")
        #expect(model.hasChanges && !model.hasUserEdits)
        #expect(model.canSave)
    }

    @Test("一把能用的 key 都没有：main 等着选 key；加了 key 回来自动选上")
    func noKeys() async throws {
        let mock = ModelsFixture.mock { state in
            state.routes[DemoData.writerID] = []
            state.credentials = []
        }
        let (_, model, _) = make(mock)
        await model.load()
        #expect(model.hasNoUsableCredentials)
        let main = try #require(model.drafts.first)
        #expect(main.credentialID == nil)
        #expect(model.problems(forRoute: main.id) == [.keyMissing, .modelMissing])
        #expect(!model.canSave)

        _ = try await mock.addCredential(
            NewCredential(vendor: "anthropic", label: "新 key", apiKey: "sk-ant-api03-0123456789"))
        await model.refreshCredentials()
        let filled = try #require(model.drafts.first)
        #expect(model.credential(filled.credentialID)?.label == "新 key")
        #expect(filled.upstreamModel == "claude-opus-5-5")
        #expect(model.canSave)
    }

    @Test("换主 key：推荐模型跟着换，手填的模型不动")
    func changeKey() async throws {
        let (_, model, _) = make()
        await model.load()
        let main = try #require(model.drafts.first)
        model.setModel("claude-opus-5-5", forRoute: main.id)
        model.setCredential(DemoData.deepseekCredentialID, forRoute: main.id)
        #expect(model.draft(main.id)?.upstreamModel == "deepseek-v4-pro")
        model.setModel("my-finetune", forRoute: main.id)
        model.setCredential(DemoData.claudeCredentialID, forRoute: main.id)
        #expect(model.draft(main.id)?.upstreamModel == "my-finetune")
        #expect(model.hasUserEdits && model.hasChanges)
        #expect(model.suggestedModels(for: DemoData.claudeCredentialID).count == 3)
        #expect(model.suggestedModels(for: nil).isEmpty)
    }

    @Test("fast 推荐轻量的模型")
    func fastPreferred() async {
        let (_, model, _) = make()
        await model.load()
        #expect(model.preferredModel(for: "fast", credentialID: DemoData.claudeCredentialID) == "claude-haiku-5-5")
        #expect(model.preferredModel(for: "fast", credentialID: DemoData.deepseekCredentialID) == "deepseek-flash")
        #expect(model.preferredModel(for: "main", credentialID: DemoData.claudeCredentialID) == "claude-opus-5-5")
    }

    @Test("降级链：最多 3 个，预选还没用上的 key，可以上下移、删")
    func fallbacks() async throws {
        let (_, model, _) = make()
        await model.load()
        let fast = try #require(model.drafts.first { $0.isFast })
        let first = try #require(model.addFallback(toRoute: fast.id))
        // fast 的主 key 是 Claude 的，备用预选 DeepSeek。
        #expect(model.draft(fast.id)?.fallbacks.first?.credentialID == DemoData.deepseekCredentialID)
        #expect(model.draft(fast.id)?.fallbacks.first?.upstreamModel == "deepseek-flash")
        let second = try #require(model.addFallback(toRoute: fast.id))
        let third = try #require(model.addFallback(toRoute: fast.id))
        #expect(model.addFallback(toRoute: fast.id) == nil)
        #expect(model.draft(fast.id)?.fallbacks.count == 3)

        model.moveFallback(third, inRoute: fast.id, by: -1)
        #expect(model.draft(fast.id)?.fallbacks.map(\.id) == [first, third, second])
        model.moveFallback(first, inRoute: fast.id, by: -1)
        #expect(model.draft(fast.id)?.fallbacks.map(\.id) == [first, third, second])
        model.removeFallback(third, fromRoute: fast.id)
        #expect(model.draft(fast.id)?.fallbacks.map(\.id) == [first, second])

        model.setFallbackCredential(DemoData.claudeCredentialID, fallback: second, route: fast.id)
        model.setFallbackModel("  claude-haiku-5-5  ", fallback: second, route: fast.id)
        let saved = try #require(model.routesToSave?.first { $0.alias == "fast" })
        #expect(saved.fallbacks.map(\.upstreamModel) == ["deepseek-flash", "claude-haiku-5-5"])
    }

    @Test("别名：fast 一键加，自定义的按格式查重，main 删不了，最多 16 个")
    func aliases() async throws {
        let (_, model, _) = make(ModelsFixture.mock { $0.routes[DemoData.writerID] = [] })
        await model.load()
        #expect(!model.hasFast)
        let fast = try #require(model.addFast())
        #expect(model.draft(fast)?.upstreamModel == "deepseek-flash")
        #expect(model.addFast() == nil)

        #expect(model.aliasProblem("") == .empty)
        #expect(model.aliasProblem("Vision Model") == .invalid)
        #expect(model.aliasProblem(" FAST ") == .duplicate)
        guard case .added(let vision) = model.addAlias(" Vision ") else {
            Issue.record("should add")
            return
        }
        #expect(model.draft(vision)?.alias == "vision")
        #expect(model.addAlias("-x") == .rejected(.invalid))

        let main = try #require(model.drafts.first)
        model.removeRoute(main.id)
        #expect(model.drafts.first?.isMain == true)
        model.removeRoute(vision)
        #expect(model.drafts.map(\.alias) == ["main", "fast"])

        for i in 0..<14 { _ = model.addAlias("extra\(i)") }
        #expect(model.drafts.count == 16)
        #expect(!model.canAddAlias)
        #expect(model.aliasProblem("one-more") == .tooMany(max: 16))
        #expect(AliasProblem.tooMany(max: 16).message(.chinese) == "一个实例最多 16 个别名。")
    }

    @Test("校验：模型名 1 到 128 个字符，停用的 key 要换掉才能保存")
    func validation() async throws {
        let (_, model, _) = make()
        await model.load()
        let main = try #require(model.drafts.first)
        model.setModel("   ", forRoute: main.id)
        #expect(model.problems(forRoute: main.id) == [.modelMissing])
        model.setModel(String(repeating: "m", count: 129), forRoute: main.id)
        #expect(model.problems(forRoute: main.id) == [.modelTooLong(max: 128)])
        #expect(!model.isValid && !model.canSave && model.routesToSave == nil)
        model.setModel("claude-sonnet-5-5", forRoute: main.id)
        model.setCredential(DemoData.qwenCredentialID, forRoute: main.id)
        #expect(model.problems(forRoute: main.id).contains(.keyDisabled))
        #expect(RouteProblem.keyDisabled.message(.chinese).contains("停用"))
        let fallback = try #require(model.draft(main.id)?.fallbacks.first)
        #expect(model.problems(forFallback: fallback).isEmpty)
    }

    @Test("放弃改动：回到服务端的样子")
    func discard() async throws {
        let (_, model, _) = make()
        await model.load()
        let fast = try #require(model.drafts.first { $0.isFast })
        model.removeRoute(fast.id)
        #expect(model.hasChanges)
        model.discardChanges()
        #expect(!model.hasChanges && !model.hasUserEdits)
        #expect(model.drafts.map(\.alias) == ["main", "fast"])
    }

    @Test("保存：没同意过的厂商要先确认；同意后记下，main 在第一个")
    func saveNeedsConsent() async throws {
        let (mock, model, consent) = make()
        await model.load()
        let fast = try #require(model.drafts.first { $0.isFast })
        model.setModel("claude-opus-5-5", forRoute: fast.id)
        #expect(model.canSave)
        let pending = model.vendorsNeedingConsent(.chinese)
        #expect(pending.map(\.key) == ["anthropic", "deepseek"])
        #expect(pending.map(\.name) == ["Anthropic (Claude)", "DeepSeek"])
        #expect(!(await model.save()))
        #expect(mock.state.routes[DemoData.writerID]?.first { $0.alias == "fast" }?.upstreamModel == "claude-haiku-5-5")

        #expect(await model.save(consented: true))
        #expect(consent.hasConsented(to: "anthropic") && consent.hasConsented(to: "deepseek"))
        #expect(model.vendorsNeedingConsent().isEmpty)
        let saved = try #require(mock.state.routes[DemoData.writerID])
        #expect(saved.map(\.alias) == ["main", "fast"])
        #expect(saved[1].upstreamModel == "claude-opus-5-5")
        #expect(saved[0].fallbacks.map(\.credentialID) == [DemoData.deepseekCredentialID])
        #expect(!model.hasChanges && !model.hasUserEdits)
        #expect(model.saveResult == RouteSaveResult(wake: KeyWakeResult(retried: 0)))
        #expect(model.saveResult?.message(.chinese) == "已保存。")

        // 再改一次就不用再问了。
        model.setModel("claude-haiku-5-5", forRoute: try #require(model.drafts.first { $0.isFast }).id)
        #expect(model.saveResult == nil)
        #expect(await model.save())
    }

    @Test("保存后：保存前在等 key 的马上重试；刚唤醒时状态还没变，也不说“还在等”")
    func saveWakes() async throws {
        let mock = ModelsFixture.mock { state in
            state.routes[DemoData.writerID] = []
            state.runs.append(ModelsFixture.waitingRun())
        }
        let (_, model, _) = make(mock)
        await model.load()
        #expect(model.waitingRuns == 1)
        // 和真的服务端一样：保存一返回，运行还在“等待 key”（执行器还没接手）。
        #expect(await model.save(consented: true))
        #expect(model.saveResult?.wake == KeyWakeResult(retried: 1))
        #expect(
            model.saveResult?.message(.chinese) == "已保存。1 个在等 key 的任务马上重试：key 能用就接着跑，还不能用的会继续等。")
        #expect(model.saveResult?.message(.chinese).contains("还有") == false)
    }

    @Test("保存后重新拉这个实例的运行（刷新缓存）：执行器接手了的就不算在等了")
    func saveRefreshesRuns() async throws {
        let mock = ModelsFixture.mock(latency: 0.03) { state in
            state.routes[DemoData.writerID] = []
            state.runs.append(ModelsFixture.waitingRun())
        }
        let (_, model, _) = make(mock)
        await model.load()
        ModelsFixture.wakeWaitingRuns(in: mock) { !($0.routes[DemoData.writerID] ?? []).isEmpty }
        #expect(await model.save(consented: true))
        #expect(model.waitingRuns == 0)
        #expect(model.saveResult?.wake == KeyWakeResult(retried: 1))
    }

    @Test("服务端不收（新选的 key 刚被停用）：显示错误，重新拉 key 把问题标出来")
    func saveRejected() async throws {
        let spare = Credential(
            id: "spare-claude", vendor: "anthropic", label: "备用 Claude", last4: "zzzz", createdAt: Date(),
            protocols: [.anthropic, .chat])
        let mock = ModelsFixture.mock { $0.credentials.append(spare) }
        let (_, model, _) = make(mock)
        await model.load()
        let fast = try #require(model.drafts.first { $0.isFast })
        model.setCredential(spare.id, forRoute: fast.id)
        model.setModel("claude-opus-5-5", forRoute: fast.id)
        #expect(model.problems(forRoute: fast.id).isEmpty)
        mock.update { $0.credentials[3].isDisabled = true }
        // 保存前先数等 key 的运行（第一个调用），第二个调用才是保存。
        mock.failNext(with: .network(message: "offline"))
        mock.failNext(
            with: .api(status: 422, code: .invalid, message: "credential x is not usable", retryAfterSecs: nil))
        #expect(!(await model.save(consented: true)))
        #expect(model.saveError?.isInvalidInput == true)
        #expect(model.problems(forRoute: fast.id).contains(.keyDisabled))
        #expect(!model.isValid)
    }

    @Test("实例原来就用着的停用 key 可以留着（11.9）：不挡保存，提示一句；新选的停用 key 照样要换")
    func keepsDisabledKey() async throws {
        // 写作助手的 main 用 DeepSeek 当备用 1；DeepSeek 停用了。
        let mock = ModelsFixture.mock { $0.credentials[1].isDisabled = true }
        let (_, model, _) = make(mock)
        await model.load()
        let main = try #require(model.drafts.first { $0.isMain })
        let fallback = try #require(main.fallbacks.first)
        #expect(fallback.credentialID == DemoData.deepseekCredentialID)
        #expect(model.problems(forFallback: fallback).isEmpty)
        #expect(model.keepsDisabledKey(fallback.credentialID))
        #expect(model.keyProblem(DemoData.deepseekCredentialID) == nil)
        #expect(!model.keepsDisabledKey(DemoData.claudeCredentialID), "没停用的不提示")
        #expect(ModelsText.keptDisabledKeyNotice(.chinese).contains("可以先留着"))
        #expect(ModelsText.keptDisabledKeyNotice(.english).contains("keep it"))

        // 改别的别名照样能存（服务端也收）。
        let fast = try #require(model.drafts.first { $0.isFast })
        model.setModel("claude-opus-5-5", forRoute: fast.id)
        #expect(model.isValid && model.canSave)
        #expect(await model.save(consented: true))
        #expect(mock.state.routes[DemoData.writerID]?.first?.fallbacks.first?.credentialID == DemoData.deepseekCredentialID)

        // 没在用的停用 key（百炼）新选上：要换。
        model.setCredential(DemoData.qwenCredentialID, forRoute: fast.id)
        #expect(model.problems(forRoute: fast.id).contains(.keyDisabled))
        #expect(!model.keepsDisabledKey(DemoData.qwenCredentialID))
    }

    @Test("路由拉不到：不能编辑；实例删掉了：找不到")
    func failures() async {
        let mock = ModelsFixture.mock()
        let (_, missing, _) = make(mock, instanceID: "gone")
        await missing.load()
        #expect(missing.isMissing && !missing.isEditable)

        // 全都拉不到（网络断了）：先读缓存（1 个调用），再并发拉 6 样。
        let (offline, model, _) = make(name: "failures-offline")
        for _ in 0..<7 { offline.failNext(with: .network(message: "offline")) }
        await model.load()
        #expect(model.error == .network(message: "offline"))
        #expect(!model.isEditable && model.drafts.isEmpty && !model.canSave)
        await model.load()
        #expect(model.isEditable && model.error == nil)
    }

    @Test("数据共享的厂商：自定义地址写上备注，按 key 记")
    func customVendorConsent() async throws {
        let mock = ModelsFixture.mock { state in
            state.credentials.append(ModelsFixture.customCredential())
            state.routes[DemoData.writerID] = [
                ModelRoute(alias: "main", credentialID: ModelsFixture.customCredentialID, upstreamModel: "claude-x")
            ]
        }
        let (_, model, _) = make(mock)
        await model.load()
        let used = model.usedVendors(.chinese)
        #expect(
            used == [ConsentVendor(key: "custom:\(ModelsFixture.customCredentialID.rawValue)", name: "自定义地址（公司网关）")])
        #expect(model.usedVendors(.english).first?.name == "Custom endpoint (公司网关)")
        #expect(model.credentialTitle(ModelsFixture.customCredentialID, language: .chinese) == "公司网关 · ••••c0de")
        #expect(model.credentialTitle("gone", language: .chinese) == "已删除的 key")
        #expect(model.credentialTitle(nil, language: .english) == "Choose a key")
    }
}
