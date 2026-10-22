import Foundation
import Testing

@testable import ThinktinKit

private let writer = ConversationFixture.writer
private let reviewer = ConversationFixture.reviewer

@MainActor
@Suite("对话页：输入框、停止、密码拦截")
struct ConversationComposerTests {
    @Test("发消息：输入框清空，新运行出现在最后（用户消息取自 Run.prompt），agent 回答完")
    func send() async throws {
        let mock = ConversationFixture.mock(autoReply: true)
        let model = ConversationModel(client: mock, instanceID: reviewer)
        await model.start()
        model.draft = "  看看 CI 为什么挂了  "
        #expect(model.canSend)
        await model.send()
        #expect(model.draft.isEmpty)
        let runID = try #require(model.lastSentRunID)
        #expect(model.turns.last?.runID == runID)
        #expect(model.turns.last?.items.first?.content.userMessage?.text == "看看 CI 为什么挂了")
        await mock.waitForPlayback()
        #expect(await eventually { model.turn(for: runID)?.state == .succeeded })
        #expect(ConversationFixture.replyText(model, runID).contains("要点一"))
    }

    @Test("有运行没结束：输入框空着时主按钮是停止，有字时是发送并提示排队；新消息排在后面")
    func queueAndStop() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        #expect(model.activeRunID == DemoData.postRunID)
        #expect(model.willQueue)
        #expect(model.composerAction == .stop)
        model.draft = "再帮我写个摘要"
        #expect(model.composerAction == .send)
        await model.send()
        let queued = try #require(model.lastSentRunID)
        #expect(model.turn(for: queued)?.state == .queued)
        #expect(model.activeRunID == DemoData.postRunID, "停止按钮停的是正在跑的那个，不是排队的")
        // 停止。
        await model.stop()
        #expect(await eventually { model.turn(for: DemoData.postRunID)?.state == .cancelled })
        #expect(mock.state.runs.first { $0.id == DemoData.postRunID }?.state == .cancelled)
        #expect(model.activeRunID == queued)
    }

    @Test("停止已经结束的运行（冲突）：拉一次最新状态，不提示错误")
    func stopFinished() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        mock.update { s in
            if let i = s.runs.firstIndex(where: { $0.id == DemoData.postRunID }) { s.runs[i].state = .succeeded }
        }
        await model.cancel(DemoData.postRunID)
        #expect(model.stopError == nil)
        #expect(model.runs[DemoData.postRunID]?.state == .succeeded)
    }

    @Test("32000 字上限：快到时显示字数，超了不能发；按去掉首尾空白后的 Unicode 标量数算")
    func lengthLimit() async {
        let model = ConversationModel(client: ConversationFixture.mock(), instanceID: writer)
        await model.load()
        model.draft = String(repeating: "字", count: 29_000)
        #expect(!model.showsLengthCounter)
        model.draft = String(repeating: "字", count: 31_000)
        #expect(model.showsLengthCounter && model.canSend)
        model.draft = "  " + String(repeating: "a", count: 32_000) + "\n"
        #expect(!model.isOverLimit && model.canSend)
        model.draft = String(repeating: "a", count: 32_001)
        #expect(model.isOverLimit && !model.canSend)
        model.draft = "   \n "
        #expect(!model.canSend)
    }

    @Test("密码拦截：命中就不发，建议名避开已有的条目；存好后引用放回输入框，再发出去的是引用")
    func interceptAndSave() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: reviewer)
        await model.start()
        let token = "ghp_" + String(repeating: "a1B2", count: 6)
        model.draft = "用这个令牌推送：\(token)"
        let runsBefore = mock.state.runs.count
        await model.send()
        #expect(mock.state.runs.count == runsBefore, "没发出去")
        let interception = try #require(model.interception)
        let entry = try #require(interception.entries.first)
        #expect(interception.entries.count == 1)
        #expect(entry.name == "github_2", "github 已经有了")
        #expect(entry.isStorable && !entry.looksLikeModelKey)
        model.editInterception(entry.id) { $0.purpose = "推送代码" }
        #expect(await model.saveSecret(entry.id))
        #expect(model.interception == nil, "都处理完了，弹层关掉")
        #expect(model.draft == "用这个令牌推送：[vault:github_2]")
        let saved = try #require(mock.state.vaultItems.first { $0.name == "github_2" })
        #expect(saved.instanceIDs == [reviewer])
        #expect(saved.purpose == "推送代码")
        await model.send()
        let sent = try #require(model.lastSentRunID)
        #expect(mock.state.runs.first { $0.id == sent }?.prompt == "用这个令牌推送：[vault:github_2]")
    }

    @Test("私钥存不进保险箱：只提示删掉；坚持发送带 allowSecrets 发出去")
    func privateKeyAndSendAnyway() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: reviewer)
        await model.start()
        model.draft = "部署用这个：\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
        await model.send()
        let interception = try #require(model.interception)
        #expect(interception.blockedEntries.count == 1)
        #expect(interception.storableEntries.isEmpty)
        #expect(interception.entries.first?.canSave == false)
        #expect(await model.saveSecret(try #require(interception.entries.first?.id)) == false)
        await model.sendAnyway()
        #expect(model.interception == nil)
        #expect(model.draft.isEmpty)
        let sent = try #require(model.lastSentRunID)
        #expect(mock.state.runs.first { $0.id == sent }?.prompt.contains("PRIVATE KEY") == true)
    }

    @Test("模型厂商的 key：提示添加为模型 key")
    func modelKey() async throws {
        let model = ConversationModel(client: ConversationFixture.mock(), instanceID: writer)
        await model.start()
        model.draft = "key 是 sk-ant-" + String(repeating: "x", count: 30)
        await model.send()
        let interception = try #require(model.interception)
        #expect(interception.hasModelKey)
        #expect(interception.entries.first?.name == "anthropic")
    }

    @Test("服务端返回 containsSecrets（本机没认出来）：同样弹拦截，只有服务端说的个数")
    func serverDetected() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        model.draft = "看着很普通的一句话"
        mock.failNext(with: .containsSecrets(count: 2))
        await model.send()
        let interception = try #require(model.interception)
        #expect(interception.entries.isEmpty)
        #expect(interception.serverCount == 2)
        #expect(interception.count == 2)
        #expect(!interception.isResolved)
        #expect(model.sendError == nil)
        model.dismissInterception()
        #expect(model.interception == nil)
        #expect(model.draft == "看着很普通的一句话", "输入框里的字还在")
    }

    @Test("存的时候重名（冲突）：提示，并换上一个不重复的名字")
    func nameConflict() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        model.draft = "password: hunter2hunter2"
        await model.send()
        let entry = try #require(model.interception?.entries.first)
        model.editInterception(entry.id) { $0.name = "github" }
        #expect(await model.saveSecret(entry.id) == false)
        let after = try #require(model.interception?.entry(entry.id))
        #expect(after.error?.isConflict == true)
        #expect(after.name == "github_2")
        #expect(!after.isSaving)
        // 名字不合规则时按钮不可用。
        model.editInterception(entry.id) { $0.name = "GitHub Token" }
        #expect(model.interception?.entry(entry.id)?.nameProblem == .invalidCharacters)
        #expect(model.interception?.entry(entry.id)?.canSave == false)
    }

    @Test("发送失败：显示错误，输入框里的字还在")
    func sendFailure() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        model.draft = "你好"
        mock.failNext(with: .network(message: "offline"))
        await model.send()
        #expect(model.sendError?.isOffline == true)
        #expect(model.draft == "你好")
        model.clearSendError()
        #expect(model.sendError == nil)
    }
}

@MainActor
@Suite("对话页：审批卡片、保险箱请求")
struct ConversationCardActionsTests {
    private func approvalItem(_ model: ConversationModel) throws -> ConversationItem {
        let id = try #require(model.pendingApprovalItemID(in: DemoData.postRunID))
        return try #require(model.items.first { $0.id == id })
    }

    private func option(_ id: String) throws -> ApprovalOption {
        try #require(DemoData.approvalOptions.first { $0.id == id })
    }

    @Test("批准：先过本机验证，再 decideApproval；卡片显示你批准了，agent 接着跑")
    func approve() async throws {
        let mock = ConversationFixture.mock()
        let gate = ScriptedBiometricGate(result: .approved)
        let model = ConversationModel(client: mock, instanceID: writer, biometricGate: gate)
        await model.start()
        let item = try approvalItem(model)
        await model.decide(item, option: try option("allow"), reason: "批准发消息")
        #expect(gate.reasons == ["批准发消息"])
        #expect(mock.state.approvals.first?.state == .approved)
        let card = try #require(model.items.first { $0.id == item.id }?.content.approval)
        #expect(card.resolution?.outcome == .approvedByUser)
        #expect(model.approvalErrors.isEmpty)
        await mock.waitForPlayback()
        #expect(await eventually { model.turn(for: DemoData.postRunID)?.state == .succeeded })
    }

    @Test("拒绝不用本机验证")
    func reject() async throws {
        let mock = ConversationFixture.mock()
        let gate = ScriptedBiometricGate(result: .failed)
        let model = ConversationModel(client: mock, instanceID: writer, biometricGate: gate)
        await model.start()
        await model.decide(try approvalItem(model), option: try option("reject"), reason: "")
        #expect(gate.reasons.isEmpty)
        #expect(mock.state.approvals.first?.state == .rejected)
    }

    @Test("本机验证取消了什么都不做；没通过提示一句、不批准；设备没法验证照常批准")
    func verification() async throws {
        let mock = ConversationFixture.mock()
        let gate = ScriptedBiometricGate(result: .cancelled)
        let model = ConversationModel(client: mock, instanceID: writer, biometricGate: gate)
        await model.start()
        let item = try approvalItem(model)
        await model.decide(item, option: try option("allow"), reason: "r")
        #expect(mock.state.approvals.first?.isPending == true)
        #expect(model.approvalErrors[item.id] == nil)
        gate.result = .failed
        await model.decide(item, option: try option("allow"), reason: "r")
        #expect(mock.state.approvals.first?.isPending == true)
        #expect(model.approvalErrors[item.id] == .verificationFailed)
        model.clearApprovalError(item.id)
        gate.result = .unavailable
        await model.decide(item, option: try option("allow_always"), reason: "r")
        #expect(mock.state.approvals.first?.state == .approved)
    }

    @Test("已经在别处处理过（冲突）：查最新记录，卡片显示结果，不提示错误")
    func decidedElsewhere() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        let item = try approvalItem(model)
        mock.update { s in
            s.approvals[0].state = .rejected
            s.approvals[0].decidedOption = "reject"
        }
        await model.decide(item, option: try option("allow"), reason: "r")
        #expect(model.approvalErrors[item.id] == nil)
        let card = try #require(model.items.first { $0.id == item.id }?.content.approval)
        #expect(card.resolution?.outcome == .rejectedByUser)
    }

    @Test("审批的状态以记录为准：打开页面时查一次 getApproval，已过期的显示已过期；平台判的超时事件也是")
    func expired() async throws {
        let mock = ConversationFixture.mock()
        mock.update { s in s.approvals[0].state = .expired }
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        let card = try #require(model.items.compactMap(\.content.approval).first)
        #expect(card.resolution?.outcome == .expired)

        let live = ConversationFixture.mock()
        let other = ConversationModel(client: live, instanceID: writer)
        await other.start()
        live.expireApproval(DemoData.pendingApprovalID)
        #expect(
            await eventually {
                other.items.compactMap(\.content.approval).first?.resolution?.outcome == .expired
            })
    }

    @Test("没关联上审批记录的卡片：不能直接决定，提示去审批中心")
    func notLinked() async throws {
        var state = DemoData.state()
        // 老的服务端：事件里没有 approval_id，审批记录也没有请求 id、标题对不上。
        state.events[writer] = state.events[writer]?.map { e in
            guard e.kind == .permissionRequested, var o = e.payloadValue?.objectValue else { return e }
            o.removeValue(forKey: "approval_id")
            var copy = e
            copy.payloadJSON = JSONValue.object(o).compactString()
            return copy
        }
        state.approvals = []
        let model = ConversationModel(client: ConversationFixture.mock(state: state), instanceID: writer)
        await model.start()
        let item = try approvalItem(model)
        await model.decide(item, option: try option("allow"), reason: "r")
        #expect(model.approvalErrors[item.id] == .notLinked)
    }

    @Test("保险箱请求：填好存进保险箱，卡片跟着事件变成已填好；拒绝；过期的按记录显示")
    func vaultRequests() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: reviewer)
        await model.start()
        let card = try #require(model.items.compactMap(\.content.vaultRequest).first)
        #expect(model.vaultStatus(for: card) == .pending)
        #expect(model.vaultRecord(for: card)?.purpose == "发布 @thinktin/sdk 0.4.0 到 npm")
        #expect(await model.fulfillVaultRequest(card.requestID, username: "", password: "") == false, "密码不能空")
        #expect(await model.fulfillVaultRequest(card.requestID, username: " bot ", password: "npm_token_123"))
        #expect(mock.state.vaultItems.contains { $0.name == "npm" })
        #expect(await eventually { model.items.compactMap(\.content.vaultRequest).first?.status == .fulfilled })
        // 再处理一次：已经处理过（冲突），按记录显示，不算出错。
        #expect(await model.declineVaultRequest(card.requestID) == false)
        #expect(model.vaultErrors[card.requestID] == nil)
        #expect(model.vaultRecords[card.requestID]?.status == .fulfilled)
    }

    @Test("保险箱请求：拒绝；记录过期了显示已过期")
    func vaultDeclineAndExpiry() async throws {
        let now = Date()
        var state = DemoData.state(now: now)
        state.vaultRequests[0].expiresAt = now.addingTimeInterval(-60)
        let mock = ConversationFixture.mock(state: state)
        let model = ConversationModel(client: mock, instanceID: reviewer, now: { now })
        await model.start()
        let card = try #require(model.items.compactMap(\.content.vaultRequest).first)
        #expect(model.vaultStatus(for: card) == .expired)

        let fresh = ConversationFixture.mock()
        let other = ConversationModel(client: fresh, instanceID: reviewer)
        await other.start()
        #expect(await other.declineVaultRequest(DemoData.npmVaultRequestID))
        #expect(fresh.state.vaultRequests.first?.status == .declined)
        #expect(await eventually { other.items.compactMap(\.content.vaultRequest).first?.status == .declined })
    }
}

@MainActor
@Suite("对话页：举报")
struct ContentReportModelTests {
    @Test("举报一条回复：带事件序号、原因和说明；没选原因不能提交")
    func reportMessage() async throws {
        let mock = ConversationFixture.mock()
        let conversation = ConversationModel(client: mock, instanceID: writer)
        await conversation.start()
        let reply = try #require(conversation.items.first { $0.content.assistantText != nil })
        let target = try #require(ContentReportTarget(item: reply))
        guard case .message(let runID, let seq) = target else {
            Issue.record("不是回复：\(target)")
            return
        }
        #expect(runID == reply.runID && seq == reply.eventSeq)
        let model = ContentReportModel(client: mock, target: target)
        #expect(!model.canSubmit)
        model.reason = .misinformation
        model.note = "  数字不对  "
        #expect(await model.submit())
        let report = try #require(mock.state.reports.first)
        #expect(report.eventSeq == seq)
        #expect(report.reason == .misinformation)
        #expect(report.note == "数字不对")
        #expect(!model.canSubmit, "提交过了")
    }

    @Test("产出物、整个运行；用户消息、状态行不能举报；说明超长不能提交")
    func targets() async throws {
        let mock = ConversationFixture.mock()
        let conversation = ConversationModel(client: mock, instanceID: writer)
        await conversation.start()
        let artifact = try #require(conversation.items.first { $0.content.artifact != nil })
        #expect(
            ContentReportTarget(item: artifact)
                == .artifact(runID: DemoData.weeklyRunID, artifactID: DemoData.weeklyArtifactID))
        let prompt = try #require(conversation.items.first { $0.content.userMessage != nil })
        #expect(ContentReportTarget(item: prompt) == nil)
        let model = ContentReportModel(client: mock, target: .run(DemoData.weeklyRunID))
        model.reason = .other
        model.note = String(repeating: "长", count: ContentReport.maxNoteLength + 1)
        #expect(model.isNoteTooLong && !model.canSubmit)
        model.note = ""
        #expect(await model.submit())
        #expect(mock.state.reports.first?.target == .run)
    }

    @Test("举报失败（限流）：显示错误")
    func failure() async {
        let mock = ConversationFixture.mock()
        let model = ContentReportModel(client: mock, target: .run(DemoData.weeklyRunID))
        model.reason = .harmful
        mock.failNext(with: .api(status: 429, code: .rateLimited, message: "slow down", retryAfterSecs: 60))
        #expect(await model.submit() == false)
        #expect(model.error?.isRateLimited == true)
    }
}
